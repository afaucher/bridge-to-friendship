extends RefCounted

# CLIMBING (M17 phase 6): the CLIMB state, and finding a ladder to enter it from.
# Vertical control, no gravity, and no verbs; pinned to the ladder's face, which
# the GRID owns (BridgeGrid.ladder_face) so the rungs and the body can never
# disagree about which side it is on.
#
# Part of PlayerBody. It holds no state of its own -- everything it changes is the
# body's, which is what keeps capture_state() the whole truth and a replay exact.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

# The ladder cell within reach, or (-1, -1). Asked of the GRID every tick rather
# than remembered, so nothing about a climb has to ride capture_state beyond the
# state enum itself.
# HOW FAR OFF THE LADDER'S OWN FACE A BODY MAY BE AND STILL REACH IT.
#
# A cosine, so 0.35 is about 70 degrees either side of straight-on: a diagonal
# approach still catches the rungs, and the opposite side of the block -- or
# either flank of a free-standing post, which read as 0 -- does not. Generous on
# purpose, because fumbling for a ladder you are standing against is not the
# interesting kind of difficulty; the thing being refused is being TELEPORTED
# around a tower you merely brushed.
const CLIMB_FACE_DOT := 0.35

# --- Climbing (M17 phase 6) ---------------------------------------------------
#
# NO GRAVITY, NO VERBS, VERTICAL CONTROL. A climbing body is doing one thing, and
# the cost of a ladder is that it is the only thing: you cannot dash, shoot or
# dodge while on one, which is what pays for it being the compact way up.
#
# THE LADDER IS A CELL, NOT A BODY. It is grid-resident like a shooter's pillar,
# so climbing asks the GRID where it is rather than tracking a node -- and that
# means a client replaying a correction reaches the same answer from the same
# position, with nothing extra to capture.
func step(move: Vector2) -> void:
	var cell: Vector2i = ladder_cell()
	if cell.x < 0:
		body.state = State.WALK
		body.grounded = false
		return

	var grid: Node = body.world.grid
	var post: Vector3 = grid.cell_surface_world(cell)
	var face: Vector3 = ladder_face(cell)

	# HELD ON THE FACE OF THE CLIFF, not on the ladder's cell. The first version
	# pinned the body to the cell centre and it stuck at y 1.50 against a top of
	# 2.62 -- because the ladder's cell IS the raised deck, so pinning to it puts
	# the body inside a solid column and the solver refuses to lift it. A ladder
	# is climbed on the outside of the thing it is bolted to.
	var stand: Vector3 = post + face * (GridConfig.CELL_SIZE * 0.5 + RADIUS + 0.05)
	body.position.x = stand.x
	body.position.z = stand.z

	# FORWARD ON THE STICK CLIMBS, BACK DESCENDS -- "away from the camera is up",
	# the same convention the whole game walks by.
	#
	# Position is set directly rather than swept. There is nothing above a climber
	# to collide with, and a sweep against the wall they are pressed to is a fight
	# with the solver that can only lose ground.
	body.position.y += -move.y * SimConfig.CLIMB_SPEED * SimConfig.TICK_DELTA
	body.velocity = Vector3.ZERO
	body.grounded = false

	# OFF THE TOP: over the lip and onto the deck the ladder serves.
	if body.position.y - HALF_HEIGHT >= post.y - 0.05:
		body.position = Vector3(post.x, post.y + HALF_HEIGHT + SimConfig.CLIMB_EXIT_LIFT, post.z)
		body.state = State.WALK
		body.grounded = true
		return
	# OFF THE BOTTOM: back on the ground, back to walking.
	var foot: float = ladder_foot(cell)
	if body.position.y - HALF_HEIGHT <= foot:
		body.position.y = foot + HALF_HEIGHT
		body.state = State.WALK
		body.grounded = true

# Which way the cliff FACES: from the ladder's cell toward the lowest ground
# beside it, which is the side a climber arrives on.
# ASKED OF THE GRID, NOT RECOMPUTED HERE. This used to be its own copy of the
# arithmetic, and the copy compared WORLD heights while the art compared
# grid-local ones -- so on the bridge's 4 degree pitch a tie between deck-level
# neighbours broke one way for the rungs and another for the body. A player saw
# the ladder on the right and was snapped to the front.
#
# The grid owns the heights, so the grid owns the answer. See BridgeGrid.ladder_face.
func ladder_face(cell: Vector2i) -> Vector3:
	return body.world.grid.ladder_face(cell)

func ladder_cell() -> Vector2i:
	if body.world == null or body.world.grid == null:
		return Vector2i(-1, -1)
	var grid: Node = body.world.grid
	var here: Vector2i = grid.cell_of_world(body.position)
	for dz in [0, -1, 1]:
		for dx in [0, -1, 1]:
			var cell := Vector2i(here.x + dx, here.y + dz)
			if grid.content_at(cell) != GridConfig.Content.LADDER:
				continue
			var at: Vector3 = grid.cell_surface_world(cell)
			var out := Vector2(body.position.x - at.x, body.position.z - at.z)
			if out.length() > SimConfig.CLIMB_REACH:
				continue
			# ON THE FACE, NOT MERELY NEAR THE BLOCK.
			#
			# This asked only how CLOSE the body was, in any of the eight cells
			# around it -- so touching any edge of a free-standing post grabbed the
			# ladder, and `step` then pinned the body to the face it is
			# actually on. Approach from the far side and you were teleported the
			# best part of three metres around the tower. Reported from play as
			# "you still snap to the ladder side when touching any edge of the
			# block".
			#
			# A ladder is climbed from the side it is bolted to. The GRAB has to
			# ask the same question the HOLD answers, or the difference between
			# them is a distance the player gets moved.
			# STANDING ON IT IS REACH TOO, and this is the top of the climb --
			# the cell you arrive at, and the cell you step off to go back down.
			# Excluding it would make a ladder one-way.
			if out.length() <= GridConfig.CELL_SIZE * 0.5:
				return cell
			var face: Vector3 = grid.ladder_face(cell)
			var toward := Vector2(face.x, face.z)
			if toward.length_squared() > 0.0001 					and out.normalized().dot(toward.normalized()) < CLIMB_FACE_DOT:
				continue
			return cell
	return Vector2i(-1, -1)

# The deck a ladder is climbed FROM: the lowest solid neighbour, which is the
# bottom of the drop it serves.
# THE GROUND THE LADDER IS CLIMBED FROM -- the cell on its FACE, not the lowest
# of all four neighbours. Those were the same answer while a ladder sat on a
# cliff and are not on a free-standing post, where three neighbours are level and
# the body is held against exactly one of them. Taking the minimum over all of
# them could put the foot on a side the climber is nowhere near.
func ladder_foot(cell: Vector2i) -> float:
	var grid: Node = body.world.grid
	var side: Vector2i = cell + GridConfig.cell_step(grid.ladder_face(cell))
	if not grid.is_solid(side):
		return grid.cell_surface_world(cell).y
	return grid.cell_surface_world(side).y

# Grab a ladder from WALK. Called from the walk step: pushing INTO a ladder is
# the whole input, because a dedicated button for "climb the thing you are
# standing against" is a button nobody presses.
func try_grab(move: Vector2) -> bool:
	if move.length_squared() < 0.04:
		return false
	var cell: Vector2i = ladder_cell()
	if cell.x < 0:
		return false
	var top: float = body.world.grid.cell_surface_world(cell).y
	if body.position.y - HALF_HEIGHT >= top - 0.1:
		# FROM THE TOP, AND ONLY BY WALKING OVER THE EDGE THE LADDER IS ON.
		#
		# This was a flat refusal -- "a ladder is not a handrail: standing on the
		# deck it serves and pushing at it should walk, not drop you onto a
		# climb". True of a ladder at a cliff, where the deck continues past it
		# and you have somewhere to walk. On a free-standing post the top IS the
		# ladder cell, so the rule made the tower one-way: climb up, then jump
		# off. Asked for from play: "let's also make sure you can get down".
		#
		# The reason survives as the CONDITION rather than as a refusal. Pushing
		# any old way on top still walks; pushing out over the ladder's own face
		# -- the one direction that would otherwise step you into open air --
		# starts the climb down. Nothing else changes what a cliff ladder does,
		# because on one of those the face direction is off the edge anyway.
		var face: Vector3 = body.world.grid.ladder_face(cell)
		var toward := Vector2(face.x, face.z)
		if toward.length_squared() < 0.0001:
			return false
		if move.normalized().dot(toward.normalized()) < CLIMB_FACE_DOT:
			return false
		# BELOW THE LIP, or `step` reads the body as having just arrived at
		# the top and hands it straight back to WALK -- a grab that undoes itself
		# in the same tick, which reads as the input doing nothing.
		body.position.y = top + HALF_HEIGHT - 0.2
	body.state = State.CLIMB
	body.state_timer = 0.0
	body.velocity = Vector3.ZERO
	return true
