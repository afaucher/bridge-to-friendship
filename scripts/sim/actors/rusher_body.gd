extends "res://scripts/sim/actors/rising_enemy.gd"

# A rusher. It rises out of an authored mound, runs straight at the nearest
# player, tumbles whoever it reaches, and burrows back down if it never reaches
# anyone. See design_ideas/hazards.md.
#
# THE FIRST DESTRUCTIBLE THING IN THE GAME. Everything hostile so far has been
# deflectable -- a ball is batted away, a stone is pushed a cell, a player is
# launched -- and nothing could be REMOVED. That made the ranged specials weak by
# construction: a shotgun was a shove you could do from further away, and the
# shove is free. A rusher is postponed by the base verbs and ended only by a
# weapon, which is what earns that whole category its slot.
#
# NO PATHFINDING, and that is the entire reason this was affordable. Spiders need
# patrol states, aggro and a route; a rusher needs a direction. It walks the
# straight line to its target and takes whatever that line runs into -- including
# straight off the edge of the bridge, which is not an oversight but the cheapest
# tool a weaponless player has.
#
# A CharacterBody3D like the player, not a RigidBody3D like a ball: what it does
# is a DESIGNED RULE ("runs at you at 8 m/s"), not physics. See plinko_ball.gd for
# the other side of that line.

const Corpse = preload("res://scripts/present/vfx/corpse.gd")

enum State {
	RISE,       # emerging. The telegraph. Cannot touch you, cannot be hurt by you
	CHASE,      # running at the target
	STAGGER,    # deflected by a dash; gets back up
}

# The network id, under the name everything outside this file has always used.
var rusher_id: int:
	get: return id
	set(value): id = value

# `age` is total time since it broke the surface, INCLUDING the rise -- one clock
# rather than two, because the rise is a tenth of the budget and the player
# experiences it as one appearance. `target_peer` is host-decided every tick; a
# client is told the answer and invents nothing. Both live on RisingEnemy.
#
# Its mask includes its own layer -- see the CLAUDE.md note on self-bits. Set in
# the scene; asserted by test_rusher and test_layers.

func _rise_height() -> float:
	return SimConfig.RUSHER_HEIGHT

func _rise_seconds() -> float:
	return SimConfig.RUSHER_RISE_SECONDS

func _risen_state() -> int:
	return State.CHASE

# Burrows back down. The floor under a weaponless player -- outliving one is
# desperate, but it is always available and it is why no player is ever stranded.
func _lifetime() -> float:
	return SimConfig.RUSHER_LIFETIME

func corpse_kind() -> int:
	return Corpse.Kind.RUSHER

# Advance one tick. Same contract as PlayerBody.step(): no delta argument,
# because move_and_slide() reads the physics frame's delta and the sim tick and
# the physics tick are the same duration.
func step(target: Vector3, has_target: bool) -> void:
	age += SimConfig.TICK_DELTA
	state_timer += SimConfig.TICK_DELTA

	match state:
		State.RISE:
			_step_rise()
		State.CHASE:
			_step_chase(target, has_target)
		State.STAGGER:
			_step_stagger()

# The rise (RisingEnemy._step_rise) is straight up out of the ground, on rails.
# Deliberately NOT physics: it is a telegraph with a promised duration, and a
# telegraph whose length depends on what it collided with is not a promise.

# How fast it actually moves this tick. A PERCENTAGE of the shipped constant, so
# the console reads "50" rather than "4.0" and a playtest report says something
# about the value in sim_config.gd rather than about a number nobody can place.
#
# Read per tick rather than cached: the knob is replicated and applied on a tick
# boundary, so a rusher mid-chase picks up a change the moment the host does.
func _speed() -> float:
	return SimConfig.RUSHER_SPEED 		* DebugSettings.tuned("rusher_speed_pct", 100.0) * 0.01

func _step_chase(target: Vector3, has_target: bool) -> void:
	var toward := Vector3.ZERO
	if has_target:
		# Flattened: it runs ALONG the deck at a target that may be above or
		# below it. Keeping the Y component would have it trying to walk into
		# the air at anyone standing on a stone.
		toward = Vector3(target.x - position.x, 0.0, target.z - position.z)
	if toward.length_squared() > 0.0001:
		toward = toward.normalized()
		var speed: float = _speed()
		velocity.x = toward.x * speed
		velocity.z = toward.z * speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	_apply_gravity_and_move()

# Knocked back and briefly out of it. Friction rather than a hard stop, so a
# deflection reads as a thing that happened to it rather than a state flag.
func _step_stagger() -> void:
	# NOT scaled by the speed knob. This is the friction that bleeds off a
	# DEFLECTION, and a deflection's distance is the dash's doing, not the
	# rusher's -- slowing the chase should not also make a batted rusher slide
	# further, which would change what winning the dash is worth.
	velocity.x = move_toward(velocity.x, 0.0, SimConfig.RUSHER_SPEED * SimConfig.TICK_DELTA)
	velocity.z = move_toward(velocity.z, 0.0, SimConfig.RUSHER_SPEED * SimConfig.TICK_DELTA)
	_apply_gravity_and_move()
	if state_timer >= SimConfig.RUSHER_STAGGER_SECONDS:
		state = State.CHASE
		state_timer = 0.0

# Batted away by a dashing player. Deflected and staggered -- NOT killed. That is
# the destructible/deflectable split staying clean: if a dash ended a rusher, the
# weapons would have no exclusive job and the whole category loses its reason to
# exist. Flagged [open] in hazards.md against playtest.
func deflect(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	velocity = flat.normalized() * SimConfig.RUSHER_DEFLECT_SPEED
	velocity.y = 3.0
	state = State.STAGGER
	state_timer = 0.0
	grounded = false

# Is it in play at all -- can it be touched, in either direction? A RISING rusher
# cannot: the telegraph would be a lie if the thing could hit you, OR be batted
# away, while it was still announcing itself.
#
# SEPARATE FROM is_dangerous() ON PURPOSE, and folding the two back together
# would reintroduce a bug. A staggered rusher is still deflectable -- a dash lasts
# six ticks and re-deflects it on each one, which is what carries it clear -- but
# it can no longer hurt anyone. One predicate cannot answer both questions, and
# when it tried, making it safe also made it unbattable and the player simply
# bulldozed it around with their body instead.
func is_in_play() -> bool:
	return state != State.RISE

# Can it HURT you? Only while it is CHASING.
#
# A STAGGERED one cannot, and it USED TO -- which made the dash a counter
# that lost. Measured 2026-08-13 from a playtest report of "winning the dash
# still tumbles you and drops your hats", and the numbers are the whole argument:
# a dash is SHOVE_DURATION (0.1 s, six ticks) and the stagger it buys is
# RUSHER_STAGGER_SECONDS (2.0 s, a hundred and twenty). So the player deflected
# it, left SHOVE six ticks later, and then walked into a thing that was still
# lethal -- and could not deflect it again, because SHOVE_COOLDOWN (0.35 s)
# expires long after the contact. That is a 1.65 s window in which the counter
# had been spent, could not be repeated, and the deflected rusher tumbled you
# anyway, took a hit point, spilled your hat stack and expended itself.
#
# hazards.md sells the dash as "deflected and staggered, buying
# RUSHER_STAGGER_SECONDS". It was buying 0.1 s. A stagger is now the breather it
# was always described as.
func is_dangerous() -> bool:
	return state == State.CHASE

# ENDED RATHER THAN POSTPONED, which a round is the only WEAPON that manages --
# the reason the weapon-special category earns a slot at all; see hazards.md: a
# dash deflects, a timer outlasts, a round removes. DEFLECTED BY A BODY, ENDED BY
# A WEAPON is EnemyBody.receive_hit plus RisingEnemy.receive_impact.
#
# `killed` has a second setter: the rusher itself, spending its body on a player
# it reached. Both are ENDINGS, which is what the flag distinguishes from a burrow
# or a fall. It is a flag rather than an immediate free because the pool walks its
# list once per tick; a rusher that vanished mid-iteration would be a freed object
# still in an array being read.

# Clients are TOLD where a rusher is; they never simulate one. Same as a ball.
func capture_state() -> Array:
	return [id, position, state, target_peer]

func apply_state(s: Array) -> void:
	position = s[1]
	state = int(s[2])
	target_peer = int(s[3])
