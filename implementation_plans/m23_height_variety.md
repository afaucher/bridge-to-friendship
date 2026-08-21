# M23 — height variety: split plateaus and towers

Written 2026-08-20, alongside M22 (bridge width), from the same playtest
question about map variety. Three related complaints, one root cause:

> "Right now height changes tend to be a single horizontal line. We never split
> the playfield left to right by height. We can build towers with enemies on
> top."

---

## Why, precisely

`SegmentGen._section_attempt` builds terrain as a 1D sequence over `z` (row):
one running scalar `height`, and `low[z]` is the height for the ENTIRE row's
non-ramp, non-lift columns (`segment_gen.gd:232-330`). A "climb" is a narrow
ramp band a few columns wide (`ramp_x0`/`ramp_w`) — narrow on purpose, "two or
three cells of a fifteen-wide deck makes the climb a PLACE" — but both sides of
that band still land back on the SAME `low[z]`, because there is only ever one
height track. There is no code path where two columns at the same row hold
different heights for more than the width of a ramp, and no code path that
produces an isolated bump — every plateau is exactly as wide as the bridge.

**"Towers with enemies on top" is already an anticipated idea, just never built
on the terrain side.** The hat-stack design explicitly writes the case into its
own reasoning: "a shooter on your level hits your BODY and a shooter above you,
on a ramp or a raised deck or **a turret on a pillar**, meets your TOWER first"
(`game_world.gd:1938`). The game already knows what an elevated shooter means
for the aim-as-silhouette model. Nothing generates the raised deck.

**The good news: the rendering and validation underneath are already fully
general.** Neither needed to be built for this milestone — they were built
right the first time and just never got exercised on this axis:

- The deck-thickness rule drops a cell's underside to the lowest of its **eight
  neighbours** (`segment_builder.gd:250-296`, comment: "beneath it walks through
  empty air where a cliff face should be"), not "the neighbour behind it in Z".
  A height discontinuity between two columns at the same row already produces a
  correct vertical face with no new renderer code.
- `SegmentValidator._flood_from` steps in all four grid directions
  (`for dir in 4: step = GridConfig.DIR_CELLS[dir]`,
  `segment_validator.gd:186-196`) and `_can_step` reads the rise between any two
  adjacent cells regardless of orientation. A left/right height difference is
  already a wall or a climb by the same rule a north/south one is, with zero
  validator changes.

So this milestone is almost entirely **generator-side**: teach
`SegmentGen`/`HazardDressing`/`SetPieces` to actually produce per-column height
variation. It leans on the same discipline M22 uses for width (a per-row event,
a persistent extent, a rate cap) rather than inventing a second model.

---

## The constraint that shapes towers: the orphan check

`SegmentValidator._check_orphans` (`segment_validator.gd:319-326`) flags **any**
solid cell the ASSISTED_RISE flood cannot reach as a bug — "marooned deck". A
sniper post with no ramp up to it, reachable by nobody, ever, is not a
free-standing hazard under today's rules — it's an error the validator will
correctly refuse.

**Decision: don't exempt towers from this.** An unreachable platform with a
shooter on it is "I'm being shot from somewhere I can never answer", which is a
worse feeling than a hard fight, and it also breaks the one guarantee this whole
generation system exists to make — every solid cell is provably part of a
crossable, contestable bridge. A tower is a real, climbable detour: high ground
that costs a ramp or a shove to take, matching the "party CAPABILITY" model
already established for boosts and Legs (`design_ideas/world_generation.md`,
Part 2). **Prefer solo-climbable** (an ordinary narrow ramp, same one-unit-per-
row discipline as any other climb) so a tower reads as an optional risk/reward
side-trip rather than a mandatory two-player gate — reserve genuinely
cooperation-required elevation for hand-authored set-pieces, which already have
a documented exception for content that legitimately needs two people
(`segment_validator.gd:31-42`).

---

## How tall can a tower be? (and yes — ladders)

Checked rather than assumed, because "is there a limit" has four different
answers depending on which system you ask.

**The climb mechanic has no height limit at all.** `_step_climb`
(`player_body.gd:791-832`) climbs until the body clears the ladder cell's top
and does not care how far that is. The art scales too: `_spawn_ladder`
(`bridge_grid.gd:1123-1159`) computes `drop` from the cell's height against its
lowest solid neighbour, sizes the rails to it, and emits `maxi(2, drop / 0.4)`
rungs — a twelve-metre ladder renders thirty rungs correctly with no special
case.

**The validator has no rise limit on a ladder either.** `_can_step` returns
`true` unconditionally for a ladder-content destination
(`segment_validator.gd:228-229`) — no rise check, unlike the ramp branch right
below it which is capped by `rise_budget`. `LADDERS_CLIMBABLE` is already
flipped true (M17 phase 6 built `State.CLIMB`). **So a ladder is already a legal
way up any height, and a laddered tower needs no validator work whatsoever.**
That makes ladders strictly better than ramps for towers: a ramp spends a row
per unit of climb, so a 10-unit tower would need 10 rows of a 16-row section
just to get up it, while a ladder does any height in one cell. Towers should
default to ladder approaches for exactly the reason `SimConfig` already gives
them: "a ladder is the right answer for a tall climb in a tight space".

**The real cap is the file format: `MAX_HEIGHT_DIGIT = 15`.** Heights are
authored as one hex digit per cell and `HEIGHT_UNIT` is 1.0 m, so a segment can
express 0-15 m of range *internally* (`grid_config.gd:16-23`). Absolute world
height is unbounded — `_next_height` accumulates each segment's exit height as
an `h_offset` (`bridge_grid.gd:397-399`) — but a **tower's height above its own
section's base is capped at 15 minus whatever the local plateau has already
climbed to.** A section that has already risen to 6 leaves 9 units of tower. In
practice that's plenty; it's worth knowing only so nobody authors a 20 and
wonders why it wrapped.

**The practical cap is the camera, and it is lower than any of the above.** The
camera is a fixed 45° pitch (`bridge_camera.gd:35`), and the roadmap records
that multi-level was CUT from M17 on precisely this: "The camera problem was
'anything above a player hides them'". A tall tower is a tall occluder — at 45°,
a player walking behind a 10 m tower is behind it from the camera's point of
view too. This is the same problem that killed layers, and it scales linearly
with tower height. **There is no constant to read here; it needs measuring.**
Proposed: soak a range of tower heights and find where occlusion starts costing
you sight of a teammate, then set a generator cap from the measurement rather
than from the format's 15.

### The blocker: enemies aim in 3D, players aim in 2D

**This is the finding that gates the whole feature.** A gunner fires at its
target's full 3D position:

```gdscript
_spawn_round(gunner.muzzle(),
    _spread((target.global_position + Vector3(0.0, 0.25, 0.0) - gunner.muzzle()).normalized()),
    0, gunner.get_rid())                              # game_world.gd:1694-1697
```

and `can_bear_on` returns `true` unconditionally in the base class
(`gunner_body.gd:106-107`). So **an enemy on a tower shoots down at you
perfectly well, at any height.**

The player cannot shoot back. `aim_mode` defaults to `level` — a flat yaw at
muzzle height — and M20's own problem statement says it in as many words: "A
skirmisher two units up is unshootable; a rusher in a pit below you is
unshootable" (`m20_point_aim.md`). A tower with a shooter on top, shipped
against today's default aim, is a thing that hits you and that you cannot
answer. CLAUDE.md already has the name for that failure:

> "a hazard aimed at somebody who cannot answer it, or one whose reach is
> invisible, reads as the TERRAIN being the hazard"

**So shipping `point` as the default is Phase 0 of this milestone** — pulled in
explicitly rather than left as a dependency on M20, because an elevated shooter
is the exact case M20 was built to fix and building towers first would ship the
unanswerable version of it. The dependency runs both ways, which is why owning
it here is the right call: towers are also the best possible *argument* for
point aim, since they make the level-aim limitation impossible to ignore in a
playtest. See Phase 0 below for what the flip actually costs.

**A ladder approach and a shooter on top is the combination to be careful
with.** The climb state cannot dodge, shove, or shoot — `SimConfig`'s own
comment calls that "the price of that compactness... TIME, spent somewhere you
cannot dodge, shove or shoot" — and at `CLIMB_SPEED` 3.0 m/s a 10 m ladder is
3.3 seconds of that. Climbing slowly toward something shooting at you, unable to
answer, is either excellent commitment design or completely unfair, and which
one it is depends entirely on whether the player could clear the top *before*
starting the climb. Recommend: **a laddered tower's occupant should be
answerable from the ground** (point aim, which is Phase 0), so the
climb is a choice to close distance rather than a gauntlet with no alternative.
A ramp approach doesn't have this problem — you can shoot while walking up one —
which is a real design difference between the two ascenders rather than just a
cost difference.

---

## Feature A — split plateaus (left/right height divergence)

**New per-row state:** instead of one `low[z]`, a row inside a SPLIT event
carries two independently-tracked heights either side of a boundary column —
`low_left[z]` / `low_right[z]` — the same shape `narrow`/`margin` already use for
width, applied to height instead.

**The rise discipline doesn't change, it forks.** Each side may only change its
own height using the exact rule that already governs the single-track case: a
ramp, one unit of rise per row, anchored in a safe corridor. What's new is that
the two corridors can disagree with each other for the duration of the split —
today's code has no vocabulary for that at all, since there's only one `height`
variable in the whole function.

**A split must begin and end level.** Enter the event with `low_left ==
low_right` (a shared plateau), diverge across the middle rows, and **reconverge
before the event's last row** — `low_left[end] == low_right[end]`. This is not
optional polish: the entry/exit-row-is-flat-and-shared invariant is what keeps
the join contract, the round barrier, and the regroup bands working
(`m22_bridge_width.md`'s "the join problem turns out not to exist" argument
leans on the identical invariant for width — a split that left the exit row
divided would reintroduce exactly the problem M22 spent a section avoiding).
Reconverging inside the event, rather than requiring the NEXT event to undo it,
keeps every other consumer of `low[z]` (piece placement, dressing, the exit-row
fixup) unaware that a split ever happened once it's over.

**The boundary needs no new wall logic.** A height difference between two
adjacent solid columns is already a cliff face by the general thickness rule
above — nothing like M22's parapet-derivation is needed here, because the face
itself is impassable geometry, not a railing beside passable ground.

**Reachability is a design knob, not a given.** A split where one side is a
higher, harder route and the other is the safe one is the point — the party
chooses, or splits up and reunites at the far end, which is exactly the "dual
path" idea M17's regroup-row work already made free for width. Recommend
reusing that machinery directly: a split plateau **is** a dual-path region with
a height difference between the lanes instead of (or in addition to) a hole
between them, and the flood already treats both lanes as legitimate routes to
the same regroup band.

---

## Feature B — towers (a footprint smaller than the segment)

`design_ideas/world_generation.md` names this capability directly and it was
never built: "the unit of authoring gets SMALLER than a segment... a set-piece
is a 4-8 row full-width slice, **or a smaller patch with a declared
footprint**". Today every piece in `SetPieces.LIBRARY` is matched by
`seg.width == width` (`set_pieces.gd:70-73`) — full width, no exceptions — and
the generator's placement loop gives a matched piece the ENTIRE row for its
whole run of rows (`segment_gen.gd:370-381`, `for x in width: seg.heights[z][x]
= ...`). A tower — solid ground narrower than the bridge, standing alone with
ordinary terrain around it — needs a footprint that is NOT the whole row, which
is the missing capability.

**Proposal: a PATCH piece.** A new authored category (or a flag on the existing
format) declaring a footprint `(rows, cols)` smaller than the section, placed at
a generator-chosen X offset within the row's currently-usable span (respecting
whatever M22 setback is active that row — a tower has to stand on real deck,
not off the edge of a narrowed section). The placement loop changes from
"a matched piece owns this row outright" to "a matched patch piece owns
columns `[x0, x0+piece.cols)` of this row; the rest of the row still runs the
normal terrain rules" — which means restructuring the `continue`-past-the-row
shortcut in `segment_gen.gd:370-381` into a per-column write, same shape the
split-plateau work above already needs for `low_left`/`low_right`.

**A minimal tower is: a raised deck patch, a ramp or ladder approach on one
side, and a content cell for an enemy spawn on top.** Built as an actual `.seg`
patch file (a 3-4 row, 3-5 column footprint: a short climb into a small plateau)
rather than procedurally computed geometry — same reasoning `world_generation.md`
already gives for Layer 2 generally: the RELATIONSHIP between the climb, the
platform edge, and where the enemy stands to get a sightline is a composition,
and a generator assembling those three primitives independently produces
texture, not a design. A generated tower should be an authored patch the
generator places, not a fourth thing the row loop invents from scratch.

**Placement rule for HazardDressing:** a shooter or rusher spawn on a tower
should follow the same cover/lane rules Layer 3 already uses elsewhere
(`hazard_dressing.gd`'s `_open_run`/`_beside_a_gap` style predicates), reading
the tower's own footprint rather than the section's full width — the tower
supplies its own "cover" in the form of being hard to reach, so a shooter up
there wants an open lane down onto the deck below, not a turret behind cover
from players who can't get near it anyway.

---

## Phases

**Phase 0 — ship point aim as the default.** Explicitly part of this milestone,
not a dependency waited on: elevated enemies are unanswerable under level aim,
so this is the phase that makes every later one shippable.

The flip itself is one line — `aim_mode`'s `"default": 0` becomes `1` in
`debug_settings.gd:105-111`. Four things go with it:

- **Run the A/B first.** M20 built three knobs precisely so a playtest could
  decide, and flipping the default without playing it is skipping the decision
  the whole milestone exists to enable. It is cheap — the knobs are already in
  the menu — and towers are the best case to judge it on, since they make the
  level-aim limitation impossible to miss.
- **`level` stays in the registry.** It is the control, the regression path, and
  what makes the next A/B possible at all. Removing a choice because it lost
  once is how a project ends up unable to reproduce its own history.
- **THE GATE WILL NOT CATCH THIS, AND THAT IS THE DANGER.** `aim_target` only
  consults the point when `is_finite(body.aim_point.x)`
  (`game_world.gd:2579`), and every scripted test input defaults `aim_point` to
  `AIM_POINT_NONE` (`Vector3.INF`). So flipping the default turns **nothing**
  red — not because it is safe, but because no test exercises the new path.
  That is this project's most-repeated trap in a new costume: a wall of green
  over a code path nothing runs. **Phase 0 is not done when the flip lands; it
  is done when tests supply a real `aim_point` and assert on the shots that come
  out of it** — at minimum a shot up onto a raised deck and a shot down into a
  pit, both of which fail under `level` and must pass under `point`.
- **Decide the pad indicator, because point aim without one is worse than level
  aim.** On a mouse the cursor *is* the aim readout. On a pad the cursor is
  virtual — held at `PAD_CURSOR_RANGE` along facing (`aim_source.gd`) — and
  **invisible**. A pad player under level aim at least knows their shot leaves
  flat; under point aim with no indicator they have no idea where it goes
  vertically, which trades a known limitation for an unknowable one. The laser
  sight already exists, is built from the same `aim_direction` the shot uses,
  and is `view_only` so a client may switch it freely — so the likely answer is
  that it ships on by default too, at least on pad. Worth confirming in the same
  playtest rather than deciding here.

**If the playtest says point loses**, towers do not simply proceed without it.
The fallback is to restrict elevated enemies to ones answerable *without*
counter-fire — a plinko shooter drops balls that roll downhill and is answered by
moving, not by shooting back — or to ship towers as player-only high ground with
nothing on top. Both are real options; neither is "put a gunner up there
anyway".

**Phase 1 — prove the renderer and validator need nothing.** Before writing any
generator code: hand-author one test fixture with a genuine left/right height
split (two columns, one row transition, no ramp — just adjacent solid cells at
different heights) and one isolated raised patch with a ramp up to it. Confirm
`SegmentBuilder.build` produces a correct cliff face and `SegmentValidator`
correctly floods, reaches, and does NOT orphan either shape, with zero code
changes. This is the claim the whole milestone rests on, and CLAUDE.md is
explicit that "should need no change" is a claim to measure, not assume.

**Phase 2 — split plateaus in the generator.** The `low_left`/`low_right`
per-row track, the begin-level/end-level invariant, anchored in a safe column
range the same way `narrow`/`margin` already are. Ships alongside a soak that
plots a sample of generated sections and confirms every split reconverges and
every lane is independently crossable at `SOLO_RISE`.

**Phase 3 — the patch-piece footprint.** Restructure the placement loop to
support a footprint narrower than the row, and one authored patch (a small
tower) exercising it end to end.

**Phase 4 — a small tower library.** Two or three more patch pieces once the
mechanism is proven. The ascender is the interesting axis, because the two are
genuinely different rather than cheaper/dearer versions of each other:

- **Ramp approach** — costs a row per unit of climb, so it is only affordable
  for a short tower, and you can shoot while walking up it.
- **Ladder approach** — any height in one cell, needs no validator work at all
  (see above), and cannot shoot or dodge during the climb. The right answer for
  a genuinely tall tower and the wrong one under fire.
- **A tower deliberately gated to `ASSISTED_RISE`** — a two-player detour,
  matching the documented "cooperation-required is wanted, not a bug" policy.

**Phase 5 — HazardDressing places enemies on towers.** Extend the placement
predicates to consider a patch piece's own footprint rather than only the
section's full width, and confirm (soak, not reasoning) that a shooter placed on
a tower has a sightline down onto reachable deck — an elevated shooter with no
lane to anyone is a wasted budget slot, the same complaint the existing
cover-in-front-of-a-turret rule already guards against at ground level.

---

## Open questions

- **Split frequency and depth.** How often should a section roll a split, and
  how large a height difference should the two lanes be allowed to reach before
  reconverging? Proposed default: rare (roughly as common as today's `narrow`
  event) and shallow (1-2 units), tightened or loosened after a soak shows what
  the silhouette actually looks like — same "measure, don't guess" posture as
  M22's rate cap.
- **Patch-piece format.** A new file convention (footprint declared in the
  header, alongside the existing `piece`/`no_dress` tags) versus reusing the
  existing full-width piece format with the footprint's outer columns simply
  authored as `HOLE`. The latter needs no format change at all and may be
  enough for a first tower — worth trying before inventing new syntax.
- **Are towers ever NOT climbable** — i.e., is a deliberately unreachable
  decorative silhouette (visible, shot from, never stood on) wanted anywhere?
  If so it needs its own exemption from `_check_orphans` rather than bending the
  general rule, and should be scoped narrowly (a specific `Content` flag meaning
  "decoration, not deck") so it can't accidentally swallow a real design mistake.
- **How tall before the camera loses you.** The one cap that needs measuring
  rather than reading off a constant. Soak a range of tower heights against a
  teammate walking behind one and find where occlusion starts costing sight;
  set the generator's cap from that, not from the format's 15.
- **Does an elevated enemy need its own reach rule?** A gunner aims in 3D and a
  plinko shooter drops balls that roll downhill — both work from height, and
  the plinko one arguably works *better*. But `fire_range()` is a straight
  distance check, so a tower merely puts the enemy further away in 3D without
  changing what it can see. Worth checking whether an elevated shooter's
  effective threat radius on the deck below matches what the player can read
  off its silhouette, since a reach nobody can see is the spike-ring bug
  CLAUDE.md already has an entry about.
- **Relationship to M22.** Both milestones add a second axis of per-row/per-
  column variation to the same generator loop (setback for solidity, split for
  height). Worth sequencing M22 first if both proceed, since Phase 2 there
  (independent left/right insets) and Phase 1 here (independent left/right
  heights) are structurally the same kind of change to the same loop, and
  building them in the same pass may be cheaper than two separate ones.
