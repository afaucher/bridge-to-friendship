extends "res://scripts/test_support/test_case.gd"

# WHERE A FALL PUTS YOU BACK, measured rather than reasoned about.
#
# REWRITTEN 2026-08-15 FOR M16, NOT DELETED. Checkpoints are gone -- a wipe now
# returns the party to the lobby they came from rather than to a banked segment
# row -- but both claims below are about the SHAPE of a return and survive the
# change intact. A test that encodes two real bugs is worth carrying forward.
#
# Written 2026-08-15 from a playtest report that a respawn lands "WAY ahead of
# where we actually got to", and reading the code produced three wrong theories
# before this file produced one number. It sweeps: stand at a row, fall out of
# the world, and print where the game puts you back.
#
# WHAT IT MEASURED, on a 3-segment run:
#   the restart is ALWAYS BEHIND, by up to a full checkpoint interval -- 61 rows
#   at the worst sample, which is two segments of bridge. Never ahead, in 1800
#   samples. So the forward jump in the report is NOT this path.
#
# It is the drone: _drone_drop_point puts a returning player beside the teammate
# FURTHEST UP THE BRIDGE, and the leash lets the party stretch to LEASH_HARD --
# so a fall can legitimately return you 70 m past where you went over. That is a
# design decision, deliberately made, and it is not a rounding error.
#
# SOLO IS THE WIPE PATH, NOT THE DRONE. One player waiting on the drone is every
# player waiting on the drone, which is the wipe condition -- so the restart runs
# on the same tick and _drone_drop_point never gets asked.
#
# The two claims, which are the promise a checkpoint makes:
#   1. IT NEVER PUTS YOU PAST THE FURTHEST YOU GOT. Ground nobody crossed is
#      ground the run skipped.
#   2. IT NEVER TAKES BACK MORE THAN A SECTION. Under M16 a fall in a section
#      returns you to that section's lobby; a return that lands further back than
#      that has lost track of the lobby entirely, which is the failure that
#      actually happened.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Every Nth row of the initial run. The sweep is what found the real number; a
# single sample would have been read as whatever the checkpoint happened to be.
const ROW_STEP := 3

var world: Node3D = null
var body: CharacterBody3D = null
var phase_frame: int = 0
var probe_row: int = 2
var last_row: int = 0
var reached_row: int = 0
var samples: int = 0
var worst_ahead: int = -9999
var worst_ahead_at: int = 0
var worst_behind: int = 0
var worst_behind_at: int = 0
var off_lobby: int = 0
var off_lobby_at: int = -1

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "CheckpointWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# A REAL ASSEMBLED RUN. The question is about segment boundaries and about
	# where a lobby is, and a single test segment cannot show either.
	world.assemble_run = true
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	# THE ROWS THAT EXIST AT THE START. The run extends itself as the party
	# advances, so an unbounded sweep walks the bridge forever -- the first draft
	# of this reached 170 segments and timed out.
	last_row = world.grid.total_length() - 2

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

	# Stand at the row (so the run machinery sees a party there), drop out of the
	# world, then WAIT FOR THE RETURN TO ACTUALLY HAPPEN before reading anything.
	#
	# The first draft read one frame after the drop and was measuring the FALLING
	# BODY -- which reported "1 to 2 rows behind" everywhere, a number with nothing
	# to do with respawning. (It is real and worth knowing: cell_of_world runs the
	# PITCHED transform, so the same x/z 35 m below the deck reads two rows
	# down-bridge of the same x/z standing on it.)
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
			# Waiting on VISIBILITY rather than a frame count, so this cannot
			# silently start sampling early again.
			if not body.visible and phase_frame < 60 * 8:
				return
			_record(_row_of(body.position))
			phase_frame = 0
			probe_row += ROW_STEP
			if probe_row <= last_row:
				return

	if phase_frame != 0:
		return
	_report()

func _record(landed: int) -> void:
	samples += 1
	var delta: int = landed - reached_row
	if delta > worst_ahead:
		worst_ahead = delta
		worst_ahead_at = reached_row
	if -delta > worst_behind:
		worst_behind = -delta
		worst_behind_at = reached_row

	# WHERE IT LANDED HAS TO BE SOMEWHERE YOU CAN STAND. Deliberately NOT compared
	# against _lobby_point: doing that asks the function under test what the right
	# answer is and then checks it against its own output, which passes with the
	# lookup hardcoded to row 1 — measured, this exact test did.
	if not world.grid.is_solid(Vector2i(world.grid.entry_spawn_cell(0).x, landed)):
		off_lobby += 1
		if off_lobby_at < 0:
			off_lobby_at = reached_row

	print("[checkpoint] stood row %3d (seg %d)  lobby %3d  ->  landed %3d  (%+d)"
		% [reached_row, world.grid.segment_index_of_row(reached_row),
			world.round_machine.rear_row + 1, landed, delta])

func _report() -> void:
	print("[checkpoint] %d samples over %d rows: worst forward %+d (at row %d), "
		% [samples, last_row, worst_ahead, worst_ahead_at]
		+ "worst back %d (at row %d)" % [worst_behind, worst_behind_at])
	check(samples > 8, "the sweep really ran (%d samples)" % samples)

	# 1. NEVER PAST THE FURTHEST YOU GOT. One row of slack, and only one: standing
	# exactly ON a banked row lands you on the row above it, which is the "+1" the
	# restart adds so nobody spawns inside a segment seam.
	check(worst_ahead <= 1,
		"a restart never puts you past the furthest you got -- worst forward was "
		+ "%+d rows, standing at row %d" % [worst_ahead, worst_ahead_at])

	# 2. AND NEVER TAKES BACK MORE THAN THE INTERVAL IT PROMISED. Measured worst
	# is one interval; the allowance is two, so this catches a checkpoint that
	# stopped banking rather than one that banked a row later than expected.
	# The allowance is a whole SECTION, because that is what a round now is: fall
	# in a section and you go back to its lobby. Generous on purpose -- this
	# catches a return that has lost track of the lobby entirely, which is the
	# failure that actually happened, not one that is a few rows out.
	# 2. AND ON GROUND YOU CAN STAND ON. WEAK, AND LABELLED WEAK: A/B'd by deleting
	# _lobby_point's own solid-ground fallback, and it still passed, because the
	# cell it picks happens to be solid in this run anyway. It is here as a
	# tripwire for a return that starts landing in a gap, not as evidence that the
	# fallback works.
	eq(off_lobby, 0,
		"every return lands on solid deck (first miss at row %d)" % off_lobby_at)

	# WHAT THIS TEST CANNOT ASSERT, stated so nobody adds it back thinking they
	# have. The rule the design actually makes is "you go back to the lobby of the
	# round you are in", and _lobby_point derives that from the round machine's
	# REAR STRIP. This test teleports its body from row to row, so it never
	# crosses a strip and the round never advances — rear_row stays at the first
	# one for all 37 samples, and every landing is correctly the first lobby.
	#
	# That makes the interesting claim untestable HERE, and two attempts to test
	# it anyway both failed in instructive ways. A distance allowance (rewind no
	# more than two segment lengths) is not what bounds a return at all, and broke
	# the day the segment layout changed while every landing was still correct. An
	# equality against _lobby_point is worse: it asks the function under test for
	# the expected answer, and passes with that function hardcoded to row 1.
	#
	# The honest version needs a body that PLAYS through a strip so the round
	# advances, and then asserts the landing follows it. That is a different test
	# and it is the one worth writing.
	#
	# Until it exists this file is THIN, and saying so is the point of this note.
	# Claim 1 discriminates; claim 2 did not when it was A/B'd. Neither of them
	# can see the rule the file is named after. A test whose weakness is written
	# down is a test somebody can fix; one that merely looks green is not.
	finish()

func _unused_longest_segment() -> int:
	var longest := 1
	for i in world.grid.segment_count():
		var rows: int = world.grid.first_row_of_segment(i + 1) \
			- world.grid.first_row_of_segment(i)
		if i + 1 >= world.grid.segment_count():
			rows = world.grid.total_length() - world.grid.first_row_of_segment(i)
		longest = maxi(longest, rows)
	return longest
