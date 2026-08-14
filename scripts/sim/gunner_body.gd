extends CharacterBody3D

# An enemy that shoots. See implementation_plans/m15_threats_and_answers.md.
#
# TWO ENEMIES, ONE SCRIPT, AND THE DIFFERENCE IS DATA. A turret is a skirmisher
# that cannot move and ignores a dash. Writing them as two classes would have
# meant two copies of the interesting part -- line of sight, the firing cadence,
# dying to a round -- and one copy of the boring part each, which is the wrong way
# round.
#
# WHAT MAKES THESE DIFFERENT FROM A RUSHER, and the reason they are worth adding:
# a rusher is answered by MOVING, so the answer is the same every time. These are
# answered by breaking line of sight or closing the distance, which are answers
# the geometry has to supply -- so they make the bridge itself part of the fight
# rather than a floor to have the fight on.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

enum Kind {
	# Holds a distance and shoots. Backs off when you close, follows when you
	# leave.
	SKIRMISHER,
	# Bolted down. Does not move, and a dash does nothing to it.
	TURRET,
}

# Host-assigned and monotonic, never a creation-order index -- the same rule every
# mid-run body in this project follows.
var gunner_id: int = 0
var kind: int = Kind.SKIRMISHER

var facing: float = 0.0
var fire_timer: float = 0.0
var grounded: bool = false
var killed: bool = false

# Set by GameWorld at spawn, for the line-of-sight query it already owns.
var world: Node = null

func _ready() -> void:
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

func is_mobile() -> bool:
	return kind == Kind.SKIRMISHER

func is_spent() -> bool:
	return killed or position.y < SimConfig.FALL_KILL_Y

func kill() -> void:
	killed = true

# ENDED BY A WEAPON; A TURRET IS NOT ENDED BY A BODY.
#
# A skirmisher is deflected by a dash the way a rusher is -- it is a thing on legs
# and running into it should do something. A TURRET IGNORES IMPACT, and that is a
# design position rather than an oversight: dashing a bolted-down gun must do
# nothing, or the free verb answers the hazard and the weapon specials lose
# another customer. hazards.md warns about exactly that twice.
#
# It makes the turret the first thing in the game that genuinely requires cover or
# a special, which is also why it is the one that has to be authored carefully.
func receive_hit(hit) -> bool:
	match hit.kind:
		Hit.Kind.BULLET, Hit.Kind.EXPLOSIVE:
			kill()
			return true
		_:
			if kind == Kind.TURRET:
				return false
			velocity += hit.launch_for(position)
			return true

# One tick. `target` is the nearest player it can see, or null.
func step(target: Node) -> void:
	fire_timer = maxf(0.0, fire_timer - SimConfig.TICK_DELTA)

	if target == null:
		if is_mobile():
			velocity.x = move_toward(velocity.x, 0.0, SimConfig.GUNNER_SPEED * SimConfig.TICK_DELTA)
			velocity.z = move_toward(velocity.z, 0.0, SimConfig.GUNNER_SPEED * SimConfig.TICK_DELTA)
		_fall_and_move()
		return

	var to_target := Vector3(target.position.x - position.x, 0.0, target.position.z - position.z)
	var range_to: float = to_target.length()
	facing = GridConfig.yaw_of_vector(to_target) if range_to > 0.01 else facing

	if is_mobile():
		_hold_the_band(to_target, range_to)
	_fall_and_move()

# APPROACH WHEN FAR, BACK OFF WHEN CLOSE, STAND STILL IN BETWEEN.
#
# The band is what makes this an enemy with a POSITION it wants rather than a
# target it runs at, and the dead zone in the middle is what stops it jittering
# back and forth across a single preferred distance forever.
func _hold_the_band(to_target: Vector3, range_to: float) -> void:
	var want: float = SimConfig.GUNNER_RANGE
	var slack: float = SimConfig.GUNNER_BAND
	var dir := Vector3.ZERO
	if range_to > want + slack:
		dir = to_target.normalized()
	elif range_to < want - slack:
		dir = -to_target.normalized()

	# IT MUST NOT BACK OFF THE BRIDGE. A body that retreats from you until it
	# falls is a comedy nobody authored, and worse, it hands the player a free
	# kill for walking forwards. Retreating is refused when there is no deck
	# behind it; approaching never is, because walking INTO the party is the
	# thing it is for.
	if dir.length_squared() > 0.0001 and range_to < want and not _deck_behind(dir):
		dir = Vector3.ZERO

	velocity.x = dir.x * SimConfig.GUNNER_SPEED
	velocity.z = dir.z * SimConfig.GUNNER_SPEED

# Is there something to stand on a step in `dir`? The same downward probe the
# carrier check uses, one body-width ahead.
func _deck_behind(dir: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var ahead: Vector3 = global_position + dir.normalized() * 0.9
	var query := PhysicsRayQueryParameters3D.create(ahead, ahead - Vector3(0.0, 2.5, 0.0), 1)
	return not space.intersect_ray(query).is_empty()

func _fall_and_move() -> void:
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()

# Ready to shoot, and roughly pointed the right way. The world asks, because the
# world is what owns rounds.
func wants_to_fire(range_to: float) -> bool:
	if fire_timer > 0.0:
		return false
	return range_to <= SimConfig.GUNNER_RANGE + SimConfig.GUNNER_BAND * 2.0

func note_fired() -> void:
	fire_timer = SimConfig.GUNNER_FIRE_INTERVAL

func muzzle() -> Vector3:
	# The same height the player's gun fires from, and for the same reason: it has
	# to be inside a 1.8 m player AND inside a 1.4 m rusher.
	return global_position + Vector3(0.0, 0.25, 0.0)

# Clients are TOLD where an enemy is; they never simulate one. Same as a rusher.
func capture_state() -> Array:
	return [gunner_id, kind, position, facing]

func apply_state(s: Array) -> void:
	kind = int(s[1])
	position = s[2]
	facing = float(s[3])
