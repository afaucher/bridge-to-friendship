extends "res://scripts/test_support/test_case.gd"

# CAN A BODY WALK A LANE FLUSH AGAINST THE BRIDGE'S PARAPET?
#
# The maze spends its outer columns on explicit WALL blocks, which costs a lane.
# The alternative is to let the deck's own railing be that boundary: `has_wall`
# already parapets any solid cell in the outermost column, and WALL_HEIGHT is 2.0
# -- exactly the height a maze wall is. Same barrier, one more corridor, and the
# maze reads as walls built ON a bridge rather than as a sealed box.
#
# THAT DESIGN RESTS ENTIRELY ON THIS BEING WALKABLE, and this repo has form for
# the opposite. A flat-bottomed cylinder does not cross a 4 cm gap, it catches the
# far lip of one; two boxes placed face to face are that with the gap set to zero;
# and the elevator stopped a walk DEAD at a boundary that looked perfectly level.
# All of those presented as "sometimes you just stop". So the lane gets walked
# before anything is built on it.
#
# MEASURED, NOT REASONED. The arithmetic says there is room -- the parapet's inner
# face is 0.7 m from the cell centre and the body's radius is 0.4 -- and the
# arithmetic said there was room in the elevator case too.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const LANE := 0            # the outermost column, against the parapet
const CONTROL_LANE := 7    # open deck, nothing beside it
const START_ROW := 1
const TARGET_ROW := 9
# Eight cells at WALK_SPEED, with margin -- and NOT enough to run off the end of a
# twelve-row fixture, which is the rig mistake CLAUDE.md already has a note about.
const WALK_TICKS := 170

var world: Node3D = null
var edge: CharacterBody3D = null
var control: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "EdgeLaneWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_edge_lane.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	edge = world.player_body(1)
	control = world.player_body(2)

	edge.position = _stand(LANE, START_ROW)
	control.position = _stand(CONTROL_LANE, START_ROW)

	# Straight up-bridge, both of them, for the whole run.
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.make(t, Vector2(0.0, -1.0), 0)

func _stand(x: int, z: int) -> Vector3:
	return world.grid.cell_surface_world(Vector2i(x, z)) + Vector3(0.0, 1.2, 0.0)

func _row_of(body: Node) -> int:
	return world.grid.cell_of_world(body.position).y

func _physics_process(_delta: float) -> void:
	if done or edge == null or world.tick < WALK_TICKS:
		return
	done = true

	var edge_row: int = _row_of(edge)
	var control_row: int = _row_of(control)
	print("[edge lane] edge reached row %d at x %.2f; control reached row %d"
		% [edge_row, edge.global_position.x, control_row])

	# THE CONTROL FIRST. If the open-deck body did not get there either, the rig
	# is what is broken and the edge result means nothing -- the same reason the
	# hat probe needed a case that could succeed before its failure was believable.
	if not check(control_row >= TARGET_ROW,
			"a body on OPEN deck walks the length of the fixture (row %d of %d) -- "
				% [control_row, TARGET_ROW]
			+ "without this the edge result below is about a rig that never moved"):
		finish()
		return

	check(edge_row >= TARGET_ROW,
		"and a body in the OUTERMOST lane, flush against the parapet, walks it too "
		+ "(row %d of %d). If this stops short, the maze cannot use the bridge edge "
			% [edge_row, TARGET_ROW]
		+ "as its boundary and the outer column has to stay an explicit wall")

	# AND IT STAYED IN ITS LANE. Reaching the far end while sliding a cell inward
	# would mean the parapet is pushing the body off its line -- passable, but not
	# a corridor you could ask somebody to follow.
	var lane_x: float = world.grid.cell_surface_world(Vector2i(LANE, TARGET_ROW)).x
	check(absf(edge.global_position.x - lane_x) < GridConfig.CELL_SIZE * 0.5,
		"without being pushed out of its own cell on the way (%.2f m off centre, "
			% absf(edge.global_position.x - lane_x)
		+ "half a cell is %.2f)" % (GridConfig.CELL_SIZE * 0.5))
	finish()
