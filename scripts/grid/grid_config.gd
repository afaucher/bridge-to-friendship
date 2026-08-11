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

enum Content { NONE, PILLAR, LADDER, BOUNCER, SHOOTER, HEART, PICKUP, SPAWN, MOUND }

const CONTENT_GLYPHS := {
	".": Content.NONE,
	"#": Content.PILLAR,
	"L": Content.LADDER,
	"B": Content.BOUNCER,
	"O": Content.SHOOTER,
	"+": Content.HEART,
	"*": Content.PICKUP,
	"S": Content.SPAWN,
	# A dormant rusher. Lowercase because it is the only content that is not
	# there yet -- it is a thing that WILL exist, authored where it starts.
	"m": Content.MOUND,
}

# Contents that get a player up a layer. Every elevation change needs at least
# one of these or a ramp; see the validator.
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

# Parapets go grey-brown so they read as structure, not as more deck.
const WALL_COLOUR := Color(0.42, 0.36, 0.30)
const RAMP_COLOUR := Color(0.75, 0.62, 0.45)
const WATER_COLOUR := Color(0.35, 0.55, 0.68)

static func deck_colour(x: int, z: int) -> Color:
	return DECK_LIGHT if (x + z) % 2 == 0 else DECK_DARK

static func height_to_world(height: int) -> float:
	return float(height) * HEIGHT_UNIT
