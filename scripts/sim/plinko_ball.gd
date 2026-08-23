extends RigidBody3D

# A plinko ball. Lobbed up the bridge by a shooter, bounces down through the
# pillar field, and arrives back at the party under SimConfig.PLINKO_DRIFT --
# which was the bridge's own pitch until the deck was flattened on 2026-08-23.
#
# THE ONE RIGID BODY IN THE GAME, and the exception proves the rule. Everything
# else uses a hand-written integrator because its behaviour is a DESIGNED rule --
# "a dash into a stone moves it exactly one cell" is a statement about the game,
# not about physics. A rolling ball has no such rule: it is simply a ball, and
# what it does to a player is decided elsewhere, by the world's proximity pass.
#
# The determinism objection in CLAUDE.md does not apply here either. Balls are
# host-authoritative and never predicted (see plinko.md), so no client ever
# replays one and no reconciliation depends on reproducing its path.
#
# Written as a kinematic body first, and it did not work. A CharacterBody3D
# micro-bounces on a shallow slope -- airborne on most ticks, so the gravity that
# should have become roll never got converted -- and it also arrives with
# `floor_stop_on_slope`, a feature whose entire job is to stop a CHARACTER
# sliding down a ramp. Balls landed and sat there, which reads as far too much
# friction and had nothing to do with friction.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

var ball_id: int = 0
var age: float = 0.0

# Stops one ball hitting the same player every tick while resting against them.
var hit_cooldown: float = 0.0

func _ready() -> void:
	# The engine's default gravity is 9.8; the game's is 24 (see SimConfig), and
	# a ball that fell at a different rate to everything else would read as
	# floating.
	gravity_scale = SimConfig.GRAVITY / 9.8
	linear_damp = SimConfig.PLINKO_ROLL_DRAG
	continuous_cd = true          # a fast ball must not tunnel a parapet
	# DOWN-BRIDGE, FOREVER. Up-bridge is -Z, so this pushes the ball back at the
	# party -- which is what the four-degree tilt did for every loose object on the
	# deck until 2026-08-23, and what only a ball ever wanted. A force rather than
	# an acceleration, so it is scaled by the ball's own mass and a heavier ball
	# does not drift faster than a light one.
	constant_force = Vector3(0.0, 0.0, SimConfig.PLINKO_DRIFT * mass)

# Bookkeeping only. The physics server moves the ball; this just ages it.
func step() -> void:
	age += SimConfig.TICK_DELTA
	hit_cooldown = maxf(0.0, hit_cooldown - SimConfig.TICK_DELTA)

func launch(from: Vector3, direction: Vector3) -> void:
	position = from
	linear_velocity = direction * SimConfig.PLINKO_LAUNCH_SPEED
	angular_velocity = Vector3.ZERO
	age = 0.0

# Batted away by a dashing player. No damage, and the dash carries on.
func deflect(direction: Vector3) -> void:
	linear_velocity = direction * SimConfig.PLINKO_DEFLECT_SPEED
	linear_velocity.y = maxf(linear_velocity.y, 2.0)
	hit_cooldown = SimConfig.PLINKO_HIT_COOLDOWN

# A BALL IS MOVED BY EVERYTHING AND DESTROYED BY NOTHING. It is the archetypal
# deflectable threat -- hazards.md's whole "deflectable versus destructible" split
# starts here -- so no kind of hit removes one; they only argue with it.
#
# IMPACT sets a velocity, because a dash is a player DECIDING where that ball
# goes. Everything else adds an impulse, because a round or a blast only pushes
# whatever it was already doing.
func receive_hit(hit) -> bool:
	if hit.kind == Hit.Kind.IMPACT:
		deflect(hit.direction_to(position))
		return true
	apply_central_impulse(hit.direction_to(position) * hit.push)
	return true

func is_spent() -> bool:
	return age > SimConfig.PLINKO_BALL_LIFETIME or position.y < SimConfig.FALL_KILL_Y

# Clients do not simulate balls -- they are told where they are. Freezing stops
# the client's own physics fighting the snapshot that overwrites it.
func set_simulated(simulated: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not simulated

func capture_state() -> Array:
	return [position, linear_velocity, age, hit_cooldown]

func apply_state(s: Array) -> void:
	position = s[0]
	linear_velocity = s[1]
	age = float(s[2])
	hit_cooldown = float(s[3])
