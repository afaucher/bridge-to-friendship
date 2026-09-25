extends "res://scripts/grid/props/consumable_props.gd"

# GRAVES: a zombie pack waits under each. Consumed when it opens.

const GraveScene = preload("res://scenes/grave.tscn")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

func _init() -> void:
	root_name = "Graves"
	node_prefix = "Grave"

func _build(cell: Vector2i) -> Node3D:
	var grave: Node3D = GraveScene.instantiate()
	grave.position = grid.cell_surface(cell) + Vector3(0.0, 0.09, 0.0)
	return grave

func surface_world(cell: Vector2i) -> Vector3:
	return grid.cell_surface_world(cell) + Vector3(0.0, SimConfig.ZOMBIE_HEIGHT * 0.5, 0.0)
