extends "res://scripts/test_support/test_case.gd"

# M12. The machine gun: the first special, and the first thing in the game that
# can REMOVE a threat rather than postpone one.
#
# The claims:
#   1. Holding the trigger fires at MG_FIRE_INTERVAL and not faster. The cadence
#      is the weapon; a rate that quietly ran at the tick rate would be six times
#      the weapon anybody agreed to.
#   2. Ammo drains one per round, and AT ZERO THE GUN IS GONE. An empty weapon you
#      keep carrying is the worst possible occupant of a one-slot rule.
#   3. A round both damages AND moves a player -- and HIT_GRACE limits that to
#      about one round in two, which is what makes a held trigger a fight rather
#      than a player being switched off.
#   4. A RUSHER DIES TO ONE ROUND.
#   5. A pillar STOPS a round. Cover is the answer to being shot at, and without
#      it there is no counter-play at all.
#   6. A round is an OBJECT IN FLIGHT that leaves the BARREL, and no two leave on
#      exactly the same line. All three asked for in playtest, and all three are
#      things the first version -- an instant line from the player's nose -- got
#      wrong in a way no test could have caught, because nothing here had an
#      opinion about where a round came from or how long it took to arrive.
#
# CLAIM 4 IS THE ONE CARRYING THE DESIGN. Everything else here is also true of a
# gun that merely inconveniences people; hazards.md's whole argument for the
# weapon category is that a shove only DEFLECTS a destructible, so a weapon that
# cannot end one is "a shove you can do from further away" -- which is free.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const RusherBody = preload("res://scripts/sim/rusher_body.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Yaw 0 is north is -Z, and a higher cell z is further north. So a player left at
# facing 0 is pointing at every cell with a larger z than their own, which is what
# every "put the target in front of them" line below relies on.
const NORTH := 0.0

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

# Held by the shooter. Level-triggered on purpose -- see
# SimConfig.ACTION_SPECIAL_HELD.
var trigger: bool = false

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "GunWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 3)
	a = world.player_body(1)
	b = world.player_body(2)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if trigger else 0
		return PlayerInput.make(t, Vector2.ZERO, actions)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_fire_rate()
		1: _phase_runs_dry()
		2: _phase_shooting_a_friend()
		3: _phase_a_rusher_dies()
		4: _phase_cover_works()
		5: _phase_rounds_are_objects()
		6: _phase_rounds_push_balls()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	trigger = false
	# ROUNDS OUTLIVE THE TICK THAT FIRED THEM, so phases are not independent unless
	# this is here. Found the hard way: a round still in the air when phase 3 began
	# killed that phase's rusher one frame after it was spawned, and the failure
	# read as "the rusher never came up". Nothing like it was possible while the
	# weapon was hitscan.
	for bullet in world._bullets:
		if is_instance_valid(bullet):
			bullet.queue_free()
	world._bullets.clear()

# --- 1. The cadence -------------------------------------------------------------

func _phase_fire_rate() -> void:
	if phase_frame == 1:
		# Both players well apart and facing empty deck, so nothing is hit and the
		# only thing being measured is the rate.
		_park(a, Vector2i(10, 9))
		_park(b, Vector2i(25, 9))
		a.facing = NORTH
		_arm(a)
		return
	if phase_frame == 2:
		trigger = true
		return
	# TWO SECONDS, not one. At MG_FIRE_INTERVAL a single second is 2.5 rounds, and
	# a budget that rounds to an integer cannot tell 2.5 from 2 or from 3. Over a
	# window the rate divides evenly into, the expected count is exact.
	if phase_frame == 123:
		trigger = false
		var weapon: Node = world.special_held_by(1)
		var fired: int = SimConfig.MG_AMMO - int(weapon.ammo)
		var expected: int = int(round(2.0 / SimConfig.MG_FIRE_INTERVAL))
		# Within one, because two seconds does not divide evenly into "the tick the
		# trigger went down". Asserting the RATE, never an exact round count.
		check(absi(fired - expected) <= 1,
			"a held trigger fires %d rounds in two seconds, not %d" % [expected, fired])
		_advance(1)

# --- 2. Running dry -------------------------------------------------------------

func _phase_runs_dry() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(10, 9))
		_park(b, Vector2i(25, 9))
		_arm(a)
		# Nearly empty, so this does not take six seconds of test.
		world.special_held_by(1).ammo = 3
		trigger = true
		return
	# Three rounds, two gaps between them, plus slack.
	if phase_frame == 75:
		trigger = false
		check(world.special_held_by(1) == null,
			"the gun is GONE at zero, not an empty weapon occupying the one slot")
		eq(world.special_count(), 0, "and is not lying on the deck either")
		_advance(2)

# --- 3. Shooting a friend --------------------------------------------------------

func _phase_shooting_a_friend() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(20, 9))
		# Directly up-bridge of the shooter and inside MG_RANGE. -Z is north, and
		# cell z + 1 is -Z, so a higher cell z is in front of a player facing north.
		# ONE CELL, two metres, and it had to close up when MG_SPREAD_DEG went from
		# 4 degrees to 10: at two metres the cone is 0.35 m and cannot move a round
		# outside a 0.4 m body, but at four it is 0.7 m and roughly half of them
		# miss. Further out the spread is doing exactly its job, and a test asserting
		# "this round hit" would be asserting a coin flip -- deterministic under the
		# seeded RNG, and still a coin flip in every sense that matters.
		_park(b, Vector2i(20, 10))
		a.facing = NORTH
		_arm(a)
		recorded["health_before"] = int(b.health)
		recorded["z_before"] = b.position.z
		recorded["ever_tumbled"] = false
		trigger = true
		return

	# WHETHER IT EVER HAPPENED, not what state they are in at the end. A tumble runs
	# TUMBLE_MIN_SECONDS and then recovers, so "are they tumbling now" depends
	# entirely on which round of the burst landed last -- it passed on a target four
	# metres away and failed at two, for no reason connected to the claim.
	if b.state == PlayerBody.State.TUMBLE:
		recorded["ever_tumbled"] = true
	# 90 ticks is 1.5 s: about four rounds fired, plus the six ticks a round spends
	# in the air crossing two metres. Rounds TAKE TIME now -- the version of this
	# test written against a hitscan gun asserted on a frame the round had not been
	# invented for yet.
	if phase_frame == 90:
		trigger = false
		var lost: int = int(recorded["health_before"]) - int(b.health)
		check(lost >= 1, "a round takes health off a friend (%d)" % lost)

		# THE GRACE WINDOW IS WHAT MAKES THIS SURVIVABLE. 90 ticks is 1.5 s and about
		# four rounds -- and HIT_GRACE is 0.75 s, so at most two of them may land.
		# Without that gate a held trigger would empty a five-point health bar as
		# fast as it could fire.
		check(lost <= 2,
			"but HIT_GRACE limits it to %d of the ~4 rounds fired" % lost)

		# AND IT MOVES THEM. Being shot is displacement, like everything else in
		# this game; a weapon that only chipped health would be the odd one out.
		check(b.position.z < float(recorded["z_before"]) - 0.3,
			"and knocks them away from the shooter (%.2f m)"
				% (float(recorded["z_before"]) - b.position.z))
		check(bool(recorded["ever_tumbled"]), "a hit tumbles you")
		_advance(3)

# --- 4. A rusher dies ------------------------------------------------------------

func _phase_a_rusher_dies() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(20, 9))
		_park(b, Vector2i(2, 2))
		a.facing = NORTH
		_arm(a)
		# TWO CELLS OUT, four metres, and that distance is bracketed from both
		# sides. Nearer than about 2 m and the rusher is already inside
		# RUSHER_HIT_RADIUS + HALF_HEIGHT, so it reaches the shooter and expends
		# itself on contact -- which removes it, and the test would then pass for
		# entirely the wrong reason. Further out and a 10 degree cone is wider than
		# the rusher.
		var at: Vector3 = world.grid.cell_surface_world(Vector2i(20, 11))
		var rusher: Node = world._spawn_rusher(at)
		rusher.state = RusherBody.State.CHASE
		# begin_rise starts it a full RUSHER_HEIGHT UNDERGROUND -- the rise is the
		# telegraph. Skipping straight to CHASE without also moving it up leaves a
		# rusher below the deck, which every round then flies over.
		rusher.position = at + Vector3(0.0, 0.7, 0.0)
		recorded["rusher_id"] = rusher.rusher_id
		recorded["rusher_at"] = rusher.position
		return
	if phase_frame == 3:
		eq(world._rushers.size(), 1, "a rusher is up and chasing")
		trigger = true
		return

	# PINNED WHERE IT STANDS, for as long as this phase runs. A chasing rusher
	# covers RUSHER_SPEED -- four metres in half a second -- so left alone it walks
	# into contact range and kills itself on the shooter long before enough rounds
	# have been fired to be sure one connected. Held still, the only thing that can
	# end it is being shot, which is the claim.
	var alive: Node = world._rusher_by_id(int(recorded.get("rusher_id", 0)))
	if alive != null:
		alive.position = recorded["rusher_at"]
		alive.velocity = Vector3.ZERO

	# TWO SECONDS, about five rounds. At four metres the cone is 0.7 m against a
	# 0.5 m rusher, so an individual round genuinely may miss -- that is the spread
	# doing its job. Firing a burst asserts the claim ("a round ends it") without
	# asserting a coin flip on any one of them.
	if phase_frame == 130:
		trigger = false
		# By ID, never by holding the node: assigning a freed object to a typed var
		# raises before is_instance_valid can answer, and the raise silently aborts
		# the rest of this function -- CLAUDE.md, and it cost test_rusher twice.
		check(world._rusher_by_id(int(recorded["rusher_id"])) == null,
			"A ROUND ENDS A RUSHER -- the only thing in the game that removes a threat")
		_advance(4)

# --- 5. Cover -------------------------------------------------------------------

func _phase_cover_works() -> void:
	if phase_frame == 1:
		# The pillar authored at cell (22, 8) in test_flat.seg, with the shooter on
		# one side of it and the target on the other.
		#
		# TWO CELLS BACK FROM THE PILLAR, not four. A 10 degree cone is 1.4 m wide at
		# four metres and the pillar is only 1 m in radius, so rounds would go PAST
		# the cover the test exists to prove -- and a cover test that leaks is worse
		# than no cover test. At two metres the cone is 0.35 m and every round is
		# stopped.
		_park(a, Vector2i(22, 6))
		_park(b, Vector2i(22, 12))
		a.facing = NORTH
		_arm(a)
		recorded["health_before"] = int(b.health)
		trigger = true
		return
	if phase_frame == 100:
		trigger = false
		var weapon: Node = world.special_held_by(1)
		check(weapon != null and int(weapon.ammo) < SimConfig.MG_AMMO,
			"rounds were actually fired at them")
		eq(int(b.health), int(recorded["health_before"]),
			"and a pillar stopped every one -- cover is the answer to being shot at")
		_advance(5)

# --- 6. What a round IS ----------------------------------------------------------
#
# All three of these were playtest notes on the first version, which fired an
# instant line from the middle of the player. None of them could have been caught
# by the tests above: a hitscan gun passes every one of claims 1 to 5.

func _phase_rounds_are_objects() -> void:
	if phase_frame == 1:
		# Facing straight down an empty lane, so nothing stops a round early and
		# every one of them lives its full flight.
		_park(a, Vector2i(10, 4))
		_park(b, Vector2i(28, 4))
		a.facing = NORTH
		_arm(a)
		recorded["lines"] = []
		trigger = true
		return

	# WHERE THE ROUND STARTED, read off the round itself. Not its current position:
	# by the time any observer sees it, it has already flown a tick -- 37 cm at
	# MG_BULLET_SPEED, which is most of the distance being asserted about.
	if not recorded.has("muzzle") and world.bullet_count() > 0:
		var first: Node = world._bullets[0]
		recorded["muzzle"] = world.to_global(first.origin)

	# Directions, sampled across several rounds.
	for bullet in world._bullets:
		if is_instance_valid(bullet) and bullet.age <= SimConfig.TICK_DELTA * 1.5:
			recorded["lines"].append(bullet.velocity.normalized())

	if phase_frame == 100:
		trigger = false

		# AN OBJECT IN FLIGHT. A hitscan round is resolved and gone inside the tick
		# that fired it, so there is never a frame where one exists to be counted.
		check(recorded.has("muzzle"), "a round exists in the world after it is fired")

		# OUT OF THE BARREL, NOT THE NOSE. The gun hangs off the Facing pivot in
		# front of and to one side of the body, so a round that started at the
		# player's own origin would be roughly on top of them.
		var weapon: Node = world.special_held_by(1)
		var barrel := weapon.get_node("Barrel") as Node3D
		var muzzle: Vector3 = recorded["muzzle"]
		check(muzzle.distance_to(barrel.global_position) < 0.35,
			"and starts at the barrel (%.2f m from it)"
				% muzzle.distance_to(barrel.global_position))
		check(muzzle.distance_to(a.global_position) > 0.6,
			"rather than inside the player who fired it (%.2f m out)"
				% muzzle.distance_to(a.global_position))

		# SPREAD. Two rounds on exactly the same line is what a weapon with no
		# dispersion does, so the claim is that the SET of directions is not a
		# single direction.
		var lines: Array = recorded["lines"]
		check(lines.size() >= 3, "several rounds were sampled (%d)" % lines.size())
		var widest: float = 0.0
		# Measured on the two axes SEPARATELY, because the cone is an ellipse and a
		# single angle between two directions cannot tell which axis it came from.
		var widest_flat: float = 0.0
		var widest_vertical: float = 0.0
		for i in lines.size():
			for j in range(i + 1, lines.size()):
				var u: Vector3 = lines[i]
				var v: Vector3 = lines[j]
				widest = maxf(widest, u.angle_to(v))
				widest_flat = maxf(widest_flat,
					Vector2(u.x, u.z).angle_to(Vector2(v.x, v.z)))
				widest_vertical = maxf(widest_vertical, absf(asin(u.y) - asin(v.y)))
		check(widest > 0.0005,
			"and no two leave on the same line -- %.2f degrees across the cone"
				% rad_to_deg(widest))
		# ...but still a CONE, not a shotgun. Every pair is inside twice the
		# half-angles, which is what the two spread numbers promise.
		var budget: float = deg_to_rad(
			2.0 * (SimConfig.MG_SPREAD_DEG + SimConfig.MG_SPREAD_VERTICAL_DEG))
		check(widest <= budget + 0.001,
			"and the cone stays inside its budget (%.2f degrees)" % rad_to_deg(widest))

		# WIDE ACROSS, NARROW UP AND DOWN. The bridge is a narrow strip and
		# everything worth shooting stands on it, so these two axes are not
		# interchangeable: horizontal scatter reads as spraying and vertical scatter
		# reads as the gun being broken. A round cone -- which is what this was --
		# gives the same number twice.
		check(widest_vertical <= deg_to_rad(2.0 * SimConfig.MG_SPREAD_VERTICAL_DEG) + 0.001,
			"vertical scatter stays inside MG_SPREAD_VERTICAL_DEG (%.2f degrees)"
				% rad_to_deg(widest_vertical))
		check(widest_flat > widest_vertical * 1.5,
			"and the cone is WIDER across than up: %.2f degrees against %.2f"
				% [rad_to_deg(widest_flat), rad_to_deg(widest_vertical)])
		_advance(6)

# --- 7. Rounds shove plinko balls -------------------------------------------------
#
# Asked for in playtest, and it is a trade rather than a freebie. Balls were
# deliberately absent from the round's mask on the argument that a ball stopping a
# round makes the plinko field cover. It now does -- and it is also something you
# can shoot at somebody, which is the half worth having.

func _phase_rounds_push_balls() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(20, 9))
		_park(b, Vector2i(2, 2))
		a.facing = NORTH
		_arm(a)
		# One ball, parked in the air two cells in front and held still, so the only
		# thing that can move it is being shot. A ball rolling down the 4 degree
		# pitch would be moving anyway, and "did it speed up" is a much weaker claim
		# than "it was stationary and now it is not".
		var ball: Node = world._launch_ball(Vector2i(20, 11))
		ball.position = a.position + Vector3(0.0, 0.25, -4.0)
		ball.linear_velocity = Vector3.ZERO
		ball.set_simulated(false)
		recorded["ball_id"] = ball.ball_id
		recorded["ball_at"] = ball.position
		return
	if phase_frame == 3:
		var ball: Node = world._ball_by_id(int(recorded["ball_id"]))
		check(ball != null, "a ball is parked in front of the shooter")
		# Let it move only now, so nothing before this frame counts.
		ball.set_simulated(true)
		trigger = true
		return
	if phase_frame == 60:
		trigger = false
		var ball: Node = world._ball_by_id(int(recorded["ball_id"]))
		check(ball != null, "the ball survived being shot -- a round shoves, it does not pop")
		var moved: float = ball.position.distance_to(recorded["ball_at"])
		# Well past what a second of gravity on a resting ball accounts for.
		check(moved > 1.0, "and a round SHOVES it (%.2f m)" % moved)
		check(ball.position.z < float(recorded["ball_at"].z) - 0.5,
			"away from the shooter, along the round (%.2f m down-range)"
				% (float(recorded["ball_at"].z) - ball.position.z))
		finish()

# --- helpers ---------------------------------------------------------------------

func _park(body: CharacterBody3D, cell: Vector2i) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.state_timer = 0.0
	body.grounded = true
	body.health = SimConfig.MAX_HEALTH
	body.invulnerable = 0.0

# Hand somebody a full weapon, without making them walk to it -- what is being
# tested here is the gun, and test_special_pickup owns getting hold of one.
func _arm(body: CharacterBody3D) -> void:
	world._specials.clear()
	var weapon: Node = world._specials.spawn_loose(body.position + Vector3(0.0, 0.2, 0.0))
	world._take_special(weapon.special_id, int(body.peer_id))
	weapon.fire_timer = 0.0
