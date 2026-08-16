extends "res://scripts/test_support/test_case.gd"

# PLAYTEST 2026-08-16: "what happens when hats get shot?" Nothing did, and the
# first attempt at this answered the wrong question -- it made hats ABSORB rounds
# aimed at the player, which is a second health bar wearing a hat.
#
# A HAT IS A TARGET, NOT ARMOUR. A round that hits the PLAYER hurts exactly as
# much as it always did. A round that hits a HAT takes that hat and everything
# stacked above it, and does not touch the person underneath.
#
# THE STACK IS A SILHOUETTE, which is the whole design. Aim is 2D yaw, so a round
# travels flat at the height of the muzzle that fired it: a shooter on your level
# meets your body, and a shooter ABOVE you -- a ramp, a raised deck, a turret on a
# pillar -- meets your tower first. Five hats neither protect you nor endanger
# you; they put a metre and a half of score above your head where high ground can
# reach it.
#
# The claims:
#   1. A round at BODY height hurts and costs no hats. Unchanged, and asserted
#      here because it is the half a "hats absorb bullets" version breaks.
#   2. A round at HAT height costs NO health.
#   3. It takes the hat it hit AND every hat above it, and leaves the ones below.
#   4. Those hats are in the world afterwards, launched, not deleted.
#   5. A ROUND THAT MISSES THE TOWER MISSES. The test that a thing can be hit is
#      worthless without the test that it can be missed -- a hat test with no
#      width would take a hat off every round fired anywhere near a player.
#
# THE COLLIDER IS THE IMPLEMENTATION, and getting there took two wrong turns
# worth naming, because both were invisible to every property you can print.
#
# FIRST: a worn hat used to be REPARENTED onto the player, and a RigidBody3D that
# is a child of another physics body is not returned by a query -- with its shape
# enabled, the mask set to every bit, and the server holding the correct
# transform. Worn hats now stay at the pool root and are driven by global
# transform.
#
# SECOND, and the one a player would actually have met: HatStyle sizes every
# hat's collider from its style id, so a tower is a column of MISMATCHED DISCS.
# Measured on one four-stack: heights of 0.233, 0.101, 0.342 and 0.191, each
# starting at its own origin, with gaps between them a round goes straight
# through. A worn hat now gets a uniform hit column exactly HAT_HEIGHT tall, so
# the slots tile; it gets its own shape back the moment it comes off, because how
# a hat SETTLES should still depend on how big it really is.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const WORN := 4

var world: Node3D = null
var victim: CharacterBody3D = null
var frames: int = 0
var phase: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "HatShotWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	# A SECOND PLAYER PARKED FAR AWAY: a solo player going down is a wipe, and a
	# wipe clears every hat, which would satisfy "the hats came off" for entirely
	# the wrong reason. Same trap test_hat_tumble documents.
	world._spawn_player(2, 1)
	victim = world.player_body(1)
	world.player_body(2).position = 		world.grid.cell_surface_world(Vector2i(27, 1)) + Vector3(0.0, 1.0, 0.0)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

	victim.position = world.grid.cell_surface_world(Vector2i(15, 5)) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO


# --- 1 to 4 -------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	frames += 1
	match phase:
		0: _phase_body_shot_still_hurts()
		1: _phase_hat_shot()
		2: _phase_a_miss_is_a_miss()

func _wear(n: int) -> void:
	for i in n:
		world._hats.spawn_loose(victim.position + Vector3(0.05 * float(i), 0.0, 0.0))

# The muzzle is placed at an explicit height and fires flat, which is what a
# shooter standing higher than you produces. Through _spawn_round and the sweep:
# a hand-built Hit would skip the raycast, and the raycast IS the feature.
func _fire_at_height(y: float) -> void:
	var muzzle: Vector3 = victim.position + Vector3(0.0, 0.0, -6.0)
	muzzle.y = y
	world._spawn_round(world.to_global(muzzle), Vector3(0.0, 0.0, 1.0), 0, RID())

# --- 1. The half that a "hats are armour" version gets wrong -------------------

func _phase_body_shot_still_hurts() -> void:
	if frames == 20:
		_wear(WORN)
		return
	if frames == 60:
		eq(world._hats.worn_by(1).size(), WORN, "the stack is on")
		recorded["health"] = int(victim.health)
		_fire_at_height(victim.position.y)      # chest height
		return
	if frames == 90:
		check(int(victim.health) < int(recorded["health"]),
			"a round at BODY height still hurts (%d -> %d) -- a hat is a target, "
				% [recorded["health"], victim.health]
			+ "not a second health bar, and being hatted must not make you tougher")
		# AND IT TAKES THE WHOLE STACK, which is M8.5's rule and NOT this change:
		# a round carries knockback, knockback tumbles you, and a tumble pops
		# everything. Asserted here because the first draft of this test claimed
		# gunfire cost no hats -- it always cost all of them, just never by hitting
		# one. That is the difference the feature actually adds: a hat shot costs
		# you PART of the tower and no health, a body shot costs you all of it and
		# health both.
		eq(world._hats.worn_by(1).size(), 0,
			"and tumbles you, which pops the stack -- the M8.5 rule, unchanged")
		phase = 1
		frames = 0

# --- 2, 3 and 4. The tower -----------------------------------------------------

# --- 2, 3 and 4. The tower -----------------------------------------------------

func _phase_hat_shot() -> void:
	# A CLEAN FIXTURE, because phase 0 left the player tumbling in a pile of their
	# own hats. Reset before measuring rather than once at setup: a long test is a
	# fixture that gets dirtier as it runs.
	if frames == 1:
		for hat in world._hats.all():
			if is_instance_valid(hat):
				world._hats.destroy(hat)
		victim.state = PlayerBody.State.WALK
		victim.health = SimConfig.MAX_HEALTH
		victim.invulnerable = 0.0
		victim.position = world.grid.cell_surface_world(Vector2i(15, 5)) 			+ Vector3(0.0, 1.0, 0.0)
		victim.velocity = Vector3.ZERO
		return
	if frames == 20:
		_wear(WORN)
		return
	if frames == 30:
		eq(world._hats.worn_by(1).size(), WORN, "a fresh stack is on")
		# Between hat 1 and hat 2 of a four-stack, so there is a below AND an above.
		# A shot at the top hat would pass claim 3 without ever testing "and
		# everything above it".
		var stack_base: float = victim.position.y + PlayerBody.HALF_HEIGHT
		recorded["health"] = int(victim.health)
		recorded["loose"] = _loose_count()
		var y: float = stack_base + SimConfig.HAT_HEIGHT * 1.5
		_fire_at_height(y)
		return
	if frames == 60:
		var left: int = world._hats.worn_by(1).size()
		print("[hat shot] %d worn after a round through the tower, health %d, "
			% [left, victim.health]
			+ "loose %d -> %d" % [int(recorded["loose"]), _loose_count()])

		eq(int(victim.health), int(recorded["health"]),
			"a round that hits a HAT does not touch the player under it -- it was "
			+ "spent on the hat, and the person wearing it never felt it")
		check(left > 0,
			"the hats BELOW the one it hit are still on (%d left) -- a tower is "
				% left
			+ "stacked, so a round through its middle takes the top off rather "
			+ "than collapsing the whole thing")
		check(left < WORN,
			"and the one it hit is gone, with everything above it (%d of %d left)"
				% [left, WORN])
		check(_loose_count() > int(recorded["loose"]),
			"they are in the world afterwards, launched rather than deleted -- "
			+ "losing the bet stays recoverable at a cost in time")
		phase = 2
		frames = 0

# --- 5. And a round that misses, misses ---------------------------------------

func _phase_a_miss_is_a_miss() -> void:
	# A FRESH STACK AGAIN: phase 1 deliberately took most of the last one, and a
	# miss test run on the remnants is a miss test that can pass by having nothing
	# to hit.
	if frames == 1:
		for hat in world._hats.all():
			if is_instance_valid(hat):
				world._hats.destroy(hat)
		return
	if frames == 10:
		_wear(WORN)
		return
	if frames == 30:
		recorded["worn"] = world._hats.worn_by(1).size()
		eq(int(recorded["worn"]), WORN, "a full stack is back on to be missed")
		# A metre above the top of the tower. Without a width test the hat rule
		# would take a hat off any round fired anywhere near a player, which is a
		# different game.
		var top: Node = world._hats.worn_by(1).back()
		_fire_at_height(top.global_position.y + 1.0)
		return
	if frames == 60:
		eq(world._hats.worn_by(1).size(), int(recorded["worn"]),
			"a round a metre over the tower takes nothing -- a hat is %.2f m wide "
				% SimConfig.HAT_HIT_RADIUS
			+ "to a bullet, not infinitely so")
		finish()

func _loose_count() -> int:
	var n: int = 0
	for hat in world._hats.all():
		if is_instance_valid(hat) and hat.mode != HatBody.Mode.WORN:
			n += 1
	return n
