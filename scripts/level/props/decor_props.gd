extends RefCounted

# SCENERY WITH RULES: ladders, cover (half walls and trees) and spikes. Built from
# the segment, never replicated -- every machine builds the same ones from the
# same data -- and the only runtime state is how far each spike block is raised,
# which the world sets every tick from a clock both machines share.

const Layers = preload("res://scripts/core/layers.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

var grid = null

func attach(g) -> void:
	grid = g

var _cover_root: Node3D = null
var _ladder_root: Node3D = null
var _spike_root: Node3D = null
var _spikes: Dictionary = {}           # Vector2i -> the spike prop, so the world can raise it
var spike_lift: Dictionary = {}        # Vector2i -> 0..1, how far out they are
const SPIKE_COUNT := 3                 # 3 x 3 across the cell
const SPIKE_HEIGHT := 0.8

func spawn_ladder(cell: Vector2i) -> void:
	if _ladder_root == null:
		_ladder_root = Node3D.new()
		_ladder_root.name = "Ladders"
		grid.add_child(_ladder_root)

	var rungs := Node3D.new()
	rungs.name = "Ladder_%d_%d" % [cell.x, cell.y]

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.LADDER_COLOUR
	mat.roughness = 0.8

	# ON THE FACE OF THE DROP, NOT AT THE CELL CENTRE (fixed 2026-08-16, reported
	# from playtest as "the ladder is inside a solid block, you can't see it").
	#
	# A ladder is authored on the HIGH cell — the deck it delivers you to — and
	# the first version hung its rails straight down from that cell's middle,
	# which is the inside of a solid deck column. Invisible, and the climb worked
	# anyway, because PlayerBody._step_climb had already been fixed to hold the
	# body on the cliff FACE: the state and the art disagreed about where the
	# ladder was, and only the art was wrong.
	#
	# Same face, same arithmetic, one place each. If _ladder_face ever changes,
	# this has to change with it or the disagreement comes straight back.
	var face: Vector3 = grid.ladder_face(cell)
	var drop: float = maxf(
		float(grid.height_at(cell) - grid.height_at(cell + GridConfig.cell_step(face)))
			* GridConfig.HEIGHT_UNIT,
		GridConfig.HEIGHT_UNIT)
	# Half a cell out, plus a hair so the rails stand PROUD of the face rather
	# than z-fighting with it.
	rungs.position = grid.cell_surface(cell) + face * (GridConfig.CELL_SIZE * 0.5 + 0.06)
	# Turned to lie flat against the wall it is bolted to, so the rails are the
	# width of the ladder rather than its depth.
	rungs.rotation.y = atan2(face.x, face.z)

	for side in [-0.28, 0.28]:
		var rail := MeshInstance3D.new()
		var post := BoxMesh.new()
		post.size = Vector3(0.09, drop, 0.09)
		rail.mesh = post
		rail.material_override = mat
		rail.position = Vector3(side, -drop * 0.5, 0.0)
		rungs.add_child(rail)

	var count: int = maxi(2, int(drop / 0.4))
	for i in count:
		var rung := MeshInstance3D.new()
		var bar := BoxMesh.new()
		bar.size = Vector3(0.64, 0.07, 0.07)
		rung.mesh = bar
		rung.material_override = mat
		rung.position = Vector3(0.0, -drop * (float(i) + 0.5) / float(count), 0.0)
		rungs.add_child(rung)

	_ladder_root.add_child(rungs)

func spawn_cover(cell: Vector2i, is_tree: bool) -> void:
	if _cover_root == null:
		_cover_root = Node3D.new()
		_cover_root.name = "Cover"
		grid.add_child(_cover_root)

	var body := StaticBody3D.new()
	body.name = ("Tree_%d_%d" if is_tree else "HalfWall_%d_%d") % [cell.x, cell.y]
	body.collision_layer = Layers.WORLD        # world: solid, and a sight blocker for free
	body.collision_mask = 0
	body.position = grid.cell_surface(cell)

	# THIN AND TALL versus WIDE AND LOW. A tree hides one player and is walked
	# around in a step; a half wall hides a line of fire and has to be flanked.
	var size := Vector3(0.5, 3.0, 0.5) if is_tree else Vector3(1.7, 1.1, 0.35)
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0.0, size.y * 0.5, 0.0)
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = col.position
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.TREE_TRUNK_COLOUR if is_tree else GridConfig.HALF_WALL_COLOUR
	mat.roughness = 0.9
	mesh.material_override = mat
	body.add_child(mesh)

	if is_tree:
		# A canopy, purely so a tree reads as a tree from the fixed camera rather
		# than as a thin brown post. No collider: the trunk is the cover.
		var crown := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = 0.85
		ball.height = 1.7
		crown.mesh = ball
		crown.position = Vector3(0.0, 3.0, 0.0)
		var leaf := StandardMaterial3D.new()
		leaf.albedo_color = GridConfig.TREE_COLOUR
		leaf.roughness = 0.95
		crown.material_override = leaf
		body.add_child(crown)

	_cover_root.add_child(body)

func spawn_spikes(cell: Vector2i) -> void:
	if _spike_root == null:
		_spike_root = Node3D.new()
		_spike_root.name = "Spikes"
		grid.add_child(_spike_root)

	var prop := Node3D.new()
	prop.name = "Spikes_%d_%d" % [cell.x, cell.y]
	prop.position = grid.cell_surface(cell)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.SPIKE_COLOUR
	# Metallic and smooth, so the points catch the light and separate from the
	# matte deck they come out of.
	mat.roughness = 0.25
	mat.metallic = 0.6

	# A cone is a cylinder with no top. Sized so nine of them fill the cell
	# without touching -- a solid bed of them would be the slab again.
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.16
	cone.height = SPIKE_HEIGHT
	cone.radial_segments = 6

	var step: float = GridConfig.CELL_SIZE / float(SPIKE_COUNT + 1)
	for ix in SPIKE_COUNT:
		for iz in SPIKE_COUNT:
			var spike := MeshInstance3D.new()
			spike.mesh = cone
			spike.material_override = mat
			spike.position = Vector3(
				-GridConfig.CELL_SIZE * 0.5 + step * float(ix + 1),
				SPIKE_HEIGHT * 0.5,
				-GridConfig.CELL_SIZE * 0.5 + step * float(iz + 1))
			prop.add_child(spike)

	prop.visible = false
	_spike_root.add_child(prop)
	_spikes[cell] = prop

# How far out, 0 to 1. The WORLD decides, from the tick, so every machine agrees
# without anything being sent. Below 0 they are inside the deck slab, which is a
# metre thick and hides them completely.
func set_spikes_lift(cell: Vector2i, lift: float) -> void:
	# Kept as well as applied, so the state is readable rather than having to be
	# inferred from a mesh position. A test that has to reverse-engineer a
	# transform to find out what the sim decided is a test measuring the view.
	spike_lift[cell] = lift
	var prop: Node3D = _spikes.get(cell)
	if prop == null or not is_instance_valid(prop):
		return
	prop.visible = lift > 0.02
	var base: Vector3 = grid.cell_surface(cell)
	prop.position = Vector3(base.x, base.y - SPIKE_HEIGHT * (1.0 - lift), base.z)
