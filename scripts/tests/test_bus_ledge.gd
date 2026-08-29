extends "res://scripts/test_support/test_case.gd"

# A PASSENGER IS NOT FALLING, HOWEVER MUCH THEY LOOK LIKE IT.
#
# Reported from play: "when you drive off the edge of the map in the bus, you
# still land on something solid below the map. Your bus disappears and it marks
# you hanging for this period."
#
# NOTHING IS SOLID DOWN THERE, and that is the whole of the diagnosis. The rider
# caught a LEDGE on the way past it, and LEDGE_HANG holds a body still -- so the
# fall stopped in mid-air under the map and the HUD said HANGING, which is a
# perfectly accurate description of a state nobody should have been in.
#
# EVERY GATE ON THE GRAB PASSES FOR A RIDER, and passes BECAUSE of the seat.
# `_plant_riders` writes `velocity = Vector3.ZERO` every tick, so a passenger on
# a bus toppling into the infield reads as the most catchable body in the game --
# drifting downward at nothing -- and as the bus sinks past the rim it spends
# several ticks within LEDGE_CATCH_REACH of solid deck. The plant then re-seats
# the hanging body and carries it down, because that pass skips only a peer the
# drone has and a hard tumble.
#
# THE TWO HALVES ARE BOTH ASSERTED, because a rule that only ever says NO is
# satisfied by deleting the feature. A rider must not catch; somebody who really
# fell off the same lip must.
#
# THE FIXTURE IS A REAL RACE CIRCUIT, driven at a crawl. Not for realism: the
# grab needs a bus descending SLOWLY past a rim it is right beside, and full
# throttle carries it clear of the lip in a tick or two -- which is why this
# never showed up in the bus tests that drive at speed.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const BusRig = preload("res://scripts/test_support/bus_rig.gd")

const A := 41

var world: Node3D = null
var body: CharacterBody3D = null
var bus: Node = null
var done := false
var phase := 0
var _hole: Vector2i = Vector2i.ZERO
var _hung_aboard := false
var _lowest := 999.0
var _pinned_ticks := 0
var _last_y := 999.0
var _dropped_at := 0

func setup(main) -> void:
	timeout_seconds = 90.0
	test_mode = GameMode.RACE
	world = Node3D.new()
	world.name = "BusLedgeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = 2024
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		var inp: Array = PlayerInput.empty(t)
		# A CRAWL. See the header: at speed the bus clears the rim before the
		# catch window opens, and the bug hides.
		inp[PlayerInput.MOVE] = Vector2(0.0, -0.06)
		return inp
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.RACE, GameMode.RACE]
	world.grid.build_run(world.grid.run_seed,
		(SegmentPool.SECTIONS_PER_ROUND + 1) * 2 + 1,
		[GameMode.RACE, GameMode.RACE])
	body = world.players[A]

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	# PINNED. A test driving one bus does not want the round machine scoring the
	# round out from under it -- SCORING freezes the entire tick.
	world.round_machine.state = RoundMachine.State.RUNNING
	match phase:
		0: _phase_launch()
		1: _phase_ride_it_down()
		2: _phase_a_real_fall_still_catches()

# --- Setting off ---------------------------------------------------------------

func _phase_launch() -> void:
	bus = BusRig.spawn(world)
	if not check(bus != null, "there is a bus to drive"):
		done = true
		finish()
		return
	body.global_position = bus.global_position + Vector3(0.0, 1.2, 0.0)
	bus.board(A)
	# AIMED AT THE NEAREST HOLE. On a circuit that is the INFIELD, which is what
	# "the edge of the map" means here -- the sides are railed by a parapet, so
	# the void in the middle is the edge a driver actually meets.
	var here: Vector2i = world.grid.cell_of_world(bus.global_position)
	var best := Vector2i(0, 0)
	var best_d := 9999
	for dx in range(-9, 10):
		for dz in range(-9, 10):
			var c: Vector2i = here + Vector2i(dx, dz)
			if world.grid.is_solid(c):
				continue
			var d: int = absi(dx) + absi(dz)
			if d < best_d:
				best_d = d
				best = c
	if not check(best_d < 9999, "there is a hole to drive into"):
		done = true
		finish()
		return
	_hole = best
	var away: Vector3 = world.grid.cell_surface_world(best) - bus.global_position
	bus.heading = atan2(away.x, -away.z)
	print("[busledge] driving from %s at the hole %s, %d cells away"
		% [here, best, best_d])
	phase = 1

# --- 1. A rider does not catch ---------------------------------------------------

func _phase_ride_it_down() -> void:
	if int(body.state) == PlayerBody.State.LEDGE_HANG and is_instance_valid(bus):
		_hung_aboard = true
	_lowest = min(_lowest, body.global_position.y)
	# PINNED IN MID-AIR is the reported symptom in its own right, and it is a
	# different claim from the state: a body that stops descending while it is
	# below the deck and above the kill plane has landed on something, and there
	# is nothing there to land on.
	if body.global_position.y < 0.0 and body.global_position.y > SimConfig.FALL_KILL_Y:
		if absf(body.global_position.y - _last_y) < 0.001:
			_pinned_ticks += 1
		else:
			_pinned_ticks = 0
	_last_y = body.global_position.y

	if is_instance_valid(bus):
		return
	# The bus has gone. Give the released body a moment to finish falling.
	if _dropped_at == 0:
		_dropped_at = world.tick
		return
	if world.tick < _dropped_at + 30:
		return

	print("[busledge] lowest y %.2f, hung while aboard %s, %d ticks pinned mid-air"
		% [_lowest, _hung_aboard, _pinned_ticks])
	check(not _hung_aboard,
		"a rider does not catch a ledge on the way down -- the seat zeroes their "
		+ "velocity every tick, so every gate on the grab passes because of the "
		+ "bus rather than in spite of it, and the hang then holds the body still "
		+ "in mid-air under the map with the HUD reading HANGING")
	eq(_pinned_ticks, 0,
		"and nothing stops the fall between the deck and the kill plane (%d ticks "
			% _pinned_ticks
		+ "held at one height) -- there is no floor down there, so a body that "
		+ "stops has been stopped by a state rather than by the world")
	check(_lowest <= SimConfig.FALL_KILL_Y,
		"the fall completes to the kill plane (%.2f, needs <= %.1f), which is the "
			% [_lowest, SimConfig.FALL_KILL_Y]
		+ "outcome a player already understands")
	phase = 2
	_dropped_at = world.tick

# --- 2. AND SOMEBODY WHO REALLY FELL STILL CATCHES -------------------------------
#
# The half that says something is POSSIBLE, which is the half carrying the
# design: without it, deleting the ledge grab outright passes phase 1.

func _phase_a_real_fall_still_catches() -> void:
	if world.tick == _dropped_at + 4:
		# OFF THE BUS ENTIRELY, and placed the way the rider was: just under the
		# rim of the same hole, barely moving. The only difference from phase 1
		# is the seat.
		world._returning.clear()
		var rim: Vector2i = _hole
		for dir in 4:
			var n: Vector2i = _hole + GridConfig.DIR_CELLS[dir]
			if world.grid.is_solid(n):
				rim = n
				break
		if not check(rim != _hole, "the hole has a solid rim to catch"):
			done = true
			finish()
			return
		var lip: Vector3 = world.grid.cell_surface_world(rim)
		var outward: Vector3 = (world.grid.cell_surface_world(_hole) - lip).normalized()
		body.state = PlayerBody.State.WALK
		body.ledge_cooldown = 0.0
		body.health = SimConfig.REVIVE_HEALTH
		body.global_position = lip + outward * (GridConfig.CELL_SIZE * 0.6) \
			- Vector3(0.0, 0.6, 0.0)
		body.velocity = Vector3(0.0, -1.0, 0.0)
		body.grounded = false
		return
	if world.tick < _dropped_at + 24:
		return
	print("[busledge] a body that really fell off the same rim is %s"
		% ["HANGING" if int(body.state) == PlayerBody.State.LEDGE_HANG else str(body.state)])
	check(int(body.state) == PlayerBody.State.LEDGE_HANG,
		"somebody who really went over that rim still catches it -- the rule is "
		+ "about the SEAT, not about the ledge, and a guard that switched the "
		+ "grab off everywhere would satisfy phase 1 just as well")
	done = true
	finish()
