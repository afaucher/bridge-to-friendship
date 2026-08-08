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

const WIDTH := 30              # cells across; see bridge_grid.md on why 30
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

enum Content { NONE, PILLAR, LADDER, BOUNCER, SHOOTER, HEART, PICKUP, SPAWN }

const CONTENT_GLYPHS := {
	".": Content.NONE,
	"#": Content.PILLAR,
	"L": Content.LADDER,
	"B": Content.BOUNCER,
	"O": Content.SHOOTER,
	"+": Content.HEART,
	"*": Content.PICKUP,
	"S": Content.SPAWN,
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

# Nearest compass direction to an arbitrary heading. What turns a stick or a
# WASD combination into the axis a shove commits to.
static func nearest_direction(heading: Vector2) -> int:
	if absf(heading.x) >= absf(heading.y):
		return DIR_EAST if heading.x >= 0.0 else DIR_WEST
	return DIR_SOUTH if heading.y >= 0.0 else DIR_NORTH

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

static func cell_centre(x: int, z: int, height: int) -> Vector3:
	return Vector3(
		(float(x) + 0.5 - float(WIDTH) * 0.5) * CELL_SIZE,
		float(height) * HEIGHT_UNIT,
		cell_z_world(z)
	)

static func cell_origin_x(x: int) -> float:
	return (float(x) - float(WIDTH) * 0.5) * CELL_SIZE

static func world_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(position.x / CELL_SIZE + float(WIDTH) * 0.5)),
		int(floor(-position.z / CELL_SIZE))
	)

static func height_to_world(height: int) -> float:
	return float(height) * HEIGHT_UNIT
