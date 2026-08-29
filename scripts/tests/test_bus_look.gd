extends "res://scripts/test_support/test_case.gd"

# THE BUS IS A TUB, NOT A PLANK.
#
# It shipped as a bare slab with four wheels, and the report was that riders read
# as balanced on a platform rather than sitting in a vehicle. So it has sides
# now, plus the parts that make a box of metal read as a bus: hubcaps, a pair of
# headlights, a radiator and a stripe at floor level.
#
# ALMOST NONE OF THAT IS TESTABLE, AND THE PART THAT IS, IS THE PART THAT MATTERS.
# Nothing here has an opinion about whether it looks good. What it does have an
# opinion about is the two heights the sides sit between, because both of them
# belong to the PLAYER and neither is a number anybody chose for the bus:
#
#   * ABOVE THE FEET, or the sides are a kerb and the rider is still standing on
#     a plank.
#   * BELOW THE MUZZLE, or a passenger is shooting into their own door. And that
#     is asked of `_muzzle_of` itself with a real held weapon, not of a copy of
#     its arithmetic -- a test that hand-builds its own input has not tested the
#     caller, and 1.15 m is a HITBOX decision made for reasons about rushers that
#     could move without anybody thinking about the bus.
#
# Both are written as relationships, so the day the player changes height this
# file says so instead of the bus quietly becoming a fence.
#
# The rest are the mistakes this project actually makes:
#   3. NOTHING NEW IS SOLID. The bodywork is drawn; the one collider is still the
#      level deck. A hit test that disagrees with the art is a hazard players
#      learn by dying to, and we have shipped that once already with the spikes.
#   4. THE BODY ROLLS AND THE WHEELS DO NOT -- the "it drove on its rims" bug,
#      which has more to get wrong now that there are sides to leave behind.
#   5. THE LAMPS AND THE GRILLE ARE ON THE FRONT. A headlight on the back has an
#      identical bounding box to one on the front; four sign errors in this
#      project have had exactly that shape, so the claim is about DIRECTION.
#   6. A HUBCAP IS OUTBOARD. One at the wheel's centre is inside the tyre --
#      invisible, and perfectly present to any test that asks whether it exists.
#   7. THE BODYWORK GROWS WITH THE BUS. `_build_body` takes the length; forget to
#      call it on a rebuild and a full bus has cab-length sides and open flanks.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")

# How much of a rider has to be behind the sides before "you are in the bus" is
# true. A third of the way to the hip is shins-and-boots gone.
const FEET_COVERED := 0.3
# And how much daylight the gun keeps. A hand's width: enough that nobody ever
# wonders, not so much that the sides are decorative.
const GUN_CLEARANCE := 0.2

var world: Node3D = null
var bus: Node = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "LookWorld"
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
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)

	world._process_buses()
	if not check(world._buses.size() > 0, "there is a bus"):
		finish()
		return
	bus = world._buses[0]
	bus.riders.clear()
	bus.board(1)
	bus.board(2)
	world._plant_riders(bus)

	_the_sides_clear_the_feet_and_not_the_gun()
	_only_the_deck_is_solid()
	_the_body_leans_and_the_wheels_do_not()
	_the_lamps_and_grille_face_forward()
	_a_hubcap_is_on_the_outside_of_its_wheel()
	_the_stripe_sits_at_floor_level()
	_the_bodywork_grows_with_the_bus()
	finish()

# --- 1 and 2. The two heights -------------------------------------------------

func _the_sides_clear_the_feet_and_not_the_gun() -> void:
	var side: MeshInstance3D = bus._panels.get("SideLeft")
	if not check(side != null, "the bus has sides"):
		return
	# In the deck's own space, and then lifted into the world by where the rider
	# is actually standing -- `slot_world` is the same function that puts them
	# there, so this cannot drift from the seat.
	var deck_top: float = bus.slot_world(0).y
	var side_top: float = deck_top + BusBody.SIDE_HEIGHT

	var rider: Node = world.player_body(1)
	var feet: float = rider.position.y - PlayerBody.HALF_HEIGHT
	near(feet, deck_top, 0.05,
		"a rider's feet are on the deck, which is what the two heights below are "
		+ "measured from")
	check(side_top - feet >= FEET_COVERED,
		"the sides cover the feet by %.2f m (want %.2f) -- below this a rider is "
			% [side_top - feet, FEET_COVERED]
		+ "standing on a plank with a kerb round it, which is the report this "
		+ "change exists to answer")

	# THE REAL MUZZLE, FROM THE REAL FUNCTION, WITH A REAL GUN IN THEIR HANDS, AND
	# FOR EVERY GUN THERE IS.
	#
	# `_muzzle_of` prefers the held weapon's Barrel node and only falls back to
	# body-plus-0.25 when there is no weapon -- so asking it empty-handed tests
	# the fallback and calls it the gun. Not a quibble: the fallback is 1.15 m
	# above the deck and a held machine gun is 0.92, so reasoning from the number
	# in the code hands you 23 cm of clearance the game does not have. The first
	# sides were sized that way and left 0.17 where they looked like 0.40.
	#
	# And the LOWEST gun is the one that matters, so all of them are measured. A
	# single kind would pass while one weapon in nine fired into the door.
	var lowest: float = 1e9
	var lowest_kind: int = -1
	for kind in [SpecialBody.Kind.MACHINE_GUN, SpecialBody.Kind.SHOTGUN,
			SpecialBody.Kind.RIFLE, SpecialBody.Kind.HEAVY,
			SpecialBody.Kind.ROCKET, SpecialBody.Kind.GRENADE]:
		var weapon: Node = world._specials.spawn_loose(rider.global_position, kind)
		weapon.hold(1)
		world._plant_riders(bus)
		var at: float = world._muzzle_of(weapon, rider).y
		if at < lowest:
			lowest = at
			lowest_kind = kind
	print("[look] deck %.2f, sides to %.2f, lowest muzzle %.2f (kind %d): %.2f m clear"
		% [deck_top, side_top, lowest, lowest_kind, lowest - side_top])
	check(lowest - side_top >= GUN_CLEARANCE,
		"and stop %.2f m below the LOWEST muzzle in the game (kind %d, want %.2f)"
			% [lowest - side_top, lowest_kind, GUN_CLEARANCE]
		+ " -- a passenger shooting into their own door is worse than no sides at "
		+ "all, and muzzle height is a hitbox decision made elsewhere, for reasons "
		+ "about shooting rushers")

# --- 3. Drawn, not solid ------------------------------------------------------

func _only_the_deck_is_solid() -> void:
	var shapes: Array = []
	for child in bus.get_children():
		if child is CollisionShape3D:
			shapes.append(child)
	eq(shapes.size(), 1,
		"the bus still has exactly one collider (%d) -- the bodywork is DRAWN. A "
			% shapes.size()
		+ "rider is posed onto its seat rather than colliding with anything, so a "
		+ "solid side would only ever be a wall between a passenger and the world")
	if shapes.size() != 1:
		return
	var box: BoxShape3D = shapes[0].shape as BoxShape3D
	near(box.size.y, BusBody.DECK_THICK, 0.001,
		"and it is still the flat deck box rather than having grown to the height "
		+ "of the sides -- which is what makes 'you can still shoot' geometry "
		+ "rather than an exception somewhere")

# --- 4. What leans ------------------------------------------------------------

func _the_body_leans_and_the_wheels_do_not() -> void:
	bus.tilt = 0.0
	bus._pose()
	var side: Node3D = bus._panels.get("SideRight")
	var wheel: Node3D = bus._wheels[0]
	var cap: Node3D = bus._panels.get("Hubcap0")
	var side_was: Vector3 = side.global_position
	var wheel_was: Vector3 = wheel.global_position
	var cap_was: Vector3 = cap.global_position

	bus.tilt = deg_to_rad(BusBody.TILT_MAX_DEG)
	bus._pose()
	var side_moved: float = side_was.distance_to(side.global_position)
	var wheel_moved: float = wheel_was.distance_to(wheel.global_position)
	print("[look] a full lean moved the side %.3f m and the wheel %.3f m"
		% [side_moved, wheel_moved])
	check(side_moved > 0.02,
		"the bodywork leans with the deck (%.3f m) -- it is parented to it, and "
			% side_moved
		+ "sides that stayed put would have the bus leaning out of its own shell")
	near(wheel_moved, 0.0, 0.001,
		"and the wheels stay flat on the ground (%.3f m). This is the bug that "
			% wheel_moved
		+ "shipped once already: rolling the whole node drove the bus on its rims")
	near(cap_was.distance_to(cap.global_position), 0.0, 0.001,
		"and a hubcap stays with its wheel rather than with the body")
	bus.tilt = 0.0
	bus._pose()

# --- 5. Which end is the front ------------------------------------------------

func _the_lamps_and_grille_face_forward() -> void:
	# FRONT IS -Z. Asserted against the TAIL rather than against a number, because
	# the thing that goes wrong is a sign and a sign is only visible as an
	# ordering. A lamp at the back has the same bounding box as one at the front.
	var tail: Node3D = bus._panels.get("Tail")
	var nose: Node3D = bus._panels.get("Nose")
	if not check(tail != null and nose != null, "the bus has a nose and a tail"):
		return
	check(nose.position.z < tail.position.z,
		"the nose is forward of the tail (%.2f < %.2f)"
			% [nose.position.z, tail.position.z])
	for i in 2:
		var lamp: Node3D = bus._panels.get("Headlight%d" % i)
		if not check(lamp != null, "headlight %d exists" % i):
			continue
		check(lamp.position.z < nose.position.z,
			"headlight %d is on the outside of the nose (%.2f < %.2f), not "
				% [i, lamp.position.z, nose.position.z]
			+ "buried in it or stuck on the back")
	var left: Node3D = bus._panels.get("Headlight0")
	var right: Node3D = bus._panels.get("Headlight1")
	if left != null and right != null:
		check(left.position.x < 0.0 and right.position.x > 0.0,
			"and there is one on each side (%.2f, %.2f) rather than two in the "
				% [left.position.x, right.position.x]
			+ "same place, which is a pair of lamps nobody can tell from one")
	var grille: Node3D = bus._panels.get("Radiator")
	if check(grille != null, "there is a radiator"):
		check(grille.position.z < nose.position.z,
			"on the front (%.2f < %.2f)" % [grille.position.z, nose.position.z])
		check(grille.position.y < (left.position.y if left != null else 99.0),
			"and below the lamps, which is where a radiator goes")

# --- 6. Hubcaps ---------------------------------------------------------------

func _a_hubcap_is_on_the_outside_of_its_wheel() -> void:
	bus._pose()
	for i in 4:
		var cap: Node3D = bus._panels.get("Hubcap%d" % i)
		if not check(cap != null, "hubcap %d exists" % i):
			continue
		var wheel: Node3D = bus._wheels[i]
		# OUTBOARD IN WORLD X, with the bus pointing along its default heading.
		# A hubcap at the wheel's own centre is inside the tyre: present, correct
		# by every property you can print, and invisible.
		# IN THE BUS'S OWN FRAME. The first version compared distances from the
		# WORLD origin, which is dominated by wherever the bus happens to be
		# parked -- so it reported the same answer for all four wheels and had
		# nothing to do with the hubcaps at all.
		var cap_x: float = bus.to_local(cap.global_position).x
		var wheel_x: float = bus.to_local(wheel.global_position).x
		var out: float = absf(cap_x) - absf(wheel_x)
		check(out > 0.0,
			"hubcap %d sits proud of its wheel's centre by %.3f m -- one at the "
				% [i, out]
			+ "centre is inside the tyre, which every existence check passes")
		check(signf(cap_x) == signf(wheel_x),
			"and on the same side of the bus as the wheel it belongs to")

# --- 7. The stripe ------------------------------------------------------------

func _the_stripe_sits_at_floor_level() -> void:
	var stripe: MeshInstance3D = bus._panels.get("StripeLeft")
	var side: MeshInstance3D = bus._panels.get("SideLeft")
	if not check(stripe != null and side != null, "there is a stripe"):
		return
	# AT THE FLOOR LINE: the deck's top face runs through it. That is what makes
	# it read as where the floor is rather than as a band somewhere up the side.
	var deck_top: float = BusBody.DECK_THICK * 0.5
	var low: float = stripe.position.y - (stripe.mesh as BoxMesh).size.y * 0.5
	var high: float = stripe.position.y + (stripe.mesh as BoxMesh).size.y * 0.5
	check(low <= deck_top and high >= deck_top,
		"the stripe straddles the floor line (%.2f..%.2f around %.2f)"
			% [low, high, deck_top])
	check(high < side.position.y + (side.mesh as BoxMesh).size.y * 0.5,
		"and stays below the top of the sides rather than being a rim")
	check(absf(stripe.position.x) > absf(side.position.x),
		"and stands proud of the side it is on (%.3f vs %.3f), or it is a band "
			% [absf(stripe.position.x), absf(side.position.x)]
		+ "painted inside the bodywork where nobody outside can see it")

# --- 8. It grows --------------------------------------------------------------

func _the_bodywork_grows_with_the_bus() -> void:
	bus.riders.clear()
	bus.board(1)
	bus._rebuild()
	var short_side: float = (bus._panels["SideLeft"].mesh as BoxMesh).size.z
	var short_nose: float = bus._panels["Nose"].position.z

	for peer in [2, 3, 4]:
		bus.board(peer)
	bus._rebuild()
	var long_side: float = (bus._panels["SideLeft"].mesh as BoxMesh).size.z
	var long_nose: float = bus._panels["Nose"].position.z
	print("[look] sides %.2f m at one rider, %.2f m at four" % [short_side, long_side])

	near(long_side, bus.length(), 0.001,
		"the sides are as long as the bus is (%.2f vs %.2f)"
			% [long_side, bus.length()])
	check(long_side > short_side + 1.0,
		"and they grew with it (%.2f -> %.2f) -- `_build_body` takes the length, "
			% [short_side, long_side]
		+ "so forgetting to call it on a rebuild leaves a full bus with "
		+ "cab-length sides and two metres of open flank")
	check(long_nose < short_nose,
		"and the nose moved forward with them (%.2f -> %.2f) rather than the bus "
			% [short_nose, long_nose]
		+ "growing out of the back of its own front panel")
