extends "res://scripts/test_support/test_case.gd"

# MVP criterion B3b: anything standing on another sim body is CARRIED by it.
# From the rider's point of view the thing underneath is not moving.
#
# Godot does not provide this. CharacterBody3D inherits platform motion only from
# bodies the physics server tracks as platforms, so one CharacterBody3D standing
# on another is simply left behind as the lower one walks out from under it.
# Since we own the integrator, the transport is explicit -- and it needs carriers
# to step BEFORE their riders, or a rider inherits last tick's motion and visibly
# slides around on its friend's head.
#
# It also watches for JITTER and CREEP. The failure mode to fear with a stacked
# pair is not "falls through" but "vibrates" or "drifts", which a single-frame
# assertion would happily pass while the move stayed unusable.
#
# The world runs its OWN host tick here rather than the test stepping bodies by
# hand -- that is the code path the game uses, carry order and all.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const BODY_HEIGHT := 1.8
const REST_Y := 0.9
const STACKED_Y := REST_Y + BODY_HEIGHT
const SETTLE_TICKS := 120
const WALK_TICKS := 180

var world: Node3D = null
var lower: CharacterBody3D = null
var upper: CharacterBody3D = null
var frame: int = 0
var settled_offset: Vector3 = Vector3.ZERO
var worst_slip: float = 0.0
var worst_wobble: float = 0.0
var carried_ticks: int = 0
var settled: bool = false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "RideWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)          # the gym: flat, uncomplicated ground

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	lower = world.player_body(1)
	upper = world.player_body(2)

	lower.position = Vector3(0.0, REST_Y, 0.0)
	# Dropped from above rather than placed at the resting height: landing on a
	# flat top is part of what is being tested, and a body positioned into place
	# would pass without ever proving it. The cylinder collider exists for this
	# -- a capsule's domed cap slides a landing body straight off.
	upper.position = Vector3(0.0, 4.0, 0.0)

	# The lower player walks east once the stack has settled. The rider is given
	# NO input at all, so every metre it covers is transport.
	world.scripted_inputs[1] = func(t: int) -> Array:
		var move := Vector2(1.0, 0.0) if t > SETTLE_TICKS else Vector2.ZERO
		return PlayerInput.make(t, move, 0)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if upper == null or world.tick == 0:
		return
	frame = world.tick

	if frame == SETTLE_TICKS:
		settled = true
		near(upper.position.y, STACKED_Y, 0.12,
			"the upper player comes to rest on top of the lower one (y = %.3f)" % upper.position.y)
		check(upper.grounded, "and reports standing on a floor")
		eq(upper.carrier, lower, "and knows the lower player is carrying it")
		eq(lower.carrier, null, "while the lower one is carried by nothing (deck is not a rider)")
		settled_offset = upper.position - lower.position

	elif settled and frame > SETTLE_TICKS:
		if upper.carrier == lower:
			carried_ticks += 1
		var offset := upper.position - lower.position
		# What "carried" MEANS, measured: the rider holds its position relative
		# to its carrier. Slipping is that offset drifting horizontally.
		worst_slip = maxf(worst_slip, Vector2(offset.x - settled_offset.x, offset.z - settled_offset.z).length())
		worst_wobble = maxf(worst_wobble, absf(offset.y - settled_offset.y))

		if frame >= SETTLE_TICKS + WALK_TICKS:
			check(lower.position.x > 5.0,
				"the lower player actually walked somewhere (%.2f m)" % lower.position.x)
			check(upper.position.x > 5.0,
				"and the rider came along (%.2f m)" % upper.position.x)
			check(worst_slip < 0.25,
				"the rider does not slide off its carrier (worst slip %.4f m)" % worst_slip)
			check(worst_wobble < 0.10,
				"and the stack does not jitter vertically (worst %.4f m)" % worst_wobble)
			check(carried_ticks > WALK_TICKS - 20,
				"the carry relationship held for the whole walk (%d of %d ticks)"
					% [carried_ticks, WALK_TICKS])
			finish()
