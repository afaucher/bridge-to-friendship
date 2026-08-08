# The bridge grid

Written 2026-08-08. The structural model the whole game sits on: units, the cell
record, how a segment is authored, and how the bridge is assembled from
segments. Numbers here are **starting values chosen for a reason**, not
measurements — every one is expected to move in playtest, and each says what it
is trading off so a change is an informed one.

## Units

`3d_conventions.md` fixes 1 unit = 1 metre. On top of that:

| thing | value | why |
|---|---|---|
| cell (block) | **2.0 m** | Player capsule is 0.4 m radius, so a player occupies about a fifth of a cell — enough room for two to pass, and a pillar stone at one full cell reads as genuinely heavy. At 1 m a player fills half a cell and pushing a stone one cell is barely a movement. |
| bridge width | **30 cells (60 m)** | As briefed. See "how wide is too wide" below. |
| segment length | **24 cells (48 m)** | Roughly a screen and a half of travel at walking pace: long enough to hold one complete idea, short enough that authoring one is an afternoon. |
| parapet height | **1 cell (2 m)** | Contains plinko balls and stops a casual walk-off, so that a *missing* parapet is a legible hazard rather than the default state. |
| deck rise | **+1 cell every ~3 segments** | Gives the "always climbing" read without the climb itself becoming the whole game. |

**Cell size is the most expensive number here to change later.** Every authored
segment, every dash distance, every rope length, and every stone-push rule is
denominated in it. It is nearly free to change today.

## How wide is too wide

30 cells is 60 metres. With 2–4 players that is wide enough that the group can
spread out past the point where anyone can help anyone, which fights the whole
premise.

The resolution is that **structural width and playable width are different
numbers.** The bridge is 30 cells wide as a structure; the *traversable path*
through a typical segment is constrained by holes, water and pillar fields to
around **10 cells (20 m)** — about two shove-lengths across, so a player can
cross the play space to reach a friend in a couple of committed actions. The
full 30 opens up only at set pieces: plinko arenas, bus roads, and the moments
that are supposed to feel exposed.

Author to that. A segment where all 30 cells are comfortably walkable is a
segment where the co-op stops happening.

## The cell record

The bridge is a 2D grid of cells indexed `(x, z)` — `x` across (0–29), `z` along
the direction of travel — each carrying a height. It is not a voxel volume;
there is exactly one deck surface per column, which is what makes the grid cheap
to author, cheap to snapshot for a drop-in join, and cheap to reason about.

```
kind     DECK | HOLE | WATER | RAMP
height   deck top, in cells above the segment's base elevation
walls    which of the 4 edges carry a parapet (derived -- see below)
content  NONE | PILLAR(stack) | SHOOTER | HEART | PICKUP | SPAWN
```

- **HOLE** is a gap you fall through. It is also where a pushed pillar stone
  disappears, which is the reward for rearranging the bridge.
- **WATER** applies a lateral flow force. Crossing is possible but your movement
  is deflected, and a player who stops making progress is washed downstream.
- **RAMP** connects two heights across its run. See climbability below.
- **PILLAR** is a stack of stones on a deck cell. Plinko balls ricochet off them;
  a dashing player pushes the *top* stone one cell along the dash axis if the
  destination is clear.

## Walls are derived, missing walls are authored

A parapet exists automatically on any DECK edge adjacent to a HOLE or to the
outside of the bridge. The author does not place walls — they place holes, and
walls appear.

What the author *does* place is the **absence** of a wall. "This section lacks
walls" is exactly how the concept brief describes the hazard, so that is the
thing that gets an explicit mark in the file, and everything else is safe by
default. A segment file that forgets to say anything produces a bridge you
cannot accidentally fall off, which is the right failure mode for a format
humans hand-edit.

## Ramp climbability is the co-op gate

A ramp's slope is `height_delta / run`, both in cells. One tunable —
`max_walk_slope` — decides whether a player can walk up it.

That single number is where the game's signature co-op moment comes from. Above
the threshold, a ramp has **no single-player solution**: you get up it by being
shoved, or by being roped from above. Authoring a "you need each other here"
beat is therefore not a scripted event, it is a steep enough ramp.

**[open]** Is there a second threshold above which even a shove will not carry
you, so the only answer is the rope? That would give two distinct grades of
cooperation instead of one.

## Segment authoring: ASCII layers

Segments are text files, one per segment, under `segments/`. Text rather than
scenes because a 30-wide grid is genuinely readable as characters, a change
shows up as a legible diff, a test can assert properties of the map directly,
and a generator can emit them.

```
# segments/ascent_03.seg
name        = ascent_03
base_height = 6
length      = 24
tags        = foot, plinko

[deck]
..........####..........#####.
.......###....~~~~....###.....
   ....##.....~~~~.....##.....
   ...........~~~~............
...///////////~~~~///////////.
                (24 rows, 30 columns each)

[height]
6666666666666666666666666666666
6666666666677777777777766666666
                (hex digit per cell)

[content]
..........O.........+.........
..............................
                (shooter, heart, pickup, spawn)

[no_wall]
..............................
XXXXXXXX......................
                (X = this cell's outward edge has no parapet)
```

Glyphs: `.` deck, ` ` hole, `~` water, `/` ramp, `#` pillar stone,
`O` plinko shooter, `+` heart, `*` pickup, `S` spawn.

A loader turns one of these into collision, meshes and entities. The **authored
file is the source of truth**; the scene is a view built from it. That is what
makes a drop-in join cheap — see `physics_and_authority.md`.

## Assembling the bridge

The bridge is a sequence of segments joined end to end, each starting at the
previous one's ending elevation. For the MVP that sequence is a fixed authored
list. Later it becomes a picker that assembles a run from a pool by tag and
difficulty.

**Streaming.** Keep a window of segments loaded around the players and unload
behind. The trailing edge is defined by the **rearmost living player**, never by
the leader, or a straggler gets unloaded out from under themselves. What happens
to a player who falls too far behind is an open design question — see
`game_concept.md`.

## Bus sections: rare, and much longer

Bus stretches are a change of pace, not a change of scenery. Because the bus
covers ground several times faster than a player on foot, a bus section that is
the same *length* as a foot section is over in seconds and reads as a gimmick
rather than an act.

So they are **spread far apart and built much longer** — a rough target of one
bus stretch every **8–12 foot segments**, each running **8 or more segments**,
so a bus section takes comparable wall-clock time to the foot sections around
it and has room for its own escalation.

Structurally a bus segment is the same grid: same cells, same heights, same
holes. The deck is surfaced as sand or grass with a road down it, and the road
is simply where the deck is continuous. Everything that makes a foot segment
dangerous still applies — the difference is that you are meeting it at speed and
one player has given up their verbs to steer.

## What this model does not do

- **No overhangs, no tunnels, no bridge under the bridge.** One deck height per
  column. If the design later wants layered structure, this model does not
  stretch to it and the replacement is a real piece of work.
- **No arbitrary rotation.** Everything is axis-aligned, which is a prerequisite
  for the compass-locked shove being legible.
- **No destructible deck.** Stones move; the bridge itself does not break. Holes
  are authored, not created.
