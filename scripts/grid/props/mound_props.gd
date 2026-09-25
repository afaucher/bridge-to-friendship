extends "res://scripts/grid/props/consumable_props.gd"

# MOUNDS: a rusher waits under each. Consumed when a player walks near and sees it.

const MoundScene = preload("res://scenes/mound.tscn")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

func _init() -> void:
	root_name = "Mounds"
	node_prefix = "Mound"

func _build(cell: Vector2i) -> Node3D:
	var mound: Node3D = MoundScene.instantiate()
	mound.position = grid.cell_surface(cell) + Vector3(0.0, 0.17, 0.0)
	return mound

# Where the rusher stands up: its own half-height above the deck.
func surface_world(cell: Vector2i) -> Vector3:
	return grid.cell_surface_world(cell) + Vector3(0.0, SimConfig.RUSHER_HEIGHT * 0.5, 0.0)
