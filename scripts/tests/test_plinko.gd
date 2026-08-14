extends "res://scripts/test_support/test_case.gd"

# MVP criterion C5, and the first time anything in the game does damage.
#
# The claims worth defending, in the order they matter:
#
#   1. Shooters fire, and balls come back DOWN the bridge without anything
#      aiming them. That is the 4-degree pitch doing its job.
#   2. Every ball that connects tumbles you and costs a hit point. One outcome,
#      no invisible glancing/solid threshold.
#   3. A DASHING player bats it away, takes nothing, and the dash carries on --
#      unlike a dash into a stone or a player, which ends on contact. That
#      difference is the whole reason the shove has a third job.
#   4. Only the ANGLE varies. Every arc is the same size, which is what gives the
#      field a rhythm a player can learn.
#   5. Balls collide with EACH OTHER. Found in playtest passing straight through
#      one another -- their mask covered world, players and stones and stopped one
#      bit short of themselves.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "PlinkoWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)

	check(world.grid.shooter_cells.size() >= 3,
		"the playtest arena has shooters (%d)" % world.grid.shooter_cells.size())

	world._spawn_player(1, 0)
	victim = world.player_body(1)
	# Driven entirely through the world's own input hook. Stepping the body from
	# here as well would move it twice a frame.
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, recorded.get("move", Vector2.ZERO), int(recorded.get("actions", 0)))

	_test_launch_variance()

# --- 4. Fixed speed, varying angle --------------------------------------------

func _test_launch_variance() -> void:
	var directions: Array = []
	for i in 40:
		directions.append(world._launch_direction())

	var min_y: float = 2.0
	var spread := 0.0
	for d in directions:
		var direction: Vector3 = d
		near(direction.length(), 1.0, 0.001, "every launch direction is a unit vector")
		min_y = minf(min_y, direction.y)
		spread = maxf(spread, Vector2(direction.x, direction.z).length())

	# Every ball leaves at the same SPEED, so the only thing that can differ is
	# the direction -- and it must differ, or the field never scatters.
	check(spread > 0.5, "the launch angle varies widely (max tilt %.2f)" % spread)
	var widest: float = rad_to_deg(acos(clampf(min_y, -1.0, 1.0)))
	check(widest <= SimConfig.PLINKO_CONE_DEG + 1.0,
		"and stays inside the %.0f-degree cone (widest %.1f)" % [SimConfig.PLINKO_CONE_DEG, widest])
	check(min_y > 0.0, "every ball is launched upward, never into the deck")

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_shooters_fire()
		1: _phase_ball_hurts()
		2: _phase_spent_ball_is_harmless()
		3: _phase_dash_deflects()
		4: _phase_balls_collide()
		5: _phase_hit_radius_matches_geometry()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 1. Shooters fire, and balls travel back down the bridge ------------------

func _phase_shooters_fire() -> void:
	# Park the player far away so nothing gets hit while this is measured.
	if phase_frame == 1:
		victim.position = world.grid.cell_surface_world(Vector2i(7, 1)) + Vector3(0.0, 1.0, 0.0)
		return
	if phase_frame == int(SimConfig.PLINKO_FIRE_INTERVAL * 60.0) + 30:
		check(world.ball_count() > 0,
			"the shooters have fired (%d balls in flight)" % world.ball_count())
		# Balls start up-bridge and must end up further DOWN it than they began.
		# Nothing aims them: the deck is pitched, and that is the entire
		# mechanism.
		var highest_z: float = -9999.0
		for ball in world._balls:
			highest_z = maxf(highest_z, ball.position.z)
		recorded["ball_z"] = highest_z
		return
	if phase_frame == int(SimConfig.PLINKO_FIRE_INTERVAL * 60.0) + 240:
		var travelled: float = -9999.0
		for ball in world._balls:
			travelled = maxf(travelled, ball.position.z)
		# A MEANINGFUL distance, not merely "more than before". The first version
		# of this assertion asked only that the number went up, and it passed
		# happily while every ball landed and then sat there creeping a
		# millimetre a second -- which is exactly the bug it was supposed to
		# catch. Four seconds of rolling should cover several metres.
		check(travelled > float(recorded["ball_z"]) + 4.0,
			"balls roll back down the bridge under the deck's pitch (%.1f -> %.1f)"
				% [recorded["ball_z"], travelled])

		# And they are still MOVING at the end of it, rather than having come to
		# rest somewhere up-bridge.
		var fastest := 0.0
		for ball in world._balls:
			fastest = maxf(fastest, Vector2(ball.linear_velocity.x, ball.linear_velocity.z).length())
		check(fastest > 1.5, "and are still rolling (fastest %.2f m/s)" % fastest)
		_advance(1)

# --- 2. A ball that connects tumbles you and costs a hit point ----------------

func _phase_ball_hurts() -> void:
	if phase_frame == 1:
		_isolate()
		return
	if phase_frame == 20:
		# One ball, aimed squarely at a player standing still.
		recorded["ball"] = _place_ball(victim.position + Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, -8.0))
		return
	# Checked INSIDE the grace window. Later than that and a second hit from the
	# same ball is legitimate, and the assertion would be measuring how long the
	# ball loitered rather than what one hit costs.
	if phase_frame == 45:
		eq(victim.health, SimConfig.MAX_HEALTH - SimConfig.PLINKO_DAMAGE,
			"a ball that connects costs a hit point")
		eq(victim.state, PlayerBody.State.TUMBLE, "and tumbles you -- every ball, no threshold")
		_advance(2)

# --- 2b. A ball that has run out of steam is not a hazard --------------------
#
# Deliberately the SAME ball at the SAME spot as the phase above, at a different
# speed -- so the only thing that can explain the different outcome is the speed.
# A ball trickling into your ankle used to cost a hit point and tumble you, which
# is the same result as one arriving at full pelt.
func _phase_spent_ball_is_harmless() -> void:
	if phase_frame == 1:
		_isolate()
		return
	if phase_frame == 20:
		recorded["ball"] = _place_ball(victim.position + Vector3(0.0, 0.0, 3.0),
			Vector3(0.0, 0.0, -SimConfig.PLINKO_MIN_HIT_SPEED * 0.4))
		return
	if phase_frame == 120:
		eq(victim.health, SimConfig.MAX_HEALTH, "a spent ball costs nothing")
		check(victim.state != PlayerBody.State.TUMBLE, "and does not tumble you")
		_advance(3)

# --- 3. A dashing player bats it away and keeps dashing ----------------------

func _phase_dash_deflects() -> void:
	if phase_frame == 1:
		_isolate()
		return
	if phase_frame == 20:
		# A ball a little way up-bridge, and a dash straight at it. Both the
		# movement and the shove press go through the input hook, so the world
		# steps the body exactly once.
		var ball: Node = _place_ball(victim.position + Vector3(0.0, 0.0, -2.4), Vector3.ZERO)
		recorded["ball"] = ball
		recorded["ball_z"] = ball.position.z
		recorded["move"] = Vector2(0.0, -1.0)
		recorded["actions"] = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 21:
		recorded["actions"] = 0          # a press is one tick wide
		eq(victim.state, PlayerBody.State.SHOVE, "the dash is running")
		return
	if phase_frame == 26:
		var ball: Node = recorded["ball"]
		check(ball.position.z < float(recorded["ball_z"]) - 0.3,
			"a dashing player bats the ball away along the dash axis (%.2f -> %.2f)"
				% [recorded["ball_z"], ball.position.z])
		eq(victim.health, SimConfig.MAX_HEALTH, "and takes no damage from it")
		check(victim.state != PlayerBody.State.TUMBLE, "and is not tumbled by it")
		_advance(4)

# --- 5. Balls collide with each other -----------------------------------------
#
# Balls used to pass straight through one another: layer 8, mask 7 -- world,
# players, stones, and one bit short of themselves. Half of a plinko field's
# scatter comes from balls hitting balls, so a field of them was quietly behaving
# like a field of independent single balls.
#
# THE ASSERTION IS ARRANGED SO IT CANNOT PASS BY ACCIDENT. The struck ball starts
# at rest on a deck pitched 4 degrees, so the ONE thing it does unaided is roll
# DOWN-bridge, toward +z. The striker is placed down-bridge of it and fired UP the
# slope, so a real collision drives the target the one direction gravity never
# will. A version of this that fired down-slope would have passed with the balls
# ghosting through each other, because the target would have rolled there anyway.
func _phase_balls_collide() -> void:
	if phase_frame == 1:
		_isolate()
		# Well clear: a ball that clipped the player would be knocking the player
		# about instead, and the player would absorb the momentum under test.
		victim.position = world.grid.cell_surface_world(Vector2i(7, 1)) + Vector3(0.0, 1.0, 0.0)
		return
	if phase_frame == 20:
		# Two cells apart in the same clear lane. Both sit on the deck SURFACE at
		# their own cell -- the bridge is pitched, so placing the second one at the
		# first one's height would have buried it in the deck.
		var target: Node = _place_ball(
			world.grid.cell_surface_world(Vector2i(6, 22)) + Vector3(0.0, 0.6, 0.0), Vector3.ZERO)
		_place_ball(
			world.grid.cell_surface_world(Vector2i(6, 20)) + Vector3(0.0, 0.6, 0.0),
			Vector3(0.0, 0.0, -9.0))
		recorded["target"] = target
		recorded["target_z"] = target.position.z
		return
	if phase_frame == 80:
		var target: Node = recorded["target"]
		var moved: float = float(recorded["target_z"]) - target.position.z
		check(moved > 0.5,
			"a ball knocks another ball up-bridge, against the pitch -- so they collide (%.2f m)" % moved)
		_advance(5)

# --- 6. The hit radius is the geometry, not twice the geometry -----------------
#
# Reported 2026-08-13: "plinko balls can seemingly hit you from quite a distance
# going past you." Measured, and it was a UNIT ERROR rather than a generous
# constant: the test added PlayerBody.HALF_HEIGHT (0.9) as its horizontal term --
# the body's TALLNESS standing in for its WIDTH -- so a 0.6 m ball and a 0.4 m
# body whose real contact distance is 1.0 m triggered at 2.0 m.
#
# WALKED IN RATHER THAN CALCULATED. Asserting `reach == RADIUS + knob` would just
# restate the line above it; placing a ball at a measured distance and asking
# whether it connects is the claim a player would make.

const NEAR_MISS := 1.9      # outside the fixed radius (1.5), inside the old one (2.0)
const CLEAR_HIT := 1.2      # inside both, so this half is not what proves the fix

func _phase_hit_radius_matches_geometry() -> void:
	if phase_frame == 1:
		_isolate()
		# Dead level with the body and moving straight at it, so this measures the
		# radius and nothing else -- no arc, no falling, no glancing angle.
		var at: Vector3 = victim.position + Vector3(NEAR_MISS, 0.0, 0.0)
		_place_ball(at, Vector3(-6.0, 0.0, 0.0))
		recorded["health_before"] = int(victim.health)
		return
	if phase_frame == 3:
		eq(int(victim.health), int(recorded["health_before"]),
			"a ball %.1f m away has not hit yet (real contact is %.1f m)"
				% [NEAR_MISS, SimConfig.BALL_RADIUS + PlayerBody.RADIUS])
		_isolate()
		var at: Vector3 = victim.position + Vector3(CLEAR_HIT, 0.0, 0.0)
		_place_ball(at, Vector3(-6.0, 0.0, 0.0))
		recorded["health_before"] = int(victim.health)
		return
	if phase_frame == 6:
		check(int(victim.health) < int(recorded["health_before"]),
			"but one at %.1f m does -- the radius still has room in it, deliberately"
				% CLEAR_HIT)
		finish()

# --- helpers ------------------------------------------------------------------

# A clean lane with nothing in it. Column x = 6 threads the whole staggered
# arena -- the pillar rows alternate between x 1,4,7,10,13 and x 2,5,8,11, so 6
# is clear in both. An earlier version stood the player in front of a pillar and
# the dash ended on contact before it ever reached the ball.
#
# It also stops the shooters, so a stray ball cannot wander in and take the
# damage assertions for a ride. That they fire at all is already proven.
func _isolate() -> void:
	for ball in world._balls:
		if is_instance_valid(ball):
			ball.queue_free()
	world._balls.clear()
	# Captured once: the second call would otherwise record the empty list the
	# first one left behind, and _place_ball has nowhere to spawn from.
	if not recorded.has("shooters"):
		recorded["shooters"] = world.grid.shooter_cells.duplicate()
	world.grid.shooter_cells.clear()
	# AND THE GUNNERS. This fixture is the PLAYTEST map -- the one place authored
	# for feel rather than for measurement -- so anything added to it for a
	# playtest arrives in here too. A skirmisher was authored into it on
	# 2026-08-14 and immediately failed three assertions in this file, none of
	# which named it: "the dash is running -- expected 1, got 2" was a player
	# being shot mid-dash.
	#
	# Isolating is the right answer rather than moving the enemy: this test needs
	# real shooters, and the map is the only fixture that has them.
	for gunner in world._gunners:
		if is_instance_valid(gunner):
			gunner.queue_free()
	world._gunners.clear()
	world.grid.take_authored_gunner_cells()

	# AND THE SPECIALS, for exactly the same reason: two grenade pickups were
	# authored into the arena on 2026-08-14. A player who walks over one is holding
	# a weapon this test knows nothing about, and a live grenade would move the
	# very body whose displacement is being measured.
	for s in world._specials.all():
		world._specials.destroy(s)
	world.grid.take_authored_special_cells()
	for d in world._deployables:
		if is_instance_valid(d):
			d.queue_free()
	world._deployables.clear()

	victim.position = world.grid.cell_surface_world(Vector2i(6, 20)) + Vector3(0.0, 1.0, 0.0)
	victim.state = PlayerBody.State.WALK
	victim.velocity = Vector3.ZERO
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	victim.shove_cooldown = 0.0
	recorded["move"] = Vector2.ZERO
	recorded["actions"] = 0

func _place_ball(at: Vector3, velocity: Vector3) -> Node:
	world._launch_ball(recorded["shooters"][0])
	var ball: Node = world._balls[world._balls.size() - 1]
	ball.position = at
	ball.linear_velocity = velocity
	ball.hit_cooldown = 0.0
	return ball
