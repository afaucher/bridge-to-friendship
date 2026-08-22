extends CharacterBody3D

# What every enemy that SHOOTS has in common. Subclassed by skirmisher_body.gd
# and turret_body.gd; never spawned directly.
#
# THIS WAS ONE SCRIPT WITH A KIND FLAG UNTIL 2026-08-14, and splitting it was the
# right call for a reason worth recording: a turret has a FIRING ARC. An arc is
# meaningless on something that can simply turn to face you, so it needs a mount
# facing, a bearing test, and a gun that rests when it cannot reach. None of that
# is a flag on a skirmisher -- it is a different object that happens to share how
# a round leaves a barrel.
#
# What stays here is the part they genuinely share: line of sight, the cadence,
# dying to a weapon rather than to a body, and how a client is told about it.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

# THE WIRE DISCRIMINATOR, and all that is left of the old flag. A client is told
# which kind an enemy is so it can build the right scene; no BEHAVIOUR reads it.
enum Kind { SKIRMISHER, TURRET }

var gunner_id: int = 0
var kind: int = Kind.SKIRMISHER

var facing: float = 0.0
var fire_timer: float = 0.0
var grounded: bool = false
var killed: bool = false
var world: Node = null

# HOW AWAKE IT IS, 0 asleep and 1 ready to shoot. See the block in sim_config.gd
# for why this is a scalar and not a state machine: the wake window, the memory
# across a brief sight break and the cheap re-acquire are all consequences of one
# number rising and falling at different rates, rather than three rules.
#
# HOST-ONLY, and deliberately NOT on the wire. It was replicated for one day so a
# client could draw a glow that ramped with it; the glow is gone (see below) and
# nothing else reads this, so sending it would be a replicated field with no
# consumer -- which rots. If anything client-side ever needs to know how awake an
# enemy is, this goes back in `capture_state` as a tail field and NOT derived
# there: the host rolls a random interval, so a client has nothing to derive from.
var alert: float = 0.0

# 1 / (the rolled wake duration). Zero means "not woken from rest yet"; it is
# re-rolled every time alert leaves zero, so an enemy that goes fully back to
# sleep gets a fresh interval next time rather than reusing its first one.
var wake_rate: float = 0.0

# Where it last had eyes on somebody. What SEARCH walks toward -- see
# skirmisher_body.move_for.
var last_seen: Vector3 = Vector3.ZERO
var has_last_seen: bool = false

func _ready() -> void:
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

func is_spent() -> bool:
	return killed or position.y < SimConfig.FALL_KILL_Y

func kill() -> void:
	killed = true

# ENDED BY A WEAPON. Both kinds die to BULLET and EXPLOSIVE -- that is the
# deflectable/destructible split hazards.md calls the most consequential line in
# the document. What a BODY arriving does is the half they disagree about, so it
# is a subclass decision.
func receive_hit(hit) -> bool:
	match hit.kind:
		Hit.Kind.BULLET, Hit.Kind.EXPLOSIVE:
			kill()
			return true
		_:
			return receive_impact(hit)

# Overridden. A skirmisher is knocked about; a turret is bolted down.
func receive_impact(_hit) -> bool:
	return false

# --- Per tick -----------------------------------------------------------------

func step(target: Node) -> void:
	fire_timer = maxf(0.0, fire_timer - SimConfig.TICK_DELTA)
	_update_alert(target)
	if target != null:
		var to_target := Vector3(target.position.x - position.x, 0.0,
			target.position.z - position.z)
		if to_target.length_squared() > 0.0001:
			# TURNING TO FACE YOU IS THE HONEST HALF OF THE TELEGRAPH, and it starts
			# on the first tick of the wake rather than at the end of it. It is real
			# information as well as a warning: with two of these on a deck, which one
			# is looking at you says which one to answer first. The glow is only the
			# read for the case where it was already pointed your way.
			aim_at(GridConfig.yaw_of_vector(to_target))
	move_for(target)
	_fall_and_move()

# ALERT RISES WHILE IT CAN SEE SOMEBODY AND FALLS WHILE IT CANNOT, at very
# different rates. The asymmetry is the whole design -- see sim_config.gd.
func _update_alert(target: Node) -> void:
	if target != null:
		if wake_rate <= 0.0:
			wake_rate = 1.0 / randf_range(SimConfig.GUNNER_WAKE_MIN, SimConfig.GUNNER_WAKE_MAX)
		alert = minf(1.0, alert + wake_rate * SimConfig.TICK_DELTA)
		last_seen = target.position
		has_last_seen = true
	else:
		alert = maxf(0.0, alert - SimConfig.TICK_DELTA / SimConfig.GUNNER_FORGET_SECONDS)
		if alert <= 0.0:
			# Fully back to sleep: the next wake rolls its own interval, and it has
			# stopped believing anybody is where it last saw one.
			wake_rate = 0.0
			has_last_seen = false

# Awake enough to shoot. The threshold is the TOP of the scale on purpose: an
# enemy that could fire at half alertness would have a telegraph half as long as
# the one the numbers claim.
func is_engaged() -> bool:
	return alert >= 1.0

# Overridden. A skirmisher walks to hold its band; a turret does not move at all.
func move_for(_target: Node) -> void:
	velocity.x = 0.0
	velocity.z = 0.0

# Overridden. A turret can only swing within its mount arc.
func aim_at(yaw: float) -> void:
	facing = yaw

func _fall_and_move() -> void:
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()
	_point_gun()

# The visible barrel follows `facing`, on a pivot, exactly as the player's held
# weapon does.
#
# AND IT IS THE ONLY TELL A WAKING GUNNER GIVES. There was a glow ramping with
# `alert` here for a day and it is gone on purpose: the wake is not something the
# enemy should advertise. What the player gets is the same thing they got before --
# a gun turning to point at them -- which is honest, is already replicated in
# `facing`, and costs the enemy nothing it would not have done anyway.
func _point_gun() -> void:
	var pivot := get_node_or_null("Facing") as Node3D
	if pivot != null:
		pivot.rotation.y = facing

# --- Where it is safe to walk -------------------------------------------------

# IS THERE FOOTING A STEP THAT WAY? Asked of the GRID rather than of a raycast,
# which is what "they know the grid" buys: a ray answers about whatever collider
# happens to be under a point, and the deck's own record of which cells exist is
# both cheaper and the same answer the level was validated against.
#
# ONE DEFINITION FOR EVERY CALLER. Retreating out of the band and wandering on
# patrol are the same question -- "may I put a foot there" -- and this project has
# twice paid for one fact having two implementations that agreed until they did
# not.
func footing_toward(dir: Vector3) -> bool:
	if dir.length_squared() < 0.0001:
		return true
	# No grid at all is a test fixture or a bare world: permit, exactly as the
	# raycast this replaced permitted when there was no physics space.
	if world == null or world.grid == null:
		return true
	var grid: Node = world.grid
	# `position`, NOT `global_position`. cell_of_world takes a point in the GRID'S
	# PARENT's space -- the GameWorld's -- and the test harness runs two worlds a
	# kilometre apart in one physics space, so a global point would be read against
	# whichever world happens to sit at the origin. Same reason player_body.gd
	# passes `position` everywhere it asks for a cell.
	var here: Vector2i = grid.cell_of_world(position)
	var there: Vector2i = grid.cell_of_world(position + dir.normalized() * FOOTING_PROBE)
	if there == here:
		return true
	if not grid.is_solid(there):
		return false
	# The same shape as SegmentValidator._can_step, and for the same reason: THERE
	# IS NO STEP-UP IN THIS GAME. A rise is only walkable onto a ramp, and a drop it
	# cannot climb back out of is a trap it would put itself in.
	var rise: int = grid.height_at(there) - grid.height_at(here)
	if rise > 0:
		return grid.kind_at(there) == GridConfig.Kind.RAMP and rise <= 1
	return rise >= -MAX_PATROL_DROP

# A body-width, which is far enough ahead that it stops before the edge rather
# than on it.
const FOOTING_PROBE := 0.9
const MAX_PATROL_DROP := 1

# --- Shooting -----------------------------------------------------------------

# Overridden per kind: the two have different engagement profiles on purpose.
func fire_range() -> float:
	return SimConfig.SKIRMISHER_RANGE

func fire_interval() -> float:
	return SimConfig.SKIRMISHER_FIRE_INTERVAL

# Can it point at this at all? Always, unless something limits it -- see
# turret_body.
func can_bear_on(_target: Node) -> bool:
	return true

func wants_to_fire(range_to: float, target: Node) -> bool:
	# THE WAKE COMES FIRST, ahead of the cadence and the range. `fire_timer` starts
	# at zero, so before this line a gunner that acquired a target fired on the very
	# tick it acquired it -- which is the whole reason alertness exists.
	if not is_engaged():
		return false
	if fire_timer > 0.0:
		return false
	if not can_bear_on(target):
		return false
	return range_to <= fire_range()

func note_fired() -> void:
	fire_timer = fire_interval()

func muzzle() -> Vector3:
	# The same height the player's gun fires from, and for the same reason: it has
	# to be inside a 1.8 m player AND inside a 1.4 m rusher.
	return global_position + Vector3(0.0, 0.25, 0.0)

# Clients are TOLD where an enemy is; they never simulate one. Same as a rusher.
func capture_state() -> Array:
	return [gunner_id, kind, position, facing]

# `kind` is NOT read back off the wire: the client used it to pick which scene to
# build, and that scene's script already set it. Assigning it here would let a
# body disagree with the script it is running.
func apply_state(s: Array) -> void:
	position = s[2]
	facing = float(s[3])
	_point_gun()
