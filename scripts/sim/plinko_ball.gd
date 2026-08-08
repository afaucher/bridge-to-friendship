extends CharacterBody3D

# A plinko ball. Lobbed up the bridge by a shooter, bounces down through the
# pillar field, and arrives back at the party under the bridge's own pitch.
#
# Simulated with the same hand-written integrator as everything else rather than
# handed to a rigid-body solver: what a ball does when it hits a player is a
# designed rule, and CLAUDE.md records that Godot's solver is not deterministic
# run to run anyway.
#
# NOTHING PUSHES IT DOWN THE BRIDGE. The whole deck is pitched 4 degrees, so a
# ball that lands anywhere rolls back toward the players on its own. That is what
# the pitch is for.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

var ball_id: int = 0
var age: float = 0.0

# Stops one ball hitting the same player every tick while resting against them.
var hit_cooldown: float = 0.0

func step() -> void:
	var dt := SimConfig.TICK_DELTA
	age += dt
	hit_cooldown = maxf(0.0, hit_cooldown - dt)

	velocity.y -= SimConfig.GRAVITY * dt

	# Proportional drag on the horizontal only. Against gravity along the deck's
	# pitch this settles to a roll a player can outwalk -- see PLINKO_ROLL_DRAG.
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	horizontal -= horizontal * SimConfig.PLINKO_ROLL_DRAG * dt
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	move_and_slide()

	# Bounce off whatever it meets -- deck, parapet, pillar. Cylinder pillars
	# deflect smoothly from any approach angle, which is why they are cylinders:
	# a box corner jams a ball, and a stuck ball is a dead ball.
	for i in get_slide_collision_count():
		var normal := get_slide_collision(i).get_normal()
		if velocity.dot(normal) < 0.0:
			velocity = velocity.bounce(normal) * SimConfig.PLINKO_BOUNCE

func launch(from: Vector3, direction: Vector3) -> void:
	position = from
	velocity = direction * SimConfig.PLINKO_LAUNCH_SPEED
	age = 0.0

# Batted away by a dashing player. No damage, and the dash carries on.
func deflect(direction: Vector3) -> void:
	velocity = direction * SimConfig.PLINKO_DEFLECT_SPEED
	velocity.y = maxf(velocity.y, 2.0)
	hit_cooldown = SimConfig.PLINKO_HIT_COOLDOWN

func is_spent() -> bool:
	return age > SimConfig.PLINKO_BALL_LIFETIME or position.y < SimConfig.FALL_KILL_Y

func capture_state() -> Array:
	return [position, velocity, age, hit_cooldown]

func apply_state(s: Array) -> void:
	position = s[0]
	velocity = s[1]
	age = float(s[2])
	hit_cooldown = float(s[3])
