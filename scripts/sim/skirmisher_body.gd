extends "res://scripts/sim/gunner_body.gd"

# The enemy that holds a distance and shoots.
#
# IT IS ANSWERED BY CLOSING, which is what makes it different from a rusher. A
# rusher is answered by moving, so its answer is the same everywhere on the
# bridge; this one asks the player to walk INTO the thing shooting at them, which
# is a decision rather than a reflex.

const Conf = preload("res://scripts/sim/sim_config.gd")

func _init() -> void:
	kind = Kind.SKIRMISHER

func fire_range() -> float:
	return Conf.SKIRMISHER_RANGE

func fire_interval() -> float:
	return Conf.SKIRMISHER_FIRE_INTERVAL

# KNOCKED ABOUT LIKE ANYTHING ELSE ON LEGS. Running into it does something; it is
# the turret that is bolted down.
func receive_impact(hit) -> bool:
	velocity += hit.launch_for(position)
	return true

# APPROACH WHEN FAR, BACK OFF WHEN CLOSE, STAND STILL IN BETWEEN.
#
# The band is what makes this an enemy with a POSITION it wants rather than a
# target it runs at, and the dead zone in the middle is what stops it jittering
# back and forth across a single preferred distance forever.
func move_for(target: Node) -> void:
	if target == null:
		velocity.x = move_toward(velocity.x, 0.0, Conf.SKIRMISHER_SPEED * Conf.TICK_DELTA)
		velocity.z = move_toward(velocity.z, 0.0, Conf.SKIRMISHER_SPEED * Conf.TICK_DELTA)
		return

	var to_target := Vector3(target.position.x - position.x, 0.0,
		target.position.z - position.z)
	var range_to: float = to_target.length()
	var dir := Vector3.ZERO
	if range_to > Conf.SKIRMISHER_RANGE + Conf.SKIRMISHER_BAND:
		dir = to_target.normalized()
	elif range_to < Conf.SKIRMISHER_RANGE - Conf.SKIRMISHER_BAND:
		dir = -to_target.normalized()

	# IT MUST NOT BACK OFF THE BRIDGE. A body that retreats from you until it
	# falls is a comedy nobody authored, and worse, it hands the player a free kill
	# for walking forwards. Retreating is refused when there is no deck behind it;
	# approaching never is, because walking INTO the party is what it is for.
	if dir.length_squared() > 0.0001 and range_to < Conf.SKIRMISHER_RANGE \
			and not _deck_behind(dir):
		dir = Vector3.ZERO

	velocity.x = dir.x * Conf.SKIRMISHER_SPEED
	velocity.z = dir.z * Conf.SKIRMISHER_SPEED

# Is there something to stand on a step in `dir`? A downward probe one body-width
# ahead, against the world layer only.
func _deck_behind(dir: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var ahead: Vector3 = global_position + dir.normalized() * 0.9
	var query := PhysicsRayQueryParameters3D.create(ahead, ahead - Vector3(0.0, 2.5, 0.0), 1)
	return not space.intersect_ray(query).is_empty()
