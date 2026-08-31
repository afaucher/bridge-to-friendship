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
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
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
	_you_can_see_the_gates_and_which_is_yours()
	_the_clock_runs_while_you_drive()
	_a_round_starts_with_no_laps()
	_dying_ends_the_lap_you_were_driving()
	_the_board_says_what_decided_it()
	_the_clock_stops_when_the_round_does()

# --- 10. DYING ENDS THE LAP YOU WERE DRIVING ------------------------------------
#
# Reported: "after death in a race, the counter still showed up in my HUD."
#
# `lap_elapsed_of` answers for as long as `_lap_next` holds the peer, and nothing
# ever took the peer out of it -- so a clock started at the line went on counting
# through the fall, the drone and the respawn, and the first thing a player saw on
# coming back was a lap time made mostly of being dead.
#
# THE BEST IS THE OTHER HALF, and it is the half that would be easy to break
# while fixing this: that lap was driven and earned, and clearing it along with
# the running one would delete the whole point of the mode. Both asserted, because
# "clear the lap state" is one sentence covering two opposite intentions.
func _dying_ends_the_lap_you_were_driving() -> void:
	var kept := [0]
	var ticking := [0]
	_at(func(): world.clear_round_stats())
	_at(func(): _leave_gates(A))
	_lap(A, [0])
	_lap(A, _rest())
	_lap(A, [0])
	# Driving again, with a clock running and a best already on the board.
	_at(func(): _leave_gates(A))
	_at(func(): _cross(A, 0))
	for i in 20:
		_at(func(): pass)
	_at(func():
		kept[0] = world.best_lap_of(A)
		ticking[0] = world.lap_elapsed_of(A)
		check(kept[0] > 0, "a lap was completed first (%d ticks)" % kept[0])
		check(ticking[0] > 0,
			"and another is running when the fall happens (%d ticks)" % ticking[0]))
	_at(func(): world._begin_drone_return(A))
	_at(func():
		print("[laps] after dying the clock reads %d (was %d) and the best is %d (was %d)"
			% [world.lap_elapsed_of(A), ticking[0], world.best_lap_of(A), kept[0]])
		eq(world.lap_elapsed_of(A), 0,
			"the lap you were driving is over when you die (%d ticks still on the "
				% world.lap_elapsed_of(A)
			+ "clock) -- you did not finish it, and a clock that runs through the "
			+ "fall and the drone hands you back a time made mostly of being dead")
		eq(world.best_lap_of(A), kept[0],
			"and the best is untouched (%d, was %d) -- that one was driven, and "
				% [world.best_lap_of(A), kept[0]]
			+ "clearing it with the running lap would delete the mode's whole point"))

# --- 11. THE BOARD EXPLAINS THE RANK IT ACTUALLY USED ---------------------------
#
# Reported: "on the victory screen it still lists '3 hats' under 1st instead of
# the lap time. It doesn't list the lap time which I would expect." The reason
# line named HATS whichever mode had been played, so a race was sorted on lap
# times and explained by a hat count -- a number nobody can explain is a number
# nobody trusts, which is the note that put the line there in the first place.
#
# ASKED OF THE COMPARATOR'S OWN PRECEDENCE. `RoundMachine.rank_key` walks the
# same keys in the same order the sort does and lives beside it;
# `HudModel.rank_reason` only turns that into words. Neither branches on the
# mode, for the reason the comparator already gives: a lap of 0 means nobody
# finished one, so outside a race every row falls through to hats exactly as
# before.
#
# THE ROWS ARE BUILT BY HAND HERE, deliberately. This is a claim about the
# EXPLANATION matching the SORT, so the inputs have to be chosen to make the two
# disagree -- a racer whose hats would rank them last and whose lap ranks them
# first. Driving that state through a real world would take a long fixture to
# produce one string.
func _the_board_says_what_decided_it() -> void:
	_at(func():
		var per: int = int(round(1.0 / SimConfig.TICK_DELTA))
		# A RACER WITH A LAP AND NO HATS, and a walker with three hats and no lap.
		# Under the old line the racer read "0 hats"; under the sort they win.
		var racer := {"peer": 1, "lap": per * 22 + per / 2, "hats": 0, "made_it": true}
		var hoarder := {"peer": 2, "lap": 0, "hats": 3, "made_it": true}
		var ordered: Array = RoundMachine.rank_entries([hoarder, racer])
		print("[laps] the board orders %s first, explained as `%s`"
			% [int(ordered[0]["peer"]), HudModel.rank_reason(ordered[0])])
		eq(int(ordered[0]["peer"]), 1,
			"the racer wins on lap time, not on hats -- otherwise this phase is "
			+ "asserting about an order that agrees with the old explanation")
		eq(HudModel.rank_reason(racer), "lap 22.5s",
			"and the row says the LAP that won it (`%s`), not the hats that did "
				% HudModel.rank_reason(racer)
			+ "not -- reported as \"it still lists '3 hats' under 1st instead of "
			+ "the lap time\"")

		# AND THE OTHER MODES ARE UNTOUCHED, which is what makes a mode-free rule
		# safe. Every entry outside a race has a lap of 0 and falls through.
		eq(HudModel.rank_reason(hoarder), "3 hats",
			"somebody with no lap is still explained by their hats (`%s`)"
				% HudModel.rank_reason(hoarder))
		eq(HudModel.rank_reason({"lap": 0, "hats": 1, "made_it": true}), "1 hat",
			"singular when there is one, as before")
		eq(HudModel.rank_reason({"lap": 0, "hats": 0, "made_it": false}),
			"did not make it",
			"and with neither, whether they got there at all -- the comparator's "
			+ "last real key")
		# THE RACER'S HATS ARE NOT ZERO IN THIS ONE, so "it printed the lap" cannot
		# be a coincidence of an empty hat count.
		eq(HudModel.rank_reason({"lap": per * 30, "hats": 4, "made_it": true}),
			"lap 30.0s",
			"a racer WITH hats is still explained by the lap (`%s`) -- the lap "
				% HudModel.rank_reason({"lap": per * 30, "hats": 4, "made_it": true})
			+ "outranks them, so it is the lap that decided the row"))

# --- 12. AND THE CLOCK STOPS WHEN THE ROUND DOES --------------------------------
#
# Reported: "once you finish a race and exit to the lobby, the lap timer should
# stop." It did not. `lap_elapsed_of` answers for as long as the peer is in
# `_lap_next`, and the only thing that ever cleared that was the START of the
# next round -- so a party standing in a lobby was watching a clock count up for
# a lap nobody was driving.
#
# THE BEST HAS TO SURVIVE IT, and that is the half worth protecting: the board
# ranking on best lap is still on screen when this runs, so clearing both would
# blank the thing the round was just scored on at the moment it is being read.
func _the_clock_stops_when_the_round_does() -> void:
	var running := [0]
	var best := [0]
	_at(func(): world.clear_round_stats())
	_at(func(): _leave_gates(A))
	_lap(A, [0])
	_lap(A, _rest())
	_lap(A, [0])
	_at(func(): _leave_gates(A))
	_at(func(): _cross(A, 0))
	for i in 20:
		_at(func(): pass)
	_at(func():
		running[0] = world.lap_elapsed_of(A)
		best[0] = world.best_lap_of(A)
		check(running[0] > 0, "a lap is running as the round ends (%d)" % running[0])
		check(best[0] > 0, "and one was completed earlier (%d)" % best[0]))
	# THE ROUND ENDS. Through the machine's own transition rather than by calling
	# the helper: the claim is that finishing a round stops the clock, and a test
	# that calls `abandon_running_laps` directly has tested the helper.
	_at(func(): world.round_machine._enter_lobby(world))
	_at(func():
		print("[laps] entering the lobby: clock %d (was %d), best %d (was %d)"
			% [world.lap_elapsed_of(A), running[0], world.best_lap_of(A), best[0]])
		eq(world.lap_elapsed_of(A), 0,
			"the clock stops when the round does (%d still on it) -- in a lobby "
				% world.lap_elapsed_of(A)
			+ "there is no lap being driven for it to be counting")
		eq(world.best_lap_of(A), best[0],
			"and the best survives (%d, was %d) -- the board ranking on it is on "
				% [world.best_lap_of(A), best[0]]
			+ "screen at that very moment"))

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

# --- 9. You can see them at all ------------------------------------------------
#
# THE GATES WERE INVISIBLE. Recorded, sequenced, ordered, tested -- and drawn by
# nothing, so a player could not find the start line and reported being unable to
# start a race. Every claim in this file passed the whole time, because every one
# of them was about where a gate IS and none about whether anybody can see it.
# That is the second thing in this milestone to be fully wired and have no face.
#
# THE HIGHLIGHT IS THE HALF THAT NEEDS A TEST. "There are marks on the deck" is
# hard to get wrong once they exist; "the one lit is the one you are driving at"
# is a sequence question, and it has the same off-by-one at both ends -- before
# you start, and after the last checkpoint, the answer is the START LINE, which
# is a thing `_lap_next` cannot say because it counts off the end of the list.
func _you_can_see_the_gates_and_which_is_yours() -> void:
	_at(func():
		var marks: Dictionary = world.grid.lap_gate_marks()
		print("[laps] %d gate cells are drawn" % marks.size())
		check(marks.size() >= world.grid.lap_gate_count(),
			"every gate is drawn on the deck (%d marks for %d gates) -- they were "
				% [marks.size(), world.grid.lap_gate_count()]
			+ "invisible, which is why a lap could not be started")
		_it_is_the_ground_and_not_a_plate_on_it(marks)
		world.clear_round_stats())
	# Before a lap: the thing to drive at is the start line.
	_at(func(): eq(world.next_lap_gate_of(A), 0,
		"with no lap started, the gate to head for is the START line (%d)"
			% world.next_lap_gate_of(A)))
	_lap(A, [0])
	_at(func(): eq(world.next_lap_gate_of(A), 1,
		"after crossing it, the first checkpoint (%d)" % world.next_lap_gate_of(A)))
	_lap(A, _rest())
	_at(func():
		print("[laps] after every checkpoint the next gate is %d"
			% world.next_lap_gate_of(A))
		eq(world.next_lap_gate_of(A), 0,
			"and after the LAST checkpoint it is the start line again (%d) -- "
				% world.next_lap_gate_of(A)
			+ "`_lap_next` counts off the end of the list here, so both ends of "
			+ "the sequence mean 0 and neither is what the counter holds"))

# A GATE IS A COLOURED GROUND SQUARE, NOT SOMETHING LAID ON THE GROUND.
#
# Reported: "it looks like you overlayed something on the ground. I wasn't sure
# why we didn't just change the color of the ground squares, like for the lobby
# line." It was a separate plate -- a box one cell wide, 6 cm tall, inset 6 cm --
# so every gate cell had a visible lip and a grout line around it.
#
# The lobby line has always done the other thing: `segment_builder` picks a
# different PALETTE for a boundary cell and the strip simply is the deck. The
# only thing stopping a lap gate doing the same was that palette materials are
# SHARED between every cell of a colour, and the world retints one gate at a time
# -- so a shared material would have lit the whole circuit. Giving a gate cell its
# own material was the entire fix; the meshes were one per cell all along.
#
# TWO CLAIMS, AND THE SECOND IS THE ONE WITH AN ARGUMENT BEHIND IT.
#
# That it is a full deck square rather than a plate is the report, answered.
# That the CHECKER SURVIVES is why doing it this way was worth the trouble: the
# parity is not decoration, it is what makes distance readable from a fixed
# 45-degree camera, and a racetrack is the one place where judging distance at
# speed is the entire activity. `GridConfig.gate_colour` makes the same point
# about the lobby strip in as many words. The overlay flattened each cell to one
# colour and broke the pattern across every band -- which nobody decided, it fell
# out of the plate being a separate object.
func _it_is_the_ground_and_not_a_plate_on_it(marks: Dictionary) -> void:
	var any_cell: Vector2i = Vector2i.ZERO
	var found := false
	for cell in marks:
		any_cell = cell
		found = true
		break
	if not check(found, "there is a gate square to look at"):
		return

	# --- 1. A FULL DECK SQUARE ------------------------------------------------
	var square: MeshInstance3D = marks[any_cell]
	var box := square.mesh as BoxMesh
	if not check(box != null, "the gate square is a box mesh"):
		return
	print("[laps] a gate square is %.2f x %.2f m against a cell of %.2f"
		% [box.size.x, box.size.z, GridConfig.CELL_SIZE])
	near(box.size.x, GridConfig.CELL_SIZE, 0.001,
		"a gate covers its whole cell (%.3f against %.3f) -- the plate it replaced "
			% [box.size.x, GridConfig.CELL_SIZE]
		+ "was inset, which is what drew the grout line around every one of them")
	near(box.size.z, GridConfig.CELL_SIZE, 0.001, "in both directions")

	# --- 2. THE CHECKER SURVIVES ----------------------------------------------
	#
	# Two cells of the SAME gate with opposite parity. Same gate, because two
	# different gates differ in hue anyway and would satisfy this by accident --
	# the claim is that the pattern survives WITHIN a band.
	var pale: Color = Color.TRANSPARENT
	var dark: Color = Color.TRANSPARENT
	var idx: int = world.grid.lap_gate_at(any_cell)
	for cell in marks:
		if world.grid.lap_gate_at(cell) != idx:
			continue
		var mat := (marks[cell] as MeshInstance3D).material_override as StandardMaterial3D
		if mat == null:
			continue
		if (int(cell.x) + int(cell.y)) % 2 == 0:
			pale = mat.albedo_color
		else:
			dark = mat.albedo_color
	if not check(pale != Color.TRANSPARENT and dark != Color.TRANSPARENT,
			"gate %d has cells of both parities to compare" % idx):
		return
	print("[laps] within gate %d the two parities are %s and %s" % [idx, pale, dark])
	check(pale != dark,
		"the checkerboard survives inside a gate band (%s vs %s) -- the parity is "
			% [pale, dark]
		+ "what makes distance readable from a fixed camera, and a racetrack is "
		+ "where that matters most. The plate flattened each cell to one colour")

	# ...AND IT IS STILL OBVIOUSLY A GATE. A parity swing wide enough to read as a
	# second signal would be two messages fighting; small enough to vanish and the
	# claim above is satisfied by a rounding error.
	var apart: float = absf(pale.get_luminance() - dark.get_luminance())
	print("[laps] the parity swing is %.3f in luminance" % apart)
	check(apart > 0.005 and apart < 0.25,
		"and the swing reads as shading rather than as a second signal (%.3f) -- "
			% apart
		+ "the HUE says which gate this is and whether it is yours; the LIGHTNESS "
		+ "says which square, and the two must not compete")

# --- 7. The clock you are watching ---------------------------------------------
#
# `lap_elapsed_of` is what the HUD's live clock reads, and it did not exist for a
# while in the shape that mattered: the function was written and NOTHING CALLED
# IT -- one reference in the whole repo, its own definition. A timer nobody reads
# is not a timer, and the ask was explicit that it shows on screen.
func _the_clock_runs_while_you_drive() -> void:
	var at_start := [0]
	var later := [0]
	# FROM A CLEAN ROUND, because a lap KEEPS RUNNING once started -- walking off
	# the gate does not cancel it, which is right and is why the first version of
	# this claim failed at 36 ticks against correct code. There is no "not on a
	# gate" state to assert; there is only "no lap has been started".
	_at(func(): world.clear_round_stats())
	_at(func(): _leave_gates(A))
	_at(func(): eq(world.lap_elapsed_of(A), 0,
		"with no lap started the clock reads nothing (%d)"
			% world.lap_elapsed_of(A)))
	_at(func(): _cross(A, 0))
	_at(func(): at_start[0] = world.lap_elapsed_of(A))
	for i in 20:
		_at(func(): pass)
	_at(func():
		later[0] = world.lap_elapsed_of(A)
		print("[laps] the live clock read %d ticks at the line and %d twenty later"
			% [at_start[0], later[0]])
		check(at_start[0] <= 2,
			"the clock starts at zero on the line (%d ticks)" % at_start[0])
		check(later[0] >= 20,
			"and RUNS (%d ticks twenty frames later) -- a clock that is correct "
				% later[0]
			+ "and does not advance is the shape this one had while nothing read "
			+ "it at all"))

# --- 8. A round is a round -----------------------------------------------------

func _a_round_starts_with_no_laps() -> void:
	_lap(A, [0])
	_lap(A, _rest())
	_lap(A, [0])
	_at(func():
		check(world.best_lap_of(A) > 0 or world.laps_completed > 0,
			"there is lap state to clear (best %d, completed %d)"
				% [world.best_lap_of(A), world.laps_completed])
		world.clear_round_stats()
		print("[laps] after the round reset: best %d, completed %d, elapsed %d"
			% [world.best_lap_of(A), world.laps_completed,
			   world.lap_elapsed_of(A)])
		eq(world.best_lap_of(A), 0,
			"a new round starts with no best lap (%d) -- nothing cleared these "
				% world.best_lap_of(A)
			+ "before, so round three showed and RANKED ON a lap driven in round "
			+ "one")
		eq(world.laps_completed, 0, "nor any laps counted (%d)" % world.laps_completed)
		eq(world.lap_elapsed_of(A), 0,
			"and no lap in progress (%d) -- one left half-driven when a round "
				% world.lap_elapsed_of(A)
			+ "ended would carry its start tick into the next and come out "
			+ "minutes long"))

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
