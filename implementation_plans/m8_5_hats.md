# M8.5 — Hats

**Status: proposed, 2026-08-08. Not started.**

**Proves:** there is a reason to take a risk you did not have to take.

Everything in the game so far is about *surviving* the bridge. Hats are the first
system that rewards doing something optional and stupid, and they are the
cheapest available answer to two exit criteria the rest of the roadmap does not
directly serve: **A2** (twenty minutes without being asked to keep going) and
**A3** (one laugh per session at an outcome nobody chose). A tower of five hats
exploding across the deck because someone clipped a plinko ball is exactly A3,
and it costs a fraction of what a new obstacle costs.

---

## The framing that decides whether this is cheap

A hat looks like a cosmetic. It is not: it is **carried, contested, droppable,
scoreable state that belongs to a player and is not part of their body.** The
game has no such channel today. Player state is `capture_state()` (per-tick,
predicted, reconciled); world state is grid cells and stone bodies. A hat is
neither.

So the real deliverable is **the carried-item channel**, and hats are its first
and simplest client. Hearts (M5), specials (M12) and anything else picked up
later are the second and third. Build it as hats-only and every one of those
reopens this milestone; build it as the channel and they are each an afternoon.

That framing also sets the boundary: this milestone builds pickup, carry, stack,
drop and bank. It does **not** build "an item that does something when you use
it" — that is M12's problem and hats deliberately do not need it.

---

## What a hat is

One record, in exactly one of four places. This is the whole model:

| place | data | notes |
|---|---|---|
| `WORN` | `owner_peer`, `stack_index` | drawn on the head, no collider |
| `FLYING` | `position`, `velocity` | just dislodged, arcing; **not collectable** |
| `LOOSE` | `position` | settled on the deck, collectable |
| *gone* | — | fell below `FALL_KILL_Y`, or culled behind the window |

Plus a `style_id` that travels with the hat forever. That last field is the one
that makes the system funny rather than administrative: **you keep wearing the
hat you stole**, visibly, and everyone can see whose it was. Do not reset style
on pickup.

A hat is a **free sim body**, not grid-resident data — unlike stones, hearts and
shooters. It has to be, because a dislodged hat arcs through the air and lands
wherever it lands; forcing it into a cell record would mean two representations
of the same object and a conversion between them on every tumble. An authored
loose hat is simply a hat body spawned at a cell at segment load. One
representation, three modes.

**Collision layer: world only.** A hat collides with deck, walls and ramps so it
lands and slides; it collides with **nothing else** — not players, not stones,
not other hats, not plinko balls. Three reasons, and all three are load-bearing:

1. A hat you can stand on is a ladder, and a stack of hats is a staircase past an
   authored ascender gate (`bridge_grid.md`, E1b).
2. B1 requires two peers to agree on world state after a scripted sequence.
   Every additional body in the contact graph is another chance for the contact
   solver to order things differently on two machines — for an object whose
   entire purpose is decorative.
3. Two hats spawned at the same point during a dislodge would hit the coincident-
   bodies trap in `CLAUDE.md` and depenetrate through the floor.

Pickup is therefore **a host-side radius test, not a collision callback.**

---

## The rules

### Picking up

A player whose feet are within `HAT_PICKUP_RADIUS` of a `LOOSE` hat wears it,
placed on **top** of their stack.

- Allowed in `WALK` and `SHOVE`. A dash down a line of loose hats collecting all
  of them is one of the better moments this milestone can produce, and it costs
  nothing to allow.
- Refused in `TUMBLE`, `LEDGE_HANG`, `DOWNED`, and both bus states. A tumbling
  player scooping their own hats back up as they roll through them removes the
  entire cost of the tumble.
- Refused while the hat is `FLYING`, and for `HAT_SETTLE_GRACE` after it lands.
  Same reason: without it, a dislodge and a re-collect are the same event.
- Refused at `HAT_MAX_STACK`.

**Exclusivity (the B8 shape).** Two players reaching one hat: exactly one gets
it. Nearest to the hat wins; **ascending peer id breaks a tie**, and the tie is
not rare — it is what happens when two players are symmetric about a hat, which
is precisely the situation a race produces.

**Resolve pickups in their own pass, after every body has stepped.** Not inline
in the step loop. `GameWorld._carry_order()` is a topological sort over who is
standing on whom, so the order players step in *changes* depending on the stack —
which would mean a player being carried systematically wins or loses hat
contests depending on who they happened to be standing on. That is an
ordering-dependent gameplay outcome hiding inside a function written for an
entirely different reason.

### Stacking

Hats stack visually on the head, bottom-first, `HAT_HEIGHT` apart.

**The collider does not change.** `player.tscn`'s cylinder is 0.9 m half-height
and M3's riding rules, the `_find_carrier` foot probe and `FOOT_PROBE` are all
denominated in it. A hat stack that grew the collider would silently change how
players stand on each other, mid-run, per hat. Hats are worn on a visual
attachment node and the physics body never learns they exist.

**And the stack leans** (added after playtest). Each hat tilts up to
`HAT_LEAN_MAX_DEG` (5°) against the one *below* it and the frames compose, so a
five-stack curves to 25° at the top and the top hat swings out past the head. A
stack that tilted as one rigid piece would be a rod on a hinge, which is what it
already looked like; the accumulation is the whole effect.

The lean is a **second-order spring per hat, driven by an impulse** proportional
to the wearer's change in velocity — not a joint, and not a force proportional to
acceleration. Both of those are deliberate:

- **Not a joint.** `ConeTwistJoint3D` gives a *limit*, not a lean; how far a hat
  tips inside its swing span falls out of masses and softness rather than being
  the number that was asked for. It would also un-freeze five bodies per player
  and put them back in the contact graph — which is exactly what the collider
  rule above exists to prevent — and it would anchor a solver chain to a
  `CharacterBody3D` that teleports up to 0.9 m per tick during a dash. Nothing is
  lost by faking it: a worn hat has never collided with anything, so there is no
  physics here to be right about.
- **An impulse, not an acceleration.** On the host a wearer's velocity changes one
  tick at a time; on a client a *remote* wearer's velocity is a step function that
  only moves when a snapshot lands. Dividing by `dt` would make the same 6 m/s
  change lean several times further on a client than on the host. An impulse is
  the integral, so it does not care how the change was delivered.

Purely cosmetic, to the last decimal: no lean angle is in `capture_state()`, on
the wire, or read by anything. That is why it is the one part of the hat system
that runs on every machine for every player rather than host-only.

Measured: a standing start peaks at 1.4° per hat (5.4° at the top of a four-stack,
6.6 cm of sideways swing); a 56 m/s dash pegs the clamp. `test_hat_lean`.

### Dislodging

**The whole stack pops on entering `TUMBLE` or `LEDGE_HANG`.** Not the top hat —
all of them.

Popping one hat makes hats a slowly-eroding counter. Popping the stack makes
carrying five hats a running, escalating, visible bet, which is the only version
of this that generates A3 moments. It also means the reward curve and the risk
curve are the same curve, so no separate balancing lever is needed.

This inherits an asymmetry the design already has and does not invent a second
one: **how hard you got hit decides what it costs you.** A shove that launches
you but leaves you in `WALK` keeps your hats. A hit solid enough to tumble you
does not. That is the same legibility rule as D2's ledge-grab-versus-launched,
and players who have learned one have learned the other.

Dislodged hats inherit the player's velocity plus a **deterministic fan** —
`HAT_SCATTER_SPEED` distributed by stack index around the player, never a random
direction. Two reasons: a host-authoritative sim does not need randomness that a
test then has to tolerate, and a fan guarantees no two hats leave from the same
point (the coincident-bodies trap again).

A player who **leaves the world entirely** — fell, drone-returned, disconnected —
takes their worn hats with them. They are gone. Dropping them at the last deck
position would be a rescue for the one failure the design deliberately does not
rescue.

### Banking — *provisional; see open question 1*

Scoring is deferred by decision: the game has not settled what a score is, and
this section is the proposal that will be tested against that answer when it
arrives, not a locked rule. **It is severable** — items 1–6 of the work breakdown
ship the whole of hats without it.

At a checkpoint, every player scores for the hats they are **still wearing**.

Hats are **not consumed**. A hat you have carried for four segments pays out at
every checkpoint it survives to. That is what makes a long-held tower a
long-running decision rather than a fetch quest, and it is why the value should
**not** escalate with distance — the escalation is already in how long you
managed to hold it.

The payout escalates with stack height, triangularly:

```
score = HAT_BASE_POINTS * n * (n + 1) / 2       # 100, 300, 600, 1000, 1500
```

so the fifth hat is worth five times the first. Linear scoring makes the choice
between one hat and five a rounding error; the point of the curve is that the
tower is worth the risk of the tower.

**Score is per-player, with a party total.** Hats are individually carried and
individually stolen; a shared pot removes the reason to care whose head a hat is
on. The party total is what the run is judged by.

On a wipe, hats and score revert to what was banked at the checkpoint, per D3.

---

## Replication

Two channels, split by how often the data changes. Getting this split wrong is
the expensive mistake available here.

**Reliable events** (`@rpc("authority", "call_local", "reliable")`) for anything
that changes *ownership*: spawn, pickup, dislodge, destroy, bank. These are rare,
and a lost pickup that silently never applies is a client wearing a hat the host
says is on the deck — a divergence that never self-corrects because nothing
re-sends it.

**The per-tick snapshot** for `FLYING` and `LOOSE` hat positions only. They are
moving bodies; they belong next to the stone array in `_broadcast_snapshot`, in
**world-local coordinates** like everything else on the wire.

**Nothing hat-related goes in `PlayerBody.capture_state()`.** That array is the
reconciliation blob: it is captured every tick, replayed through `step()`, and
compared field-by-field. A worn-hat list there would be broadcast sixty times a
second to report a change that happens twice a minute, and — worse — would become
part of the replay path, where a client would have to re-derive pickups it has no
authority to decide. Hats are never predicted, for the same reason a shove is
never predicted: the outcome depends on bodies this machine does not own, and a
hat that appears on your head and then vanishes is worse than one that appears
80 ms late.

**Hat ids are host-assigned and monotonic, not creation-order indices.** Stones
get away with `_stone_list` indices because both machines load the same segments
in the same order, so creation order is agreed for free. Hats are not: a hat can
be created by a player joining mid-run. Copying the stone pattern here is a bug
that only appears with a late joiner, which is the worst possible time to find
it. The id is assigned by the host and carried in the reliable spawn event.

**Drop-in (D2) needs the full hat list** — every hat's id, style, mode, and
either its owner+index or its position. Short, cheap, and it has to be built with
the rest or the first late joiner sees a hatless world.

---

## Authoring

One new content glyph. `Content.HAT`, drawn `^`, added to
`GridConfig.CONTENT_GLYPHS` alongside `+` and `*`; `SegmentBuilder` reports hat
cells the way it already reports stone cells, and `BridgeGrid` spawns a hat body
per cell at load.

Loose hats live "at some checkpoints", per the brief — but they should be
authorable anywhere, because the interesting place to put one is *past* a hazard,
not next to the safe spot. Checkpoint segments get them by convention, not by
rule.

**Cull rule, and it is not optional.** An endless run scattering hats leaks
bodies forever. Hats behind the streaming window's trailing edge (the rearmost
living player, per `bridge_grid.md`) are destroyed, and live loose hats are capped
at `HAT_MAX_LOOSE` with the oldest culled first.

---

## Work breakdown

| # | work | files |
|---|---|---|
| 1 | Hat body: three modes, world-only collision, land/settle, fall-out | `scripts/sim/hat_body.gd`, `scenes/hat.tscn` |
| 2 | Hat pool: id assignment, the list, the pickup pass, snapshot/apply, cull | `scripts/sim/hat_pool.gd` |
| 3 | Worn stack on the player: attach node, `dislodge_hats()`, stack cap | `scripts/sim/player_body.gd`, `scenes/player.tscn` |
| 4 | World wiring: pickup pass after the step loop, hats in the snapshot, the reliable events, drop-in dump | `scripts/sim/game_world.gd` |
| 5 | Dislodge triggers on `TUMBLE` / `LEDGE_HANG` entry, and on leaving the world | `scripts/sim/player_body.gd` (M5 states) |
| 6 | Authoring: `Content.HAT`, `^`, builder + grid spawn | `scripts/grid/grid_config.gd`, `segment_builder.gd`, `bridge_grid.gd` |
| 7 | Scoring: per-player score, the bank hook, wipe revert | checkpoint code (M8) |
| 8 | Tunables | `scripts/sim/sim_config.gd` |
| 9 | HUD: own hat count and score, friends' hat count | M9 |

Items 1–4 and 6 are gym-testable with no dependency on M5 or M8. Item 5 needs
M5's `TUMBLE`. **Item 7 is severable and deferred** — it needs both M8 and an
answer to what a score is, and hats are a complete, playable, funny system
without it. Item 9's score readout goes with it.

---

## Tests

| test | what it pins |
|---|---|
| `test_hat_pickup` | walking over a loose hat wears it; three stack in order; a `TUMBLE` player walks through one and does not; the stack cap refuses the sixth |
| `test_hat_exclusive` | two players contesting one hat: **exactly one** wears it (B8), and the winner is the nearer one regardless of carry order |
| `test_hat_tumble` | entering `TUMBLE` pops the whole stack; no two hats leave from the same point; none is collectable while `FLYING` or inside the settle grace; all are collectable after |
| `test_hat_scoring` | *(ships with item 7, deferred)* a checkpoint with n hats pays the agreed value; crossing two checkpoints pays twice; zero hats pays zero; a wipe reverts to the banked figure |
| `test_hat_replication` | over ENet (**port 28781** — add to `CLAUDE.md`'s allocation list when this lands): host and client agree on who wears what and where every loose hat is, after a scripted pickup-then-tumble |
| `test_hat_lifecycle` | a hat knocked into a hole is destroyed and the live count is right; the cull removes hats behind the window; no leak over a long run |
| `test_hat_lean` | a standing player's stack is dead upright; changing speed tips it *against* the change; **the top of the tower leans further than the bottom** (the only claim here that fails if the lean is deleted); no hat passes `HAT_LEAN_MAX_DEG` against the one below it, *and a dash actually reaches it*; it settles upright again |

`test_hat_exclusive` is the one most likely to fail first, and it is the reason
the pickup pass is specified as separate from the step loop.

---

## Tunables

Starting values, each with its reason, per house rules — every one is expected to
move in playtest.

| constant | value | why |
|---|---|---|
| `HAT_PICKUP_RADIUS` | 0.7 m | a little wider than the 0.4 m body radius, so walking *near* a hat gets it and nobody has to aim |
| `HAT_MAX_STACK` | 5 | tall enough to read as absurd from across a 60 m bridge, short enough that the top hat is still on screen |
| `HAT_HEIGHT` | 0.35 m | five stacked is 1.75 m — roughly a second player's worth, which is the visual joke |
| `HAT_SETTLE_GRACE` | 0.5 s | long enough that a tumbling player has rolled clear before their own hats are live again |
| `HAT_SCATTER_SPEED` | 4.0 m/s | scatters over ~2 cells, so a stack lands as a spread you have to walk to rather than a pile you re-collect in one step |
| `HAT_BASE_POINTS` | 100 | round number; the curve matters, the unit does not |
| `HAT_MAX_LOOSE` | 24 | a segment's worth of debris |
| `HAT_LEAN_MAX_DEG` | 5° | *per hat*, so a full stack curves to 25° at the top — obvious in motion, nowhere near a topple |
| `HAT_LEAN_STIFFNESS` | 90 | ω² — about 1.5 Hz, roughly what a tall soft thing does |
| `HAT_LEAN_DAMPING` | 9 | ζ ≈ 0.47, deliberately *under*damped: critically damped it eases back like a menu animation instead of wobbling |
| `HAT_LEAN_KICK` | 0.08 rad/s per m/s | a standing start peaks near 3°, a dash pegs the clamp — which is the ranking those two events should have |

---

## Follow-up: hats that actually look like different hats

*(Requested 2026-08-10, after the core. Not in the first pass — the first pass
proves pickup, stack and dislodge, and a hat is a coloured box until it does.)*

The catalogue should be **generated from a handful of shape knobs** rather than
authored one hat at a time, and randomised so a run turns up a tiny pillbox and
an enormous floppy thing in the same segment:

| knob | what it does |
|---|---|
| base width | the crown where it meets the head |
| top width | equal to base is a cylinder, narrower is a cone, wider is a bucket |
| rim width | how far the brim sticks out past the crown |
| height | pillbox to stovepipe |
| curl | the brim's edge lifting up or drooping down |
| colour | **from a palette, not fully random** — random RGB produces mud and clashes with the deck browns and the player blue |

**THE SHAPE MUST BE A PURE FUNCTION OF `style_id`, NOT ROLLED AT SPAWN.** This is
the constraint that decides whether it works at all, and it is why it is written
down before the code exists.

`style_id` already travels with a hat forever, deliberately: *you keep wearing the
hat you stole*, and "that is MY hat on your head" is the sentence the whole
feature exists to produce. If the knobs are rolled with `randf()` when a hat
spawns, then the same hat is a different shape on every machine, and a stolen hat
silently becomes a different hat. Randomise the ID; derive the hat from it with a
hash, the way `segment_pool.plan()` already derives a run from a seed without
touching the global RNG.

That also makes it free to replicate — the wire already carries `style_id`, and
nothing else needs to travel — and free to test, because a given id has one
correct answer on every machine and in every run.

**Palette**, for the same reason the deck is two browns and the player is blue: a
hat has to read as *not scenery* from across a 60 m bridge, and against browns
and one blue that is a narrow window. A short hand-picked list, indexed by the
same hash.

## Open questions

1. **[open, deferred by decision] What is a score, exactly?** Recorded as an
   intent in `game_concept.md` and deliberately left unanswered: units,
   per-player versus per-party, and whether anything but hats feeds it. **This is
   no longer a blocker for M8** — M8 owes scoring only a *shape*, an extensible
   per-player bank record and a hook other systems can attach to, which costs it
   nothing to provide.

   The consequence for this milestone is the split in the work breakdown below:
   items 1–6 build hats and need no answer, and item 7 attaches whatever the
   answer turns out to be. The triangular payout above is a **placeholder with a
   stated reason**, not a decision — it exists so item 7 has something concrete
   to test against the day it is built.
2. **ANSWERED 2026-08-10: (a), and PERSISTED TO DISK.** `style_id` is your
   identity, and it now survives between launches rather than lasting a run.

   - First ever launch: you are given a **random** hat, and it is saved.
   - You start every session wearing whatever hat you saved.
   - **Lose it and you start bare next time.** The save follows what you are
     actually wearing, so a fall that destroys your hats is felt the next time
     you open the game, not just for the rest of the run.

   This is a stronger version of (a) than was proposed, and it is what makes the
   feature's own premise pay off: "that is *my* hat on your head" only means
   something if the hat was mine yesterday too. It also gives the game its first
   piece of state that outlives a session, so the file format is worth getting
   boring and forward-compatible now rather than later.

   **Consequence worth naming:** a stolen hat is kept. Your saved hat is whatever
   you are wearing at the bottom of your stack when the session ends, so losing
   yours and taking someone else's is a complete story rather than a dead end.
3. **ANSWERED 2026-08-10: no. If you fall, you lose them.** Confirmed rather than
   softened, so it is now a rule rather than a placeholder. Worn hats die with a
   player who leaves the world — fell, drone-returned, disconnected. They are
   **destroyed, not dropped at the last deck position**: dropping them would be a
   rescue for the one failure the design deliberately does not rescue, and it
   would put a free pile of hats at the exact spot that just killed somebody.

   Note this is a *different* rule from the tumble dislodge, and both are wanted.
   Tumbling scatters your hats onto the deck where anyone — including you — can
   pick them up again. Falling out of the world destroys them outright. The
   asymmetry is the same one D2 already draws: how badly it went decides what it
   costs you.
4. **[open] Can you shove a hat?** A dash into a loose hat currently does nothing
   (no collision). Making the dash *punt* hats down the deck is nearly free and
   turns hats into a thing you can deny a teammate. Probably good; deliberately
   not in scope, because it puts hats back into the contact graph and
   `resolve_shove_contact` is a rule surface B1 asserts against.

---

## Placement, and why here

Hats need `TUMBLE` (M5) for the dislodge trigger. With scoring deferred, the bank
is no longer a dependency, so **the earliest hats can land is after M5** — but it
should still land **before M9**, so the HUD milestone draws the hat count in its
first pass instead of getting a second one. M8.5 is therefore the latest sensible
slot rather than the earliest; pulling it forward to M5.5 is available and costs
nothing but the score readout arriving later.

The counter-argument is real and worth stating: the roadmap's ordering principle
is *riskiest unknown first*, and hats are not a risky unknown — they are an
additive layer on a loop that is already proven by the time they arrive. A strict
reading puts them post-MVP as M13.

**Recommendation: keep them at M8.5, inside the MVP.** A2 and A3 are exit
criteria, they are the two the current milestone set addresses least directly,
and they are judged by humans playing the game rather than by a test. Hats are
the cheapest thing on the board that aims at them. Scoring (item 7) is already
severed and deferred; pickup, stack and dislodge are funny on their own, and they
are what items 1–6 deliver.

## Explicitly NOT in this milestone

- **Hats that do anything.** No stat effects, no abilities, no set bonuses. The
  moment a hat is worth wearing for a reason other than points, it stops being a
  bet and starts being equipment, and it needs balancing against specials (M12).
- **Unlocks or progression.** The catalogue is a fixed list.
- **Hats on anything but players.** No hats on stones, no hats on the bus.
- **Trading, throwing, or giving.** You get a hat off someone's head by tumbling
  them, which is a verb the game already has.
