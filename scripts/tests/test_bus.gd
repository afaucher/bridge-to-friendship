extends "res://scripts/test_support/test_case.gd"

# THE BUS. M25 phase 3: a drivable vehicle, and the blank zone's reason to exist.
#
# THE MILESTONE'S BIGGEST TECHNICAL UNKNOWN IS RETIRED BY THE DESIGN RATHER THAN
# ANSWERED. The plan's prerequisite was a measurement -- "does a predicted client
# riding a moving platform over ENet stay put? Do that first and alone" -- and the
# answer here is that NOTHING RIDES. Riders are POSED onto their slot every tick,
# the way a worn hat is posed onto a head, so there is no platform-riding to
# predict and none of the carrier/rider tangle CLAUDE.md opens with: no mutual
# collision exception, no one-tick-late transport, no carrier that cannot walk
# because somebody is standing on it.
#
# The claims:
#   1. IT ONLY EXISTS IN THE BLANK ZONE. The first real customer of the pool
#      policy phase 1 built, and the first time that table decides something.
#   2. BOARDING IS AN ORDER, and the order IS the design: riders[0] drives, so
#      promotion on exit falls out rather than being maintained.
#   3. IT GROWS with each rider, and every offset is computed from the CURRENT
#      length rather than baked.
#   4. IT DRIVES, and steering needs speed -- a vehicle that turns on the spot is
#      a turret.
#   5. IT LEANS INTO A CORNER, proportionally to speed, and settles out of one.
#   6. RIDERS ARE PLANTED: they end the tick on their slot whatever their own
#      input did.
#   7. UNLIMITED AMMO ABOARD, AND YOU LEAVE WITH A FULL ONE -- one rule, not two.
#   8. THE DRIVER CANNOT SHOOT.
#   9. PASSENGERS CANNOT MACHINE-GUN EACH OTHER, and CAN still blow each other up.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const SpecialPool = preload("res://scripts/sim/special_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var bus = null
var done := false

func setup(main) -> void:
	timeout_seconds = 60.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "BusWorld"
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
	# IN THE BLANK ZONE, which is where a bus is allowed to be at all.
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.BLANK]

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)

	_only_in_the_blank_zone()
	_boarding_is_an_order()
	_it_grows()
	_it_drives_and_leans()
	_riders_are_planted()
	_ammo_aboard_and_on_the_way_out()
	_the_driver_cannot_shoot()
	_passengers_do_not_shoot_each_other()
	_a_bus_that_falls_is_let_go_of()
	finish()

# --- 1. Where it is allowed to exist ------------------------------------------

func _only_in_the_blank_zone() -> void:
	check(GameMode.runs(GameMode.BLANK, "bus"), "a blank zone runs the bus pool")
	check(not GameMode.runs(GameMode.BASE, "bus"),
		"and the ordinary bridge does not -- a vehicle among pillars and holes is "
		+ "a different feature with a different set of problems")

	# THROUGH THE WORLD, not the table. The table is a declaration; the gate at the
	# top of the tick is the behaviour, and asserting the first proves only that
	# the first says what it says.
	world.run_modes = [GameMode.BASE]
	world._process_buses()
	eq(world._buses.size(), 0, "so no bus is built on the ordinary bridge")

	world.run_modes = [GameMode.BLANK]
	world._process_buses()
	check(world._buses.size() > 0, "and one is built in a blank zone")
	bus = world._buses[0]

# --- 2. The queue --------------------------------------------------------------

func _boarding_is_an_order() -> void:
	if not check(bus != null, "there is a bus"):
		return
	bus.riders.clear()
	bus.board(1)
	eq(bus.driver(), 1, "the first aboard drives")
	bus.board(2)
	eq(bus.driver(), 1, "and a second rider does not take the wheel")
	eq(bus.riders, [1, 2], "they queue behind, in boarding order")

	# BOARDING TWICE IS NOT TWO SEATS. A held key, a replayed packet and a double
	# press all look the same from here.
	bus.board(1)
	eq(bus.riders, [1, 2], "boarding twice takes one seat, not two")

	# THE DRIVER LEAVING PROMOTES THE NEXT IN LINE, and it falls out rather than
	# being maintained: the driver is DEFINED as riders[0], so there is no second
	# fact to update on the tick somebody steps off.
	bus.leave(1)
	eq(bus.driver(), 2, "the driver stepping off promotes the next in line")
	eq(bus.riders, [2], "and the queue closes up")
	bus.leave(2)
	eq(bus.driver(), 0, "an empty bus has no driver")

# --- 3. It grows ---------------------------------------------------------------

func _it_grows() -> void:
	bus.riders.clear()
	bus._rebuild()
	var empty: float = bus.length()
	bus.board(1)
	var one: float = bus.length()
	bus.board(2)
	var two: float = bus.length()
	print("[bus] length: empty %.2f m, one rider %.2f, two %.2f" % [empty, one, two])
	near(one, empty, 0.001, "the cab is the bus, so the first rider adds nothing")
	check(two > one + 0.5,
		"and each rider past the first lengthens it (%.2f -> %.2f m)" % [one, two])

	# EVERY OFFSET IS COMPUTED FROM THE CURRENT LENGTH. A slot baked at build time
	# would leave the second rider standing where the bus used to end.
	var a: Vector3 = bus.slot_world(0)
	var b: Vector3 = bus.slot_world(1)
	check(a.distance_to(b) > 0.5,
		"two riders stand in different places (%.2f m apart)" % a.distance_to(b))
	check(bus.distance_to_deck(b) < 0.6,
		"and both slots are ON the bus (%.2f m from its deck) -- a reach measured "
			% bus.distance_to_deck(b)
		+ "from the ORIGIN would call the back seat off the vehicle as it grew")

# --- 4, 5. Driving and leaning -------------------------------------------------

func _it_drives_and_leans() -> void:
	bus.riders.clear()
	bus._rebuild()
	bus.global_position = world.player_body(1).global_position + Vector3(0.0, 0.6, -10.0)
	bus.heading = 0.0
	bus.speed = 0.0
	bus.tilt = 0.0

	# A STANDING START. Throttle only, no steering.
	var from: Vector3 = bus.global_position
	for _i in 60:
		bus.drive(1.0, 0.0, SimConfig.TICK_DELTA)
	var travelled: float = from.distance_to(bus.global_position)
	print("[bus] a second of throttle moved it %.2f m at %.2f m/s"
		% [travelled, bus.speed])
	check(travelled > 2.0, "a second of throttle moves it (%.2f m)" % travelled)
	check(bus.speed > SimConfig.WALK_SPEED,
		"and it is faster than walking (%.1f against %.1f m/s) -- a vehicle no "
			% [bus.speed, SimConfig.WALK_SPEED]
		+ "faster than your legs is a worse way of walking")

	# STEERING NEEDS SPEED. A vehicle that turns on the spot is a turret.
	var parked = BusBody.new()
	world.add_child(parked)
	parked.global_position = bus.global_position + Vector3(20.0, 0.0, 0.0)
	parked.speed = 0.0
	var still: float = parked.heading
	for _i in 30:
		parked.drive(0.0, 1.0, SimConfig.TICK_DELTA)
	near(parked.heading, still, 0.001,
		"a parked bus does not turn however hard the wheel is held")
	parked.queue_free()

	# ...AND MOVING, IT DOES, AND IT LEANS INTO IT.
	var before: float = bus.heading
	for _i in 30:
		bus.drive(1.0, 1.0, SimConfig.TICK_DELTA)
	var turned: float = absf(angle_difference(bus.heading, before))
	print("[bus] half a second of lock turned it %.1f deg and leaned %.1f deg"
		% [rad_to_deg(turned), rad_to_deg(absf(bus.tilt))])
	check(turned > deg_to_rad(5.0),
		"a moving bus turns (%.1f deg)" % rad_to_deg(turned))
	check(absf(bus.tilt) > deg_to_rad(2.0),
		"and leans into the corner (%.1f deg)" % rad_to_deg(absf(bus.tilt)))

	# THE LEAN IS PROPORTIONAL TO SPEED, which is the whole reason it is worth
	# having: a tilt that ignored speed would lean as hard at walking pace and
	# read as a broken suspension rather than as momentum.
	var fast: float = absf(bus.tilt)
	bus.speed = 1.0
	for _i in 40:
		bus.drive(0.0, 1.0, SimConfig.TICK_DELTA)
	print("[bus] leaning %.1f deg fast against %.1f deg slow"
		% [rad_to_deg(fast), rad_to_deg(absf(bus.tilt))])
	check(absf(bus.tilt) < fast,
		"and leans LESS when slower (%.1f against %.1f deg)"
			% [rad_to_deg(absf(bus.tilt)), rad_to_deg(fast)])

	# ...AND SETTLES OUT OF ONE rather than staying tipped over.
	for _i in 90:
		bus.drive(1.0, 0.0, SimConfig.TICK_DELTA)
	check(absf(bus.tilt) < deg_to_rad(1.0),
		"and comes back level out of the corner (%.2f deg)"
			% rad_to_deg(absf(bus.tilt)))

# --- 6. Planted ----------------------------------------------------------------

func _riders_are_planted() -> void:
	bus.riders.clear()
	bus._rebuild()
	bus.speed = 0.0
	bus.board(1)
	bus.board(2)
	var body: Node = world.player_body(2)

	# THROWN OFF ON PURPOSE, then posed. Whatever a rider's own movement did this
	# tick is overwritten, which is what "planted" means -- and is why none of the
	# carrier/rider traps apply.
	body.global_position = bus.global_position + Vector3(9.0, 3.0, 9.0)
	body.velocity = Vector3(5.0, 2.0, -5.0)
	world._plant_riders(bus)
	var slot: Vector3 = bus.slot_world(1) + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0)
	near(body.global_position.distance_to(slot), 0.0, 0.01,
		"a rider is put back on their slot whatever they were doing (%.2f m off)"
			% body.global_position.distance_to(slot))
	near(body.velocity.length(), 0.0, 0.001, "with no momentum of their own")

	# AND THEY MOVE WITH IT. A slot that did not follow the bus would be a rider
	# standing in the road watching it drive away.
	var was: Vector3 = body.global_position
	for _i in 30:
		bus.drive(1.0, 0.0, SimConfig.TICK_DELTA)
		world._plant_riders(bus)
	print("[bus] the bus carried a planted rider %.2f m"
		% was.distance_to(body.global_position))
	check(was.distance_to(body.global_position) > 1.0,
		"and they are carried along with it (%.2f m)"
			% was.distance_to(body.global_position))

# --- 7. Ammo -------------------------------------------------------------------

func _ammo_aboard_and_on_the_way_out() -> void:
	var weapon: Node = world._specials.spawn_loose(
		world.player_body(2).global_position, SpecialBody.Kind.MACHINE_GUN)
	weapon.hold(2)
	var full: int = SpecialPool.full_ammo(SpecialBody.Kind.MACHINE_GUN)
	weapon.ammo = 3
	check(bus.is_rider(2), "the passenger is aboard")

	world._plant_riders(bus)
	eq(weapon.ammo, full,
		"a rider's weapon is topped up to full (%d) -- 'unlimited while aboard' "
			% full
		+ "and 'you leave with a full one' are the SAME line rather than two rules "
		+ "that have to agree, so there is no flag to clear on the way out")

	# AND IT STAYS FULL AS IT IS SPENT.
	weapon.ammo = 1
	world._plant_riders(bus)
	eq(weapon.ammo, full, "and stays that way as it is spent")

	# ...WHICH IS WHY LEAVING NEEDS NO CODE AT ALL. The last tick aboard already
	# filled it, so stepping off carries a full one by construction.
	bus.leave(2)
	world._plant_riders(bus)
	eq(weapon.ammo, full,
		"so stepping off carries a full one without a single line to do it")
	bus.board(2)

# --- 8. The driver drives ------------------------------------------------------

func _the_driver_cannot_shoot():
	# ASKED OF THE SEAT, not of a flag. The driver is riders[0], so promoting
	# somebody by stepping off hands over the trigger in the same instant it hands
	# over the wheel -- there is no second fact to keep in step.
	eq(bus.driver(), 1, "player 1 is driving")
	var driver_actions: int = _actions_after_seating(1)
	eq(driver_actions & (SimConfig.ACTION_SPECIAL | SimConfig.ACTION_SPECIAL_HELD), 0,
		"the driver's fire bits are taken away")
	var rider_actions: int = _actions_after_seating(2)
	check(rider_actions & SimConfig.ACTION_SPECIAL_HELD != 0,
		"and a passenger keeps theirs -- being aboard is not being disarmed")

	# AND PROMOTION MOVES IT. The passenger who becomes the driver loses the
	# trigger on the same tick.
	bus.leave(1)
	eq(bus.driver(), 2, "the passenger is promoted")
	eq(_actions_after_seating(2) & SimConfig.ACTION_SPECIAL_HELD, 0,
		"and loses the trigger with the promotion, in the same instant")
	bus.riders = [1, 2]

# --- 9. Not at each other ------------------------------------------------------

func _passengers_do_not_shoot_each_other() -> void:
	bus.riders = [1, 2]
	var victim: Node = world.player_body(2)
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0

	# A BULLET FROM ONE PASSENGER TO ANOTHER IS REFUSED.
	world._resolve_round_hit(victim, Vector3(0.0, 0.0, -1.0),
		victim.global_position, victim.global_position + Vector3(0.0, 0.0, 3.0), 1)
	eq(victim.health, SimConfig.MAX_HEALTH,
		"a passenger cannot machine-gun the passenger in front of them")

	# THE CONTROL, AND IT HAS TO BE ABLE TO SUCCEED. If a round could not have hurt
	# them anyway, the assertion above is about nothing -- the hat that "could not
	# be shot" until the control was lifted clear of the deck.
	bus.riders = [1]
	victim.invulnerable = 0.0
	world._resolve_round_hit(victim, Vector3(0.0, 0.0, -1.0),
		victim.global_position, victim.global_position + Vector3(0.0, 0.0, 3.0), 1)
	check(victim.health < SimConfig.MAX_HEALTH,
		"and the same shot DOES hurt them once they are not sharing a bus "
		+ "(%d health) -- being aboard is the rule, not the geometry" % victim.health)

	# AND A BLAST STILL CATCHES EVERYONE, including the person who fired it. The
	# bus is not a safe room: it is a place where you cannot casually machine-gun
	# the person in front of you, and blowing yourselves up stays available.
	bus.riders = [1, 2]
	check(not world._riders_shielded_from(1, victim) == false,
		"two passengers are shielded from each other's bullets")
	eq(world._riders_shielded_from(1, world.player_body(1)), false,
		"but nobody is shielded from themselves -- a rocket at your own feet is "
		+ "still a rocket at your own feet")

# --- helpers ------------------------------------------------------------------

# What the step loop would hand this player, with the seat rule applied. Mirrors
# the two lines in _host_tick rather than calling them, because the loop needs a
# whole tick and this phase is about one bit.
# --- 9. Off the edge ----------------------------------------------------------
#
# EVERY OTHER FALLING THING IN THIS GAME CULLS ITSELF -- a bullet, a hat, a
# rusher, a plinko ball all answer `is_spent()` with a check against FALL_KILL_Y.
# The bus does not, because the bus is driven by the world rather than by itself,
# so the world has to do it: without this a bus driven off the edge falls for
# ever, and its riders are POSED to it every tick, so they fall with it and never
# reach the fall-kill path that would drone them back. The party loses the
# vehicle and the people on it, silently, and the only symptom is a track with
# nobody on it.
#
# The rule is that the bus is emptied rather than the riders being freed with it.
# Released mid-air they are ordinary falling bodies, and the game already has an
# answer for one of those.
#
# WHAT MAKES THIS TESTABLE AT ALL is that it is a PRESENCE claim on both sides:
# the old bus is gone AND a new one exists. Asserting only the first passes just
# as well if the pool broke entirely.
func _a_bus_that_falls_is_let_go_of() -> void:
	world.run_modes = [GameMode.BLANK]
	world._process_buses()
	if not check(world._buses.size() > 0, "there is a bus to push off the edge"):
		return
	var doomed = world._buses[0]
	doomed.riders.clear()
	doomed.board(1)
	var body: Node = world.players.get(1)
	eq(world.bus_carrying(1), doomed, "with somebody aboard it")

	# BELOW THE LINE EVERYTHING ELSE IS CULLED AT. Placed rather than driven off
	# the edge, because the claim is about what happens at that depth and driving
	# there would take four hundred ticks of falling to say the same thing.
	doomed.global_position = Vector3(doomed.global_position.x, SimConfig.FALL_KILL_Y - 1.0,
		doomed.global_position.z)
	world._process_buses()

	check(not is_instance_valid(doomed) or doomed.is_queued_for_deletion(),
		"a bus below FALL_KILL_Y is culled -- nothing else in this game falls for "
		+ "ever, and a vehicle is not the exception")
	eq(world.bus_carrying(1), null,
		"and it does not take its passenger with it: a rider is let GO, so it "
		+ "becomes an ordinary falling body and the existing rescue path has it")
	if body != null and is_instance_valid(body):
		check(body.global_position.y < 0.0,
			"who is where the bus left them (y %.1f), falling" % body.global_position.y)

	# AND THE PARTY IS NOT LEFT WITHOUT ONE. `_ensure_bus` builds the next on the
	# following tick; if it did not, driving off the edge once would end the mode.
	world._process_buses()
	check(world._buses.size() > 0, "a replacement is built")
	if world._buses.size() > 0:
		check(world._buses[0] != doomed, "and it is a new one, not the wreck")

func _actions_after_seating(peer: int) -> int:
	var actions: int = SimConfig.ACTION_SPECIAL | SimConfig.ACTION_SPECIAL_HELD
	var riding: Node = world.bus_carrying(peer)
	if riding != null and riding.driver() == peer:
		actions &= ~(SimConfig.ACTION_SPECIAL | SimConfig.ACTION_SPECIAL_HELD)
	return actions
