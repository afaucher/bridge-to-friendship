# Death fragments

What an enemy leaves behind when it is killed. Rushers, zombies, skirmishers and
turrets; the player is deliberately out of scope until there is a life limit for
a death to mean something.

The look: **a body fragments into parts that resemble the whole.** Not a puff of
particles and not a ragdoll — the pieces of the thing, in the shape of the thing,
until something disturbs them.

## The frame of death has to be invisible

The one hard requirement, and everything below follows from it. A body that
vanished and was replaced by a heap of approximately-body-shaped chips would be a
silhouette popping on the exact frame the player is looking straight at it —
which is worse than the pop it was built to remove.

So the fragments **tile the body exactly**. On the frame it appears, the pile is
the body: same outline, same size, same colour, same place. `test_fragment_shape`
asserts it three ways, and the strongest of the three is that every point inside
the body is inside exactly one fragment — a gap and an overlap both fail it, in
the place where they are. A bounding volume could not see any of this; the union
of a set of fragments has the same AABB whether they tile the body or sit in a
heap.

## One shape model for every character

A rusher is a tapered cylinder, a skirmisher is a capsule, a player is a
cylinder. Four cases would be four sets of bugs. One case is a **solid of
revolution** — a profile `r(y)` spun about Y — and `fragment_shape.gd` never
learns that rushers exist.

### A body is a list of parts

Not every body is one lathe, and pretending otherwise silently dropped things. A
**zombie** is a torso and two arms; a **turret** is a tapered base, a ring and a
box gun barrel, in two different greys. So a body is a list of **parts**, each
either a lathe or a box, each with its own placement on the body and its own
colour. `_parts_of` walks the scene for visible `MeshInstance3D` descendants
rather than looking for a node called `Mesh`.

A box splits by the same rule the lathe does — cut the longest physical side at
equal volume — which on a box is simply the midpoint of its longest axis, since
volume is linear along all three. So a box needs no special argument about
*where* to cut, only about *which way*, and the answer is the same answer.

**One greedy loop runs over every part at once**, rather than a per-part budget
handed out in proportion to volume. That is what makes a turret's gun barrel
break into pieces the same size as its base. A per-part budget gives every part
its own idea of how big a fragment is, and a body whose pieces do not match reads
as two objects rather than one that broke.

A mesh the fragmenter cannot lathe or box is **skipped**, not approximated — a
visible gap someone will report beats a corpse quietly the wrong shape.

Each part is also drawn at **its own source mesh's resolution**. A turret's base
is authored with `radial_segments = 8` because a chunky octagon is the look;
re-lathing it at the default 32 made the corpse rounder than the living turret,
and an octagonal base becoming a smooth one on the frame of death is the pop this
feature exists to remove. Resolution is part of a shape, and no tiling or volume
assertion can see it — it took one glance at the contact sheet.

The profile is read off the mesh the game actually draws, at runtime, not
restated as constants. There is one record of how big an enemy is and it is the
`.tscn`.

A fragment is a cell in **lathe space**: `y ∈ [y0,y1]`, `θ ∈ [θ0,θ1]`, and a
radial band expressed as a *fraction* of the local `r(y)` rather than a distance.
That last part is what lets one cell description work on a taper — a cell at
`p 0.5..1.0` is the outer half of the body at every height, so the pieces of a
cone taper with the cone instead of being cut by a cylinder that does not fit it.

## The split

Recursive binary subdivision, greedy: repeatedly cut the largest remaining cell
until there are exactly N.

**Which axis** — the one with the largest *physical* extent: height, arc length
at the mid radius, or radial thickness, all in metres. That single rule is what
makes the pieces resemble the whole. Always cutting the longest side drives every
cell toward the same proportions at the same time as it drives them toward the
same size. A fixed axis order gives splinters; a random axis gives a mess.

**Where** — at equal volume, which is not the midpoint on two of the three axes:

| axis | split at | why |
|---|---|---|
| angle | the midpoint | volume is linear in θ |
| radius | `sqrt((p0² + p1²) / 2)` | equal *area* annulus. Halving a disc at 0.5 gives an inner core of a quarter the volume against an outer ring of three quarters |
| height | where `∫r²dy` is halved | the midpoint on a cylinder, well below it on a taper, well inside the cap on a capsule |

### Keep the count a power of two

Every cut divides a piece into two of exactly equal volume, so at 2, 4, 8, 16,
32 or 64 every fragment is exactly the same size and **at anything else they are
not**. Measured at 20: sixteen pieces at full size and four at half, a spread of
exactly 2.000, identically for every character. That is arithmetic, not a tuning
trade-off. `test_fragment_shape` asserts the spread is 1.0, so a non-power-of-two
count fails loudly rather than quietly making deaths lumpy.

`CORPSE_FRAGMENTS` is 32. At 16 the pieces are large curved plates and the death
reads as the body *peeling*; at 64 it reads as gravel; 32 is chunky enough to
read as pieces of a body at the distance this game is played at. It is also a
rigid-body count — a pack of eight zombies dying together is 256 of them — which
is the real ceiling on it.

**Exactness is only available to a one-part body.** A single lathe cut to a power
of two gives fragments of identical volume. A body of several parts cannot: the
greedy starts with one cell per part, and no number of halvings makes a turret's
base agree with its gun barrel. What greedy still buys is the top end — nothing
ends up more than twice the average, so there is never one giant slab among the
chips. The *bottom* end is a fact about the body rather than a defect: a zombie's
arm is smaller than a fragment of its torso ought to be, so it is never split,
and you cannot make an arm bigger. `test_fragment_shape` asserts exactness for
the one-part bodies and the top-end bound for the rest, and prints the raw spread
either way.

## The corpse

Two states.

**INTACT** — the fragments drawn in their assembled positions, frozen, costing
the solver nothing. It stands until something disturbs it or `CORPSE_LIFETIME`
runs out.

**SCATTERED** — every piece unfrozen with an impulse radial from wherever the
disturbance came from, falling off with distance so a nudge to one side tips the
pile over rather than detonating it, plus spin. Fades and frees on
`CORPSE_DEBRIS_LIFETIME`, measured from the scatter rather than from the death,
so a pile burst on its last standing second still gets a full flight.

An explosive kill skips INTACT entirely and arrives scattered, with the blast as
the impulse origin: a blast never leaves a body standing.

## It is cosmetic, and that is a decision with teeth

Debris is on its own collision layer that nothing masks but the world and other
debris. A player cannot be pushed by it, blocked by it, or stand on it. Three
things follow:

* **It needs no replication.** Nothing authoritative reads a fragment, so two
  machines may tumble the same corpse differently at no cost.
* **It cannot kill anyone.** Physics debris that could shove would be a new way
  to go off a bridge, from an object with no verb to answer it.
* **It cannot wedge a doorway.** A corpse that blocked movement would be terrain
  appearing mid-fight.

The bump is therefore detected on the *corpse*, not on the pieces — one proximity
check while the pile is intact, the same shape as a mound waking or a grave
opening. Once scattered the fragments are inert scenery with a fuse on them.

The pieces are `RigidBody3D`, which is the second exception to this project's
rule that everything is a hand-written integrator. Same argument as the plinko
ball: there is no *designed rule* about where a chip of a dead zombie should
land, and the determinism objection does not apply because nothing replays a
fragment.

## What crosses the wire

Only the death, and only because it has to be **told rather than inferred**. A
client sees nothing but an enemy ceasing to be mentioned in the snapshot, and
that is equally what a rusher burrowing away and a body falling off the bridge
look like. Guessing would leave rubble every time something quietly expired off
the end of the deck. `_corpse_seen` is the same shape, and has the same reason,
as `_blast_seen` next to it.

Everything else each machine works out for itself: the cutting is fully
deterministic, and the scatter seed is derived from the position both ends
already agree on.

## Three ways to stop existing, and only one is a death

`_retire_enemy` is the single door out of the world for every enemy. A rusher
that outlives its welcome burrows back down; anything can go off the side; a
gunner is culled once the party has walked past it. None of those leaves rubble,
and the culled one least of all — it is behind the party, out of sight, and the
pieces would be a lie about a fight that never happened.

## How it is tested

Three tiers, cheapest first.

1. **`test_fragment_shape`** — the cutting, over every character, with no world,
   no physics and no rendering. Sums, disjointness and single-coverage of
   interior points (all per part, since two parts of one body are allowed to
   overlap in space — a turret's ring sits in the column above its base), size
   equality, and determinism.
2. **`test_corpse`** — the behaviour, killing each enemy in a real world. Where
   the pile stands, that it is frozen and intact, that a player walking into it
   scatters it, that a blast never leaves one standing, and that the deaths which
   are not deaths leave nothing.
3. **`art/shots_corpse.json`** — the look, across every kind at once, from one
   windowed command:

   ```
   godot --path . --run-shots art/shots_corpse.json
   ```

   Alive / intact / bumped / blasted per enemy, plus a 16-vs-32-vs-64 density
   comparison. `--headless` disables rendering, so this is a dev-box run and not
   a gate.

### The mesh is a separate question from the cut

Everything in tier 1 is about the *subdivision* — that the cells tile the body —
and all of it passed while the fragments were being drawn with ledges down the
rusher cone, and again while every fragment was a hollow shell. The cells were
exact both times; the drawing was wrong.

So `_check_normals` measures the drawn mesh against the cell it came from, using
the divergence theorem: for a closed surface, `(1/3) Σ area · (centroid · normal)`
is the enclosed volume, which catches a missing face, an inconsistent winding and
an inward winding in one number. It is computed from the *stored* normals, so it
is convention-free, and compared against a volume computed from the *cell*, so it
is not the mesh agreeing with itself. For the player — a pure cylinder, whose
only inscription is angular — the answer is predicted rather than tolerated: a
regular 32-gon is `(32/2π)·sin(2π/32)` = 0.99359 of its circle.

Three rendering faults have now been found this way, and none was visible to
tiers 1 and 2:

* a transparent material not writing depth, so 32 pieces sorted by origin and an
  intact corpse rendered with a quarter of itself missing;
* per-piece angular tessellation insetting chords differently, putting ledges
  down the cone;
* the two radial end faces wound opposite to the other four, so every piece was
  a hollow shell enclosing 14% of its cell — **invisible while a corpse is
  intact**, because an inward-facing surface inside an assembled solid is hidden
  by the solid.

## Not done

* **The player**, until a life limit exists. Two things are missing, and the
  second only surfaced once bodies became multi-part:
  * *When.* A downed player is revivable and should stay a body, so the pile
    belongs at the drone return rather than at the moment they go down.
  * *What counts as body.* A player comes back as three parts — the body, and
    the sidearm's grip and barrel — and a sidearm is **gear**, not body.
    Visibility already excludes a stowed shield and will never exclude a drawn
    pistol. Measured, including the sidearm puts the fragment spread at 76.8,
    because a grip is a thousandth of a cubic metre and is never worth
    splitting. A corpse needs a rule for telling a body from the things it is
    carrying.
* **The player's beak** is a `PrismMesh`, which is neither a lathe nor a box, so
  it would be skipped. Same answer as the sidearm, or a third part kind.
