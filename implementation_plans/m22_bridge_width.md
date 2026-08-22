# M22 — bridge width, for real

Written 2026-08-20, after a playtest question ("we did a whole milestone around
map variety — where's the width variety?") turned up that M17 never built it.
`design_ideas/world_generation.md` names width as Layer 1, generated, parametric,
"the properties a player reads as 'a different place'". What shipped instead is
a documented workaround, in the generator's own words:

> "Narrowness is drawn as HOLES in the outer columns rather than a width change:
> the loader refuses a width mismatch, a fiction is cheaper than a format"
> (`segment_gen.gd:183`)

That fiction has a real cost: an interior hole gets no parapet by deliberate M2
rule (`segment_data.gd:148`, "a gap in the decking is broken structure, not a
railed balcony"), so every "narrow" stretch the generator produces today is
unrailed and can be walked or shoved off the side by accident. It reads as
missing floor, not as a narrower bridge. This milestone makes width a first-class
generated property with real edges, and asks nothing of `has_wall` or the join
contract that they cannot already mostly do.

---

## What's actually there today

`BridgeGrid.width` (`bridge_grid.gd:36`) is set once, from the first segment
loaded, and held for the entire run:

```
func load_segment(seg) -> void:
    if _segments.is_empty():
        width = seg.width
    elif seg.width != width:
        printerr("... refusing to join a step into the deck")
        return
```

Every generated section is called as `SegmentGen.section(width, ...)` — the same
value, every time (`bridge_grid.gd:150-152`). `width` is also the coordinate
frame: `GridConfig.cell_centre`/`world_to_cell` centre the deck on `x = 0` using
it, so it is read by the camera, the HUD, spawn-lane math, and every world↔cell
conversion in the game. **Nothing about that is wrong** — a stable coordinate
frame for the whole run is worth keeping.

What the generator narrows today is a *usable* strip inside that frame: rows
tagged `narrow` cut `margin` columns off each side as `Kind.HOLE`
(`segment_gen.gd:387-413`). `has_wall` — the function that derives a parapet —
only ever fires at the true grid boundary:

```
func has_wall(x, z, dir) -> bool:
    ...
    var nx: int = x + step.x
    return nx < 0 or nx >= width          # segment_data.gd:172
```

A margin hole is *inside* `[0, width)`, so it never satisfies that check. Hence:
unrailed.

---

## The decision: one canvas, per-row setbacks

Two ways were on the table:

1. **A segment declares its own width; joins between differing widths are
   resolved at the boundary** (a taper, or a generated transition piece).
2. **The canvas — the coordinate frame — stays fixed for the whole run, and
   "width" becomes where the *solid edge* sits within that canvas, per row.**
   Same data model as today's margin holes, but the edge becomes real: it gets
   a parapet, because it's derived from the same rule a true edge already uses.

**(2) is the plan.** Reasoning:

- **Nothing about the coordinate frame changes.** `world_to_cell`, the camera,
  the HUD, `entry_spawn_cell`'s lane math, `SimConfig.ROUND_WALL_HEIGHT`'s "wider
  than any bridge" assumption — none of it needs touching, because `width` (the
  canvas) never varies mid-run. That's the whole blast radius of option 1 gone
  for free.
- **The join problem in option 1 turns out not to exist once you look at what a
  join already requires.** `segment_gen.gd:427-433` already forces every
  segment's entry and exit row to flat, full-canvas DECK — narrowing is
  explicitly suppressed on those rows ("THE ENTRY AND EXIT ROWS ARE FLAT DECK").
  That's the same invariant a differing-width join would need a taper *for* —
  it's already load-bearing today, for a different reason (stacking height
  cleanly). A setback that respects it never produces a step at a segment
  boundary, so there is no join-time case to special-case. The one rule this
  milestone adds is naming that invariant explicitly and keeping the regroup
  bands (`_check_gates`) full-width too, which M16 already requires for an
  unrelated reason.
- Option 1 is still available later if a playtest specifically wants the canvas
  itself to change — a genuinely wider *arena* beat that the setback range can't
  reach. Flagged as a stretch phase below, not built now.

---

## The mechanism: a parapet follows the void to the edge, not the column index

The new rule for `has_wall(x, z, dir)`: walk outward from `(x, z)` in `dir`. If
every cell crossed is `HOLE` all the way to the canvas boundary, this is a real
edge — parapet it. If the walk hits solid ground (`DECK`/`WATER`/`RAMP`) or a
`WALL` block before reaching the boundary, this is an *interior* hole — a pit,
not an edge — and stays unrailed exactly as today.

```
func has_wall(x, z, dir) -> bool:
    if not is_solid(x, z) or no_wall_at(x, z) or kind_at(x, z) == Kind.RAMP:
        return false
    if dir is Z:                       # unchanged -- ends join the next segment
        return false
    var nx := x + step.x
    while nx >= 0 and nx < width:
        if kind_at(nx, z) != Kind.HOLE:
            return false                # hit solid or a wall -- this is a pit
        nx += step.x
    return true                         # ran off the canvas -- this is an edge
```

This one change is the entire fix. It needs nothing new in the segment format —
a margin setback is *already* written as `HOLE` today, it's just never been
asked "does this reach the edge". `WALL` cells stop the walk (a maze's outer
column is already a true edge and untouched by this — `test_edge_lane` covers
exactly that case and must keep passing unmodified, since it never uses margin
setbacks). A single-row gap in the middle of the deck — a pit meant to be jumped
or shoved through — still has solid ground on both sides and stays unrailed,
which is correct: that's design, not terrain.

**A worked distinction, because it's the whole point:** columns `0..2` cut for
five rows as a setback (edge unbroken all the way out) get a parapet at column 3.
Columns `6..8` cut for one row as a mid-deck gap (solid at columns `0..5` and
`9..14` either side) stay unrailed. Same `Kind.HOLE`, same authoring, different
geometry, and the rule tells them apart correctly because it asks the geometric
question rather than trusting a tag.

---

## Canvas headroom

`GridConfig.DEFAULT_WIDTH` is 15 today, and every pool/piece segment is authored
at exactly that (checked: `lobby.seg`, `playtest_bridge.seg`, every `piece_*.seg`
and every `run_*.seg` in the assemblable pool are all 15 wide). If the generator
only ever *narrows* from 15, there's no way to ever feel wider than today's
normal — variety needs headroom on both sides of a baseline.

**Proposal: raise the canvas to 21**, and change the generator's *default*
(unmarked) row from "full canvas" to a baseline inset of 3 columns each side —
i.e. the common case reads at 15, identical to today's width, and rows can then
move independently in either direction: pinch down toward ~7 for a chokepoint,
or open out toward the full 21 for a plaza beat. The baseline choice matters
because it's what "normal" feels like; 15 is what the game has been tuned and
played at, so keeping it as the median rather than an extreme is the safe
default. Flagged below as a number worth confirming rather than locking in blind.

### CORRECTION 2026-08-20: the canvas bump is not a one-line change

Written into the first draft as if `DEFAULT_WIDTH` could simply be raised. It
cannot, and the failure mode is quiet. Traced through:

- Slot 0 of every run is `GENERATED_LOBBY` (`segment_pool.gd:109-119`), built as
  `SegmentGen.lobby(width, ...)` while `_segments` is still empty — so
  `DEFAULT_WIDTH` **is** the canvas for the whole run.
- Every authored pool segment is 15 wide. At canvas 21 each one hits the
  width-mismatch guard in `load_segment` (`bridge_grid.gd:367-370`) and is
  REFUSED — `playtest_bridge`, `run_gaps`, `run_pillars` and `run_maze` drop out
  of every run behind one `printerr`.
- `SetPieces.for_width(21)` returns an **empty array** (`set_pieces.gd:70-73`,
  matched on `seg.width == width`) — all eight set-pieces silently disabled,
  with no message at all. This is the worse of the two: the generator's piece
  branch simply never fires and every section comes out as bare terrain.

So a canvas bump requires re-authoring all thirteen 15-wide `.seg` files. **That
is affordable, and there is a property that makes it provably safe.** Pad each
file with 3 `HOLE` columns on each side to reach 21. Because `cell_centre` is
`(x + 0.5 - width * 0.5) * CELL_SIZE` (`grid_config.gd:307-312`), a symmetric pad
of 3 against a width that grew by 6 leaves **every existing cell at exactly the
same world coordinate** — old column 0 at width 15 and new column 3 at width 21
are both at x = -14. And under the new parapet rule the padding runs unbroken to
the canvas edge, so column 3 grows the railing column 0 used to have, in the same
place. **The pad is a no-op in world space, and that is a claim a test can
assert rather than a hope.**

Which is why the build order below puts the canvas bump LAST and optional: the
parapet rule and the independent insets deliver the variety that was actually
asked for, need no re-authoring at all, and are what makes the padded canvas
worth having if it is done.

Things that read `DEFAULT_WIDTH` or `.width` and need a pass to confirm they
still hold, none of which need new logic, just re-verifying against the larger
number:

- `bridge_camera.gd`'s `bridge_width_cells` framing (set once from `grid.width`
  in `game_world.gd:376` — still a one-time set, canvas is still constant, so
  this is a re-tune of the FOV/margin constants at most, not a structural
  change).
- `SimConfig.ROUND_WALL_HEIGHT`'s comment that the round barrier is "wider than
  any bridge" — check the actual wall mesh width against 21 cells.
- `entry_spawn_cell`'s `width / 2 - 3 + slot * 2` lane math (`bridge_grid.gd:302
  -304`) — still clamped to `[0, width)`, still fine, but worth re-reading given
  the clamp trap CLAUDE.md already has two entries about.
- `SetPieces.for_width(width)` — pieces are matched by exact declared width
  (`set_pieces.gd:72`). Existing 15-wide pieces still work at any *row's* usable
  span as long as the generator only stamps a piece into rows it has reserved at
  full baseline width (today's behavior — a piece owns its rows outright and the
  narrowing pass already skips piece rows). No change needed, just confirm the
  invariant survives the canvas bump.

---

## Phases

**Phase 0 — canvas headroom, no visible change.** Bump `DEFAULT_WIDTH`, set the
generator's default inset so the common row still measures 15 solid columns.
The gate this phase proves: an assembled run at the new canvas, with every row
at baseline inset, should be geometrically identical to today's play area — same
walkable width, same parapet positions. If a soak run's *median* row width
differs from 15, the baseline is wrong, not the test.

**Phase 1 — the parapet rule.** The `has_wall` change above. This is the
load-bearing phase: `test_edge_lane` must keep passing byte-for-byte (true edges
are untouched by construction — the walk immediately runs off the canvas at
column 0 in one step, same as today's check). New coverage needed: a segment
with a persistent multi-row setback grows a parapet at the new solid edge and a
body cannot walk or be shoved through it; a segment with a single-row mid-deck
gap stays exactly as unrailed as it is today. Both cases from one fixture,
because they're the same mechanism and the test that can't tell them apart isn't
proving the distinction exists.

**Phase 2 — the generator varies both edges, independently, in both directions.**
Today's `margin` is one symmetric number subtracted from both sides
(`segment_gen.gd:191`). Split it into an independent `left_inset`/`right_inset`
per row so the bridge can hug one edge while opening out the other — a canyon
wall on the left, open air on the right — rather than always pinching evenly to
a centred lane. Widening is the same code path with a negative inset (toward the
canvas edge, capped at 0), which is why doing this as insets-from-canvas rather
than as today's holes-from-width was the right call: "wider than baseline" was
never expressible as `margin`, because `margin` only ever subtracted from a
ceiling that had no headroom above the baseline to subtract into.

**REVISED 2026-08-20: a cap is not a gradient.** The first build treated the rate
cap as the whole answer and let a two-pass minimum cone discover the taper — which
always produces the STEEPEST slope the cap allows, because the largest profile
that fits is the one that tapers as late and as hard as it is permitted to. Every
assertion passed and a three-column setback completed in three rows: six metres,
crossed in a second, reading as the deck snapping rather than tapering.

So the shape is now STATED rather than derived — waypoints joined by straight
ramps, with a rolled `INSET_STEP_ROWS` stride of 2 to 6 rows per column of
change, so the same setback takes 12 to 36 m. The rate cap stays underneath as
the correctness floor. Measured after: the edge is moving on **17%** of rows
(effectively every transition row before), longest unbroken run of moves 3, and
the median width is still exactly the 15-cell baseline.

A consequence worth knowing: **gradual transitions and short sections trade off.**
A section is 14–21 rows, and a full-depth change at a gentle stride can fill most
of one, so a section now tends to hold one shape rather than several. The variety
moved up a level — from within a section to between them.

**Rate of change is a budget, not a free choice.** A setback that jumps by many
columns in one row is the tapered-shape trap CLAUDE.md already has an entry
about (`design_ideas` note on paper-thin ramps and skirts) wearing a new hat: the
deck-thickness rule keys off a cell's neighbours, and an edge that moves fast
row-to-row can produce a solid cell whose newly-exposed underside has nothing
supporting it. Cap the per-row change (a candidate: 1 column per row, matching
the existing `SOLO_RISE`-style one-unit-per-row discipline the height profile
already uses) so a setback reads as a taper a player can see coming, not a cliff
that appears underfoot.

**Phase 3 — dressing and pieces respect the row's actual span.** `SegmentValidator`
and `HazardDressing` already iterate `for x in seg.width` and gate everything on
`is_solid`, so they should need no change — worth confirming with a soak rather
than assuming, since "should need no change" is exactly the kind of claim this
project's CLAUDE.md says to measure rather than reason about. The one thing to
check explicitly: hazard placement rules that reference "beside the edge"
(`hazard_dressing.gd:333`, `x < 2 or x >= seg.width - 2`) currently mean the
*canvas* edge; confirm whether "near the edge" should now mean the row's local
solid edge instead, since a spike gallery meant to guard a bridge's flank should
probably track the flank, not a canvas boundary that might be several empty
columns away from any deck.

**Phase 4 (open) — parapet continuity where the edge moves.** When the setback
changes row-to-row, does the parapet stair-step (a short unrailed lip at each
step, matching how the height profile already stair-steps a climb) or does it
need a angled/mitred piece? Recommend shipping stair-step first — it's free,
matches the existing ramp/height convention, and the one-column-per-row rate cap
from Phase 2 makes each step small — and only build a mitred piece if a playtest
specifically flags the stair-step as reading wrong.

**Phase 5 — DONE 2026-08-20, and it went the other way.** Not "the camera reads
the local span" but the reverse: **the frame is a fixed number of metres and the
camera PANS within the deck.** Framing the canvas would have zoomed every player
out 40% to show six cells of air; framing the local span would have made every
width change a zoom, which is a drift under the cursor and worse under point aim.

The rule is now: the screen always shows the width it has always shown, and the
camera's X is `clampf(focus_x, deck_left + half, deck_right - half)` — so a deck
that fits the frame is framed whole and the camera holds the centre line exactly
as before, and a deck WIDER than the frame lets it move, clamped so one parapet
is always against the edge of the screen. Walk to the left edge of a wide section
and it reads as a 15-wide bridge with no wall on the right, because the bridge
keeps going.

**Both of the old no-sideways-tracking reasons survive.** This is not a camera
that chases; it is one that refuses to look past the deck. It clamps to the DECK
and not the canvas deliberately — clamping to the canvas would let it slide three
cells into empty air beside a baseline section, which is the "corridor" failure
arriving by another route. `GameWorld` pushes the deck's real edges each tick,
averaged over ±2 rows so a one-column-per-row taper cannot twitch the clamp.

**Phase 6 (stretch, likely deferred) — the camera reads the local span, not just
the canvas.** `bridge_camera.gd`'s own comment already describes the intent
("a narrower bridge brings the camera in") but `bridge_width_cells` is set once
per run from the canvas (`game_world.gd:376`) and never varies — that comment
predates a mechanism where width could actually change under a moving party. Once
Phase 2 ships, framing to the party's *local* usable span rather than the run's
canvas is a genuine option, not a bug fix. Worth trying, but it changes how the
whole game reads (the camera has never moved on this axis before) and belongs in
front of a playtest question, not baked in on spec.

**Phase 6 (deferred, maybe never) — genuinely different declared widths across a
join.** The option not taken above. Only worth revisiting if a design wants the
canvas itself to change — a bonus-arena beat wider than the setback range can
reach — since everything Phase 0-4 deliver is visible width variety without it.

---

## Open questions

- **Canvas number.** 21 proposed (15 baseline + 3 headroom each side). Worth
  confirming against the camera's actual framing distance before committing —
  Phase 0 measures this directly.
- **Baseline inset.** Proposed as fixed at 3/3 so "normal" reads as today's 15.
  Could instead vary the baseline itself section-to-section for another axis of
  variety, but that's a second decision riding on top of this one and probably
  wants its own playtest data first.
- **Rate-of-change cap.** 1 column/row proposed, unmeasured. A soak that plots
  the resulting silhouette is cheap and should decide this rather than picking a
  number and hoping it reads as a taper.
- **Phase 4 stair-step vs mitred parapet** — ship stair-step, revisit only on
  playtest feedback.
- **Phase 5 dynamic camera framing** — explicitly punted to "after a playtest
  asks for it", not part of this milestone's definition of done.
- **Phase 6** — not in scope. Named so nobody rediscovers the differing-width-
  join idea later without knowing it was considered and why it was set aside.
