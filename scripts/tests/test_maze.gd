extends "res://scripts/test_support/test_case.gd"

# THE WALL KIND, WALKED INTO RATHER THAN INSPECTED.
#
# `Kind.WALL` is new geometry, and this repo has now had FIVE bugs that were a
# blocker which did not block -- the round barrier on an unmasked layer being the
# worst, because `check(wall != null)` was green for its whole life. A wall that
# exists, is positioned, is drawn and is replicated is not a wall. So this drives
# a body at one under power for two seconds and asks where it ended up.
#
# THE CONTROL IS THE OTHER HALF, and it is the half that carries the design.
# A second body runs the SAME input, the same distance, in the same row, with open
# corridor ahead of it instead of a wall. Without it, "the body did not move" is
# equally well explained by a broken rig -- and a maze nobody can walk in at all
# passes a blocking test perfectly.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Both bodies stand in row 2 -- the first corridor row past the entrance -- and
# both push EAST. Read off segments/run_maze.seg:
#
#   z=2:  X.X.....X.....X
#         0123456789...
#
# (7,2) has a WALL at (8,2). (10,2) has open corridor as far as (13,2). One input,
# two outcomes, and the difference is the only thing under test.
const BLOCKED_CELL := Vector2i(7, 2)
const WALL_CELL := Vector2i(8, 2)
const OPEN_CELL := Vector2i(10, 2)
const OPEN_REACH := 12          # two clear cells east of OPEN_CELL

# Two seconds at full stick. A body crosses a 2 m cell in about a third of a
# second, so this is six times what the control needs -- the margin is for the
# BLOCKED body, where the question is whether it eventually squeezes through.
const PUSH_TICKS := 120

var world: Node3D = null
var blocked: CharacterBody3D = null
var control: CharacterBody3D = null
var _done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "MazeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/run_maze.seg"]
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	blocked = world.player_body(1)
	control = world.player_body(2)

	# NOT COINCIDENT, and three cells apart with a wall between them: two bodies in
	# the same place depenetrate through the floor (CLAUDE.md), and two in the same
	# corridor would have the front one deciding the back one's result.
	blocked.position = _stand(BLOCKED_CELL)
	control.position = _stand(OPEN_CELL)

	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.make(t, Vector2(1.0, 0.0), 0)

func _stand(cell: Vector2i) -> Vector3:
	return world.grid.cell_surface_world(cell) + Vector3(0.0, 1.2, 0.0)

func _physics_process(_delta: float) -> void:
	if _done or blocked == null or world.tick < PUSH_TICKS:
		return
	_done = true

	var half: float = GridConfig.CELL_SIZE * 0.5
	var home: float = world.grid.cell_surface_world(BLOCKED_CELL).x
	var drift: float = blocked.global_position.x - home

	# THE WALL HELD. Still inside its own cell after two seconds of full stick --
	# stated as "did not leave cell 7" rather than "moved less than N", because the
	# cell is the unit the level is authored in and a metre is not.
	check(drift < half,
		"a body at full stick into a WALL stays in its own cell: drifted %.2f m "
			% drift
		+ "east of (%d,%d), which is %.2f m past the boundary into the wall at (%d,%d)"
			% [BLOCKED_CELL.x, BLOCKED_CELL.y, drift - half, WALL_CELL.x, WALL_CELL.y])

	# AND THE CONTROL GOT SOMEWHERE. Same input, same row, open corridor: if this
	# fails, the assertion above proved nothing about walls and everything about a
	# body that cannot move.
	var reached: float = world.grid.cell_surface_world(Vector2i(OPEN_REACH, OPEN_CELL.y)).x
	check(control.global_position.x >= reached,
		"and the same input in open corridor crosses cells: reached x %.2f, "
			% control.global_position.x
		+ "wanted %.2f (cell %d) -- without this the block above is equally well "
			% [reached, OPEN_REACH]
		+ "explained by a rig that never moved anybody")

	_check_doors()
	finish()

# ONE WAY IN AND ONE WAY OUT is the composition, not an accident of the carve, so
# it is worth a claim: a seven-wide mouth would let the party fan out before the
# maze asked them anything.
func _check_doors() -> void:
	var seg = SegmentData.from_file("res://segments/run_maze.seg")
	if not check(seg.is_valid(), "run_maze parses (%s)" % ", ".join(seg.errors)):
		return
	for row in [1, seg.length - 3]:
		var open_cells := 0
		for x in seg.width:
			if seg.is_solid(x, row):
				open_cells += 1
		eq(open_cells, 1,
			"row %d is a wall with exactly one door in it" % row)
