extends RefCounted

# The bridge's units and coordinate system, and the glyphs a .seg file is
# written in. Everything that converts between cells and metres goes through
# here -- a second copy of "cell size" anywhere else is a bug waiting for the
# day the number changes.

# --- Units --------------------------------------------------------------------

# See design_ideas/bridge_grid.md for why 2 m: a player is 0.4 m in radius, so a
# player occupies about a fifth of a cell, two can pass in one, and a pillar
# stone at one full cell reads as genuinely heavy.
const CELL_SIZE := 2.0

# Heights are authored as a single hex digit per cell, so the unit has to be
# small enough for a gentle ramp and big enough that 0-f covers a segment's
# range. At 1 m: a layer is 2 units, and 0-f spans 15 m.
#
# A whole CELL as the height unit would make the shallowest possible ramp 45
# degrees -- which is above max_walk_slope, so EVERY ramp would need cooperation
# and the gentle/steep distinction the design rests on could not be authored.
const HEIGHT_UNIT := 1.0
const MAX_HEIGHT_DIGIT := 15

# THE WHOLE BRIDGE IS TILTED, so that "up the bridge" is genuinely uphill.
#
# This is what makes plinko work. A shooter drops spheres and they must come
# DOWN the bridge at the players under their own weight -- not because something
# pushes them, and not on a scripted path. A constant pitch gives every loose
# object on the bridge a reason to roll toward the party, and it costs one
# rotation on the grid root rather than a rule anywhere in the sim.
#
# Well under MAX_WALK_ANGLE_DEG: it must be free to walk up, so it reads as
# atmosphere rather than as a slope you fight.
const BRIDGE_PITCH_DEG := 4.0

# Width is a property of the BRIDGE, not a global: a .seg declares its own, and
# every cell<->world conversion below takes it as an argument. This exists only
# as the fallback for a file that does not say.
#
# 15 cells (30 m) for the playtest bridge. 30 was the original brief, but a
# 60 m deck lets 2-4 players spread past the point where anyone can help anyone,
# which fights the co-op premise -- see "how wide is too wide" in
# design_ideas/bridge_grid.md. The test fixtures declare 30 explicitly and are
# unaffected.
const DEFAULT_WIDTH := 15
const DECK_THICKNESS := 1.0    # how far the deck slab hangs below its top face
const WALL_HEIGHT := 2.0       # one cell -- contains plinko balls, blocks a walk-off
const WALL_THICKNESS := 0.3

# --- Cell kinds ---------------------------------------------------------------

enum Kind { DECK, HOLE, WATER, RAMP }

# HOLE is `_` and NOT a space. Every text editor on earth strips trailing
# whitespace, so a row ending in holes would silently lose its tail and the
# segment would load one cell narrower with no error -- or worse, load fine and
# put a wall where the author drew a gap. A visible glyph makes a row's width
# checkable, and the validator does check it.
const DECK_GLYPHS := {
	".": Kind.DECK,
	"_": Kind.HOLE,
	"~": Kind.WATER,
	"/": Kind.RAMP,
}

# --- Cell contents ------------------------------------------------------------

enum Content { NONE, PILLAR, LADDER, BOUNCER, SHOOTER, HEART, PICKUP, SPAWN, MOUND, HAT, SKIRMISHER, TURRET, PICKUP_GRENADE, PICKUP_MINE, PICKUP_SHIELD, PICKUP_ROCKET, GATE, TREE, HALF_WALL, SPIKES, PICKUP_LEGS, CRUMBLE, TIMED }

const CONTENT_GLYPHS := {
	".": Content.NONE,
	"#": Content.PILLAR,
	"L": Content.LADDER,
	"B": Content.BOUNCER,
	"O": Content.SHOOTER,
	"+": Content.HEART,
	# A machine gun on the deck. `*` predates there being more than one special,
	# so it keeps meaning the first one rather than becoming a generic pickup --
	# every map already authored with it means a gun, and silently changing that
	# would be a content change disguised as a refactor.
	"*": Content.PICKUP,
	"S": Content.SPAWN,
	# A dormant rusher. Lowercase because it is the only content that is not
	# there yet -- it is a thing that WILL exist, authored where it starts.
	"m": Content.MOUND,
	# A loose hat, waiting to be picked up. Authorable ANYWHERE, not just at
	# checkpoints: the interesting place for one is PAST a hazard, not beside the
	# safe spot. Checkpoint segments get them by convention, never by rule.
	"^": Content.HAT,
	# Grenades. Lowercase, like the other things that are picked up rather than
	# fought.
	"g": Content.PICKUP_GRENADE,
	# Mines. `x` because that is what a mine is on a map, and because `m` was
	# already a mound -- two lowercase letters one apart would be a typo nobody
	# ever spots in a grid of them.
	"x": Content.PICKUP_MINE,
	# A shield. Lowercase `s` -- uppercase `S` was already the spawn point, and
	# the two are never in the same place, so the case is doing real work.
	"s": Content.PICKUP_SHIELD,
	# A rocket launcher. `r` for rocket, and lowercase like every other thing
	# that is picked up rather than fought.
	"r": Content.PICKUP_ROCKET,
	# LEGS (M17 phase 6). `j` for jump {D} `l` is the one letter nobody should ever
	# have to tell apart from a 1 in a grid of them, and `L` is already the ladder
	# this thing is an alternative to.
	"j": Content.PICKUP_LEGS,
	# MUTABLE TERRAIN (M17 phase 8). Two triggers on one mechanism: a cell that
	# stops being solid at runtime. `c` crumbles under the weight of whoever stands
	# on it; `%` is on a timer and asks you to cross in rhythm.
	"c": Content.CRUMBLE,
	# `t` is the tree and `T` the turret, so the timed block takes `%` -- a shape
	# rather than a letter, because a grid of them is read as a picture.
	"%": Content.TIMED,
	# The two enemies that shoot. Lowercase for the one on legs, uppercase for
	# the one bolted down -- the same convention `m` already set for a mound.
	"k": Content.SKIRMISHER,
	"T": Content.TURRET,
	# COVER (M17). Two shapes, and the difference between them is the whole
	# design: a TREE is thin and tall, so it hides one player and is trivially
	# walked around; a HALF WALL is wide and low, so it hides a crouching line of
	# fire and has to be gone AROUND rather than through.
	#
	# Neither needs a new system. SIGHT_BLOCKERS is `world | stones` and
	# _clear_line already uses it, so a collider on the world layer blocks a
	# gunner's line of sight the moment it exists. Cover is a glyph and a box.
	#
	# WHAT THIS IS NOT, named so nobody assumes it: a half wall you can SHOOT OVER
	# but WALK THROUGH. That needs a layer that is in SIGHT_BLOCKERS and not in
	# the player mask, and it is a real idea -- it is just not this one. These
	# both stop a body.
	"t": Content.TREE,
	"h": Content.HALF_WALL,
	# A SPIKE BLOCK: dormant deck that periodically drives spikes into the cells
	# around it. Lowercase `v` for the shape of a spike, and lowercase because it
	# is a thing that happens rather than a thing that is built.
	"v": Content.SPIKES,
	# THE ROUND BOUNDARY (M16). A black-and-white checker strip across the full
	# width of the bridge, marking where one round ends and the lobby begins.
	#
	# CONTENT AND NOT A NEW `Kind`, which was the first design and is wrong. A
	# gate cell is ordinary deck in every physical respect -- solid, walkable, a
	# slab under it, parapets and ramps behaving normally -- and the only thing
	# that makes it a gate is that the round machine reads it. A fourth Kind would
	# have to be added to every `kind == DECK` test in the builder, and there are
	# two of them guarding the mesh and the collision separately: miss the second
	# and the strip is a walkable surface with NOTHING UNDER IT, which is exactly
	# the ramp-skirt bug of 2026-08-13 and presents as "sometimes I fall through".
	#
	# `=` because it looks like the thing: a row of them draws a stripe across the
	# deck layer in a text editor, which is the whole reason this format is ASCII.
	"=": Content.GATE,
}

# Contents that get a player up a layer. Every elevation change needs at least
# one of these or a ramp; see the validator.
# CELLS THAT COME AND GO (M17 phase 8). Deck while they are there, a hole while
# they are not, and the difference between the two is only WHEN.
#
# THEY ARE SOLID TO THE FLOOD, deliberately. 2b of the design doc: an edge that
# exists periodically is "always available with a time cost", because a party can
# WAIT -- and the round clock is where that cost is paid. The alternative, an
# oracle that refuses to route through anything temporary, would reject every
# segment built out of these and there would be no point having them.
const MUTABLE_CONTENTS := [Content.CRUMBLE, Content.TIMED]

# READABLE AT A GLANCE OR THEY ARE A TRAP RATHER THAN A HAZARD. A cell that is
# about to stop existing has to LOOK different from the deck beside it before you
# stand on it; the checkerboard is deliberately uniform, so these two break it.
const CRUMBLE_COLOUR := Color(0.72, 0.45, 0.22)   # cracked earth
const TIMED_COLOUR := Color(0.30, 0.62, 0.78)     # cold, and it blinks

const ASCENDER_CONTENTS := [Content.LADDER, Content.BOUNCER]

# --- Directions ---------------------------------------------------------------
#
# The four compass axes a shove locks to, in cell space. Index order is fixed
# because it is used as a wire value for a dash direction.

# NORTH is UP THE BRIDGE: -Z in world space, +1 in cell z.
const DIR_NORTH := 0   # -Z, cell z + 1
const DIR_EAST := 1    # +X, cell x + 1
const DIR_SOUTH := 2   # +Z, cell z - 1
const DIR_WEST := 3    # -X, cell x - 1

const DIR_CELLS := [
	Vector2i(0, 1),
	Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(-1, 0),
]

const DIR_VECTORS := [
	Vector3(0.0, 0.0, -1.0),
	Vector3(1.0, 0.0, 0.0),
	Vector3(0.0, 0.0, 1.0),
	Vector3(-1.0, 0.0, 0.0),
]

# Nearest compass direction to an arbitrary heading.
#
# NO LONGER ON THE MOVEMENT PATH. Facing and the dash are free angles now (see
# the yaw helpers below); this survives for the things that are genuinely
# cell-shaped -- a stone is pushed exactly ONE CELL, and a cell has four
# neighbours no matter how the player was pointing when they hit it.
static func nearest_direction(heading: Vector2) -> int:
	if absf(heading.x) >= absf(heading.y):
		return DIR_EAST if heading.x >= 0.0 else DIR_WEST
	return DIR_SOUTH if heading.y >= 0.0 else DIR_NORTH

# --- Yaw: the free-angle facing ------------------------------------------------
#
# YAW 0 IS NORTH, which is -Z, which is up the bridge -- the same north the four
# constants above use, so the two systems agree at the four points where they
# overlap. Increasing yaw turns anticlockwise seen from above, which is Godot's
# own convention for a rotation about +Y, so a facing angle can be written
# straight into `Node3D.rotation.y` with no correction.
#
# Everything the player points at is an angle now: the dash, the nose marker, the
# knockback a shove delivers. Cells stay cardinal.

static func yaw_vector(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

# The yaw of an XZ heading, in the same (x, z) packing the input's `move` uses.
static func yaw_of(heading: Vector2) -> float:
	return atan2(-heading.x, -heading.y)

static func yaw_of_vector(heading: Vector3) -> float:
	return atan2(-heading.x, -heading.z)

# For the cell-shaped things. Rounding to a quarter turn rather than reusing
# nearest_direction() so the conversion happens in ANGLE space and there is one
# definition of where the boundaries between the quadrants sit.
static func yaw_to_direction(yaw: float) -> int:
	# yaw 0 -> NORTH(0), -PI/2 -> EAST(1), PI -> SOUTH(2), +PI/2 -> WEST(3).
	# Quarter turns ANTICLOCKWISE from north run N, W, S, E, so the quadrant index
	# counts backwards through DIR_* and posmod puts it back in range.
	var quarter: int = int(round(yaw / (PI * 0.5)))
	return posmod(-quarter, 4)

# --- Cells <-> world ----------------------------------------------------------
#
# The bridge is centred on x = 0 and runs along -Z. -Z because that is Godot's
# forward and the player's "move_forward" input: if the bridge ran the other way,
# holding forward would walk back DOWN it.
#
# Cell z still counts UP from the entry, so a .seg file reads top-to-bottom in
# the direction of travel and z always means "how far along". The sign flip lives
# here and nowhere else.

static func cell_z_world(z: int) -> float:
	return -(float(z) + 0.5) * CELL_SIZE

static func cell_centre(x: int, z: int, height: int, width: int) -> Vector3:
	return Vector3(
		(float(x) + 0.5 - float(width) * 0.5) * CELL_SIZE,
		float(height) * HEIGHT_UNIT,
		cell_z_world(z)
	)

static func cell_origin_x(x: int, width: int) -> float:
	return (float(x) - float(width) * 0.5) * CELL_SIZE

static func world_to_cell(position: Vector3, width: int) -> Vector2i:
	return Vector2i(
		int(floor(position.x / CELL_SIZE + float(width) * 0.5)),
		int(floor(-position.z / CELL_SIZE))
	)

# --- Appearance ---------------------------------------------------------------

# The deck is a CHECKERBOARD of two light browns, alternating on (x + z).
#
# Not decoration: it is the only thing that makes distance readable on a big
# flat deck seen from a fixed 45-degree camera. Without it a player cannot tell
# whether a gap is two cells away or four, and every judgement the game asks for
# -- where a dash ends, whether a stone clears a hole -- is a judgement about
# cells. The grid IS the gameplay, so the grid has to be visible.
const DECK_LIGHT := Color(0.82, 0.70, 0.52)
const DECK_DARK := Color(0.68, 0.55, 0.38)

# Pillars are a THIRD brown, darker and more saturated than either deck shade.
# A stone has to read as an object sitting on the checker rather than as another
# square of it -- it is the one piece of scenery you can push, so telling it
# apart at a glance from across the bridge is gameplay, not decoration.
const STONE_COLOUR := Color(0.56, 0.38, 0.20)

# THE ROUND BOUNDARY, in black and white on the same parity as everything else.
#
# Not literally 0 and 1: pure black reads as a hole from a distance on a deck lit
# this way, which is the one thing a boundary strip must never look like. Near
# enough to be unmistakably not-brown, far enough off the ends to still read as a
# surface.
const GATE_LIGHT := Color(0.93, 0.93, 0.94)
const GATE_DARK := Color(0.12, 0.12, 0.14)

# COVER. Green for a tree so it reads as the one thing on this bridge that grew
# rather than being built, and a grey for the half wall close to the parapet
# — it IS a parapet, standing in the middle of the deck instead of at the edge.
const TREE_COLOUR := Color(0.24, 0.45, 0.22)
const TREE_TRUNK_COLOUR := Color(0.34, 0.26, 0.18)
const HALF_WALL_COLOUR := Color(0.46, 0.42, 0.38)

# A spike block is deck-coloured while dormant and reads only by its spikes,
# which are the one thing on the bridge that is nearly white: they have to be
# legible against brown deck from across a 60 m span, at the moment they matter.
const SPIKE_COLOUR := Color(0.86, 0.87, 0.90)

# A ladder is the one built thing on the bridge that is not part of the deck, so
# it takes a warmer wood than the parapet's grey-brown -- it reads as something
# somebody put there rather than as more structure.
const LADDER_COLOUR := Color(0.62, 0.44, 0.24)

# Parapets go grey-brown so they read as structure, not as more deck.
const WALL_COLOUR := Color(0.42, 0.36, 0.30)
const RAMP_COLOUR := Color(0.75, 0.62, 0.45)
const WATER_COLOUR := Color(0.35, 0.55, 0.68)

static func deck_colour(x: int, z: int) -> Color:
	return DECK_LIGHT if (x + z) % 2 == 0 else DECK_DARK

# THE SAME PARITY RULE, A DIFFERENT PALETTE. The checker is not decoration -- it
# is what makes distance readable from a fixed 45-degree camera, and every
# judgement this game asks for is a judgement about cells. So a boundary strip
# changes the two colours and never the rule: a player counting squares across it
# is still counting the same squares.
static func gate_colour(x: int, z: int) -> Color:
	return GATE_LIGHT if (x + z) % 2 == 0 else GATE_DARK

static func height_to_world(height: int) -> float:
	return float(height) * HEIGHT_UNIT
