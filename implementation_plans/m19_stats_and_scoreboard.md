# M19 — stats between lobbies, and the screen that shows them

A round already ends in a board. Today that board carries four fields — peer,
name, hats, made_it — and renders as a few small labels tucked inside the HUD.
This milestone turns the space between two lobbies into a **measured** thing and
gives it the screen it deserves.

Two halves, and they are separable on purpose. The **counters** are simulation:
host-authoritative, replicated, and worth building even if the screen never
changed. The **screen** is a view of them, and if the counters are wrong a
beautiful screen shows wrong numbers confidently.

---

## What already exists, so nothing here is rebuilt

| | |
|---|---|
| `RoundMachine.rank_entries` | the ranking rule, already a pure function over a table |
| `RoundMachine.board` | built at `_begin_scoring`, held so the lobby can show it |
| `_round_sync` RPC | sends the board reliably on every state change |
| `Hit.source` | **every hit already knows whose it is** — a peer id, or 0 for the world |
| `receive_hit` per body | one place per target kind where harm is actually applied |
| `NetworkManager.steam_avatar(id)` | the portrait, already used by the HUD's friend rows |
| `DebugSettings.OPTIONS` | the registry pattern this milestone copies wholesale |

The single most important of those is `Hit.source`. The damage-model refactor
already made every source build one `Hit` and hand it over, which means
attribution — who shot whom, friendly or otherwise — is a field that exists
rather than a system to invent.

---

## The ranking rule does not change

Rank stays **N hats > 1 hat > made it > didn't**, computed by `rank_entries`,
with peer id as the stable tie-break. The stats below are *not* inputs to rank.
That separation is the point: the rank is what the round was for, and the stats
are what happened during it. A game where "most shots fired" moves your position
is a game about shooting.

**One decision to make before phase 3** (see Open questions): `rank_entries`
breaks a genuine tie by peer id, so two players with identical hats and identical
survival get 1st and 2nd rather than joint 1st. On a screen that prints "1st"
next to a face, that reads as a claim rather than an arbitrary sort.

---

## Phase 0 — the registry, the counters, and the wire

**The registry first, because it is what makes every later stat one line.**
`scripts/sim/stat_registry.gd`, in exactly the shape `DebugSettings.OPTIONS`
already proved:

```gdscript
const STATS := {
    "shots_fired": {
        "label": "Shots fired", "best": MOST, "common": true,
        "help": "Counted where the round is SPAWNED, on the host.",
    },
    "hits": {
        "label": "Hits", "best": MOST, "common": true, "percent_of": "shots_fired",
    },
    "deaths": { "label": "Deaths", "best": LEAST, "common": true },
    ...
}
```

`best` is `MOST` or `LEAST` and it is not decoration — it is what the superlative
selection reads, and it is the difference between "0 is a non-result" and "0 is
the best possible score". Adding a stat is one entry here plus one `+= 1` at the
line where the thing happens, and **nothing else**: no UI change, no wire change,
no per-stat replication code. That is the property to protect.

**A `RoundStats` object on GameWorld**, host-only: `peer -> {key -> int}`.
Cleared where `reached.clear()` already happens, in `_cross` on the way into
RUNNING — the same tick the round begins, so there is one definition of "this
round" rather than two that can drift.

**On the wire it rides the board.** `_round_sync` already sends `board: Array`
reliably on state change; each entry gains a `stats` dictionary. Four players by
twenty ints, once a round, is nothing — and the alternative (a second RPC with
its own timing) is a way for the board and its stats to arrive out of step.

**Clients never compute a stat.** A client that counted its own shots would
disagree with the host about any round where a packet was late, and two players
would be looking at two different scoreboards. The host counts; everyone reads.

*Phase 0 ships with two or three cheap stats wired end to end and no UI.* Proving
the pipe on `shots_fired` and `deaths` before instrumenting fifteen things is the
same argument that made the lobby the pilot generator in M17.

---

## Phase 1 — counting honestly

This phase is mostly about *where* the `+= 1` goes, and CLAUDE.md has already
paid for most of these lessons.

**"Attempted" is not "delivered."** A send function that returns a sequence
number whether or not anyone was listening once produced a "12/12 landed" counter
that was measuring sends. So:

- `shots_fired` increments at the line that **spawns the round**.
- `hits` increments **on the receiving side**, at the line that consumes the hit.

Anything else makes the hit percentage a lie in exactly the situation it is most
interesting — a firefight against cover.

**Damage is counted as DELIVERED, not as intended.** A shield blocks; cover
stops a bullet; a body at full health takes less than the hit's `amount` on the
last point. So `receive_hit` should **return how much was actually applied**, and
every call site funnel through one `GameWorld` helper that records it. One place,
for the same reason `Hit` exists at all: five sources against four targets is
twenty places to forget.

**Friendly versus enemy falls out of the target, not the source.** `hit.source`
is the peer; whether it counts as `friendly_damage` or `enemy_damage` is decided
by what received it. `source == 0` is the world and is recorded against nobody.

**A kill is attributed to whoever delivered the last point** — which needs the
returned-damage value above, so this cannot be built before it.

**Deaths are counted at the TRANSITION, never by polling.** CLAUDE.md: *a value
destroyed when it reaches its terminal state is never observed in it*. A loop
watching for `health == 0` will miss deaths, because the body is already in the
down state by the time anything looks.

**Rescues count on the rescuER**, at `_tick_revive`'s `body.revive()` line.

The seven **common** stats, which appear on every scoreboard:

| stat | direction | notes |
|---|---|---|
| shots fired | most | at the spawn line |
| hits | most | at the receive line, shown with a % |
| enemy damage | most | delivered, target is a rusher/gunner |
| enemy kills | most | last point delivered |
| deaths | **least** | at the transition |
| friendly damage | most | delivered, target is a player |
| friendly rescues | most | at `revive()` |

**Hit % with zero shots is not 0%.** It is "—". A player who never fired has no
accuracy, and printing 0% next to their name says they missed everything.

---

## Phase 2 — the superlatives, as a pure function

This is the phase most likely to be got subtly wrong, and the one that is
cheapest to get right, because it is arithmetic over a table. `rank_entries` is
already the model: a pure static function that takes an array of dictionaries and
returns an ordering, testable as a table of cases rather than by playing a round.

**The rule, stated precisely:**

1. For each stat in the registry, find the best value across the party, using the
   stat's own `best` direction.
2. A player **wins** the stat if their value equals that best value. Ties all win
   — the ask is "won *or tied for* first".
3. **Drop a win on a default value, unless the direction is LEAST.** Nobody wants
   "most dashes: 0". But "fewest deaths: 0" is the best score available and is
   exactly the thing worth saying.
4. **Drop a win the whole party shares.** If all four players tied at the same
   value, nothing distinguishes anybody and four identical badges is noise. *(This
   is the one rule not stated in the ask — see Open questions.)*
5. Each player keeps **up to three**, ordered **rarest first**: a stat won
   outright beats one tied two ways, which beats one tied three ways. Registry
   order is the stable tie-break, for the same reason `rank_entries` falls back to
   peer id — two clients showing different badges is a disagreement about the
   round.

Written as `StatRegistry.superlatives(stats_by_peer) -> {peer: [keys]}`, with no
reference to the world, the HUD or the network. Which means the table test can
say things like: *three players on 0 dashes and one on 1 gives one badge;
everybody on 0 gives none; everybody on 4 gives none; two on 4 and two on 1 gives
two badges, each marked as a tie.*

The long tail from the ask — most hats worn, most hats lost, most specials used,
most dashes, most healed, and whatever follows — is **phase 4**, and by then each
is one registry entry and one increment.

---

## Phase 3 — the screen

A new `ScoreScreen` Control, not a bigger `_board_panel`. The current board is a
`VBoxContainer` of small labels living inside the HUD's round panel; what is
being asked for is a different object that happens to appear at the same moment.

- **Three-quarters of the screen**, centred, over a scrim.
- **The HUD hides while it is up.** Not dimmed — hidden. It is the same instinct
  that moved the debug console out of the top corner yesterday: a panel that
  covers the numbers you are reading is worse than no panel.
- **Per player: avatar, name, rank.** The portrait comes from
  `NetworkManager.steam_avatar` exactly as the HUD's friend rows already do.
- **The common block**, seven rows, with the leader in each marked.
- **The badges**, up to three per player, from phase 2.
- Shown for `SCORE_SECONDS` — the state already exists and already has a clock.

**Two traps that this project has already paid for, and both apply here:**

*A dev box has Steam and the gate does not.* `steam_avatar` returns a texture
beside a running client and null on CI, so no assertion may say "the portrait is
there". Assert the **relationship**: `face.visible == (face.texture != null)`.
The same test went green in the gate and red on the dev box once already, in the
other direction.

*The headless viewport is 64×64.* Any assertion about where something sits on
screen is a statement about the harness. Split the layout maths into a pure
function taking an explicit screen size, assert *that* at 1280×720, and leave the
placement to Godot.

---

## Phase 4 — the long tail

One registry entry and one increment each. Candidates from the ask plus the ones
the game already has state for: hats worn, hats lost, specials used, dashes,
healed, rescued (the receiving end of rescues), falls, ledge grabs, blocks with
the shield, terrain destroyed, furthest row reached, time spent downed.

The point of the phasing is that this list can grow at playtest speed, from a
playtest, without touching the wire or the screen.

---

## What to test, and what not to bother testing

The valuable tests here are almost all on **pure functions**, which is a
deliberate consequence of phase 2's shape:

- `superlatives()` as a table: default-value wins dropped, LEAST-wins kept at
  zero, ties marked, the cap at three, rarest-first ordering, party-wide ties
  dropped.
- `rank_entries` unchanged — it has tests; they should still pass untouched, which
  is itself the assertion that rank did not quietly grow a stat input.
- **Shots > hits when firing into cover.** The one test that catches the
  attempted-versus-delivered bug, and it has to be a played scenario rather than a
  table, because the whole claim is about *where* the counter sits.
- **A shield blocking records zero damage delivered**, not a full hit.
- **Stats are empty at the start of a round and non-empty at the end** — the reset
  is in `_cross`, and a reset that runs at the wrong moment produces a scoreboard
  covering two rounds, which nobody would notice by looking.
- **A client's board matches the host's** over ENet, since the whole design rests
  on clients never computing a stat. Next free port is **28786**.

---

## Open questions — worth deciding before phase 2

1. **Joint ranks.** Two players on identical hats and identical survival are
   ordered by peer id today. On a screen printing "1st" and "2nd" beside faces,
   should a genuine tie show as joint 1st? *(Recommendation: yes — the tie-break
   exists to make the ORDER deterministic, not to invent a winner.)*
2. **Party-wide ties as badges.** Rule 4 above drops a superlative everybody
   shares. With two players that fires often — "fewest deaths: 0" for both. *(This
   is the rule I added that the ask did not state; it is the one most likely to be
   wrong, and it is a one-line change either way.)*
3. **Does a wiped round still show a full board?** It does today, and the stats
   would be real. Worth confirming that is wanted rather than a blank "you lost".
4. **Solo.** Every superlative is won by the only player, and every one is a
   party-wide tie. Rule 4 makes a solo scoreboard show no badges at all, which is
   probably right and is worth saying out loud.
