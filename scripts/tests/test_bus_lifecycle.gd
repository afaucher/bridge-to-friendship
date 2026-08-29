extends "res://scripts/test_support/test_case.gd"

# WHAT HAPPENS TO A BUS WHEN THINGS GO WRONG. Both claims here are playtest
# reports (2026-08-29), and both are about the bus outliving a moment it should
# not have.
#
#   1. "If you fall off the world in the bus, the player gets stuck midair."
#      A rider is posed onto their seat EVERY tick, and nothing in that pass
#      asked whether the drone already had them. So a rider who crossed
#      FALL_KILL_Y was put on the drone AND yanked back onto the falling bus on
#      the same tick, every tick -- the rescue and the seat pulling in opposite
#      directions, which is what "stuck" looks like from outside. The step loop
#      has said `a body the drone has is not in the world, so it is not
#      simulated` since M5; the planting pass never got the memo.
#
#   2. "If you die, you lose, respawn in the lobby, and the bus doesn't spawn
#      again." `_restart_at_checkpoint` frees the balls, the rushers, the
#      zombies and the gunners -- and left the bus wherever it was, which after a
#      rewind is somewhere the party is not. `_ensure_bus` then sees a perfectly
#      valid bus and declines to build another, so the mode's only content is
#      stranded up the bridge and the party is in an empty room.
#
# Both are the same shape: a rule about the bus that was never asked at a moment
# somebody else owns.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var bus: Node = null
var phase := 0
var fell_at := 0
var wiped_at := 0


func setup(main) -> void:
	timeout_seconds = 90.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "LifecycleWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.BLANK]

func _physics_process(_delta: float) -> void:
	if world.tick < 4:
		return

	# --- 1. Off the bottom of the world, with somebody aboard -----------------
	if phase == 0:
		world._process_buses()
		if not check(world._buses.size() > 0, "there is a bus"):
			finish()
			return
		bus = world._buses[0]
		bus.riders.clear()
		# EVERYBODY ABOARD, which is the case that was reported: a bus going over
		# the edge takes the whole party with it, so the fall is also a WIPE, and
		# the wipe path clears `_returning` from under the drone.
		bus.board(1)
		bus.board(2)
		world._plant_riders(bus)
		# DROPPED, NOT TELEPORTED PAST THE LINE. The bug lives in the ticks
		# BETWEEN a rider crossing FALL_KILL_Y and the bus crossing it -- the
		# rider is lower than the bus by nothing much, but the two do not cross
		# on the same tick, and that window is where the drone and the seat fight.
		# Putting the bus straight below the line would skip the whole thing.
		bus.position = Vector3(bus.position.x, SimConfig.FALL_KILL_Y + 6.0,
			bus.position.z)
		fell_at = world.tick
		phase = 1
		return

	# PAST DRONE_RETURN_SECONDS (3.0 s = 180 ticks), not a round number of my
	# own choosing. The first version waited 90 and reported the player "stuck"
	# at exactly FALL_KILL_Y -- which is correct behaviour seen too early: a body
	# the drone has is not simulated, so it holds position until the drone puts
	# it down. A test that samples inside somebody else's timer measures the
	# timer.
	if phase == 1 and world.tick > fell_at + 240:
		_the_rider_comes_back()
		phase = 2
		return

	# --- 2. A wipe leaves the party somewhere the bus is not ------------------
	if phase == 2:
		world._process_buses()
		if not check(world._buses.size() > 0, "a bus exists again to be stranded"):
			finish()
			return
		bus = world._buses[0]
		# STRANDED UP THE BRIDGE, which is what a rewind does: the party goes
		# back and the bus does not.
		bus.position += Vector3(0.0, 0.0, -60.0)
		world._restart_at_checkpoint()
		wiped_at = world.tick
		phase = 3
		return

	if phase == 3 and world.tick > wiped_at + 2:
		_a_wipe_takes_the_bus_with_it()
		finish()

func _the_rider_comes_back() -> void:
	var rider: Node = world.player_body(1)
	var aboard: bool = world.bus_carrying(1) != null
	print("[buslife] after the fall: aboard %s, returning %s, y %.1f, buses %d"
		% [aboard, world._returning.has(1), rider.position.y, world._buses.size()])

	check(not aboard,
		"a rider the drone has is off the roster -- the seat and the rescue were "
		+ "pulling in opposite directions every tick, which is what `stuck "
		+ "midair` looks like from outside")
	check(rider.position.y > SimConfig.FALL_KILL_Y,
		"and they are back above the kill line (y %.1f), not hanging below it"
			% rider.position.y)
	# THE REAL CLAIM, and the one a position alone does not make: they are
	# somewhere a player can play from. A body parked at a plausible height with
	# the drone still holding it is exactly the reported symptom.
	check(not world._returning.has(1),
		"and the drone has finished with them rather than still carrying "
		+ "somebody it can never put down")

func _bus_near_party() -> bool:
	var front: float = world._front_position().z
	for b in world._buses:
		if is_instance_valid(b) and absf(b.position.z - front) < 30.0:
			return true
	return false

func _a_wipe_takes_the_bus_with_it() -> void:
	# TWO CLAIMS, AND NEITHER OF THEM WAITS FOR THE ROUND MACHINE.
	#
	# The obvious test -- wipe, then wait for a bus to reappear near the party --
	# cannot be written here, and finding out why is worth the note. A wipe puts
	# the score board up, `_board_is_up()` FREEZES the whole tick, and this
	# harness drives a world directly rather than the menu flow that takes the
	# board back down. So the wait was 900 ticks of a paused world reporting "the
	# bus never came back" about a game that was merely stopped. A test cannot
	# observe a recovery through a transition it is not driving.
	#
	# What it CAN say is the two halves of the fix, and between them they are the
	# bug: nothing stranded survives the wipe, and the pass builds a replacement
	# the moment it is asked.
	eq(world._buses.size(), 0,
		"a wipe takes the bus with it (%d left) -- it does not follow the party "
			% world._buses.size()
		+ "back, so left alone it sits up the bridge being valid, and a valid bus "
		+ "is exactly what stops `_ensure_bus` building a reachable one")
	world._process_buses()
	check(_bus_near_party(),
		"and the next time the pass runs, there is one where the party actually "
		+ "is -- which is the half that turns `the stale one is gone` into `you "
		+ "have a bus`")
