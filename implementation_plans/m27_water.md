# M27 — Water

Water exists, does nothing, and is a trap. This plan makes it a place with a
direction, and puts three things in it.

---

## What water is today, measured

- `GridConfig.Kind.WATER`, glyph `~`. Built by `segment_builder` as an ordinary
  deck slab whose top is **0.4 m below** the cell's nominal height
  (`_surface_y`). Same collision as deck, same thickness, different colour.
- `SegmentData.is_solid` counts it as solid, so the reachability flood walks it
  freely.
- Nothing else in the codebase reads it. There is no flow, no damage, no
  swimming, no sound. A comment in `segment_builder` says "the flow that makes it
  dangerous is M7", and M7 came and went.
- **It appears in exactly one place in the shipped game**: two rows of
  `playtest_bridge.seg`, a 7-wide pond in the middle of the deck. The generator
  never emits water at all.

That last point is the most useful fact in this document. **We are not
retrofitting water, we are designing it.** Almost nothing depends on its current
shape, so the shape is free.

---

## Phase 1 — You can get out (the bug) — *done*

**The report:** you can't step out of water, so you get stuck.

**The cause, and it is two bugs wearing one symptom.** A water cell at the same
grid height as the deck beside it is a 0.4 m drop in, and a 0.4 m vertical wall
out. There is no step-up in this game — `move_and_slide` does not mantle, and
ramps, ladders, bouncers and lifts all exist *because* of that.

And the oracle does not know. `_can_step` compares `height_at`, which is
identical for the pond and the deck around it, so the rise is 0 and the move is
free. **`SegmentValidator` certifies a route nobody can walk** — the second time
this exact lesson has been paid for here. The first was `SOLO_RISE` allowing a
one-unit step onto plain deck, and CLAUDE.md already carries the note: *check
what the BODY does before trusting what the model says it does.*

### The decision: a step-up, bounded under one height unit

The fact that settles this is the height grid. Heights are **hex digits times
`HEIGHT_UNIT` = 1.0 m**, one character per cell, so *the smallest difference the
grid can express is a whole metre*. That splits step-up into two completely
different features wearing one name:

- **A step at or above 1.0 m** makes every grid-expressible rise walkable. That
  reverts a deliberate fix — a rise onto plain deck was made a wall precisely
  because the validator was certifying impassable levels — and it drains the
  meaning out of ramps, ladders and bouncers for every one-unit difference. That
  is a rewrite of the traversal model, and it is not what is wanted here.
- **A step below 1.0 m** cannot be reached by any authored height difference at
  all. It is invisible to every existing level by construction.

So: **`STEP_UP_HEIGHT`, above the 0.4 m water lip and below `HEIGHT_UNIT`.**
Around 0.45 m. The bound is the whole safety argument and belongs in the constant
comment, not in a plan nobody rereads.

**What the bound buys.** No existing level changes, because none of them contains
a sub-metre rise. No climb verb loses its meaning, because every rise a level can
author is still a wall. And **`SegmentValidator` needs no change at all**: water
is already `rise == 0` in its model, so the step-up makes the model *true* rather
than teaching it an exception — which is the cheapest kind of fix this codebase
has.

### Stairs, which is the second customer

A staircase in this grid is a 1 m rise over a 2 m cell, which is a 26.6° gentle
ramp — **already walkable today**. What is missing is not the traversal, it is
the mesh: draw risers instead of a wedge and you have stairs now.

Without step-up that has to stay a trick, because stepped art over a smooth ramp
collider deviates by up to ~0.17 m mid-step and feet float and sink. With a step
of 0.45 m, stairs can have **real stepped collision** — three 0.33 m risers per
cell, each under the limit — and the thing you see is the thing you stand on.

That is what makes this worth a movement verb. A general rule added to serve one
terrain type is a bad trade; the same rule serving water *and* the game's fourth
climb vocabulary, under a bound that provably touches nothing else, is a good one.

### What it costs, honestly

- `CharacterBody3D` has no step height. This is a manual shape-cast
  up-forward-down, every tick, on every body that walks.
- It has to be **replay-safe**, or `corrections` climbs on every client. It
  should be a pure function of position and world geometry, which keeps it out of
  `capture_state()` — but that is a claim to verify, not to assume.
- **Audit every sub-metre vertical face before shipping it.** A step-up makes
  each one climbable, and the list is not obvious: cover is 1.1 m and safe, the
  bus sides are 0.68 m and safe, but anything with a top face between 0.4 m and
  the chosen bound becomes a thing players can stand on. That audit is part of
  the work, not a follow-up.

### What it came out as

`STEP_UP_HEIGHT = 0.45`, probed by hand after `move_and_slide` in `_step_walk`:
lift, retry the blocked motion up there, drop back down, and land on whatever the
descent actually hit. Each leg refuses for its own reason — no headroom, still
blocked, nothing underneath — and the last is what stops it being a way to walk
onto thin air at the top of a wall.

Measured, on `playtest_bridge`'s pond: **0.001 m of climb in two seconds
before, 0.401 m in 17 ticks after**, ending on the shore cell. On the rig, a
0.40 m ledge is climbed and crossed; a 1.00 m ledge stops the body dead at
0.001 m after 1.6 m of walking into it.

**The audit came out empty**, which is what the bound predicted. Nothing in the
player's collision mask has a top face under 0.45 m except water: the bus is on
layer 2048 and the mask is 1687, so players never touch it at all; the merchant
is 1.6 m, the posts 1.9 m, cover 1.1 m. That conclusion holds only while the
bound does, so the bound itself is now a claim.

**Replay-safe as designed** — it reads position and collision geometry and
nothing else, so `capture_state()` is untouched and `test_client_prediction`
still reports 3 corrections over 240 ticks at 0.1 m.

### The claims

Both halves, because a rule with one half tested is a rule half-shipped:

1. A body walks into the pond in `playtest_bridge` and back out under its own
   power, asserted on the position rather than on the geometry.
2. **The same body still cannot climb a 1-unit step onto plain deck.** That is
   the half that says we added a bounded step and not a mantle, and without it
   the traversal rewrite ships silently.

---

## Phase 2 — Water goes somewhere

**The ask:** a more natural reason for water, a gameplay effect, a push toward
the edge, and waterfalls off the side with an ungrabbable edge.

### The natural reason: water is a crossing, not a puddle

A pond in the middle of a bridge is scenery nobody can explain. A **channel that
runs across the bridge and off one side** explains itself: it enters at one rail,
it leaves at the other, and the thing at the far end is a waterfall because that
is what water does when the floor stops.

This also hands us the push direction for free. The flow runs from the closed end
toward the open end, so "which way does it shove" is a property of the channel's
own shape rather than a number somebody tunes.

**Not gravity-driven.** The deck is pitched about 4° along −Z, so water left to
find its own way would run *down the bridge*, pushing the party backwards into
the leash and the trailing edge. That fights the whole direction of play. A
spillway across the deck is a designed thing, and designed is what we want.

### The effect

Crossing a channel costs you **lateral position**, proportionally to how long you
are in it. That is a real decision rather than a tax:

- A narrow channel mid-deck is a tempo cost — cross it fast, or lose a metre.
- A channel near the rail is genuinely dangerous, because downstream is the edge.
- A wide slow one and a narrow fast one can be the same total shove, and read
  completely differently to a player.

The push is a pure function of `(cell, grid)`, so it adds nothing to
`capture_state()` and replays for free. It must be applied **before**
`move_and_slide`, like everything else that decides a body's motion.

### The ungrabbable lip

This collides with `_try_catch_ledge`, which grabs when a body is over a hole
with solid deck within reach below. **A waterfall lip is solid deck**, so today
you would catch it — and being shoved off a waterfall only to dangle from it is
the opposite of the intended reading.

The rule is one line and it states itself: **you cannot hold on to a waterfall.**
`_try_catch_ledge` refuses when the lip cell is `WATER`. Same shape as the fix
that stopped a bus passenger catching a ledge on the way down: the entry
condition has to ask what the state will do.

### Open questions for a playtest, not for this document

- Does the shove read as *water* or as *ice*? A push with no visual flow is a
  bug report waiting to happen ("the deck slides").
- Should the flow carry loose hats and specials downstream? It would be
  wonderful and it makes water a hat thief, which is a scoring change.

---

## Phase 3–5 — Three things that live in it

Ordered by the machinery each one needs, not by the order they were asked for.
Each states the decision it poses, because a hazard that poses no decision is
texture.

### The Bubble Swallow — a sustained pull

*Kirby-like floating ball. Sucks everything toward it, eats small things, hurts
large ones. You can outrun it; standing still gets you taken.*

**The decision:** the thing you want is inside its reach. Do you dash through and
accept being pulled, or go the long way?

**The rule has to be arithmetic, not tuning.** "Run away and it lets you go,
stand still and it takes you" is a statement about two numbers: at the rim the
pull must be **less than `WALK_SPEED`**, and inside the core it must be **more**.
Written that way it is testable — sample the pull at a ring of radii and assert
where it crosses walking pace — and it cannot be quietly broken by a designer
nudging a constant.

**Eating small things is the interesting half.** A swallow that consumes loose
hats is a threat to the score rather than to the body, which is the scarcest kind
of threat this game has. Worth deciding explicitly whether it *destroys* them or
*holds* them until killed — the second makes it a target rather than an obstacle,
and that is a different enemy.

**Reuses:** the pool shape every enemy has, the blast's radial maths.
**New:** a sustained force applied to bodies *and* to loose items.

### The Bee — the first flying enemy

*Stays near ground level but needs no ground square. Patrols; winds up and lunges
when you get close.*

**The decision:** it owns a volume, not a tile — so it can hold a gap, a
waterfall lip, or the air over a channel, which nothing else in the game can do.
That is the reason to build it beyond "a flying one".

**The wind-up is the whole fairness of it**, exactly as it is for the rusher: a
lunge with no tell is a tax, and a lunge with one is a dodge you can learn.

**Reuses:** the skirmisher's patrol — including the hard-won lesson that a "walk
to a point" needs a way to give up, and that the give-up must be a *progress*
check rather than a time budget. The rusher's charge for the lunge.
**New, and this is the part that will bite:** *content never sits on a hole* is a
validator rule, `_discard_level_entities_past` sweeps by cell, the dressing pass
picks candidate cells from solid ground, and the leash and trailing edge cull by
position. **A thing with no ground under it walks through four separate
assumptions that nobody wrote down as assumptions.** Budget for that rather than
for the flying.

### The Frog — a tongue that is an object

*Pops out of the water, aims, fires a tongue. The tongue is a rod: it collides
with things. If it sticks it reels you in, and being reeled hurts.*

**The decision:** the tongue is cover. A hazard that also creates an obstacle for
everything else is something this game does not have, and it is the most
interesting idea in the list.

**It is also the hardest and should be prototyped before it is planned.** A
persistent, moving, *solid* segment is a new kind of body here. Two traps are
already written down and both apply: a `RigidBody3D` parented to another physics
body is not raycastable however correct its transform looks, so the tongue must
live at the root and be driven by global transform; and existence must ride the
**reliable** channel while only motion goes in the snapshot, or a client sees a
frog with no tongue and a player being pulled by nothing.

**Reuses:** the gunner's aim and telegraph, the turret's arc.
**New:** a solid moving rod, and a pull that is attached rather than radial.

---

## Suggested order

1. **The step-up.** Unblocks everything; the pond stops being a trap, and
   stairs become authorable.
2. **The channel** — flow, push, waterfall, ungrabbable lip. Water becomes a
   place with a direction, and the generator can start emitting it.
3. **Bubble swallow.** New force machinery, contained.
4. **Bee.** Cheap behaviour, expensive assumptions.
5. **Frog.** Prototype the tongue first, then plan it.

Nothing past step 2 should start before a playtest of step 2. The three enemies
are all *about* water, and how water feels decides whether they are threats or
furniture.

## What I would measure before writing any of it

- What the pond actually does to a body now, as a position trace, so "you get
  stuck" is a number in the plan rather than a description.
- Every static top face in the game between 0.4 m and `STEP_UP_HEIGHT` above a
  standable surface — the audit above. Measured, not recalled: this project has
  been wrong twice recently about what geometry exists by reasoning from the
  code instead of asking it.
