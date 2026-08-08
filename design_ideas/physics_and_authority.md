# Physics and authority

Written 2026-08-08. The most consequential technical decision in the project,
and the one that retires a decision made in M0.

## The finding: client-authoritative movement cannot survive this design

M0 shipped client-authoritative movement — each player simulates their own
avatar and broadcasts the result — with a note that it was fine for co-op and
wrong for competitive play, and that the swap was deferred to the game design.

The game design has arrived and it does not turn on competitiveness at all. It
turns on this: **every core verb is an interaction between two players' bodies.**

- A shove transfers momentum from one player into another. Who computes the
  result? If each client owns its own body, the shover's machine and the
  target's machine each compute a collision from slightly different positions
  and arrive at different outcomes. Both are then authoritative about their half
  of it. There is no reconciliation that is not simply "pick a winner".
- A rope **ties two bodies together with a constraint**. A constraint solved
  independently on two machines that each own one end diverges within a second,
  and the divergence is visible as the rope stretching or snapping on one screen
  and not the other.
- A tumbling player bouncing through a pillar field is a chaotic trajectory.
  Chaotic trajectories amplify small differences, which is the definition of the
  thing you cannot let two machines compute separately.

So: **the host simulates everything.** Clients send input; the host owns every
body, every stone, every ball, and every rope; the host broadcasts state.

This is not a nice-to-have upgrade. It is a precondition for the first
milestone, and it must land before shove is built rather than after, because
everything built on top of client authority has to be redone.

## The model

**Clients send input. The host simulates. Clients predict and reconcile.**

- Each client sends its intent — movement axis, and the discrete actions
  (shove + direction, rope fire/release, special) — to the host every tick.
- The host runs the whole world in its physics tick and broadcasts authoritative
  state for everything a client can see.
- Each client **predicts its own avatar** locally so walking feels immediate,
  and reconciles when the host's frame arrives. Prediction covers ordinary
  movement only.
- **Committed actions are not predicted.** A shove, a tumble, a rope yank — the
  states where the player has no control anyway — play from host state. This is
  the payoff of "you cannot steer a shove": there is no input to mispredict, so
  the correction never fights the player. The design's comedy constraint and its
  networking constraint are the same constraint.

## Custom integration, not rigid bodies

Players, stones and balls are simulated by **our own integrator** — explicit
velocity, explicit collision response, `move_and_slide` for sweeping — rather
than by handing them to Godot's rigid-body solver.

Three reasons, in order of weight:

1. **The momentum rules are game rules, not physics results.** "A dash into a
   stone moves it exactly one cell" is a designed, readable outcome. Ask a rigid
   body solver for it and you get a stone that slides a variable distance
   depending on approach angle and contact ordering — tunable only by fighting
   the solver. We want the *feel* of physics with the *legibility* of rules.
2. **`CLAUDE.md` already records that Godot's physics is not bit-deterministic
   run to run** (contact solver and float ordering). A host-authoritative game
   does not strictly need determinism, but a test suite that asserts "this dash
   pushes this stone into that cell" very much does, and so does any future
   replay or desync check.
3. **A rope is a constraint between two bodies.** `CharacterBody3D` has no
   joints, and `RigidBody3D` joints are solved by the engine on its terms. With
   our own integrator the rope is a positional constraint applied after both
   bodies move, which is a dozen lines and behaves exactly as specified.

The cost is real: we write our own collision response, our own resting contact
handling, and our own tuning. That is accepted deliberately in exchange for
rules we can state, test, and tune.

## One body, one state machine

Every player runs the same integrator with an explicit state:

| state | control | notes |
|---|---|---|
| `WALK` | full | analog movement, client-predicted |
| `SHOVE` | none | locked axis, fixed speed, ends on impact/edge/distance |
| `TUMBLE` | none | ball-like, rolls with inherited momentum, timed recovery |
| `SWING` | partial | roped and taut; replaces TUMBLE on impact |
| `DOWNED` | none | zero health, awaiting a teammate |
| `BUS_DRIVER` | steering only | every other verb suppressed |
| `BUS_RIDER` | verbs, no movement | |

The bus states exist in this table already because "the driver loses their
verbs" is a statement about the *player's* state, not about the bus. Building
the state machine with that shape now costs nothing; discovering it later means
unpicking every ability check.

## Riding: anything on top of another body is carried — NOT BUILT YET

**Decided 2026-08-08, scheduled for M3. Nothing implements this today.**

Anything standing on another sim body is carried by it: from the rider's point
of view the thing underneath is not moving. Stand on a player and they carry you.
An enemy that lands on you gets carried by you. It applies to every sim body, not
just players — a stone, a plinko ball at rest, the bus.

This is why the player collider is a **cylinder and not a capsule** (already
changed in `scenes/player.tscn`). A capsule's domed cap slides a landing body
straight off; the flat top is what makes standing on someone possible at all, and
the flat bottom is what lets a body come to rest on a stone rather than teeter on
it. The collider never tips — `CharacterBody3D` is kinematic and does not rotate
from physics — which is a constraint on TUMBLE when it arrives: **tumble must
roll the mesh and leave the collider upright**, or a rolling player stops being
something anyone can stand on halfway through the roll.

**Godot will not do this for us.** `CharacterBody3D` inherits platform motion
only from bodies the physics server tracks as platforms (`AnimatableBody3D` and
friends); one `CharacterBody3D` standing on another just gets left behind as the
lower one walks out from under it. Since we own the integrator anyway, the
transport is explicit, and it brings two requirements with it:

1. **Step order matters.** A carrier must step before its riders, or a rider
   inherits last tick's motion and visibly slides around on its carrier's head.
   With a stack this is a topological order, and it needs a cycle guard — two
   bodies each reporting the other as its carrier is physically impossible and
   would still spin forever.
2. **The carrier must be re-derivable, not replicated.** A reconciliation replay
   has to arrive at the same carrier the host did. Deriving it from a downward
   probe each step keeps it a function of position, which a replay reproduces.
   Reading it from the last `move_and_slide` collision list does not work: a body
   resting motionless can report zero slide collisions, which drops the carrier
   on exactly the frames where standing still on a friend matters most.

## The authoritative world is data; the scene is a view

Grid-resident things — cells, pillar stones, hearts, pickups, shooters — live in
the **grid model as data**, keyed by cell coordinate. The Godot nodes that draw
and collide with them are built from that data and are downstream of it. A stone
pushed one cell is a change to a cell record that the view follows; it is not a
`Transform3D` that happens to be near a grid position.

Free-moving things — players, plinko balls, the bus — are ordinary simulated
bodies whose state is replicated numerically.

This split is what makes **drop-in join tractable**. A newcomer needs: the
current segment window, the grid data for each (small, and mostly the authored
file plus a diff of what has moved), and a snapshot of the live bodies. If stone
positions lived only in the scene graph, "serialise the world" would mean
walking the scene tree and inventing a format for every node type — the standard
way late-join becomes a months-long retrofit.

It also makes the grid testable without rendering anything: a test can push a
stone and assert a cell record, headless, in milliseconds.

## Ticks and rates

- Simulation runs at the pinned **60 Hz** physics tick (`3d_conventions.md`).
- **[open]** State broadcast rate. Every tick is simplest and almost certainly
  too much bandwidth once there are four players and a field of balls; 15–20 Hz
  with client-side interpolation is the usual answer. Decide when there is
  something real to measure — and measure the stage, not the end of the funnel.
- **[open]** Do plinko balls need full authoritative replication, or can clients
  simulate them from a seed and only correct on player contact? The cheap answer
  is attractive and the risk is that a ball is exactly the thing whose
  trajectory must agree, since it does damage.

## What this obsoletes in M0

- `player.gd`'s client-authoritative `_push_state` broadcast. Replaced by input
  upload plus authoritative state download.
- The `has_control()` / `is_multiplayer_authority()` split as the thing that
  decides who simulates. Authority becomes "the host simulates; the owning
  client predicts".
- The M0 note in `multiplayer_topology.md` that deferred this decision. It is
  now decided; that document should be updated when M1 lands rather than
  rewritten speculatively now.

What survives unchanged: the `NetworkManager` / `SteamManager` split, the two
transports, the ENet-in-the-gate rule, and the host-decided spawn handshake.
Those were the parts worth getting right early, and they were.
