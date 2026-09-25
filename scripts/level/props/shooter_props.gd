extends "res://scripts/level/props/consumable_props.gd"

# PLINKO SHOOTERS. Consumed only by a blast; the grid's `shooter_cells` is what
# GameWorld._process_plinko walks, so a taken shooter leaves that list too.

const ShooterScene = preload("res://scenes/shooter.tscn")
const GridConfig = preload("res://scripts/level/grid_config.gd")

func _init() -> void:
	root_name = "Shooters"
	node_prefix = "Shooter"

func _build(cell: Vector2i) -> Node3D:
	var shooter: Node3D = ShooterScene.instantiate()
	shooter.position = grid.cell_surface(cell) + Vector3(0.0, GridConfig.CELL_SIZE * 0.5, 0.0)
	return shooter

# The body's centre, which is what a blast is measured to.
func surface_world(cell: Vector2i) -> Vector3:
	return grid.cell_surface_world(cell) + Vector3(0.0, GridConfig.CELL_SIZE * 0.5, 0.0)

func _on_taken(cell: Vector2i) -> void:
	grid.shooter_cells.erase(cell)
