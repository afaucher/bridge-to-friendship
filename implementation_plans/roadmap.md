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

## M2 — Bridge grid and segment loader — **DONE (2026-08-08)**

**Proves:** a text file becomes a bridge you can walk on.

Shipped: `scripts/grid/` (config, parser, validator, builder, runtime grid), the
`.seg` format, `segments/test_flat.seg` and `segments/test_ascent.seg`, and two
tests. Deck cells merge along X into runs (a 30x14 segment is 420 cells and far
fewer boxes). The validator runs the reachability flood twice — once with a solo
budget, once with an assisted one — so "no way up" and "a solo player is
stranded" are the same check with different numbers.

Two design corrections came out of building it, both now in `bridge_grid.md`:
**interior holes carry no parapet** (railing them made it impossible to ever
shove a stone through one, which the design calls out as the reward for
rearranging the bridge), and **the whole bridge is pitched 4 degrees** so loose
plinko balls roll back down at the players under their own weight rather than
needing a rule.

The cell model, heights, derived walls, holes, water and ramp geometry, pillar
stones as grid-resident data. The `.seg` ASCII format and its loader. The grid
is authoritative data; the scene is a view built from it.

Ships a handful of throwaway test segments — **not** designed content. Real
authoring is M10.

Exit: C1, C2, and the grid half of A4 (`max_walk_slope` is enforced).

## M3 — Bodies interacting: shove and riding — **DONE (2026-08-08)**

**Proves:** the signature verb feels good and resolves legibly, and bodies stack.

Shipped: the compass-locked dash with its momentum-transfer table, one-cell stone
pushing (including into a hole), dashing off the deck, and riding. Two tests.

Riding uses **Godot's built-in moving-platform transport**, not the explicit
`ride()` this milestone was scoped around — less code, at the cost of being one
tick stale and of living in engine state a reconciliation replay cannot restore.
`ride()` remains on the bodies, unused, so swapping back is a small edit. The
half Godot does *not* solve is a carrier being blocked by its own rider, which
the step loop handles by masking.

**Jump was removed here.** Space is the dash. A jump would quietly solve
obstacles that are meant to need a second player, which would undercut the
ascender grades the whole level design rests on.

Still open, deliberately: a rider cannot presently be shoved off its carrier, and
the fixed-yaw camera is not built (nothing renders yet).

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

## BUILD ORDER: M5 BEFORE M4 (decided 2026-08-08)

The numbering stays as it is — the exit criteria reference it — but **M5 is
built first.**

The reason is the question "how does a yank get anyone up anything?". It does
not, on its own: a yank is a horizontal tug, and a player dragged into the side
of a 2 m step just slams into it. The rope only lifts someone because the
someone is **hanging from a ledge** and gets pulled up and over it — the vertical
component comes from the geometry of pulling toward a friend who is already up
there, not from the rope pulling upward.

So the ledge mechanic is the prerequisite, not the payoff. Building M4 first
would mean building a yank with nothing to yank anyone onto, then rebuilding it.

The cost is real and worth naming: the first genuinely playtestable co-op moment
moves later, and that moment is the roadmap's own stated riskiest unknown. M5's
practice-partner support (already shipped) is the mitigation — tumble, ledges and
the drone return can all be felt solo before the rope arrives.

## M5 — Damage, tumble, ledge grab and return — **NEXT**

**Proves:** failure is a setback with a rescue window, not a wall.

Hit points, the grace window, hearts as exclusive pickups, the ledge-grab rule
and its bleed-out timer, and the drone return. Resolves the open question of what
zero health does.

**TUMBLE is a pinwheel, not a slide.** A hard hit throws a chaotic, bouncing body
that KEEPS its momentum — on a bridge full of holes the threat is displacement,
not damage, and a tumble that decelerates politely is not a threat at all.

Ships the **ledge primitive** the rope depends on: a player near a lip catches
it and hangs; a hanging player cannot mantle unaided; a hanging player being
pulled can. M4 then supplies the pull and nothing else.

Exit: B5, B6, B7, B8.

## M4 — Rope

**Proves:** the game is cooperative rather than parallel.

A real soft simulated rope — a particle chain that drapes and swings — with grab
targeting, player-to-player tie, and the yank. Full design in
`design_ideas/rope.md`; the load-bearing idea is that **the rope's SHAPE is
cosmetic and simulated on every machine, while the rope's FORCE is one
authoritative rule at the endpoints.** That is what makes a simulated rope
affordable in a game with rewind-and-replay: the chain is never in
`capture_state()`, never in a snapshot, and never replayed.

There is no `SWING` state. A tumbling player on a taut rope swings because that
is what a body on a line does; it falls out of the constraint.

**This is the first playtestable moment of the whole co-op premise** — two
players, a ledge, a rope, and a friend hauling you back up. If A1 and A3 are
going to fail, they fail here. Playtest before starting M6.

Exit: B4, B4b, and the co-op half of A4.

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

## M8.5 — Hats — **proposed, not agreed**

**Proves:** there is a reason to take a risk you did not have to take.

Stackable hats worn on the head, dislodged as a whole stack by a tumble, picked
up by walking over a loose one, and banked for points at each checkpoint. Loose
hats are authored content (a new `^` glyph).

The real deliverable is **the carried-item channel** — carried, contested,
droppable state that belongs to a player and is in neither `capture_state()` nor
the grid. Hearts and specials are its next two clients, so building it as
hats-only reopens this milestone twice.

Aimed squarely at A2 and A3, the two exit criteria the rest of the milestone set
addresses least directly.

**Scoring is deferred by decision** (2026-08-08) and severed from the rest of the
milestone: hats are complete and playable without it. `game_concept.md` records
the intent and leaves the answer open; all M8 owes it is a *shape* — an
extensible per-player bank record and a hook, not a distance integer.

That leaves `TUMBLE` (M5) as the only hard dependency, so this could run as early
as M5.5. It sits at M8.5 because it should precede M9, which is where the hat
count gets drawn.

Full scoping: `implementation_plans/m8_5_hats.md`.

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

## M12 — Specials

Shotguns, swords, thrown bombs, anchoring shields, **legs**. Fixed uses, dropped
when spent, replacing one leaves the spent one behind. One slot. The HUD slot
exists from M9; the carried-item channel exists from M8.5.

**Build legs first**, even though it reads as the simplest, because it is the one
that decides the shape of the whole system.

The other four are committed actions: press, and the host resolves what happened.
They need no prediction, for exactly the reason a shove needs none — the player
has no control over the outcome, so there is nothing to mispredict. Legs are the
opposite. They modify ordinary walking, the player keeps air control, and a jump
that arrives 80 ms late feels broken in a way an unsteerable dash never does. So
legs must be **client-predicted**, which drags the charge count onto the
reconciliation path: whether tick N produces a jump depends on how many charges
are left.

That splits a special's state in two, and the split is the finding:

- **The part that affects stepping** — charges remaining, mid-jump flags — goes
  in `PlayerBody.capture_state()`. Not an exception to the hats milestone's "keep
  items out of the blob" rule but the same rule read correctly: `CLAUDE.md` says
  anything affecting stepping must be in `capture_state()` or replays diverge,
  and hats were excluded because hats *do nothing*.
- **The part that does not** — which special you are holding, its style, who
  dropped it where — is the M8.5 carried-item channel, reliable and unpredicted.

Design consequences of legs are settled in `game_concept.md` §Special: 2 m of
rise (one layer, so a solo player can get themselves up); a shortcut and never an
ascender, so `SegmentValidator`'s two rise budgets are untouched; and the failure
mode to watch is legs being *common*, not legs being *strong*.

`ACTION_SPECIAL` must stay edge-triggered for exactly one tick, or a
reconciliation replay re-fires the jump and burns the charges — the trap
`player_input.gd` already documents for shove.

`sim_config.gd`'s "THERE IS NO JUMP" note asks that nobody restore a jump without
deciding what it does to the ascender grades. That decision is now made and
recorded; update the comment to point at it when this milestone lands.

## Later

Real Steam appid and store presence. Audio. More than four players. Progression
and unlocks, if any.
