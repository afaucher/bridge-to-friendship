---
name: level-authoring
description: Author or edit level content for Bridge to Friendship — whole segments (`.seg` files in segments/) and M18 set-pieces. Use this whenever the task touches a `.seg` file, the glyph grids ([deck]/[height]/[content]), the set-piece library in scripts/grid/set_pieces.gd, or anything phrased as "make a level / a section / a piece / an arena", "add a ramp or a ladder or a lift somewhere", "place spikes / a turret / a plinko field", "why is this segment rejected", or "the validator says this is uncrossable". Also use it when reviewing someone else's level file, because most of the rules here are ones the oracle cannot check and a file can be perfectly valid and still unfair.
---

# Authoring levels for Bridge to Friendship

Two things get authored here and they share one format:

- **A segment** — a whole level, 16–30 rows, in `segments/*.seg`. Listed in
  `SegmentPool.POOL`.
- **A set-piece** — a 4–8 row composition the generator stamps into generated
  terrain. Same format plus a `piece` tag. Listed in `SetPieces.LIBRARY`.

A `.seg` is a header plus three aligned character grids. The grids are
`length` rows of `width` characters and they must line up exactly — row `z`,
column `x` means the same cell in all three.

```
name = piece_example
base_height = 0
width = 15
length = 6
piece_exit = 0          # set-pieces only
tags = foot, piece, firefight

[deck]      -- terrain kind, one char per cell
[height]    -- integer height per cell, one digit per cell
[content]   -- what stands in the cell
```

## The glyphs

Read these off `scripts/grid/grid_config.gd` if anything looks stale — that file
is the authority, this table is a convenience.

**[deck]** — `.` deck · `_` hole · `~` water · `/` ramp

**[content]** — `.` nothing
| | | | |
|---|---|---|---|
| `#` pillar | `L` ladder | `B` bouncer | `E` elevator |
| `O` plinko shooter | `k` skirmisher | `T` turret | `m` rusher mound |
| `v` spikes | `c` crumbling floor | `%` timed block | `=` gate strip |
| `t` tree (thin cover) | `h` half wall (wide cover) | `+` heart | `^` hat |
| `*` machine gun | `g` grenade | `x` mine | `s` shield |
| `r` rocket | `j` legs | `S` spawn | `$` merchant |

Case carries meaning: `t` is a tree and `T` a turret, `s` a shield and `S` a
spawn. Two glyphs one keypress apart are a typo nobody spots in a grid of them.

The merchant is `$` and not a letter for exactly that reason — he is the one NPC
who is not trying to kill you, and `M` puts him one shift-key from `m`, the mound
that charges you. He also breaks the capitals-are-terrain convention on purpose:
he is neither terrain nor something you walk over and collect. You buy from him
by **dashing into him**, so never author one within three cells of anything
dangerous — a player dashing at a rusher clips the shopkeeper and spends a hat on
a trade they never made. The dressing pass enforces that for generated sections;
an authored piece can still do it by hand.

## Rules the parser and the oracle enforce

These fail loudly, so you will find out. They are listed so you do not have to
find out.

**There is no step-up in this game.** `move_and_slide` does not mantle and
nothing implements it. A rise onto a plain deck cell is a wall at any height —
measured, a body at full stick into a one-unit step stops dead. Every climb must
land on a **ramp** (`/`, one unit per row is walkable solo, two needs a shove), a
**ladder** (`L`, authored on the HIGH cell), a **bouncer** (`B`), or an
**elevator** (`E`, authored at the height it rises TO). This is the single most
common reason a hand-authored segment is rejected.

**Content never sits on a hole.** A turret over a gap is an error, not a
floating turret.

**A set-piece's entry and exit rows are full-width solid deck.** It is stamped
between two plateaus; if either end is not solid across, the party meets a step
or a hole nobody authored on the seam.

**`piece_exit` must equal the geometry** — the exit row's height minus the entry
row's. It is declared rather than derived so a piece that lies about it gets
caught; the generator carries on from the declared number, so a lie leaves a step
behind the piece.

**A piece is skipped, not stretched, if its width differs from the run's.**
Author at `GridConfig.DEFAULT_WIDTH` (15) unless you have a reason.

## Rules the oracle cannot check

This is the part worth reading twice. Every one of these came from a playtest,
and a file that breaks them is perfectly valid and still bad.

### Never aim a hazard at somebody who has no verbs

A player on a **ladder** or riding a **lift** cannot dodge, dash, take cover or
shoot — stepping off is a fall. A shooter in range of one is firing at something
that cannot leave.

This reached playtest as *"the elevator hurts you, every time it moves"* — the
lift never touched anyone; a hazard nearby did, and the damage arrived exactly
when the platform carried the player into it. The dressing pass now keeps
dangerous content three cells clear of a lift, but **an authored piece can still
do it by hand**, because a piece brings its own hazards and layer 3 keeps out.

A **ramp** is fine — on a slope you keep every verb. That is why
`piece_ramp_duel` puts a turret at the top of a ramp and no piece puts one at the
top of a ladder.

### Spikes hurt the cell they are drawn in

Nine cones standing up out of one cell. Until 2026-08-16 the hit test measured
from the block's four *neighbours*, so the safe spot was the middle of the spikes
and the danger was a ring 3.3 m wide. It reached playtest twice before anyone
measured it.

So: a spike block is an obstacle you step **around**, and the cell it occupies is
the dangerous one. Being carried over it on a lift is safe. Stagger them across
rows to make a rhythm; a solid row of them is a wall, not a hazard.

### Cover pairs with shooters

A shooting gallery with no cover is not a theme, it is a punishment. Wherever you
place `k`, `T` or `O`, put `t` or `h` where a player crossing the lane can
actually reach it. The relationship between the cover and the thing it is cover
*from* is the composition — that is the whole reason set-pieces exist rather than
scattering the same parts randomly.

### A composition needs a decision, not just contents

The test for a good piece: can you say in one sentence what choice it poses?
"Three lanes, the short one is watched and the long ones are off the turret's
angle" is a piece. "Some spikes and a turret" is texture.

### Consumables may only ever be a shortcut

Legs (`j`) run out. A route that *requires* one becomes impossible the moment the
last charge is spent, with the party stuck and nothing telling them why. The
reachability flood deliberately cannot see legs, so it will happily certify a
route that needs them. Put them past the obstacle, never as the way through it.

Presence is different — a route may require a second player, because people come
back.

### Small mercies that came from play

- **One ladder, not two.** A queue is not dead time — it is an order: who
  climbs first, who holds the ground below, who is last and most exposed. Two
  ladders delete that decision to save three seconds. (This one was authored the
  other way round first and overruled at playtest, which is worth knowing: the
  argument for two was "a party standing still is a party being shot at", and it
  lost because standing still TOGETHER while somebody climbs is a thing players
  organise around.)
- **A reward you can see from the entry row** pulls a player through a hazard;
  one they discover afterwards was just a tax.
- **Nothing lethal on the entry or exit row** — a party meets it with no warning.

## Writing a set-piece

Full width, 4–8 rows, `tags = foot, piece, <theme>`. Add the path to
`SetPieces.LIBRARY` — **append, never reorder**, because a piece's index in that
list feeds the seed mix and reordering silently changes every level in the game.

Write a header comment saying what decision the piece poses and why the parts are
where they are. The next author needs the reasoning, not the layout — they can
see the layout.

## Validating

Always run this; the oracle is good and it is instant.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File ./test_runner.ps1 -TestName test_set_pieces
```

For whole segments, `test_segment_format` and `test_segment_gen` cover the pool
and the generator. Full gate:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File ./build.ps1 -TestsOnly
```

Read `test_logs/<name>.err.log` for the real message — the runner's summary is
lossy, and a parse error appears only there.

### If you add a check, A/B it before believing it

A new assertion that passes on the first run has not yet been shown to be capable
of failing. Break the thing deliberately — remove the ladder, lie about
`piece_exit`, wall off the route — and confirm the check goes red, then restore.

This is not ceremony. In this repo an assertion about hazard placement passed
with its own rule deleted at 40 seeds and again at 250, because it was inspecting
the raw generator output while hazards are placed at *load*. A test run on the
wrong object cannot fail however many samples it takes.

**Restore by copying the file back, never `git checkout --`** — checkout restores
from HEAD, and an A/B is a temporary edit rather than a revert. That mistake cost
an hour of uncommitted work here once already.

## Where things live

| | |
|---|---|
| `segments/*.seg` | every segment and piece |
| `scripts/grid/grid_config.gd` | glyph tables, cell size, height unit |
| `scripts/grid/segment_data.gd` | the parser and its header keys |
| `scripts/grid/segment_validator.gd` | the reachability oracle |
| `scripts/grid/set_pieces.gd` | the piece library |
| `scripts/grid/segment_pool.gd` | the segment pool and run plan |
| `scripts/grid/hazard_dressing.gd` | layer 3 themes and placement rules |
| `design_ideas/world_generation.md` | the three-layer model and its reasoning |
| `implementation_plans/m18_set_pieces.md` | what a set-piece is and why |

New `.seg` files are packed by the `segments/*.seg` entry in
`export_presets.cfg`. If you ever put one in a subdirectory, check the
`savepack:` list in the export output and find it there — a data file that exists
in the editor and not in the shipped build is the worst shape a bug can have.
