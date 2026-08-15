# M16 — Rounds and the lobby

Planned 2026-08-15. **Proves: the game has a shape.** Everything up to here is a
bridge you walk along until you fall off it. This milestone gives the walk a
beginning, an end, a score, and a place to stand between attempts — and it does
it with a structure that is also the in-game menu, because a lobby where players
gather and choose is the only menu a co-op game of this kind should need.

The loop:

```
  LOBBY  ──all players on the checker──▶  ROUND  ──first player on the next──▶  CLOSING (30 s)
    ▲                                                                                │
    └──────────────────────  SCOREBOARD  ◀───────────────────────────────────────────┘
```

---

## Part 1 — The rules

These are the constraints the whole milestone is built to satisfy. They are here
first because most of them are cheap to honour while writing the code and
expensive to retrofit, and because several are restatements of traps this project
has already paid for once (`CLAUDE.md`).

### R1. The round state is ONE enum, on the host, on the wire

`LOBBY / ARMING / RUNNING / CLOSING / SCORING`, owned by `GameWorld`, replicated
in the snapshot beside `tick`. **No client ever infers which state it is in from
where its body is standing.**

This is the rule everything else hangs off. The moment two machines can disagree
about whether the round has started, they disagree about whether the wall is up,
whether a fall costs you the round, and what the scoreboard says. Position-derived
state gives you exactly that: four clients, four opinions, all of them locally
consistent.

It is also what makes this a menu. A menu is a state machine you can see; if the
state is real and replicated, the menu is a view of it and every future console,
vote and selection screen is a field on the same enum rather than a new system.

### R2. All players transition together, and the check is POLLED

The barrier opens on a predicate over **every** player, evaluated every tick —
never in the handler that fired when somebody stepped on the strip.

This exact bug has already cost this project a day: `CLAUDE.md`, *"a readiness
check that only runs in an event handler never runs again"* — the net harness
asked "is everyone spawned?" from `peer_connected`, saw an incomplete roster
once, and reported not-ready forever. "Is everyone on the checker?" is the same
question with the same failure mode, and the symptom would be a wall that never
opens with every player standing on the strip looking at it.

### R3. The wall is a collider the sim owns; the fade is a view

The barrier is authoritative geometry, created and destroyed by the state
machine, on the players layer and nothing else. The transparent blue and its
fade are a mesh that follows.

Same data/view split as the grid, for the same reason — and specifically because
**a wall that exists only as a mesh is a wall a client walks through.** Two
`CLAUDE.md` traps apply directly: check the collision MASK before debugging the
behaviour (four bugs so far), and a body must collide with what it is meant to
stop.

### R4. The checker strip is AUTHORED, never a computed z

A new deck kind in the `.seg` format. The round machine asks the grid *"which
rows are gates"* and never does arithmetic on a position.

A hardcoded row cannot survive the segment pool — the bridge is assembled from a
seed and segments vary in length, so the only stable name for a place is the cell
the author drew it in. This is the same reason spawns, hats, specials and mounds
are all glyphs.

### R5. Spawn behaviour is a property of the STATE, not a third code path

One `respawn_point(peer)` that branches on the round state. In `LOBBY` you come
back **in the lobby, immediately** — no drone, no wipe, no checkpoint. In
`RUNNING` you get today's behaviour unchanged.

Stated as a rule because the tempting implementation is a new `if in_lobby` beside
the drone and the wipe, and this project already knows what that costs: the HUD
grew a second copy of one decision and drew two bars for a month
(2026-08-15). Two places expressing one rule is two places for it to differ.

### R6. Nothing about a round may live in a timer only the host can see

The 30-second countdown and the round clock are sim state, carried like
`state_timer` already is. Every client draws them, so every client must have them.

### R6a. FIVE MINUTES IS A TARGET, SO THE CLOCK MEASURES AND NEVER FIRES

Decided 2026-08-15. The five minutes is an **authoring budget**, not a mechanism:
nothing in the state machine reads the round clock, and a section ends when the
party reaches the next strip and at no other time.

The clock is still sim state and still on the wire, because **a target nobody
measures is a target nobody hits.** It is what tells an author their section is
really a ninety-second sprint or a twelve-minute slog, and it belongs on the
scoreboard for the same reason. Keeping it visible while keeping it powerless is
the whole point — the moment it can end a round it stops being a measurement of
the design and starts being part of it.

The consequence has to be stated because it is now load-bearing: with no cap,
**reaching the next strip is the only way forward, so "everyone is out" is the
only other way a round can end.** See question 1 below, which is no longer
optional.

### R7. "Made it" is recorded WHEN IT HAPPENS, never re-derived at scoring time

The instant a player touches the strip, mark them. Do not ask "who is standing on
the checker?" when the scoreboard opens — by then the closing sequence has moved
people, and the answer is about where bodies ended up rather than what players
did.

### R8. Scoring is a criterion object, not an if-chain

One `RoundScorer` with a ranking function; hats-carried is the first
implementation. The user has already said each future game type gets its own
criteria, and the difference between "a scorer per mode" and "a growing if-chain"
is decided now, while there is exactly one.

### R9. The lobby is a segment like any other

Same `.seg` format, same loader, same streaming. It is not a special scene, it is
not a menu screen, and it has no code of its own. The only thing that makes it a
lobby is that the round plan put it between two sections.

### R10. The section is a SLOT filled by name

The loop is `lobby → section → lobby → section`. Which section is a string the
round plan holds. Today there is one and it repeats; the whole point of naming it
is that "players vote for the next one" is later a value change, not a structural
one.

---

## Part 2 — What this replaces

**Checkpoints and the wipe are subsumed, and should go.** `checkpoint_row`,
`checkpoint_index`, `_bank_checkpoint` and `_restart_at_checkpoint` exist to
answer "where does the party restart" for an endless bridge. With rounds, the
answer is always *the lobby you came from* — which is authored, obvious to the
player, and not derived from anything.

That is a genuine simplification and it should be taken deliberately in Step 4
rather than left to rot beside the new machinery. Note what it also deletes: the
integer-division checkpoint interval, and the 2026-08-15 bug class where a bogus
"how far has the party got" answer put everyone thousands of rows up the bridge.
**Rounds remove the question that bug was an answer to.**

`_extend_run` stays but changes masters: the run is no longer extended by how far
the front player walked, it is extended by the round plan appending the next
lobby or section. That is strictly more predictable and removes the feedback loop
between player position and world size.

---

## Part 3 — The steps

Eight slices. Each one is separately gateable and each says what it *proves*,
because a step that cannot fail has not been specified.

### Step 1 — The checker strip in the `.seg` format

**Proves:** a text file can say "the round boundary is here".

- New deck kind `GATE` with glyph `=`, alongside `. _ ~ /` in `DECK_GLYPHS`.
  Walkable deck in every respect — it is scenery with a name, not new physics.
- Black/white checker: `deck_colour` gains the kind, and gate cells alternate
  `GATE_LIGHT`/`GATE_DARK` on the same `(x + z)` parity the brown deck uses. The
  parity rule is the thing that makes distance readable (see `grid_config.gd`);
  the strip changes the palette, not the rule.
- Validator: a gate row must span the **full width** with no holes. A strip with
  a gap in it is a strip players can walk around, and every barrier rule
  downstream assumes it cannot be flanked.
- Grid API: `gate_rows() -> Array[int]`, `is_gate_row(row)`, and
  `gate_after(row)` for "the next boundary up-bridge of here".

**Gate:** a segment with a strip parses; the strip is solid and walkable; the
colours alternate; a strip with a hole in it is REFUSED with a message naming the
row. That last one is the half of the test that says something is impossible —
`CLAUDE.md`'s "half a gate is not a gate".

### Step 2 — The round state machine, headless, invisible

**Proves:** the sequence is right before anything can be seen.

- The enum (R1), the transitions, the polled predicates (R2), the countdown and
  round clock as sim state (R6), `reached_gate` per peer (R7).
- The round clock ACCUMULATES AND DECIDES NOTHING (R6a). Worth writing the
  assertion that says so: a round left running past five minutes changes state on
  the tick the party reaches the strip and on no earlier one. That is the test
  that stops a cap being added later by accident, and it costs one phase.
- No walls, no meshes, no HUD. Bodies are placed by the test and the machine is
  asserted on.

**Gate:** the full sequence over one loop. Specifically including:
one player on the strip does **not** advance (the barrier is a barrier); the
last player arriving advances it on that tick; a player who steps on during
`CLOSING` is still recorded as having made it; the countdown runs on the clock
rather than on a frame count; and **the round clock passing five minutes does
nothing at all**.

The last one is the half of the gate that says something is IMPOSSIBLE, and this
project has a note about skipping those: `test_ramp_traversal` asserted a lone
player could not climb the steep ramp and nothing asserted a shoved one could, so
a wall nobody could climb passed it for months.

### Step 3 — The barrier

**Proves:** the transition is enforced, not merely announced.

- A sim-owned collider spanning the full width at a gate row, on the players
  layer only (R3). Two placements — ahead of the party during `LOBBY`, behind
  them once `RUNNING` — flipped by the state machine and by nothing else.
- The blue fade is a `MeshInstance3D` following the collider's existence, with
  its alpha driven by how recently the state changed.

**Gate:** a player walking into a raised barrier does not cross it (measured as a
position, over several ticks — one sample cannot see a body that squeezes through
later); it stops blocking on the state change; and it is present *behind* the
party in `RUNNING`. Non-player bodies — balls, rushers, grenades — are checked
explicitly to pass or not pass, whichever is decided, because "what does the wall
stop" is a design question that a collision mask will otherwise answer by
accident.

### Step 4 — Spawn by state, and the retirement of the checkpoint

**Proves:** falling means different things in the two states, from one rule.

- `respawn_point(peer)` branching on round state (R5).
- In `LOBBY`: immediate return, in the lobby, with no drone delay and no wipe.
  The lobby is a place to stand around; falling off it should cost a walk back,
  not a ceremony.
- In `RUNNING`: today's drone-and-teammate behaviour, unchanged — the existing
  tests are the gate on that.
- Delete `checkpoint_row`, `checkpoint_index`, `_bank_checkpoint`,
  `_restart_at_checkpoint` and the wipe's checkpoint arithmetic. A wipe becomes
  "the round ended badly": everyone returns to the lobby they started from, which
  is the same code path as the closing sequence.

**Gate:** `test_checkpoint_return` and `test_spawn_fall` are rewritten against
the new rule rather than deleted — they encode two real bugs and the claims
survive the change ("a return never puts you past where the party got", "walking
off the back does not build the bridge forever").

### Step 5 — The closing sequence

**Proves:** the round ends the same way for everyone.

- First player on the next strip starts the 30 s countdown; a barrier holds
  everyone *out* of the next lobby until it expires.
- On expiry: the barrier flips, everyone on the strip walks through, everyone
  else is respawned in the lobby immediately and marked as not having made it.

**Gate:** a party split across the boundary at expiry ends up entirely in the
lobby, with the two groups distinguishable in the round record. And the
countdown is asserted on **every tick of its duration**, not at its end — the
2026-08-13 rusher bug is precisely this shape ("a phase that samples ONE frame
cannot see a bug seven frames later").

### Step 6 — The scoreboard

**Proves:** the round produced a result players can read.

- `RoundScorer` (R8) with the hats criterion: `N hats > 1 hat > made it >
  didn't`.
- A model function first, a panel second — the same split as `hud_model.gd`,
  which is what makes the ranking testable in milliseconds.

**Gate:** the ranking as a **table of cases** over the pure function, including
the ties (two players with the same hat count; everybody with none). The view
test only proves the panel builds and runs — `test_hud_view`'s job, not the
ranking's.

### Step 7 — The loop and the section slot

**Proves:** it goes round, and the section is a choice waiting to be offered.

- A round plan: `[lobby, section, lobby, section, …]`, section named by string
  (R10), appended by the plan rather than by player position.
- The demo level becomes the first named section. A second one — even a trivial
  one — is authored in this step, because **a one-of-something test cannot see a
  many-of-something bug** and a slot with exactly one occupant proves nothing
  about a slot.

**Gate:** two complete loops in one session, with different sections in each, and
the world's segment count growing by exactly what the plan appended.

### Step 8 — The lobby as a place

**Proves:** the space between rounds is worth standing in.

- Authored racks of hats and specials, using the existing `^` and pickup glyphs.
  The `playtest_bridge.seg` rack at z2 is the precedent and its header already
  says why that arrangement reads as a choice rather than a conveyor.
- What crosses the gate is what you are carrying — which makes lobby choice a
  real decision under the hat criterion.

**Gate:** a hat picked up in the lobby is still worn on the far side of the
barrier, and counts in that round's score.

---

## Part 4 — Open questions, named rather than assumed

1. **Does a round end when everyone is out?** *Promoted from "open" to "must be
   answered in Step 2" by the five-minutes-is-a-target decision (R6a): with no
   clock to fire, this is the ONLY terminator other than reaching the strip, so
   without it a wiped party has no way out of a section at all.*
   Recommendation: it ends the round and scores it, everyone marked as not having
   made it. That is a nicer failure than a restart, it is one transition rather
   than a new subsystem, and it reuses the closing sequence Step 5 already
   builds. It also means the wipe stops being a special case and becomes the
   ordinary bad ending.
2. **What does the barrier stop besides players?** A grenade, a plinko ball and a
   rusher each have an obvious-but-different right answer. Step 3 has to pick;
   the plan does not.
3. **Do specials cross the gate?** Hats do (they are the score). A special
   carried out of the lobby makes the lobby a stockpile — which is exactly the
   reasoning already recorded in `_restart_at_checkpoint` for why a wipe strips
   held weapons.
4. **A player who joins mid-round.** They join the party's state; in `RUNNING`
   they are marked as not-yet-reached and are subject to the leash. Cheap, but it
   should be a decision rather than whatever falls out.
5. **What counts as "everyone is out"?** Today's wipe condition is every player
   `_returning` — which was itself narrowed once, after a playtest found the run
   restarting on the same tick the last player caught a ledge. Rounds inherit
   that reasoning: the round ends when nobody has a chance left, not when nobody
   is standing.

---

## What this does not do

No consoles, no voting, no per-mode criteria beyond hats, no unloading behind the
party. All four are things this structure is *shaped for* — a console is a
content glyph that writes to the round plan; a vote is a field on the state; a
criterion is another scorer — and none of them is needed to prove the loop works.
