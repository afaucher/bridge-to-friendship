# MVP: locked decisions and exit criteria

Written 2026-08-08, before any game code. Part 1 records the gameplay decisions
that are now settled and what each one obliges us to build. Part 2 is the exit
bar: **the MVP milestone set is done when every criterion below is met**, and
not before.

Numbers marked *(tunable)* are starting values picked for a stated reason. They
are expected to move in playtest; they are written down so that moving one is a
decision rather than a drift.

---

# Part 1 — Locked decisions

## D1. A run is an endless climb with banked checkpoints

The bridge is **assembled from a pool of authored segments** by tag and
difficulty, not laid out as one fixed hand-built level. Difficulty rises with
distance. Progress banks at a checkpoint every **5 segments** *(tunable)*; a
party wipe restarts at the last checkpoint rather than at the bottom.

**Obliges us to build:** a segment pool with tags and a difficulty rating; an
assembler that picks the next segment; checkpoint state in the world snapshot;
a distance/progress readout. **Rules out** hand-authoring one continuous level,
which means every segment must be able to follow every other segment — segments
join at a declared entry and exit elevation and are otherwise self-contained.

## D2. Falling is the failure, and the rescue is a ledge grab

This replaces the earlier "zero health means downed" proposal outright.

- A player pushed **over an edge while still near the deck** automatically
  catches the ledge and hangs there, on a bleed-out timer of **8 s** *(tunable)*.
- A hanging player **cannot pull themselves up.** The only rescue is a teammate's
  rope, which pulls them back onto the deck.
- A player knocked **clear of the deck** — launched into the air, several cells
  out — never reaches a ledge. They just fall. There is no rescue and that is
  intended.
- A player who falls is **returned by a drone and dropped next to another
  player** *(tunable: which player — nearest to the front, or the one furthest
  from danger)*. If there is nobody to drop next to, they are dropped at the
  party's forward-most safe cell.

The consequence worth naming: **whether your friends can save you is decided by
how you got hit, not by how fast they react.** A shove along the deck leaves you
grabbing a ledge; a plinko ball to the chest launches you and nobody can do
anything. That is a texture the design wants — it makes positioning near edges a
real, legible risk, and it means the rope rescue is a moment that has to be
earned rather than a routine.

**Obliges us to build:** a ledge-detection rule; a `LEDGE_HANG` player state with
a timer; rope-assisted recovery; a drone return with a placement rule. **Makes
the rope MVP-critical** — without it the ledge grab is just a slower way to die.

**[open]** Zero health is currently unresolved. The simplest unification is that
running out of hit points does exactly what falling does — you are removed and
drone-returned — so the game has one failure resolution instead of two. Confirm
before M5.

**[open]** Is the ledge grab automatic, or a button press? Automatic is kinder
for the audience; a press adds a skill moment. Defaulting to automatic.

## D3. The party is held loosely together by a soft leash

Players separate freely up to about **40 m** *(tunable)*, past which a straggler
is nudged forward and, past a hard limit, fast-travelled to the group.

**Obliges us to build:** a party-centroid tracker; the nudge/fast-travel rule.
**Buys us:** bridge streaming becomes one window around the party rather than
per-player windows; the 60 m structural width can stay wide without the group
dissolving; and no player can strand the others.

## D4. Shove is a continuous dash on a grid-aligned axis

The player accelerates to dash speed along one of four world axes and cannot
steer, slow, or cancel. It ends **wherever** it hits something — not on a cell
boundary. **Only pushed stones snap to cells**; the player's own stopping
position is continuous.

Starting values *(tunable)*: dash speed **14 m/s**, duration **0.8 s**, so a
dash covers about **11 m ≈ 5.5 cells** — roughly half the width of a typical
playable corridor, which means one committed action can cross the play space to
reach a friend.

**Consequence already banked:** a compass-locked dash requires a **fixed-yaw
camera**. That is settled by this decision, not open.

---

# Part 2 — MVP exit criteria

Each criterion is written to be checkable. Those marked **[test]** must be
covered by an automated test in the gate; those marked **[playtest]** are
judged by humans and are explicitly subjective — they are here because the
things that decide whether this game works cannot all be asserted in a headless
run.

## A. The core loop actually works

- **A1 [playtest]** Two players who have not played before solve a
  too-steep ramp cooperatively — by shoving or roping each other up — **without
  being told the solution**, within one session. If they cannot discover it, the
  central premise is not communicating and no amount of content fixes that.
- **A2 [playtest]** A two-player session runs **20 minutes** without the players
  being asked to keep going.
- **A3 [playtest]** At least one moment per session where the group laughs at an
  outcome nobody chose. This is the actual product; if it never happens, the
  committed-action design is not landing.
- **A4 [test]** A ramp above `max_walk_slope` is not climbable by a lone player
  by any input sequence, and **is** clearable by a shoved or roped player.
  The co-op gate is a real gate, verified rather than assumed.

## B. Simulation and authority

- **B1 [test]** Host-authoritative: after a scripted sequence of shoves,
  collisions and stone pushes, **two peers report identical world state** —
  every player position, every stone cell, every health value.
- **B2 [test]** A client's own walking is predicted locally and reconciles
  without a visible snap under **120 ms** simulated latency.
- **B3 [test]** Shove resolution: dash into a stone moves it **exactly one cell**
  when the destination is clear and **zero cells** when it is blocked; dash into
  a player transfers momentum along the dash axis; dash off the deck leaves the
  bridge.
- **B3b [test]** Riding: a player standing on another player is **carried** by
  them — the lower one walks and the rider goes with it, staying put relative to
  its carrier rather than sliding off the back. Holds for a stack (A on B on the
  ground) and for any sim body, not just players. A stationary stack neither
  jitters nor creeps.
- **B4 [test]** Rope: a taut rope holds its maximum length between two bodies and
  never pushes; a dash by either end **moves the other**; a tumbling player on a
  taut rope is caught at maximum length and swings instead of continuing away.
  The swing is not a state — it falls out of the constraint. See
  `design_ideas/rope.md`.
- **B4b [test]** The rescue, end to end: a player hanging from a ledge cannot
  mantle unaided, and **can** while a roped teammate dashes away from the edge.
  That is the whole co-op payoff and it spans two milestones, so it is asserted
  as one behaviour rather than as two halves that each pass alone.
- **B5 [test]** Ledge grab: a player shoved over an edge along the deck enters
  `LEDGE_HANG`; a player launched clear of the deck does **not**; a hanging
  player roped by a teammate returns to the deck; an unrescued one falls when the
  timer expires.
- **B6 [test]** Drone return: a fallen player is back in play, next to another
  player, within **5 s** *(tunable)*.
- **B7 [test]** Damage: every obstacle collision costs at least one hit point;
  the grace window of **0.75 s** *(tunable)* means a single tumble through a
  pillar field costs **at most 2** hit points rather than the whole bar.
- **B8 [test]** Hearts and pickups are **exclusive** — two players contesting one
  results in exactly one collecting it.

## C. The bridge

- **C1 [test]** A segment file loads into collision, meshes and entities, and a
  player can walk from its entry to its exit.
- **C2 [test]** Walls are derived correctly: every deck edge adjacent to a hole
  or to the bridge boundary carries a parapet **unless** the cell is marked in
  `[no_wall]`.
- **C3 [test]** A stone pushed into a hole falls out of the world and the cell
  record updates.
- **C4 [test]** Water applies lateral flow; a player who stops making headway is
  washed downstream.
- **C5 [test]** Plinko: a shooter spawns balls; balls ricochet off pillars; a
  glancing hit shoves and a solid hit tumbles.
- **C6 [test]** Segments assemble end to end at matching elevations, and the
  assembler never produces a join a player cannot traverse.

## D. Session

- **D1 [test]** Two players on separate machines create and join a Steam lobby
  from the menu and complete a run together.
- **D2 [test]** A third player **joins a run already in progress** and, within
  **5 s**, has correct world state — same segments, same stone positions, same
  health values as the peers already playing.
- **D3 [test]** A party wipe restarts at the last banked checkpoint, not at the
  bottom.
- **D4 [test]** The soft leash keeps the party within its limit; a straggler is
  returned to the group without being able to strand anyone.
- **D5** The HUD shows, per the brief: own health, own three action slots (push,
  rope, special) top-left; each friend's name, health and special top-right.

## E. Content

- **E1** At least **12 authored segments**, covering every structural idea:
  ramp gate, hole field, missing-parapet run, water crossing, and a pillar
  field with a plinko shooter — with more than one segment per idea, so the
  assembler has something to choose between.
- **E1b** Every elevation change is crossed by at least one **ascender**, and
  the mix is authored deliberately: ladders (free), gentle ramps (free), steep
  ramps (two players), bouncers. A layer with no way up fails validation, and no
  layer is solvable *only* by a cooperating pair — drop-in means the party can be
  one player, and a solo-impossible layer strands them permanently.
- **E2 [playtest]** Difficulty demonstrably rises with distance: an
  experienced pair reaches roughly **checkpoint 3–5** before their first wipe,
  and a first-time pair reaches roughly **checkpoint 1–2**.
- **E3** Authoring a new segment takes **under an hour** for someone who has
  done it once, using only a text editor and the loader. If it takes longer, the
  format is wrong and the level-design milestone has not finished.

---

## Explicitly NOT in the MVP

Deferring these is a decision, not an omission:

- **Bus mode.** Design-relevant now (the player state machine reserves
  `BUS_DRIVER` / `BUS_RIDER` so abilities are suppressible per-player, and the
  grid model already accounts for road-surfaced segments), but not built. Bus
  stretches are rare and long — roughly one every 8–12 foot segments, each 8+
  segments — so a bus section is a substantial content investment that should
  follow a proven core loop, not precede it.
- **Weapon specials.** The HUD reserves the slot; nothing fills it.
- **More than 4 players**, cosmetics, progression, audio beyond placeholders.
- **A real Steam appid.** Still on Valve's Spacewar test appid.
