extends "res://scripts/level/props/consumable_props.gd"

# HEARTS: health on the deck. Consumed by walking into one -- first come, first
# served, and exclusive by construction: taking one removes it.
#
# WHICH HEARTS HAVE GONE is sent to clients (the layout). A heart is built from the
# segment, so every machine draws one until it is told otherwise -- and nothing
# told them. Reported as "client doesn't see health disappear after pickup": the
# host ate it, healed the player, and left a heart drawn on every other screen.

const HeartScene = preload("res://scenes/heart.tscn")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

func _init() -> void:
	root_name = "Hearts"
	node_prefix = "Heart"

func _build(cell: Vector2i) -> Node3D:
	var heart: Node3D = HeartScene.instantiate()
	heart.position = grid.cell_surface(cell) + Vector3(0.0, 0.8, 0.0)
	return heart

# The one a body at `world_position` is standing in, taken, or false. Measured in
# the grid's own space, which is where the hearts are.
func try_take_near(world_position: Vector3) -> bool:
	if nodes.is_empty():
		return false
	var local: Vector3 = grid.transform.affine_inverse() * world_position
	for cell in nodes.keys():
		var heart: Node3D = nodes[cell]
		if not is_instance_valid(heart):
			continue
		if heart.position.distance_to(local) <= SimConfig.HEART_PICKUP_RADIUS:
			take(cell)
			return true
	return false
