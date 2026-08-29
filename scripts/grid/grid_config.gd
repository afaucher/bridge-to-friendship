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

# THE BRIDGE IS FLAT, AS OF 2026-08-23, AND WAS TILTED FOUR DEGREES BEFORE THAT.
#
# The tilt existed for exactly one thing, and its old note said so: "This is what
# makes plinko work. A shooter drops spheres and they must come DOWN the bridge at
# the players under their own weight -- not because something pushes them, and not
# on a scripted path. A constant pitch gives every loose object on the bridge a
# reason to roll toward the party, and it costs one rotation on the grid root
# rather than a rule anywhere in the sim."
#
# EVERY LOOSE OBJECT was the problem. That sentence is a feature for a ball and a
# bug for everything else, and two systems had already grown workarounds for it:
# a dropped weapon that rolls never settles, so it never becomes collectable and
# runs away down the bridge (special_body.gd); and a hat that lands on its side
# rolls, so its rotation is locked (hat_body.gd). The pitch was doing one job it
# was asked for and two nobody wanted.
#
# It was also a quiet tax on every height comparison in the project. Grid-local Y
# and world Y disagreed by the pitch, which is what broke the ladder face (see
# CLAUDE.md) and what "most altitude gained" would have measured if that stat had
# used world space.
#
# So the ball gets an explicit force instead -- SimConfig.PLINKO_DRIFT, applied to
# the one object that wanted it -- and "horizontal" becomes a stable definition,
# which is what the 2026-08-23 playtest asked for.
#
# KEPT AS A CONSTANT RATHER THAN DELETED. It is one rotation on the grid root, so
# putting the tilt back is this line; and a pitched bridge may well be what a bus
# route or a ship corridor wants (see M25).
const BRIDGE_PITCH_DEG := 0.0

# Width is a property of the BRIDGE, not a global: a .seg declares its own, and
# every cell<->world conversion below takes it as an argument. This exists only
# as the fallback for a file that does not say.
#
# 15 cells (30 m) for the playtest bridge. 30 was the original brief, but a
# 60 m deck lets 2-4 players spread past the point where anyone can help anyone,
# which fights the co-op premise -- see "how wide is too wide" in
# design_ideas/bridge_grid.md. The test fixtures declare 30 explicitly and are
# unaffected.
#
# RAISED TO 21 FOR M22 PHASE C, and the number that matters is the one below it.
# The canvas was 15 and every authored file was 15, so "narrow" was the only
# direction variety could go: 15 was simultaneously the default width and the
# maximum, and no section could ever feel WIDE. A canvas with headroom on both
# sides of the baseline is what makes "wider than usual" expressible at all.
#
# EVERY 15-WIDE FILE WAS PADDED BY 3 COLUMNS OF HOLE ON EACH SIDE, which is a
# provable no-op rather than a re-authoring: `cell_centre` is
# (x + 0.5 - width * 0.5) * CELL_SIZE, so a symmetric pad of 3 against a width
# that grew by 6 leaves every existing cell at exactly the same world coordinate
# -- old column 0 at width 15 and new column 3 at width 21 are both x = -14. And
# because the padding runs unbroken to the canvas edge, M22's parapet rule grows
# column 3 the railing column 0 used to have, in the same place.
const DEFAULT_WIDTH := 21

# WHAT "NORMAL WIDTH" IS, as an inset from each side of the canvas.
#
# 21 - 2*3 = 15, which is the width this game has been played and tuned at for
# its whole life. Keeping it as the MEDIAN rather than as an extreme is the whole
# point of the canvas bump: a section can now pinch tighter than usual OR open
# out past it, and the shape a player thinks of as "the bridge" is unchanged.
#
# Deliberately NOT zero. A generator whose default is the full canvas would make
# every section the widest it can be and put the variety entirely below it, which
# is the situation the canvas bump exists to escape.
const BASELINE_INSET := 3
const DECK_THICKNESS := 1.0    # how far the deck slab hangs below its top face
# A RAILING, NOT A WALL (2026-08-20, from a playtest of M22's variable width:
# "it might visually read better with half height walls").
#
# It was 2.0 -- a whole cell -- and the player is 1.8 m tall, so the bridge was
# fenced by something you cannot see over. That reads as a trench rather than as
# a structure in the air, and the effect got louder the moment the deck started
# changing width, because the railing is what draws the outline. At 1.0 it is
# waist-high on a 1.8 m body: still stops a walk-off (there is no jump in this
# game and no step-up), and now the drop past it is visible, which is what makes
# a narrow section read as narrow.
#
# THE OLD NUMBER WAS CHOSEN FOR CONTAINMENT, NOT FOR LOOKS -- its comment said
# "contains plinko balls, blocks a walk-off". Deliberately NOT gated: a ball that
# escapes over a low rail and rolls off the bridge is a fine thing to happen, and
# writing a test that pins containment would make it a rule nobody agreed to.
const WALL_HEIGHT := 1.0
const WALL_THICKNESS := 0.3

# --- Cell kinds ---------------------------------------------------------------

# WALL IS APPENDED, NOT INSERTED. A kind's integer value is what a `.seg` parses
# into and what every downstream match reads; renumbering DECK or HOLE would
# reinterpret every cell in the game. Same rule as SetPieces.LIBRARY and
# SegmentPool.POOL, for the same reason.
enum Kind { DECK, HOLE, WATER, RAMP, WALL }

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
	# A BLOCK, NOT A FLOOR (2026-08-16). Solid geometry from the floor beside it up
	# to its own height, that nothing can ever stand on.
	#
	# THIS GAME HAD NO WALL PRIMITIVE and a maze is the thing that needs one. The
	# obvious substitute -- raised DECK -- already looks and collides exactly right,
	# because `cell_underside` hangs a slab down to its lowest neighbour and there
	# is no step-up in this game, so a cell one unit up is impassable. What it is
	# NOT is walkable, and the validator had no way to know that: every wall top is
	# a solid cell no flood can reach, so `_check_orphans` reports the entire
	# lattice as "marooned deck" and rejects the segment. The two readings cannot be
	# told apart geometrically -- a wall top and a shelf you were meant to reach are
	# the same cell -- so it takes the AUTHOR to say which one it is. That is all
	# this glyph is: the declaration.
	#
	# Being a non-solid kind is what does the work. `is_solid` is false, so the
	# flood refuses to enter it, the orphan count skips it, parapets skip it,
	# content on it is an error, and the dressing pass never picks it. Every one of
	# those is the behaviour a wall wants, and not one of them had to be written.
	#
	# `X` rather than `#`, which reads better as a wall and is already PILLAR in the
	# content grid. Two glyphs that mean different things in two grids is the typo
	# nobody spots.
	"X": Kind.WALL,
}

# --- Cell contents ------------------------------------------------------------

enum Content { NONE, PILLAR, LADDER, BOUNCER, SHOOTER, HEART, PICKUP, SPAWN, MOUND, HAT, SKIRMISHER, TURRET, PICKUP_GRENADE, PICKUP_MINE, PICKUP_SHIELD, PICKUP_ROCKET, GATE, TREE, HALF_WALL, SPIKES, PICKUP_LEGS, CRUMBLE, TIMED, ELEVATOR, PICKUP_SHOTGUN, PICKUP_RIFLE, PICKUP_HEAVY, MERCHANT, GRAVE, MODE_POST, BUS_POST }

const CONTENT_GLYPHS := {
	".": Content.NONE,
	# `w` is WIDE and `f` is FAR, which is the only thing that separates the two
	# new guns -- and both are lowercase like every other pickup, so a glyph grid
	# still reads as terrain in capitals and things-to-take in lower case.
	"w": Content.PICKUP_SHOTGUN,
	"f": Content.PICKUP_RIFLE,
	# `y` for heavy. Not adjacent to any glyph it could be mistyped for, which
	# matters more in a grid of them than the mnemonic does.
	"y": Content.PICKUP_HEAVY,
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
	# A grave: a dormant PACK of zombies. Lowercase for the same reason `m` is --
	# it is a thing that WILL exist, authored where it starts -- and `z` is the one
	# letter nobody will ever wonder about in a grid full of them.
	#
	# ONE GLYPH IS ONE PACK, not one zombie. That is worth stating in the format
	# rather than only in the code, because it is the first content in this game
	# where a cell is worth more than a body: an author who reads `z` as "a zombie"
	# will put five of them down and get twenty-five.
	"z": Content.GRAVE,
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
	# AN ELEVATOR (M17 phase 9). Uppercase, like every other fixed structure that
	# is part of the terrain rather than dropped on it: L is a ladder, B a bouncer,
	# E is the platform that does their job while you stand still.
	"E": Content.ELEVATOR,
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
	# THE MERCHANT: the first NPC here that is not trying to kill you. He takes one
	# hat off your tower and gives back one three and a half times taller, once,
	# and you pay by dashing into him. See design_ideas/merchant.md.
	#
	# `$` AND NOT A LETTER, deliberately breaking the capitals-are-terrain /
	# lowercase-is-a-pickup convention rather than bending it, because he is
	# neither: he is not built into the bridge and he is not something you walk
	# over and collect. `M` was the obvious pick and is the wrong one -- `m` is a
	# mound, and a friendly NPC one shift-key away from the hazard that charges you
	# is the typo nobody spots in a grid of them. That is the same argument that
	# put mines on `x` rather than beside the mound already.
	"$": Content.MERCHANT,

	# THE MODE SELECTOR (M25 phase 2). A post you dash into to say what the next
	# stretch of bridge will be.
	#
	# `?` FOR THE SAME REASON THE MERCHANT IS `$`: it is neither terrain nor a
	# pickup, so it breaks the capitals-are-terrain convention rather than bending
	# it -- and a question mark is what the thing does. It is also nowhere near a
	# letter, which is the property that matters in a grid of them.
	"?": Content.MODE_POST,
	# A BUS POST -- dash it and a bus turns up. `!` because it is not adjacent to
	# anything else on the board: `b` would have been the mnemonic and `B` is the
	# bouncer, and two glyphs one shift apart is a typo nobody spots in a grid of
	# them (see the level-authoring notes).
	"!": Content.BUS_POST,
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
const ELEVATOR_COLOUR := Color(0.78, 0.66, 0.24)   # brass, and it moves
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

# The cell step for a direction VECTOR, which is the inverse of DIR_VECTORS.
#
# Exists because `ladder_face` answers in world directions (the art needs one to
# point the rungs) while the cell it names is needed too, and deriving one from
# the other by hand at each call site is how the two ends of a ladder came to
# disagree in the first place.
static func cell_step(v: Vector3) -> Vector2i:
	var best: int = DIR_SOUTH
	var closest: float = INF
	for dir in 4:
		var d: float = DIR_VECTORS[dir].distance_to(v)
		if d < closest:
			closest = d
			best = dir
	return DIR_CELLS[best]

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
