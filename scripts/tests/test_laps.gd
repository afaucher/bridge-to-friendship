extends "res://scripts/test_support/test_case.gd"

# LAP TIMING. M26 phase 3 -- see implementation_plans/m26_race_track.md.
#
# The rule, from the ask: crossing the start line begins a lap; crossing it again
# ends one, but it only COUNTS if every other gate was touched in order on the
# way round. A cut corner is not punished, it just does not score.
#
# NOTHING HERE POKES THE COUNTERS. Every lap is driven by putting a body on a
# gate cell and letting `_process_laps` see it, for the reason test_stat_wiring
# exists: a counter that can only be made to move by calling the function that
# moves it is a counter whose WIRING has never been tested, and that is the exact
# shape that hid two dead stats in M19.
#
# ONE STEP PER PHYSICS FRAME, AND THAT IS NOT CEREMONY. The first version ran the
# whole file inside a single `_physics_process` and every lap came back as ZERO
# TICKS -- a lap is measured against `world.tick`, and the world does not tick
# inside one of its own frames. The zero-length guard rejected them all,
# correctly, and the failure read as the gates being broken. A test of a DURATION
# has to let the clock run.
#
# The claims:
#   1. A clean lap counts, and is timed from the start line rather than from the
#      beginning of the round.
#   2. A CUT LAP DOES NOT. Skip a gate and crossing the line again silently
#      starts over -- the only claim here the GEOMETRY cannot make. Gates being
#      uncuttable stops you driving around one; nothing but the sequence stops
#      you missing one out and calling the result a lap.
#   3. OUT OF ORDER IS ALSO A CUT. A set of gates would accept it.
#   4. THE BEST IS KEPT, not the last.
#   5. A GATE IS EDGE-TRIGGERED, and what that buys is the CLOCK: a lap is timed
#      from reaching the start line rather than from leaving it. A gate is four
#      cells deep and a bus crosses at 13 m/s, so a level trigger loses most of a
#      second off every lap.
#   6. Zero is not a time. Somebody who never finished a lap ranks BELOW anyone
#      who did, however slow -- the half of the ranking that is easy to get
#      backwards, because sorting ascending on the raw number does the opposite.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const A := 41
const B := 57

var world: Node3D = null
var done := false
var _queue: Array = []
var _built := false

func setup(main) -> void:
	timeout_seconds = 60.0
	test_mode = GameMode.RACE
	world = Node3D.new()
	world.name = "LapWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# A REAL RACE RUN, so the gates arrive through the generator, the builder and
	# the grid rather than being planted by this file. The path is as much the
	# thing under test as the arithmetic is.
	world.assemble_run = true
	world.run_seed = 2024
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world._spawn_player(B, 1)
	for peer in [A, B]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	# ROUND 0 IS ALWAYS BASE, and there is nothing wrong with that: the mode is
	# chosen at the first lobby, so a world's OPENING sections carry no circuit and
	# therefore no gates. The run is extended into a race round here, which is what
	# the selector does in play.
	world.run_modes = [GameMode.BASE, GameMode.RACE]
	world.grid.build_run(world.grid.run_seed,
		(SegmentPool.SECTIONS_PER_ROUND + 1) * 2 + 1,
		[GameMode.BASE, GameMode.RACE])

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	if not _built:
		_built = true
		if not check(world.grid.lap_gate_count() > 0,
				"the run really carries lap gates (%d) -- everything below is "
					% world.grid.lap_gate_count()
				+ "about nothing without them"):
			done = true
			finish()
			return
		_build_script()
		return
	if _queue.is_empty():
		done = true
		finish()
		return
	var step: Callable = _queue.pop_front()
	step.call()

func _build_script() -> void:
	_a_clean_lap_counts()
	_a_cut_lap_does_not()
	_out_of_order_is_a_cut()
	_the_best_is_kept()
	_a_gate_is_edge_triggered()
	_at(_no_lap_ranks_below_any_lap)

# --- Driving -------------------------------------------------------------------

func _at(fn: Callable) -> void:
	_queue.append(fn)

# ONE CELL OF ONE GATE. Standing a body there and ticking the pass is exactly
# what the game does when somebody drives over it.
func _cross(peer: int, gate: int) -> void:
	var body: Node = world.player_body(peer)
	for cell in world.grid.lap_gate_cells:
		if int(world.grid.lap_gate_cells[cell]) != gate:
			continue
		body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 0.9, 0.0)
		world._process_laps()
		return
	check(false, "gate %d exists to be crossed" % gate)

# OFF EVERY GATE, which is what makes the next crossing an EDGE. Without it a
# body moved from one gate straight to another is never seen to leave.
func _leave_gates(peer: int) -> void:
	world.player_body(peer).position = Vector3(0.0, -400.0, 0.0)
	world._process_laps()

func _lap(peer: int, gates: Array) -> void:
	for g in gates:
		_at(func(): _leave_gates(peer))
		_at(func(): _cross(peer, g))

func _rest() -> Array:
	var out: Array = []
	for i in range(1, world.grid.lap_gate_count()):
		out.append(i)
	return out

# --- 1. A clean lap ------------------------------------------------------------

func _a_clean_lap_counts() -> void:
	var before := [0]
	var started := [0]
	_at(func(): before[0] = world.laps_completed)
	_lap(A, [0])
	_at(func(): started[0] = world.tick)
	_lap(A, _rest())
	_lap(A, [0])
	_at(func():
		var got: int = world.laps_completed - before[0]
		print("[laps] a clean lap: %d completed, best %d ticks"
			% [got, world.best_lap_of(A)])
		eq(got, 1, "a lap through every gate in order counts (%d)" % got)
		check(world.best_lap_of(A) > 0,
			"and a time is recorded (%d ticks)" % world.best_lap_of(A))
		check(world.best_lap_of(A) <= world.tick - started[0] + 2,
			"timed from the start line (%d ticks) rather than from the beginning "
				% world.best_lap_of(A)
			+ "of the round (%d)" % world.tick))

# --- 2 and 3. Cuts -------------------------------------------------------------

func _a_cut_lap_does_not() -> void:
	var before := [0]
	_at(func(): before[0] = world.laps_completed)
	var partial: Array = _rest()
	partial.remove_at(partial.size() - 1)
	_lap(B, [0])
	_lap(B, partial)
	_lap(B, [0])
	_at(func():
		var got: int = world.laps_completed - before[0]
		print("[laps] a lap missing one gate: %d completed, best %d"
			% [got, world.best_lap_of(B)])
		eq(got, 0,
			"a lap that skipped a gate does not count (%d) -- the only claim here "
				% got
			+ "the GEOMETRY cannot make: gates being uncuttable stops you driving "
			+ "around one, and nothing but the sequence stops you missing one out")
		eq(world.best_lap_of(B), 0, "and no time is recorded for it"))

func _out_of_order_is_a_cut() -> void:
	if world.grid.lap_gate_count() < 4:
		return
	var before := [0]
	_at(func(): before[0] = world.laps_completed)
	var shuffled: Array = _rest()
	var last = shuffled[shuffled.size() - 1]
	shuffled[shuffled.size() - 1] = shuffled[shuffled.size() - 2]
	shuffled[shuffled.size() - 2] = last
	_lap(B, [0])
	_lap(B, shuffled)
	_lap(B, [0])
	_at(func():
		var got: int = world.laps_completed - before[0]
		eq(got, 0,
			"and touching them out of order is a cut too (%d) -- a SET of gates "
				% got
			+ "would accept this, which is why they are a sequence"))

# --- 4. The best of them -------------------------------------------------------

func _the_best_is_kept() -> void:
	var quick := [0]
	_at(func(): quick[0] = world.best_lap_of(A))
	_lap(A, [0])
	# A DELIBERATELY SLOWER ONE: the same route with frames burnt in the middle.
	for i in 30:
		_at(func(): pass)
	_lap(A, _rest())
	_lap(A, [0])
	_at(func():
		print("[laps] after a slower lap the best is %d (was %d)"
			% [world.best_lap_of(A), quick[0]])
		check(quick[0] > 0, "there was a first lap to beat (%d)" % quick[0])
		eq(world.best_lap_of(A), quick[0],
			"a slower lap does not overwrite a quicker one (%d, was %d) -- `best` "
				% [world.best_lap_of(A), quick[0]]
			+ "is the word in the ask and `last` is what a plain assignment gives"))

# --- 5. The edge ---------------------------------------------------------------

func _a_gate_is_edge_triggered() -> void:
	# A LAP IS TIMED FROM WHEN YOU REACH THE LINE, NOT WHEN YOU LEAVE IT.
	#
	# TWO WRONG VERSIONS OF THIS CLAIM CAME FIRST, and both passed with the edge
	# check deleted, which is the only reason the right one exists.
	#
	# The first held the START line and checked the lap count did not move --
	# satisfied by a level trigger too, since restarting a lap repeatedly does not
	# complete one. The second parked on a MID-LAP gate expecting the sequence to
	# be walked past every checkpoint -- and the sequence check already refuses
	# that, because after one advance the gate under you is no longer the one
	# expected next.
	#
	# What the edge check actually buys is the CLOCK. Level-triggered, `_lap_from`
	# is rewritten every tick you are still touching the line, so the lap is timed
	# from the moment you leave it. A gate is four cells deep and a bus crosses at
	# 13 m/s, so that is most of a second missing from every lap on a circuit that
	# takes twenty -- a timer that flatters whoever crosses slowest.
	var lap := [0]
	_lap(B, [0])
	for i in 20:
		_at(func(): world._process_laps())      # still standing on the line
	_lap(B, _rest())
	_lap(B, [0])
	_at(func():
		lap[0] = world.best_lap_of(B)
		print("[laps] 20 ticks parked on the line, lap came out %d ticks" % lap[0])
		check(lap[0] >= 20,
			"the 20 ticks spent on the start line are INSIDE the lap (%d) -- "
				% lap[0]
			+ "level-triggered, the start is rewritten on every one of them and "
			+ "the lap comes out that much shorter, which is a timer that rewards "
			+ "sitting on the line"))

# --- 6. Zero is not a time -----------------------------------------------------

func _no_lap_ranks_below_any_lap() -> void:
	var ordered: Array = RoundMachine.rank_entries([
		{"peer": 1, "lap": 0, "hats": 9},
		{"peer": 2, "lap": 6000, "hats": 0},
	])
	eq(int(ordered[0]["peer"]), 2,
		"a slow lap beats no lap and a pile of hats (%d first) -- sorting "
			% int(ordered[0]["peer"])
		+ "ascending on the raw number does the exact opposite, because 0 is the "
		+ "smallest value and it means `never finished`")
	var two: Array = RoundMachine.rank_entries([
		{"peer": 1, "lap": 9000, "hats": 9},
		{"peer": 2, "lap": 6000, "hats": 0},
	])
	eq(int(two[0]["peer"]), 2, "and between two laps the quicker one wins")
	var none: Array = RoundMachine.rank_entries([
		{"peer": 1, "lap": 0, "hats": 2},
		{"peer": 2, "lap": 0, "hats": 5},
	])
	eq(int(none[0]["peer"]), 2,
		"and with nobody lapping it falls through to hats exactly as before -- "
		+ "which is why there is no mode branch in the comparator")
