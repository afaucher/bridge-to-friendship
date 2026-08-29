extends "res://scripts/test_support/test_case.gd"

# WHAT CAN HURT YOU IN THE BUS, AND WHAT IT DOES WHEN IT DOES.
#
# The bus was built with exactly one rule about damage -- two passengers on the
# same bus cannot machine-gun each other -- and nothing anywhere states the rest.
# That is the gap this file closes. Everything below is a MEASUREMENT of what the
# game already does, written down so the next change to it is a decision rather
# than an accident.
#
# WHEN IT WAS FIRST MEASURED, KNOCKBACK WAS ERASED ENTIRELY. A rider is planted
# every tick and `_plant_riders` runs AFTER the hazards, so a hit landed, health
# fell, and every positional consequence was overwritten before anybody saw it --
# the same rusher shove threw a player on the deck 6.04 m and a rider 0.00, and
# nothing in the game could get somebody out of a bus.
#
# THE THRESHOLD IS THE ANSWER TO THAT, and it is why this file is now mostly
# about one number. A shove at or above SimConfig.BUS_EJECT_SPEED takes your seat
# and lets the tumble carry you off; below it the seat is reasserted as before.
# 10 m/s sits in the empty space between a round (8.25) and a body-check (11.28),
# so gunfire chips and a collision throws you out -- and both halves are asserted,
# because a threshold with only its upper half tested is a threshold that could
# be zero.
#
# The claims:
#   1. Two riders on one bus cannot shoot each other, and everything else can.
#      A rider shooting the ground, the ground shooting a rider, and a rider on
#      ANOTHER bus are all live -- being aboard is not cover.
#   2. Damage lands. Health falls, by the ordinary path.
#   3. A body-check throws you clear of the bus and off the roster -- measured
#      against a player on the deck taking the identical hit, because "the rider
#      moved" is also satisfied by a hit that would move anybody.
#   3b. And a round does not, using the real MG_KNOCKBACK -- so if that constant
#      is ever raised past the threshold, this says so rather than the split
#      quietly ceasing to exist.
#   4. A rider who goes down STAYS ABOARD, and the next seat is inside reviving
#      range -- which is what keeps going down aboard a setback rather than a
#      locked room with a witness.
#   5. The bus itself is not a target and not a weapon: no receive_hit, and a
#      mask that drives it through anything alive.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const BusRig = preload("res://scripts/test_support/bus_rig.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")

var world: Node3D = null
var bus: Node = null
var phase := 0
var seat: Vector3 = Vector3.ZERO
var ground_from: Vector3 = Vector3.ZERO

func setup(main) -> void:
	timeout_seconds = 30.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "DamageWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	world._spawn_player(3, 2)
	for peer in [1, 2, 3]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.BLANK]

func _physics_process(_delta: float) -> void:
	if world.tick < 4:
		return

	if phase == 0:
		bus = BusRig.spawn(world)
		if not check(bus != null, "there is a bus"):
			finish()
			return
		bus.riders.clear()
		bus.board(1)
		bus.board(2)
		world._plant_riders(bus)
		_who_may_shoot_whom()
		_damage_lands()
		_shove_them_both()
		phase = 1
		return

	# THIRTY TICKS LATER, because a hit does not MOVE anybody. `receive_hit`
	# begins a tumble and the travel happens in `step()` over the frames after --
	# so measuring on the tick of the hit reports 0.00 m for everybody, which
	# looks exactly like the claim below being true and is nothing of the kind.
	if phase == 1 and world.tick > 40:
		_a_body_check_throws_you_out()
		_reseat()
		phase = 2
		return

	if phase == 2 and world.tick > 45:
		_gunfire_only_chips()
		_reseat()
		phase = 3
		return

	if phase == 3 and world.tick > 75:
		_still_aboard_after_gunfire()
		_down_the_rider()
		phase = 4
		return

	if phase == 4 and world.tick > 85:
		_a_downed_rider_stays_aboard()
		_the_bus_is_not_a_target()
		finish()

# Put everybody back in their seat at full health between phases, so each claim
# is measured on a fixture nothing else has already moved. A long sequence is a
# fixture that gets dirtier as it runs.
func _reseat() -> void:
	bus.riders.clear()
	bus.board(1)
	bus.board(2)
	for peer in [1, 2, 3]:
		var body: Node = world.player_body(peer)
		body.health = SimConfig.MAX_HEALTH
		body.invulnerable = 0.0
		body.state = PlayerBody.State.WALK
		body.velocity = Vector3.ZERO
	world._plant_riders(bus)

# --- 1. The one rule that was written down ------------------------------------

func _who_may_shoot_whom() -> void:
	var one: Node = world.player_body(1)
	var two: Node = world.player_body(2)
	var three: Node = world.player_body(3)

	check(world._riders_shielded_from(1, two),
		"a rider's round does not reach the rider in front of them -- the bus is "
		+ "a place where you cannot casually machine-gun a teammate")
	check(not world._riders_shielded_from(1, one),
		"but your own rounds still reach you, so nothing about being aboard makes "
		+ "you immune to your own blast")
	check(not world._riders_shielded_from(1, three),
		"and a rider shooting somebody on the GROUND is refused nothing -- the "
		+ "rule is about the seat next to you, not about a firing arc")
	check(not world._riders_shielded_from(3, two),
		"nor is somebody on the ground shooting a rider: being aboard is not "
		+ "cover. Asked of both ends, so the bus cannot be used as a bunker")

	# A SECOND BUS IS A SECOND ROOM. The rule reads `on.is_rider(victim)`, so it
	# is about SHARING a vehicle rather than about being in one -- worth its own
	# assertion, because "riders are safe from riders" is the phrasing everybody
	# reaches for and it is not what the code says.
	var other = BusBody.new()
	world.add_child(other)
	other.name = "OtherBus"
	other.board(3)
	world._buses.append(other)
	check(not world._riders_shielded_from(1, three),
		"and a rider on a DIFFERENT bus is a fair target -- the rule is about "
		+ "sharing a vehicle, not about being in one")
	world._buses.erase(other)
	other.riders.clear()
	other.queue_free()

# --- 2 and 3. What a hit actually does ----------------------------------------

func _damage_lands() -> void:
	var rider: Node = world.player_body(2)
	var before: int = rider.health
	rider.receive_hit(Hit.make(Hit.Kind.IMPACT, 1,
		rider.position + Vector3(3.0, 0.0, 0.0), 0.0, 0.0))
	print("[busdmg] a rider took %d -> %d health" % [before, rider.health])
	check(rider.health < before,
		"damage reaches a rider normally (%d -> %d) -- the bus is not armour, and "
			% [before, rider.health]
		+ "the only thing it stops is the person sitting next to you")

# THE SAME SHOVE TO A RIDER AND TO SOMEBODY STANDING ON THE GROUND.
#
# THE CONTROL HAS TO BE ABLE TO SUCCEED. "The rider did not move" is satisfied by
# a shove that does nothing to anybody -- by a grace window swallowing the hit, by
# the wrong Hit kind, by a knockback of zero. Player 3 is on the deck taking the
# identical hit, so the two numbers together say what one alone cannot.
func _shove_them_both() -> void:
	var rider: Node = world.player_body(2)
	var walker: Node = world.player_body(3)
	for body in [rider, walker]:
		body.health = SimConfig.MAX_HEALTH
		body.invulnerable = 0.0
	seat = rider.position
	ground_from = walker.position
	for body in [rider, walker]:
		body.receive_hit(Hit.make(Hit.Kind.IMPACT, 1,
			body.position + Vector3(3.0, 0.0, 0.0),
			SimConfig.RUSHER_KNOCKBACK, SimConfig.RUSHER_KNOCKBACK_LIFT))

func _a_body_check_throws_you_out() -> void:
	var rider: Node = world.player_body(2)
	var walker: Node = world.player_body(3)
	# MEASURED FROM THE SEAT, NOT THROUGH WORLD SPACE. An earlier version recorded
	# a world position and compared against it thirty ticks later, and reported
	# 0.50 m about a build that was working perfectly: a bus is put down
	# BUS_SPAWN_LIFT above the deck and settles onto it, and a planted rider rides
	# down with it. That is the fixture moving, not the hazard.
	#
	# CLEAR OF THE BUS, asked through `distance_to_deck` -- the same function that
	# decides whether you are close enough to board. So the claim is not "they
	# moved a bit", it is "they are further away than a person who could climb in".
	var moved: float = bus.distance_to_deck(rider.position)
	var control: float = ground_from.distance_to(walker.position)
	print("[busdmg] a rusher shove threw a rider %.2f m from the seat, a walker %.2f m; aboard %s"
		% [moved, control, world.bus_carrying(2) != null])
	check(control > 1.0,
		"the shove really is a shove: the player on the deck was thrown %.2f m by "
			% control
		+ "it. Without this, every claim below is satisfied by a hit that does "
		+ "nothing to anybody")
	check(world.bus_carrying(2) == null,
		"a body-check takes a rider's SEAT away -- the shove is above "
		+ "BUS_EJECT_SPEED, so they are off the roster and the tumble carries "
		+ "them off. Nothing in the game could do this before: planting reasserted "
		+ "the seat after every hazard had had its turn")
	check(moved > SimConfig.BUS_REACH,
		"and they really left it -- %.2f m clear of the bodywork, further than the "
			% moved
		+ "%.2f m you can board from. Being off the roster is only half of it: a "
			% SimConfig.BUS_REACH
		+ "rider dropped and left standing where they were is somebody riding on "
		+ "the roof")

# --- 3b. And gunfire does not -------------------------------------------------
#
# THE OTHER HALF OF THE THRESHOLD, and the half that decides whether the bus is
# playable on its own track. A skirmisher is the only enemy the bus route runs;
# if a round threw you out, one gunner would empty a moving vehicle a passenger
# at a time and there would be nothing the party could do about it.
#
# The same hit a real round delivers -- MG_KNOCKBACK, not a number invented here
# -- so if that constant is ever raised past BUS_EJECT_SPEED this fails and says
# so, rather than the split quietly ceasing to exist.
func _gunfire_only_chips() -> void:
	var rider: Node = world.player_body(2)
	rider.invulnerable = 0.0
	seat = bus.slot_world(1) + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0)
	rider.receive_hit(Hit.make(Hit.Kind.BULLET, SimConfig.MG_DAMAGE,
		rider.position + Vector3(3.0, 0.0, 0.0),
		SimConfig.MG_KNOCKBACK, SimConfig.MG_KNOCKBACK_LIFT))
	print("[busdmg] a round launched a rider at %.2f m/s, eject threshold %.2f"
		% [rider.velocity.length(), SimConfig.BUS_EJECT_SPEED])
	check(rider.velocity.length() < SimConfig.BUS_EJECT_SPEED,
		"a round's shove (%.2f m/s) is below the ejection threshold (%.2f) -- the "
			% [rider.velocity.length(), SimConfig.BUS_EJECT_SPEED]
		+ "gap between gunfire and a body-check is what the constant is FOR, and "
		+ "raising MG_KNOCKBACK past it would close the gap silently")

func _still_aboard_after_gunfire() -> void:
	var rider: Node = world.player_body(2)
	var off: float = seat.distance_to(rider.position)
	print("[busdmg] thirty ticks after being shot: aboard %s, %.3f m from the seat"
		% [world.bus_carrying(2) != null, off])
	check(world.bus_carrying(2) != null,
		"being shot does not take your seat -- one skirmisher would otherwise "
		+ "empty a moving bus a passenger at a time, and the party could do "
		+ "nothing about it")
	near(off, 0.0, 0.05,
		"and the seat is reasserted under them (%.3f m), so a round chips at a "
			% off
		+ "rider's health and moves them not at all")

# --- 4. Going down in a moving vehicle ----------------------------------------

func _down_the_rider() -> void:
	var rider: Node = world.player_body(2)
	rider.health = 1
	rider.invulnerable = 0.0
	rider.receive_hit(Hit.make(Hit.Kind.IMPACT, 99,
		rider.position + Vector3(3.0, 0.0, 0.0), 0.0, 0.0))

func _a_downed_rider_stays_aboard() -> void:
	var rider: Node = world.player_body(2)
	print("[busdmg] after a killing blow: state %d, aboard %s, y %.2f (seat %.2f)"
		% [rider.state, world.bus_carrying(2) != null, rider.position.y,
		   bus.slot_world(1).y + PlayerBody.HALF_HEIGHT])
	check(rider.is_awaiting_rescue(),
		"a rider who runs out of health goes down like anybody else (state %d)"
			% rider.state)
	check(world.bus_carrying(2) != null,
		"and stays ON THE BUS -- nothing takes a downed rider off the roster, so "
		+ "they ride along until somebody picks them up")

	# WHICH IS ONLY SURVIVABLE BECAUSE THE PERSON WHO CAN HELP IS RIGHT THERE.
	# The driver is a metre away and cannot leave the wheel without giving it up;
	# if a downed rider were out of reviving range, going down aboard would be a
	# locked room with a witness.
	var reviver: Node = world.player_body(1)
	var gap: float = reviver.position.distance_to(rider.position)
	print("[busdmg] the next seat is %.2f m away, revive radius %.2f"
		% [gap, SimConfig.REVIVE_RADIUS])
	check(gap <= SimConfig.REVIVE_RADIUS,
		"and the rider in front is inside reviving distance (%.2f m of %.2f) -- "
			% [gap, SimConfig.REVIVE_RADIUS]
		+ "the seats are close enough that going down aboard is a setback rather "
		+ "than a locked room nobody can reach you in")

# --- 5. The vehicle ------------------------------------------------------------

func _the_bus_is_not_a_target() -> void:
	check(not bus.has_method("receive_hit"),
		"the bus takes no damage -- `_resolve_round_hit` returns on anything "
		+ "without receive_hit, so a round spends itself on the bodywork exactly "
		+ "the way it spends itself on the deck or a pillar")
	# AND IT DOES NOT HURT WHAT IT DRIVES INTO. Its mask is world and barrier
	# only, so it passes through a rusher rather than running it down. Stated here
	# because "a bus at 13 m/s does nothing to an enemy" is the kind of thing that
	# reads as a bug the first time somebody tries it.
	eq(bus.collision_mask, 1 | (1 << 7),
		"and its mask is world plus the round barrier and nothing else (%d), so "
			% bus.collision_mask
		+ "it drives THROUGH enemies rather than running them down")
