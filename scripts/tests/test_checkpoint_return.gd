extends "res://scripts/test_support/test_case.gd"

# WHERE A FALL PUTS YOU BACK, measured across the whole bridge.
#
# Written 2026-08-15 from a playtest report that a respawn lands "WAY ahead of
# where we actually got to". Reading the code produced three wrong theories in a
# row, so this sweeps instead: stand at every row of a real assembled run, bank
# whatever the game banks, wipe, and print where the game puts you.
#
# SOLO IS THE WIPE PATH, NOT THE DRONE. One player waiting on the drone is every
# player waiting on the drone, which is the wipe condition -- so _drone_drop_point
# never runs and _restart_at_checkpoint does.
#
# The claim, and the only one worth a gate: A RESTART NEVER PUTS YOU PAST THE
# FURTHEST YOU GOT. A checkpoint is ground the party already took; being returned
# ahead of it skips bridge nobody crossed, and skipped bridge is the report.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var body: CharacterBody3D = null
var phase_frame: int = 0
var probe_row: int = 2
var reached_row: int = 0
var worst_ahead: int = -9999
var worst_at: int = 0

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "CheckpointWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# A REAL ASSEMBLED RUN. The question is about segment boundaries and the
	# checkpoint's integer division by CHECKPOINT_EVERY_SEGMENTS, and a single
	# test segment cannot show either.
	world.assemble_run = true
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _row_of(at: Vector3) -> int:
	return world.grid.cell_of_world(at).y

func _place(row: int) -> void:
	body.position = world.grid.cell_surface_world(
		Vector2i(world.grid.entry_spawn_cell(0).x, row)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	phase_frame += 1

	# Stand at the row (so _bank_checkpoint sees a party there), drop out of the
	# world, then WAIT FOR THE RETURN TO ACTUALLY HAPPEN before reading anything.
	#
	# The first version of this read one frame after the drop and measured the
	# FALLING BODY -- which reported "1 to 2 rows behind" for every row on the
	# bridge, a number that is not about respawning at all. (It is real, though,
	# and worth knowing: cell_of_world runs the PITCHED transform, so the same x/z
	# 35 m below the deck reads two rows down-bridge of the same x/z on it.)
	match phase_frame:
		1:
			_place(probe_row)
			reached_row = _row_of(body.position)
			return
		2:
			body.position = Vector3(body.position.x,
				SimConfig.FALL_KILL_Y - 5.0, body.position.z)
			return
		_:
			# The drone takes DRONE_RETURN_SECONDS; the body is invisible and
			# parked until then. Waiting on the VISIBILITY rather than on a frame
			# count means this cannot silently sample early again.
			if not body.visible and phase_frame < 60 * 8:
				return
			var landed: int = _row_of(body.position)
			var ahead: int = landed - reached_row
			if ahead > worst_ahead:
				worst_ahead = ahead
				worst_at = reached_row
			print("[probe] stood row %2d  seg %d  checkpoint_row %2d  ->  landed %2d  (%+d)"
				% [reached_row, world.grid.segment_index_of_row(reached_row),
					world.checkpoint_row, landed, ahead])
			phase_frame = 0
			probe_row += 2
			if probe_row < world.grid.total_length() - 1:
				return

	if phase_frame != 0:
		return

	print("[probe] WORST: %+d rows, standing at row %d (total %d rows, %d segments)"
		% [worst_ahead, worst_at, world.grid.total_length(),
			world.grid.segment_count()])
	check(worst_ahead <= 0,
		"a restart never puts you PAST the furthest you got -- worst was %+d rows, "
			% worst_ahead
		+ "standing at row %d" % worst_at)
	finish()
