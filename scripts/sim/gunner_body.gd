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
	if target != null:
		var to_target := Vector3(target.position.x - position.x, 0.0,
			target.position.z - position.z)
		if to_target.length_squared() > 0.0001:
			aim_at(GridConfig.yaw_of_vector(to_target))
	move_for(target)
	_fall_and_move()

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
func _point_gun() -> void:
	var pivot := get_node_or_null("Facing") as Node3D
	if pivot != null:
		pivot.rotation.y = facing

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
