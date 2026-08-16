# World generation: getting variety without losing completability

Written 2026-08-15, after M16 made a run a sequence of rounds. The question is
how to get a much larger variety of environments than three hand-authored
segments, and the answer has to survive one constraint that nothing else in this
project has had to: **a generated bridge can be unplayable, and nobody will be
watching when it is.**

---

## Part 1 — What generates, and what does not

The instinct is to pick a point on a line from "author everything" to "generate
everything". That is the wrong axis. The right split is by **what kind of claim
each part has to make**:

| | must be true | who can guarantee it |
|---|---|---|
| the ground is crossable | a proof | a machine |
| the fight is interesting | a judgement | a person |

So the plan is not "how procedural should this be" but:

> **Generation guarantees COMPLETABLE. Authoring carries DESIGNED. Nothing is
> generated that a flood cannot check, and nothing is authored that a generator
> could have produced.**

That gives three layers, and every item on the wish list belongs to exactly one.

### Layer 1 — the terrain skeleton (GENERATED)

Width, the height profile, gap density, where the deck splits into levels, where
it narrows. Entirely parametric, entirely checkable, and the part where
generation earns the most: these are the properties a player reads as "a
different place", and they are also the ones a person is worst at varying — hand
authoring drifts toward the same comfortable width and the same comfortable gap
every time.

### Layer 2 — set-pieces (AUTHORED, placed by the generator)

A shooter on a pillar behind a gap, with cover halfway across. A button on the
far side of a drop with its door behind you. These are *compositions* — the
interesting thing is the relationship between the parts, and a generator that
scatters the same parts randomly produces texture rather than design.

**The unit of authoring gets SMALLER than a segment.** Today a `.seg` is 16–30
rows and is a whole level. A set-piece is a 4–8 row full-width slice, or a
smaller patch with a declared footprint, and the generator slots it into a
skeleton that has room for it. Variety then becomes combinatorial rather than
linear in authoring days.

### Layer 3 — hazard dressing (GENERATED FROM A BUDGET)

Which enemies, how many, where. Explicitly a separate pass over a finished
layout, because that is what makes the question the user actually asked
answerable:

> *how would we take the same map layout and think about both enemy dense and
> hazard dense versions?*

Same layers 1 and 2, different layer 3. A **theme** is a budget plus a
whitelist: `{shooters: 8, rushers: 0, plinko: 0, spikes: 12, ammo: 3}` against
the same skeleton is the environmental version of a map whose enemy version is
`{shooters: 2, rushers: 6, plinko: 3, spikes: 0, ammo: 1}`. Placement is by RULE
against the terrain — a shooter wants cover in front of it and a clear lane, a
spike block wants a corridor a player must cross — so the same rules produce
sensible placement on any skeleton.

This also retires an M15 note: a validator rule refusing a turret with no cover
in front of it stops being a lint and becomes the *placement rule itself*.

---

## Part 2 — Completability is a REJECTION ORACLE, not a construction

The single most important architectural statement in this document:

> **Generate, then validate, then reject and reroll. Never construct-and-hope.**

`SegmentValidator` already floods from the entry row with a rise budget and does
it twice — once at `SOLO_RISE` (1) and once at `ASSISTED_RISE` (4) — so "there is
no way up" and "a solo player is stranded" are the same check with different
numbers. That is exactly the right shape and it is already written. What changes
is its job: it stops being an authoring lint and becomes the generator's accept
test, run thousands of times in a soak rather than once per file.

Three extensions are needed, in increasing order of difficulty.

### 2z. THE JOIN IS A CONTRACT, NOT A SEARCH

Taken 2026-08-15, and it makes most of the rest cheaper.

A run is segments concatenated, so "is the run crossable" looks like a
reachability question over the whole run. **It is not, if the boundary is a
contract.** The rule is as weak as it can be:

> **ANY OVERLAP IS ENOUGH.** Segment B may follow segment A if at least one cell
> is solid on both sides of the join.

and it is bought by what a segment must prove about itself:

> **Every solid cell of its exit row is reachable from SOME solid cell of its
> entry row.**

Today's `_exit_reached` proves something much weaker — that SOME exit cell was
reached — so a segment can pass with one corner of its exit reachable while the
next segment enters from the other.

### The regroup row, which M16 already enforces

The obvious hole in "some entry cell" is that a segment can split into lanes that
never meet, and a player on the wrong lane is stuck. **The answer is a row where
everything is solid, and the run already has one at every round boundary:**
`_check_gates` refuses a boundary strip with a gap, so a round begins and ends on
a full-width standable band.

That band is a REGROUP POINT, and it is what makes dual path free:

```
    XXXXXXXX      lobby        every cell solid: the party can be anywhere
    XX____XX      section      two lanes, and no way across between them
    XXXXXXXX      lobby        solid again: the party is back together
```

Between two regroup rows the deck may split, braid and rejoin as it likes. Each
lane is entered from the band behind it and delivers to the band ahead of it, and
neither lane has to know the other exists. **A lobby is always at least as wide as
everything that connects to it**, which is free, because a lobby is generated
(2y) and a solid rectangle is the easiest thing to generate.

**AND IT HAS A MINIMUM WIDTH OF ITS OWN**, independent of its neighbours. A lobby
that merely fits the section either side of it could legitimately come out three
cells wide, and that is not a lobby — it is a corridor with a rack in it. The
floor is set by what the space is FOR: four players standing around without
shoving each other off, a rack read as a row of choices rather than a queue, and
room to walk past somebody who is deciding. `LOBBY_MIN_WIDTH` is that number and
the generator takes `max(min_width, widest neighbour)`.

It costs nothing structurally, because a lobby wider than its neighbours is
exactly the regroup row this section is about — the surplus is just more solid
cells on a row that was already fully solid.

### So the two-token flood is NOT needed

An earlier draft had dual path requiring reachability over `(cell_a, cell_b)`
— two tokens in a shared state space, quadratic, and the one item worth a
standalone prototype. **That was a consequence of trying to prove connectivity
without a regroup row.** With one, each lane is checked independently by the
ordinary flood and the band does the joining.

What is left of the two-player question is genuinely two-player: **a button on one
lane opening a door on the other.** That is not a second algorithm — it is the
`(cell, switches)` product flood of 2b, which Phase 7 builds anyway, with the
lanes as ordinary cells. A party of one simply never satisfies it, which is
exactly what "report completability per party size" is for.

Dual path therefore costs no reachability machinery at all. What remains of its
risk is the camera and the leash, which is Part 5.

**It exposes something weak that exists today.** `_exit_reached` returns true if
ANY solid cell of the exit row was reached, so a segment can pass validation with
only one corner of its exit reachable while the next segment enters from the
other. The strengthened property is the claim that was always worth making.

**THE ONE DESIGN THIS FORBIDS is dual path**, and it forbids it correctly: a
segment with two lanes that never meet cannot promise "any entry cell reaches
every exit cell", because entering left means exiting left. If dual path
survives Phase 4, such a segment declares its connectivity as GROUPS — which
entry cells reach which exit cells — and the join check becomes an intersection
against the group you actually arrived in. Still local, still O(1)-ish. Nothing
else on the list needs it.

**M16 already did half of it.** `_check_gates` refuses a boundary strip with a
gap, so round boundaries span the full width by rule and lobby-to-section joins
were always fully overlapping. The unguarded joins are SECTION TO SECTION inside
a round: four of the six.

### 2y. Lobbies are GENERATED, and width is a fiction

Two consequences of the above, both of which delete work.

**A LOBBY IS PARAMETRIC, so it should be generated on demand rather than
authored.** It is a solid rectangle, a rack, some hats, and a checker band at
each end — there is nothing in it a person needs to decide. `segments/lobby.seg`
becomes the generator's template rather than a file the pool loads, and a lobby
is then built to fit whatever it finds itself between. It is also the safest
place in a run to put a transition, because it is the one stretch with no hazards
on it.

**AND VARIABLE WIDTH IS NOT A FORMAT CHANGE AT ALL.** The loader refuses a width
mismatch ("refusing to join a step into the deck") and that looked like a problem
for narrow sections. It is not: keep every segment the same width and draw
narrowness as HOLES in the outer columns. Width becomes a fiction, "narrow" is
just a solid run with holes either side, and the join contract only ever asks
which cells are SOLID — which is exactly the overlap rule above.

The parapet behaviour falls out correctly for free. `has_wall` returns true only
where the neighbour is off the SIDE of the bridge, so an interior hole carries no
railing (deliberate since M2 — railing them made it impossible to shove a stone
through one). **A narrow section drawn this way is automatically unrailed and
therefore automatically more dangerous**, which is what a thin bridge should be
and what would otherwise have needed a rule.

### 2a. The flood must know the party's VERBS

Reachability today is a function of rise budget. It becomes a function of
**capability**:

```
can_traverse(edge, party) where party = {size, has_legs, has_boost, can_climb}
```

- a ladder is a vertical edge, available always (`ASCENDER_CONTENTS` already
  lists it — the flood has known about ladders since M2; only the player's verb
  is missing)
- a boost is a vertical edge available only when `size >= 2`
- legs are an edge onto layer 2, available only while that special is held

**And the answer must be reported per party size**, because "completable" is not
one bit. A segment can be solo-completable, two-player-completable, or
neither — and the run assembler needs to know, because a party of one must never
be handed a segment that needs a boost.

### 2b. Conditional edges: doors, timed blocks, elevators

A door is an edge that exists only if a button has been pressed, and the button
may be on the far side of the thing the door gates. That is no longer a plain
flood — it is reachability over a state space of `(cell, switches_pressed)`. With
a handful of switches this is tiny and exact; it is the classic
"keys-and-doors" reachability and it is solved by flooding the product graph.

**Bound the switch count in the format** (say four per segment) so the product
stays trivially small. A generator that can produce ten interlocking switches is
a generator that can produce a puzzle nobody can verify.

An elevator and a timed block are edges that exist *periodically*. Treat both as
**always available with a time cost** for the purposes of completability — a
player can wait for an elevator — and let the round clock express the cost.
A timed block that falls is the dangerous case: it is an edge that exists ONCE.
If a run's only route crosses one, the run is completable exactly once, which is
fine for a forward-only bridge and must be asserted as such.

### 2c. Dual path — RETIRED as a reachability problem

Previously the hard one, and dissolved 2026-08-15 by the regroup row in 2z. Left
here as a record of the reasoning rather than as work: a split deck between two
full-width bands needs no two-token flood, because each lane is an ordinary route
from one band to the next.

---

## Part 3 — The deck stays a HEIGHTFIELD. Layers are cut.

Every "multi-level" idea — split level, interior walls, walking on top of the
level — looks like it needs a surface above another surface, which
`height_at(cell)` cannot express. It was going to be the largest data model
change in this document.

**It is not needed, and the reason is one line of design:**

> **LEGS LET YOU JUMP UP ONTO THINGS. NOTHING EVER NEEDS TO GO UNDER THEM.**

If no solid cell has walkable space beneath it, there is no second surface
anywhere, and the heightfield covers the entire wish list — Legs included. So
layers are CUT, not deferred. What replaces them is a change to how thick a deck
cell is.

### The adjacency thickness rule

A deck cell is currently a slab hanging a constant `DECK_THICKNESS` (1 m) below
its top face, so a cell at height 4 beside one at height 0 floats seven metres up
with an open void under it. Instead:

```
underside(cell) = min(own_top — DECK_THICKNESS,
                      lowest top face among solid neighbours)
```

A cell at a height CHANGE extends down to meet its lowest neighbour. A cell whose
neighbours match it stays exactly as thin as it is today.

**Which means the middle of a plateau is never thickened.** Only the perimeter
is, and the perimeter is what seals it — the hollow interior is invisible
because you cannot get to a sightline that sees in. That is cheaper than dropping
every raised cell to a global base, and it produces no geometry anywhere the
terrain is flat.

**It replaces the ramp skirt rather than joining it.** `_build_ramps` already
emits "the same box the deck would have had" to close the void under a ramp's
tapered end (the 2026-08-13 fall-through bug). That is this rule applied to one
shape; generalising it retires the special case.

### Two decisions, both taken 2026-08-15

- **8-WAY ADJACENCY, not 4.** With 4-way, a DIAGONAL height change leaves a thin
  vertical slit at the corner — and the camera looks down the bridge at 45
  degrees, which is exactly the angle that catches it. 8-way closes it for
  nothing, so the neighbour set is the eight surrounding cells.
- **A PLATFORM WITH NO SOLID NEIGHBOUR STAYS THIN.** There is no floor beneath it
  to stand on, so there is nothing to hide. It is the one place the old floating
  look survives, and only while falling past it. The alternative — dropping it
  to a global base so it reads as a pillar — is prettier and less honest about
  what it is; a thin platform over nothing IS a thin platform over nothing, and a
  player who reads it that way is reading it correctly.

### What it costs elsewhere

`_merge_deck_collision` groups cells into greedy rectangles by kind AND HEIGHT.
Thickness now varies per cell, so the key becomes **(kind, height, underside)**:
plateau edges stop merging with plateau interiors. More boxes, but only ever at a
height change, which is where a merge was going to break anyway.

---

## Part 4 — The items, by what they actually cost

Sorted by cost, because the cheap ones should land first and prove the pipeline.

### Self-contained — no new system

| item | why it is cheap |
|---|---|
| **Trees, half-walls (partial cover)** | `SIGHT_BLOCKERS` already exists as a mask and `_clear_line` already uses it. Cover is a content glyph, a collider on that layer, and a mesh. **A half wall blocks sight and not movement; a tree blocks both.** That distinction is one bit and it is the whole design. |
| **Spike blocks** | A cell hazard with a phase. Same shape as a mound: authored cell, sim-owned body, deals a hit through the damage matrix M15 already built. The phase must be sim state and derived from the tick, not a local timer, so every machine agrees. |

### One new system, two features

| item | the system |
|---|---|
| **Destroyable squares** + **timed blocks** | **MUTABLE TERRAIN.** Both are "a cell stops being solid at runtime". The hard part is not the rule, it is that deck collision is MERGED into greedy rectangles at build time, so removing one cell means re-merging that segment's shape — and the change must replicate. There is precedent for the wire format: `spent_shooter_layout` / `apply_spent_mounds` already ship a cell-level diff of what has changed. Build it once and both features fall out; timed blocks are destroyable blocks with a trigger. |

### New systems

| item | why |
|---|---|
| **Ladders** | The flood already knows (`ASCENDER_CONTENTS`). What is missing is a player STATE — a climb, like `LEDGE_HANG` — and per CLAUDE.md **anything affecting stepping must be in `capture_state()` or client replays diverge.** |
| **Buttons and doors** | A persistent, replicated world state machine, plus the product-graph flood of 2b. The biggest gameplay-logic item on the list. |
| **Elevators** | A moving platform, and CLAUDE.md's riding note is a warning: Godot's built-in platform transport is engine-internal state `capture_state()` cannot restore. An elevator carrying a *predicted* player is the worst netcode case in this document. Consider making elevators HOST-ONLY cargo — a player on one stops being predicted while riding. |
| **Legs** (jump up onto raised deck) | Needs no new data model at all — Part 3. It is a special that changes which edges the flood may use, and the first item making completability depend on INVENTORY. |
| **Teammate boost** | A co-op verb near the existing shove. Makes `ASSISTED_RISE` a real mechanic rather than a notional one, and is the cheapest way to make two-player runs structurally different from solo. |

### Environment types → generator parameters

Each of these is a knob on layer 1, not a feature:

- **thin paths / gap density** — a density parameter, already expressible
- **steps down** — the height profile allows negative deltas. `_next_height` stacks
  `exit_height()`, so a net-descending segment already works; what is untested is
  whether the *validator's* rise budget handles descending routes, since falling
  is free and climbing is not
- **split level** — two heights side by side, which the heightfield already does
- **interior walls** — a tall cell in the middle of a deck
- **variable width** — NOT a format change. Every segment keeps one width and
  narrowness is drawn as holes in the outer columns; interior holes carry no
  parapet, so a thin section is unrailed and dangerous for free. See 2y.
- **dual path** — see below

---

## Part 5 — The risks, and what is left of them

There were two. Part 3 dissolved the first; the second is still real and is
answerable in a day with a hand-authored map and no new systems.

### Risk 1: things above the player — KNOWN, WITH THREE ESCAPES

The camera is a fixed-yaw 45-degree view, so anything above a player hides them.
Downgraded from a risk to a decision on 2026-08-15: it has three answers, and the
plan is to try them and adjust rather than to pick one on paper.

1. **NEVER THE SAME LOCATION.** Heights vary but no surface sits over another.
   Costs nothing, needs no new system, and per Part 3 it covers every environment
   idea except Legs. **This is the default**, and the reason layers are deferred.
2. **LET THE CAMERA MOVE** to keep the player in view — lift, or push in, when
   something comes between the camera and a body. Contained in
   `bridge_camera.gd`, and the escape that costs the least design.
3. **CHOOSE A DIFFERENT ANGLE** and design against it. The most expensive: the
   45-degree view is what makes the checkerboard read as distance, and every map
   so far was authored for it. Also the most permanent, if overlapping levels
   turn out to matter.

Try them in that order — but per Part 3, (1) is now not merely the default, it
is SUFFICIENT. The adjacency thickness rule means nothing is ever above a
walkable space, so (2) and (3) are held in reserve for a problem that may never
arrive.

### Risk 2: dual path versus the leash and one camera

**Narrowed 2026-08-15.** The reachability half is gone (2c); what is left is the
half that was always the bigger one.

The whole session is built on the party staying together: `LEASH_SOFT` 40 m,
`LEASH_HARD` 70 m, ONE camera, and a streaming window around the group. **Dual
path asks for the opposite** — two players deliberately separated, each needing
to see where they are going.

That is a camera and session question, not a generation one. Options are
split-screen (which changes the whole presentation), a camera that zooms out
(limited), or lanes that stay within one screen width — which is probably the
honest answer, and makes dual path mean *two lanes a few metres apart* rather
than *two routes*. Note that the cheap answer is also the one the regroup row
already supports, so nothing is blocked on deciding it.

---

## Part 6 — Implementation order

Reordered 2026-08-15 after walking the dependencies rather than the wish list.
Three principles, in priority order:

1. **A MULTIPLIER GOES AFTER THE CHEAP THINGS IT MULTIPLIES.** The dressing pass
   is `layouts x content types`, so its value is set by what there is to dress
   with. Two earlier drafts got this wrong in opposite directions — first
   putting content before the pass ("cheap content proves the pipeline"), then
   the pass before content ("a pipeline before the things that go in it"). Both
   were reasoning about plumbing. **Count instead:** today the pass would have
   FOUR hazard types (skirmisher, turret, mound, plinko shooter) and three
   layouts, and of the four themes wanted it could express plinko/survival well,
   shooter-heavy BADLY (no cover exists, so it is not a theme, it is a
   punishment), and jumping and mazelike not at all. So the cheap inputs go
   first and the multiplier follows them. The re-plumbing this "costs" is a glyph
   and one table row.

2. **NOTHING IS BUILT WITHOUT A CONSUMER.** The thickness rule has no map that
   exercises it until the generator exists, five phases away. Pair it with a
   hand-authored split-level segment, which is also a new environment type
   delivered on the same day.
3. **PRESENT RISK BEATS FUTURE RISK.** The oracle was scheduled first to guard
   generated terrain. There is an unguarded hole in the terrain that exists
   TODAY, and it is the same work.

### Phase 0 — the join contract

`SegmentValidator` is called from tests and nowhere else, and `_flood` starts at
row 0 of ONE segment and stays inside it. **Nothing checks that a run's segments
connect.** Segment A can exit solid only on the left while segment B enters solid
only on the right, and the party stops at a seam no authoring pass looked at.

It works today by luck: the three pool segments are near-solid across their full
width at both ends. Thin paths and variable width both spend that luck, and M16
made a round five segments, so a run has six joins per round rather than one.

Per 2z: strengthen the per-segment flood to "from any entry cell, every exit cell
is reachable", and have the assembler refuse a join with no solid overlap. Small,
provable rather than sampled, and worth doing even if generation is never built.

### Phase 1 — cover and spike blocks

The cheapest content on the list, and the one that changes what a theme can BE.
Trees and half walls need only a collider on `SIGHT_BLOCKERS`, which already
exists and which `_clear_line` already uses; spikes are a mound-shaped hazard
with a tick-derived phase.

**Cover is what turns "lots of shooting enemies" from a punishment into a
theme.** Without it, an enemy-dense section is a corridor you cross while being
shot; with it, the same section is a route with decisions in it. It is the single
highest-leverage content item for the same reason it is the cheapest: the
shooters already exist and already do line-of-sight.

### Phase 2 — deck thickness by adjacency, WITH a split-level segment

The rule from Part 3, and a hand-authored segment with a real tall step to
exercise it. The rule alone is untestable and the segment alone falls through, so
they are one phase. Delivers split level — a new kind of place — with no
generator involved, and gives the dressing pass a fourth layout to work over.

### Phase 3 — the dressing pass and themes

Layer 3 with a budget. NOW it has something to multiply: four layouts, six hazard
types, and cover to make the shooter-heavy theme fair. The same ground played as
enemy-dense or hazard-dense is a different table, and with Phase 1 in place that
is finally all four of the themes wanted rather than one.

Still before any generated terrain, and still the highest variety-per-day item on
the list — it has simply been given a bigger number to multiply.

**SHOULD IT WAIT FOR THE GENERATOR TOO?** The multiplier argument appears to say
yes: generated terrain is unbounded layouts, which is a far bigger number than
four. Two reasons it does not.

**The principle says CHEAP inputs, and the generator is the most expensive thing
in this plan.** Waiting for it puts the cheapest high-value item in the project
behind the largest build, so the first felt variety arrives last. If the
generator turns out slow or hard, everything visible is stuck behind it.

**And the dependency runs the other way.** Layers 1 and 3 are separate ON PURPOSE
(Part 1): the generator produces terrain, the pass fills it. If the generator
lands first it either ships bare terrain or grows placement logic of its own
— which is the two layers collapsing into one, and the exact thing the
three-layer split exists to prevent. **The pass existing first is what gives the
generator somewhere to send its output on the day it works.**

What IS true is that the placement rules will be tuned against four hand-authored
layouts and will need re-tuning against generated ones. That is expected and
cheap: the rules are data, and the pass that applies them does not change.

### Phase 4 — generated lobbies, as the PILOT generator

Was "the dual-path decision", whose entire stated purpose was to tell Phase 5
whether dual path is a skeleton parameter or a two-token reachability project.
**2z answered it: parameter.** So the spike is gone and what replaces it is the
work 2y created.

Generate the lobby instead of loading `lobby.seg`: a solid rectangle at
`max(LOBBY_MIN_WIDTH, widest neighbour)`, a rack, some hats, a band at each end.

**It is the ideal first thing to generate**, which is why it gets a phase of its
own rather than being folded into Phase 5:

- trivially parametric — there is nothing in a lobby a person needs to decide
- **it cannot hurt anybody.** A lobby has no hazards, so a generation bug costs a
  strange-looking room rather than a run nobody can finish
- it exercises the WHOLE pipeline end to end — generate, validate against the
  Phase 0 contract, assemble, play — on the one piece of content where being
  wrong is cheap

Every later generator inherits a proven loop. Getting the first one wrong on
terrain full of holes and shooters is how you end up debugging the generator and
the level design at the same time.

### Phase 5 — the terrain skeleton generator

Width, height profile, gap density, set-piece slots. Everything it needs is now
in place: the contract to reject on (0), content to build with (1), a fourth layout and
safe height variation (2), something to dress it with (3),
thickness safety for the height variation that makes it interesting (2), and a
proven generate-validate loop (4).

**Three things it no longer has to solve**, all removed by decisions taken while
planning rather than by work:

- **width** — not a parameter of the format. One width per segment, narrowness
  drawn as holes in the outer columns (2y), and the unrailed edge comes free
- **dual path** — an ordinary skeleton parameter. Split the deck between two
  regroup rows and the existing flood checks each lane (2z)
- **overhangs** — do not exist. Nothing is ever above walkable space (Part 3)

### Phase 6 — conditional access

The capability-aware flood, then ladders (a climb state), the teammate boost, and
Legs. The assembler starts filtering by party size. **The flood work comes first
within this phase**: authoring a boost-only route before the flood understands
boosts is how an unfinishable segment ships.

### Phase 7 — buttons and doors

Product-graph reachability over `(cell, switches)`, bounded at four switches per
segment.

### Phase 8 — mutable terrain

Destroyable squares, then timed blocks. Moved late from second: **nothing
depends on it.** It is a self-contained feature with real replication cost, and
its position should be decided by how much it is wanted rather than by what it
unblocks.

### Phase 9 — elevators

Last, because it is the only item whose failure mode is a netcode bug rather than
a level bug: Godot's platform transport is engine state `capture_state()` cannot
restore. Consider making a rider host-only cargo.

### What four planning decisions did to this order

Recorded because the order moved more from THINKING than it will from any single
day of work, and because the deletions are the valuable part:

| decision | effect on the plan |
|---|---|
| **layers cut** (Part 3) | a whole phase deleted; the thickness rule took its place at Phase 2 |
| **the join is a contract** (2z) | Phase 0 shrank from "flood every assembled run" (a sample) to "strengthen one flood and check an overlap" (a proof) |
| **lobbies generate, width is a fiction** (2y) | deleted the transition piece and the loader change; ADDED Phase 4, which is the only thing on this list that grew |
| **the regroup row** (2z) | deleted the two-token flood and the dual-path spike outright |
| **counting what the pass would multiply** | cover and spikes moved AHEAD of the dressing pass: four hazard types and no cover could express one of the four themes wanted |

Net: **four items left the plan and one joined it.** Nothing that left was
deferred {D} the two-token flood, the run-level soak, the transition piece, the
loader width change and the layer system are all gone rather than postponed,
because in each case a cheaper structure made the problem not exist.

### What the order deliberately does NOT do

- **It does not build the generator early.** Phases 0 to 4 add variety with no
  generated terrain at all, which means the generator lands into a project that
  already knows what a good section looks like.
- **It does not front-load systems.** Buttons, mutable terrain and elevators are
  the three biggest builds and all three are after the point where the game is
  already more varied than it is today.

---

## What this does not decide

- **Whether generated terrain is FUN.** The oracle proves crossable; nothing
  proves interesting. Expect the first generated runs to be correct and dull, and
  expect the fix to be more and better set-pieces rather than better parameters.
- **How many segments a round should be.** M16 left that open and it interacts
  with everything here: a five-segment round of generated terrain is a lot of
  bridge to get wrong at once.
- **Difficulty progression.** The pool has a `difficulty` field nothing reads yet.
