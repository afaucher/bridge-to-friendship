extends CharacterBody3D

# A zombie. It claws out of an authored grave IN A PACK, closes on the nearest
# player in threes and ones, bites whoever it reaches, and rots away if it never
# reaches anyone. See design_ideas/hazards.md.
#
# WHAT IT IS FOR, stated against the enemy beside it: a rusher is one straight
# line at one player, so it is answered by MOVING SIDEWAYS, and that answer is the
# same everywhere on the bridge. A pack cannot be answered by moving sideways,
# because sideways is where the next one is. It asks for GROUND instead -- a
# chokepoint, a pillar at your back, a blast spent early -- which is a decision
# about the level rather than a reflex, and nothing in the game asked for that
# before.
#
# THREES AND ONES. Every move is a COMMITMENT: a heading picked once at the moment
# the move starts, then held until a fixed distance has been covered. It does not
# re-aim mid-move, and that is deliberate rather than cheap.
#
#     a ONE   -- a shuffle, 60 degrees off the line to you, one step
#     a THREE -- a lunge, 20 degrees off that line, three steps
#
# Even odds, and a fresh coin for which side it leans. Both angles are inside a
# right angle, so every move still closes the distance -- it arrives, it just
# never arrives from a direction you could have predicted.
#
# THE COMMITMENT IS THE COUNTERPLAY, and it is where the free answer for a
# weaponless player comes from. Three steps of held heading is three metres of
# travel that has already been decided, so a player who stands with a hole behind
# them is inviting a lunge to finish somewhere there is no deck. That is not a
# rule anybody wrote; it falls out of the walk, and it is the reason the walk
# commits.
#
# A CharacterBody3D like the rusher and the player, not a RigidBody3D: what it
# does is a designed rule, not physics. See plinko_ball.gd for the other side of
# that line.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

enum State {
	RISE,       # clawing out. The telegraph: cannot touch you, cannot be touched
	WALK,       # threes and ones
	RECOVER,    # it bit someone and was knocked back off them
	STAGGER,    # deflected by a dash
}

# THE WIRE DISCRIMINATOR for a move, and the reason it is an enum rather than a
# bool: a client is told which one is running so the mesh can lean into a lunge,
# and "is_lunging" would have had to grow a second flag the day a third move
# exists.
enum Move { SHUFFLE, LUNGE }

var zombie_id: int = 0
var state: int = State.RISE
var state_timer: float = 0.0

# Total time since it broke the surface, INCLUDING the rise -- one clock, same as
# the rusher's, because the player experiences it as one appearance.
var age: float = 0.0

# Host-decided every tick. A client is told the answer and invents nothing.
var target_peer: int = 0

var grounded: bool = false

# --- The move in progress -----------------------------------------------------
#
# A heading and a budget. `_travelled` is measured against the FLAT distance the
# body actually covered, not against elapsed time, so a zombie that spends half a
# lunge grinding on a pillar does not silently finish the lunge standing still --
# it is still owed the ground, and it keeps pushing until it gets it or the move
# is abandoned.

var move_kind: int = Move.SHUFFLE
var _heading: Vector3 = Vector3.ZERO
var _budget: float = 0.0
var _travelled: float = 0.0
var _last_position: Vector3 = Vector3.ZERO

# A MOVE HAS TO BE ABLE TO GIVE UP. Distance-budgeted is right for the common case
# and wrong for exactly one: a zombie pressed against a wall covers no ground, so
# a pure distance budget never expires and it grinds there forever -- which is the
# "visibly stuck" failure the rusher's sight test exists to avoid. The clock is
# the backstop, set well past the honest duration of the longest move.
const MOVE_TIMEOUT := 2.5

# ITS OWN RNG, NEVER THE GLOBAL ONE. Two reasons, and the second is the one that
# matters. Determinism: the global RNG is seeded once per launch and shared with
# everything else in the process, so a test asserting anything about the
# distribution of moves would be asserting a property of whatever else happened to
# roll that frame. And independence: a pack rising from one grave in one tick
# would otherwise draw consecutive values from one stream, which is exactly how
# five zombies end up performing the same choreography.
var _rolls: int = 0

# Where the deck was when it woke: the rise animates from ZOMBIE_HEIGHT below this
# to standing on it.
var _emerge_from: Vector3 = Vector3.ZERO

func _ready() -> void:
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

func begin_rise(at: Vector3) -> void:
	position = at - Vector3(0.0, SimConfig.ZOMBIE_HEIGHT, 0.0)
	_emerge_from = at
	velocity = Vector3.ZERO
	state = State.RISE
	state_timer = 0.0
	age = 0.0
	_last_position = position
	_facing_from = position

# Advance one tick. Same contract as PlayerBody.step() and RusherBody.step(): no
# delta argument, because move_and_slide() reads the physics frame's delta and a
# sim tick and a physics tick are the same duration.
func step(target: Vector3, has_target: bool) -> void:
	age += SimConfig.TICK_DELTA
	state_timer += SimConfig.TICK_DELTA

	match state:
		State.RISE:
			_step_rise()
		State.WALK:
			_step_walk(target, has_target)
		State.RECOVER:
			_step_settling(SimConfig.ZOMBIE_RECOVER_SECONDS)
		State.STAGGER:
			_step_settling(SimConfig.ZOMBIE_STAGGER_SECONDS)

# Straight up out of the ground on rails, exactly like a rusher's, and for the
# identical reason: a telegraph whose length depends on what it collided with on
# the way up is not a promise.
func _step_rise() -> void:
	var t: float = clampf(state_timer / SimConfig.ZOMBIE_RISE_SECONDS, 0.0, 1.0)
	position = _emerge_from - Vector3(0.0, SimConfig.ZOMBIE_HEIGHT * (1.0 - t), 0.0)
	velocity = Vector3.ZERO
	if t >= 1.0:
		state = State.WALK
		state_timer = 0.0
		_last_position = position
		_budget = 0.0
		_travelled = 0.0

# How fast this move goes. A PERCENTAGE of the shipped constant, the same shape
# the rusher's knob has, so a playtest report says something about the value in
# sim_config.gd rather than about a number nobody can place.
func _speed() -> float:
	var base: float = SimConfig.ZOMBIE_LUNGE_SPEED if move_kind == Move.LUNGE \
		else SimConfig.ZOMBIE_SHUFFLE_SPEED
	return base * DebugSettings.tuned("zombie_speed_pct", 100.0) * 0.01

func _step_walk(target: Vector3, has_target: bool) -> void:
	if not has_target:
		# STANDS THERE, exactly like a rusher with nobody in sight. Wandering would
		# need a search behaviour, and a search behaviour is the pathfinding this
		# whole family of enemies bought its way out of.
		velocity.x = move_toward(velocity.x, 0.0, SimConfig.ZOMBIE_SHUFFLE_SPEED * SimConfig.TICK_DELTA)
		velocity.z = move_toward(velocity.z, 0.0, SimConfig.ZOMBIE_SHUFFLE_SPEED * SimConfig.TICK_DELTA)
		_budget = 0.0
		_apply_gravity_and_move()
		return

	# Ground covered since the last tick, FLAT. Measured rather than integrated
	# from velocity, because the two disagree the moment anything is in the way --
	# and it is precisely the blocked case that a budget has to get right.
	var moved := Vector3(position.x - _last_position.x, 0.0, position.z - _last_position.z)
	_travelled += moved.length()
	_last_position = position

	if _travelled >= _budget or state_timer >= MOVE_TIMEOUT:
		_begin_move(target)

	var speed: float = _speed()
	velocity.x = _heading.x * speed
	velocity.z = _heading.z * speed
	_apply_gravity_and_move()

# PICK ONE. Fifty-fifty between a three and a one, and a fresh coin for the side.
#
# The heading is taken from where the target is RIGHT NOW and then frozen: this is
# the only line in the file that reads the target's position during a move, and
# that is the commitment the whole design rests on.
func _begin_move(target: Vector3) -> void:
	var toward := Vector3(target.x - position.x, 0.0, target.z - position.z)
	if toward.length_squared() < 0.0001:
		# Standing on top of them. Any heading is as good as any other and none of
		# them is meaningful, so keep the last one rather than normalising a zero.
		toward = _heading if _heading.length_squared() > 0.0001 else Vector3(0.0, 0.0, 1.0)
	toward = toward.normalized()

	var lunging: bool = _draw() < SimConfig.ZOMBIE_LUNGE_CHANCE
	# A fresh coin, INDEPENDENT of the one above -- one draw used for both would
	# make every lunge go left and every shuffle go right.
	var side: float = 1.0 if _draw() < 0.5 else -1.0

	move_kind = Move.LUNGE if lunging else Move.SHUFFLE
	var degrees: float = SimConfig.ZOMBIE_LUNGE_DEG if lunging else SimConfig.ZOMBIE_SHUFFLE_DEG
	var steps: int = SimConfig.ZOMBIE_LUNGE_STEPS if lunging else SimConfig.ZOMBIE_SHUFFLE_STEPS

	# ROTATED ABOUT Y, WHICH IS THE ONLY AXIS THAT MEANS ANYTHING HERE. `toward` is
	# already flat, so this stays flat -- and it goes through Vector3.rotated
	# rather than being rebuilt from sin/cos, which is the sign error CLAUDE.md
	# records this project shipping four times.
	_heading = toward.rotated(Vector3.UP, deg_to_rad(degrees) * side)
	_budget = SimConfig.ZOMBIE_STEP * float(steps)
	_travelled = 0.0
	state_timer = 0.0

# A 0..1 draw off this zombie's own stream. Salted with the id so two zombies
# rising in the same tick do not walk in step.
func _draw() -> float:
	_rolls += 1
	return float(_mix(zombie_id * 8191 + _rolls * 7919) % 10000) / 9999.0

static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)

# Knocked back and briefly out of it -- shared by RECOVER (it bit somebody) and
# STAGGER (somebody dashed it). Friction rather than a hard stop, so being knocked
# off reads as a thing that happened to it rather than a state flag.
func _step_settling(duration: float) -> void:
	# NOT scaled by the speed knob, for the same reason the rusher's stagger is
	# not: this friction bleeds off a KNOCKBACK, whose distance belongs to whatever
	# delivered it. Slowing the walk should not also make a deflected zombie slide
	# further, which would quietly change what winning a dash is worth.
	var drag: float = SimConfig.ZOMBIE_LUNGE_SPEED * SimConfig.TICK_DELTA
	velocity.x = move_toward(velocity.x, 0.0, drag)
	velocity.z = move_toward(velocity.z, 0.0, drag)
	_apply_gravity_and_move()
	_last_position = position
	if state_timer >= duration:
		state = State.WALK
		state_timer = 0.0
		# NO BUDGET LEFT, so the next walk tick picks a fresh move. Resuming the
		# move it was interrupted mid-way through would have it finish a lunge at
		# somebody who has since walked off, which is the stale-heading bug the
		# commitment is supposed to be worth living with, not one to invent.
		_budget = 0.0
		_travelled = 0.0

func _apply_gravity_and_move() -> void:
	if grounded:
		# The same trick as the player and the rusher: a small downward push while
		# grounded, because velocity.y == 0 does not reliably produce a floor
		# collision and everything keyed off `grounded` then flickers with it.
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()
	_face_travel()

# WHICH WAY IT IS POINTING, DERIVED FROM WHERE IT WENT -- on the host and on every
# client independently, from each machine's own position history.
#
# It is derived rather than sent because it costs nothing to derive and a float per
# zombie per tick is not nothing: a pack of sixteen at 60 Hz is real MTU, and
# CLAUDE.md already records this project overrunning ENet's 1392 bytes once.
#
# THE THING THAT MAKES DERIVING IT SAFE is that facing has no consequences. A
# client that disagrees by a frame draws the arms a few degrees off; nothing reads
# `rotation`, no hit test uses it, and the collider is a cylinder, which is
# rotationally symmetric about the only axis this turns on. Contrast the elevator
# in CLAUDE.md, which was derived from the tick and WAS load-bearing -- the
# question to ask of any derived quantity is what breaks when the two ends
# disagree, and here the answer is honestly nothing.
func _face_travel() -> void:
	var moved := Vector3(position.x - _facing_from.x, 0.0, position.z - _facing_from.z)
	_facing_from = position
	# A DEAD ZONE, not an epsilon. Below a real step the delta is depenetration
	# noise, and turning to face noise is a body that spins on the spot while it
	# stands still -- which is the flicker CLAUDE.md's FLOOR_STICK note describes
	# one layer down.
	if moved.length_squared() < 0.0004:
		return
	# THROUGH GridConfig, NOT sin/cos BY HAND. This project has shipped four sign
	# errors out of hand-built direction vectors and CLAUDE.md names every one of
	# them; yaw_of_vector is the same definition the player's facing uses, so the
	# arms point the way a nose does.
	var want: float = GridConfig.yaw_of_vector(moved)
	# Smoothed, and through lerp_angle so it turns the short way round rather than
	# unwinding the long way past pi.
	rotation.y = lerp_angle(rotation.y, want, TURN_RATE * SimConfig.TICK_DELTA)

# Radians per second, near enough to snap on a lunge and slow enough that a
# shuffle's 60-degree swing is visible as a turn rather than a teleport.
const TURN_RATE := 9.0

var _facing_from: Vector3 = Vector3.ZERO

# Batted away by a dashing player. Deflected and staggered -- NOT killed, which is
# the destructible/deflectable split hazards.md calls the most consequential line
# in the document.
func deflect(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	velocity = flat.normalized() * SimConfig.ZOMBIE_DEFLECT_SPEED
	velocity.y = 3.0
	state = State.STAGGER
	state_timer = 0.0
	grounded = false

# IT BIT SOMEBODY. Knocked back off them and harmless for a beat -- and crucially
# NOT spent, which is the one place this differs from a rusher and the difference
# a group makes.
#
# A rusher expends itself on contact so that ONE of them cannot chain-tumble
# somebody already out of control. With five that rule protects nobody: the pack
# would simply land five hits and vanish. Recoiling puts the same beat in the
# player's favour without deleting the encounter after one exchange.
func recoil_from(from: Vector3) -> void:
	var away := Vector3(position.x - from.x, 0.0, position.z - from.z)
	if away.length_squared() < 0.0001:
		away = -_heading if _heading.length_squared() > 0.0001 else Vector3(0.0, 0.0, 1.0)
	velocity = away.normalized() * SimConfig.ZOMBIE_RECOIL_SPEED
	velocity.y = 2.0
	state = State.RECOVER
	state_timer = 0.0
	grounded = false

# Is it in play at all -- touchable, in either direction? A RISING one is not: the
# telegraph would be a lie if the thing could hit you, OR be batted away, while it
# was still announcing itself.
#
# SEPARATE FROM is_dangerous() ON PURPOSE, and the rusher paid for that separation
# already: one predicate answering both questions meant that making a deflected
# enemy safe also made it unbattable, and the player bulldozed it around with
# their body instead. A recovering or staggered zombie is still deflectable -- a
# dash lasts six ticks and re-deflects on each one, which is what carries it clear.
func is_in_play() -> bool:
	return state != State.RISE

# Can it HURT you? Only while it is walking. Not while it is rising, not while it
# is staggered, and not during the beat after it has just bitten someone.
func is_dangerous() -> bool:
	return state == State.WALK

# SHOT. The only thing that ENDS a zombie rather than postponing it. A flag rather
# than an immediate free, for the same reason the rusher's is: the pool walks its
# list once per tick and removes what is spent, so one that vanished mid-iteration
# would be a freed object still sitting in an array being read.
var killed: bool = false

func kill() -> void:
	killed = true

func receive_hit(hit) -> bool:
	match hit.kind:
		Hit.Kind.BULLET, Hit.Kind.EXPLOSIVE:
			kill()
			return true
		_:
			# A dash. Deflected along the way the hit was travelling, which for a
			# contact is away from the body that arrived.
			deflect(hit.direction_to(position))
			return true

# It rots. The floor under a weaponless player, the same one the rusher's burrow
# provides -- longer, because there are more of them, and outliving a pack is
# meant to be grim rather than impossible.
func is_spent() -> bool:
	return killed or age > SimConfig.ZOMBIE_LIFETIME or position.y < SimConfig.FALL_KILL_Y

# Clients are TOLD where a zombie is; they never simulate one. `move_kind` rides
# along so a client can lean the mesh into a lunge -- it is the only part of the
# walk that is visible, and deriving it on the far end would mean shipping the
# heading, the budget and the roll counter to reproduce a lean.
func capture_state() -> Array:
	return [zombie_id, position, state, target_peer, move_kind]

func apply_state(s: Array) -> void:
	position = s[1]
	state = int(s[2])
	target_peer = int(s[3])
	move_kind = int(s[4])
	# The client's own facing pass, off its own position history. See _face_travel:
	# the host runs this from its step, a client runs it from the wire, and neither
	# needs the other to agree.
	_face_travel()
