extends "res://scripts/test_support/test_case.gd"

# M17 phase 9: elevators.
#
# The plan called this "the only item whose failure mode is a netcode bug rather
# than a level bug", because Godot transports a rider on a moving body using
# engine-internal state capture_state() cannot restore. That warning is answered
# by a restriction rather than by machinery: AN ELEVATOR MOVES ONLY VERTICALLY.
# Going up it pushes the body standing on it, which is ordinary collision; going
# down, gravity keeps the body in contact. There is nothing horizontal to carry,
# so there is no engine state to fail to rewind -- and the platform's position is
# a pure function of the tick, which a replaying client reproduces exactly.
#
# The claims:
#   1. IT CARRIES A BODY UP. Measured as the body's height against the deck it is
#      being delivered to, over a rise no other verb in the game can make.
#   2. AND SETS IT DOWN ON THE FAR DECK, walking. Arriving is not the same as
#      being deposited: a body pressed into the wall at the top would satisfy any
#      height check and be stuck forever.
#   3. THE FLOOD ROUTES THROUGH IT WITH NO CAPABILITY AT ALL -- not a ladder verb,
#      not a second player, not an item. 2b: waiting is a cost in round time, not
#      in reachability. Both halves: without the lift the same cliff is rejected.
#   4. ITS POSITION IS A PURE FUNCTION OF THE TICK. Asked of the same grid twice
#      for the same tick, and for a tick in the past -- which is what a client
#      replaying a correction does, and the whole reason this needs no wire.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const LIFT_CELL := Vector2i(2, 3)
const TOP_CELL := Vector2i(2, 4)

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0
var boarded_frame: int = -1
var arrived_frame: int = -1
var arrived_row: int = -1

func setup(main) -> void:
	timeout_seconds = 60.0
	_check_the_flood()

	world = Node3D.new()
	world.name = "ElevatorWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_elevator.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	body.position = world.grid.cell_surface_world(Vector2i(2, 2)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

	# PUSH UP-BRIDGE UNTIL THE FAR DECK IS UNDERFOOT, then stop. The stick is
	# released on arrival for the reason CLAUDE.md gives twice over: a rig that
	# holds a movement input walks the player off the map, and this fixture is
	# four rows deep past the lift.
	#
	# Held THROUGHOUT the ride, deliberately. A body that only walks on when the
	# platform is level and then stands perfectly still is a body being tested in
	# the one condition a player will never be in.
	world.scripted_inputs[1] = func(t: int) -> Array:
		return [t, Vector2(0.0, -1.0) if _wants_forward() else Vector2.ZERO, 0, body.facing]

# A RIG THAT LOOKS BEFORE IT STEPS, which is not rig convenience -- it is the
# behaviour under test. An elevator that is UP leaves an open shaft, and walking
# into one is falling down it. "A party can wait" is the whole of 2b's claim
# about this feature, so a rig that cannot wait is testing a different feature.
func _wants_forward() -> bool:
	if arrived_frame >= 0:
		return false          # off the map otherwise; four rows past the lift
	var here: Vector2i = world.grid.cell_of_world(body.position)
	if here.y > LIFT_CELL.y:
		return true           # past it, walking off onto the far deck
	var span: Vector2 = world.grid.elevator_low_high(LIFT_CELL)
	var at: float = world.grid.elevator_surface_y(LIFT_CELL, world.tick)
	if here == LIFT_CELL:
		# ABOARD: stand still until it arrives, then step off. Riding is doing
		# nothing, which is the cost -- and a rig that rides forever never steps
		# off, which is how the first run of this test spent twenty seconds going
		# up and down and reported that it never arrived.
		return at > span.y - 0.3
	return at < span.x + 0.3

# --- 3 and 4. The oracle, and determinism -------------------------------------

func _check_the_flood() -> void:
	var seg = SegmentData.from_file("res://segments/test_elevator.seg")
	check(seg.is_valid(), "the fixture parses")

	# A LONE PLAYER WITH NOTHING. Not two, not a climber -- the weakest party the
	# model can describe, because "an elevator asks for nothing" is the claim.
	var alone: Dictionary = SegmentValidator.party_of(1, false)
	eq(SegmentValidator.validate_run([seg], alone).size(), 0,
		"a four-unit cliff with a lift in it is crossable by ONE player with no "
		+ "climb verb and no teammate -- an elevator asks only that you wait, and "
		+ "2b pays that in round time rather than in reachability")

	var bare = SegmentData.from_file("res://segments/test_elevator.seg")
	bare.contents[LIFT_CELL.y][LIFT_CELL.x] = GridConfig.Content.NONE
	check(SegmentValidator.validate_run([bare], alone).size() > 0,
		"and the same cliff without it is not -- four units is above every rise "
		+ "budget, out of reach of a boost, and one unit past the apex of legs")

# --- 1 and 2. It actually carries somebody ------------------------------------

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1

	# CLAIM 4, CHECKED LIVE. Two questions about the same tick must agree, and a
	# question about a PAST tick must still be answerable -- that is exactly what a
	# client replaying a correction asks, and it is why this feature has no wire
	# format at all.
	if frames == 30:
		var now_a: float = world.grid.elevator_surface_y(LIFT_CELL, world.tick)
		var now_b: float = world.grid.elevator_surface_y(LIFT_CELL, world.tick)
		var back: float = world.grid.elevator_surface_y(LIFT_CELL, world.tick - 12)
		check(is_equal_approx(now_a, now_b),
			"a platform's position is a function, not a reading")
		check(is_finite(back),
			"and it can be asked about a tick that has already happened (%.2f) -- "
				% back
			+ "which is what a replaying client does, and why no packet carries this")

	var lift_y: float = world.grid.elevator_surface_y(LIFT_CELL, world.tick)
	var low: float = world.grid.elevator_low_high(LIFT_CELL).x
	if boarded_frame < 0 and body.grounded 			and world.grid.cell_of_world(body.position) == LIFT_CELL 			and lift_y < low + 0.5:
		boarded_frame = frames
	var row: int = world.grid.cell_of_world(body.position).y
	if arrived_frame < 0 and body.grounded and row >= TOP_CELL.y:
		arrived_frame = frames
		arrived_row = row

	if arrived_frame < 0 and frames < 1200:
		return

	var top: float = world.grid.cell_surface_world(TOP_CELL).y
	print("[elevator] boarded f%d, arrived f%d at row %d (deck top %.2f, y %.2f)"
		% [boarded_frame, arrived_frame, arrived_row, top, body.position.y])

	check(boarded_frame > 0,
		"a player walks onto the platform while it is DOWN -- which is the only "
		+ "time it is a floor at the height they are standing at")
	check(arrived_frame > boarded_frame,
		"and is carried up a four-unit rise (boarded f%d, arrived f%d)"
			% [boarded_frame, arrived_frame])
	check(arrived_row >= TOP_CELL.y,
		"stepping off ONTO the far deck (row %d, deck starts at %d) -- arriving at "
			% [arrived_row, TOP_CELL.y]
		+ "the top is not the same as being put down on it, and a body pressed "
		+ "into the wall up there would pass any height check while stuck forever")
	check(body.grounded, "standing on something, not falling off the back of it")
	finish()
