extends "res://scripts/test_support/test_case.gd"

# A CLIENT RUNS THE HOST'S CLOCK, NOT ITS OWN.
#
# `tick` started at zero on every machine and was never synced. The host has sent
# it on every snapshot since snapshots existed -- the parameter is literally named
# `server_tick` -- and the client threw it away. So a client joining a session
# already thousands of ticks old ran its own clock from zero, forever.
#
# THAT IS INVISIBLE FOR ALMOST EVERYTHING, WHICH IS WHY IT SURVIVED. Bodies,
# bullets, hats and specials are all TOLD where they are, so a wrong clock costs
# them nothing at all.
#
# It is fatal for the two systems that are PURE FUNCTIONS OF THE TICK, and both
# are that way on purpose:
#
#   an elevator, because "there is nothing to agree about beyond the tick itself"
#   -- so the two machines placed the platform at different heights and stayed
#   there. Reported from a playtest as "stuck elevator, one player saw elevator
#   offset";
#
#   and spikes, whose lift is float(tick) * TICK_DELTA -- so a client saw them
#   DOWN while the host had them out and was hurting people. That is the
#   hit-test-disagrees-with-the-art bug in CLAUDE.md with the two ends on two
#   different computers.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const CELL := Vector2i(2, 3)
# NOT A ROUND NUMBER, and the control assertion below is what caught that. The
# cycle is (ELEVATOR_RISE_TICKS + ELEVATOR_DWELL_TICKS) * 2 = 500, so the obvious
# 5000 is an exact multiple and lands on the SAME PHASE as tick zero -- the two
# clocks disagreed by five thousand ticks and the platform was in the same place,
# which would have made every assertion below pass while measuring nothing.
const HOST_TICK := 5123

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "ClockWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_elevator.seg"]
	world.start(true, 1, false)

func _physics_process(_delta: float) -> void:
	if done or world.tick < 3:
		return
	done = true

	# THE DISAGREEMENT, MEASURED. Same grid, same cell, two clocks -- which is
	# exactly the situation a joining client was in.
	var here: float = world.grid.elevator_surface_y(CELL, 0)
	var there: float = world.grid.elevator_surface_y(CELL, HOST_TICK)
	var lh: Vector2 = world.grid.elevator_low_high(CELL)
	print("[clock] elevator runs %.2f..%.2f; at tick 0 it is %.2f, at tick %d it is %.2f"
		% [lh.x, lh.y, here, HOST_TICK, there])
	check(absf(here - there) > 0.5,
		"an elevator really is a pure function of the tick, so two machines "
		+ "counting differently put it in different places (%.2f against %.2f) -- "
			% [here, there]
		+ "without this the test below is asserting about a platform that does not "
		+ "move")

	# AND THE CLIENT TAKES THE HOST'S NUMBER. Driven through the same entry point
	# the snapshot uses rather than by assigning `tick`, so what is under test is
	# the adoption and not the assignment.
	var client: Node3D = Node3D.new()
	client.name = "ClockClient"
	client.set_script(GameWorldScript)
	get_parent().add_child(client)
	client.position = Vector3(1000.0, 0.0, 0.0)
	client.segment_paths = ["res://segments/test_elevator.seg"]
	client.start(false, 2, false)
	client.tick = 0

	client._adopt_server_tick(HOST_TICK)
	eq(client.tick, HOST_TICK,
		"a client adopts the host's clock, so anything keyed on the tick agrees")
	near(client.grid.elevator_surface_y(CELL, client.tick), there, 0.001,
		"and now puts the elevator where the host has it")

	# ONCE. The tick numbers the client's own inputs and indexes its prediction
	# history, so taking it repeatedly would throw that away on every snapshot --
	# sixty times a second, which is a worse bug than the one being fixed.
	client._adopt_server_tick(HOST_TICK + 999)
	eq(client.tick, HOST_TICK,
		"and only ONCE -- re-taking it on every snapshot would discard the "
		+ "prediction history sixty times a second")
	finish()
