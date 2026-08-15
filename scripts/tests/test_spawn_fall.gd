extends "res://scripts/test_support/test_case.gd"

# FALLING OFF THE BOTTOM EDGE AT SPAWN. Reported 2026-08-15 as a CRASH.
#
# The bottom edge is the one nothing protects: the bridge is walked up-bridge
# (-Z), so the down-bridge end of the first segment is an open edge two metres
# from where every player is put at the start of a run. Walking backwards off it
# is the first thing anybody does by accident.
#
# What makes it different from any other fall is that it happens with the party
# at row 1, so every "where is the party" query -- the checkpoint, the run
# extension, the drone's drop point, the streaming window -- is being asked about
# a body BEHIND the start of the bridge, where the row index is NEGATIVE.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0
var worst_segments: int = 0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "SpawnFallWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1

	if frames == 2:
		# OFF THE BACK OF THE BRIDGE. +Z is down-bridge, so this is behind row 0 --
		# a negative cell row, which is the case every lookup here has to survive.
		var behind: Vector3 = world.grid.cell_surface_world(
			world.grid.entry_spawn_cell(0))
		body.position = behind + Vector3(0.0, 1.0, 8.0)
		body.velocity = Vector3.ZERO
		print("[spawnfall] pushed to row %d (behind the start)"
			% world.grid.cell_of_world(body.position).y)
		return

	worst_segments = maxi(worst_segments, world.grid.segment_count())
	if frames % 120 == 0:
		print("[spawnfall] t=%.1fs segments=%d rows=%d checkpoint_row=%d" % [
			float(frames) / 60.0, world.grid.segment_count(),
			world.grid.total_length(), world.checkpoint_row])
	if frames < 60 * 12:
		# Let it fall the whole way and come back on its own. Nothing is forced:
		# the point is that the ordinary path survives a negative row.
		return

	var landed: int = world.grid.cell_of_world(body.position).y
	print("[spawnfall] survived: wipes=%d row=%d visible=%s peak_segments=%d"
		% [world.wipes, landed, body.visible, worst_segments])

	# 1. THE RUN DOES NOT RUN AWAY. This is the crash: the extension keeps
	# RUN_LOOKAHEAD_SEGMENTS ahead of the party's front, and a body behind the
	# start used to report as being AT the front -- so every tick built more
	# bridge, which moved the front, which built more. Measured before the fix:
	# 199 segments and 4198 rows within two seconds, all of it real geometry.
	#
	# Asserted as a PEAK over the whole run, not a reading at the end: a runaway
	# that stopped growing would look identical to one that never started.
	var ceiling: int = SimConfig.RUN_INITIAL_SEGMENTS 		+ SimConfig.RUN_LOOKAHEAD_SEGMENTS + 2
	check(worst_segments <= ceiling,
		"walking off the BACK does not build the bridge forever -- peaked at %d "
			% worst_segments
		+ "segments against a ceiling of %d" % ceiling)

	# 2. AND THE RETURN IS SOMEWHERE THE PARTY ACTUALLY WAS. The same wrong
	# answer banked a checkpoint thousands of rows up, so the wipe put the player
	# down past ground nobody had crossed. At spawn there is no banked progress at
	# all, so the only correct answer is the start of the bridge.
	check(landed >= 0 and landed <= 4,
		"and a fall at spawn returns you to the START, not kilometres up the "
		+ "bridge (row %d of %d)" % [landed, world.grid.total_length()])
	check(world.running, "the world is still running after a fall off the back")
	check(body.visible, "and the player was returned rather than left invisible")
	finish()
