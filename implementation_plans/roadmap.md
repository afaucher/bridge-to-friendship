# Roadmap

Written 2026-08-08. The MVP is **M1–M10**; it is finished when every criterion
in `design_ideas/mvp_success_criteria.md` is met. Each milestone below says what
it *proves*, because a milestone that cannot fail has not been specified.

Ordering principle: **the riskiest unknown first.** The two unknowns that could
sink this project are (a) whether host-authoritative simulation of ropes and
momentum transfer is tractable, and (b) whether shove-plus-rope between two
players is actually fun. Both are answerable in a bare test room, before a
single metre of bridge exists — which is why content authoring is M10 and not
M1. Building levels for verbs that do not feel good yet is the expensive
mistake available here.

---

## M1 — Authoritative simulation core — **DONE (2026-08-08)**

**Proves:** two machines agree about a shared physics world.

Shipped: `scripts/sim/` (config, input, player body, game world),
`scripts/test_support/net_harness.gd`, the gym, and four new tests. Measured at
the end: **1 correction over 240 ticks under 133 ms of injected latency**, i.e.
prediction is right essentially always and B2's "no visible snap" holds with the
worst single-tick displacement at the budget's edge rather than over it.

Three things it cost that are now in `CLAUDE.md`: two perfectly coincident
bodies fall through the floor; `is_on_floor()` is derived state that survives a
rewind; and a readiness check that only runs in an event handler never runs
again.

Retires M0's client-authoritative movement, which
`design_ideas/physics_and_authority.md` establishes cannot survive this design.
Clients send input; the host simulates; clients predict their own walking and
reconcile. Introduces the custom integrator (explicit velocity, our own
collision response, `move_and_slide` for sweeping) and the player state machine
with `WALK` implemented and the rest stubbed.

Also delivers the **gym**: a flat test room with a few stones and two players.
Everything through M5 is developed and playtested there.

Exit: B1, B2.

## M2 — Bridge grid and segment loader

**Proves:** a text file becomes a bridge you can walk on.

The cell model, heights, derived walls, holes, water and ramp geometry, pillar
stones as grid-resident data. The `.seg` ASCII format and its loader. The grid
is authoritative data; the scene is a view built from it.

Ships a handful of throwaway test segments — **not** designed content. Real
authoring is M10.

Exit: C1, C2, and the grid half of A4 (`max_walk_slope` is enforced).

## M3 — Bodies interacting: shove and riding

**Proves:** the signature verb feels good and resolves legibly, and bodies stack.

Direction lock, dash, the momentum transfer table, stone pushing (exactly one
cell), leaving the deck. Fixed-yaw camera lands here, since the compass is
unusable without it.

Also **riding**: anything standing on another sim body is carried by it — stand
on a player and they carry you; an enemy landing on you gets carried by you. It
sits here rather than in M1 because it is a gameplay rule about bodies
interacting, which is what this milestone is. Godot does not provide it for
`CharacterBody3D` on `CharacterBody3D`; it needs an explicit carrier probe and a
carriers-before-riders step order. See `design_ideas/physics_and_authority.md`.

Exit: B3, B3b.

## M4 — Rope

**Proves:** the game is cooperative rather than parallel.

Grab targeting, the distance constraint, player-to-player tie, the yank, and
`SWING` replacing `TUMBLE` while taut.

**This is the first playtestable moment of the actual game** — two players, a
gym, a ramp, a rope. If A1 and A3 are going to fail, they fail here, when
nothing has been built on top of them yet. Playtest before starting M5.

Exit: B4, and the co-op half of A4.

## M5 — Damage, tumble, ledge grab and return

**Proves:** failure is a setback with a rescue window, not a wall.

Tumble state, hit points, the grace window, hearts as exclusive pickups, the
ledge-grab rule and its bleed-out timer, rope-assisted recovery, and the drone
return. Resolves the open question of what zero health does.

Exit: B5, B6, B7, B8.

## M6 — Plinko

**Proves:** there is a reason to keep moving.

Shooter, ball simulation, ricochet off pillar fields, and hit resolution
(glancing shoves, solid tumbles). Answers the open question of whether balls
need full authoritative replication or can be client-simulated from a seed.

Exit: C5.

## M7 — Water

**Proves:** terrain can threaten without an obstacle in it.

Lateral flow force, impaired movement, wash-away for a player who stops making
headway.

Exit: C4.

## M8 — Session: lobby, drop-in, checkpoints, leash

**Proves:** friends can actually get into a game together and stay there.

Menu create/join over Steam. Drop-in join with a world snapshot. Segment
assembly from a pool, checkpoint banking, wipe-and-restart. The soft leash and
party-window streaming.

Exit: D1, D2, D3, D4.

## M9 — HUD

**Proves:** players can read their own and each other's state.

Own health and three action slots top-left; friends' name, health and special
top-right. The special slot is built and empty.

Exit: D5.

## M10 — Level design

**Proves:** the game has content, and making more of it is cheap.

Three distinct pieces of work, and the milestone is not done until all three
land:

1. **Tooling.** Whatever makes authoring fast: a validator that rejects a broken
   segment with a useful message, a way to load a single segment directly for
   iteration, and a live reload. E3 (a segment in under an hour) is the bar.
2. **The pool.** At least 12 segments covering every structural idea, more than
   one per idea so the assembler has real choices. Tagged and difficulty-rated.
3. **The curve.** How the assembler escalates with distance — segment
   difficulty, plinko density, heart scarcity — and where checkpoints fall.

Deliberately last, because a segment authored against verbs that later change is
a segment authored twice. It is also the milestone most likely to send work back
upstream: content is where a movement rule that seemed fine in the gym turns out
to be unusable on a real bridge, so expect M10 to reopen M3–M7.

Exit: A1, A2, A3, C3, C6, E1, E2, E3.

---

# Post-MVP

## M11 — Bus mode

Rare and long: roughly one bus stretch every 8–12 foot segments, each running 8
or more segments, because the bus covers ground several times faster and a
short one is over before it registers as an act.

Needs the player state machine's `BUS_DRIVER` / `BUS_RIDER` states (reserved in
M1), road-surfaced segments (the grid already supports them), a vehicle in the
authoritative sim, and the seat-rotation `switch` that tells nobody it happened.

## M12 — Weapon specials

Shotguns, swords, thrown bombs, anchoring shields. Fixed uses, dropped when
spent, replacing one leaves the spent one behind. The HUD slot exists from M9.

## Later

Real Steam appid and store presence. Audio. More than four players. Progression
and unlocks, if any.
