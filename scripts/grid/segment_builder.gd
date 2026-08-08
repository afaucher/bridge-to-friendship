extends RefCounted

# Turns a parsed segment into collision and meshes.
#
# The authored file stays the source of truth; this produces a VIEW of it. That
# split is what makes a drop-in join cheap -- a newcomer needs the segment name
# and a diff of what has moved, not a walk of the scene tree inventing a format
# for every node type. See design_ideas/physics_and_authority.md.
#
# DECK CELLS ARE MERGED ALONG X before becoming boxes. A 30x24 segment is 720
# cells; one collision shape each is 720 shapes the physics server tests every
# tick, for geometry that is mostly long flat runs. Greedy row merging turns a
# typical segment into a few dozen boxes and costs about fifteen lines.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# Built with the segment so callers can find things without re-walking the grid.
class Built:
	extends RefCounted
	var root: Node3D
	var stone_cells: Array = []      # Vector2i, where pillars were authored
	var ladder_cells: Array = []
	var spawn_cells: Array = []
	var deck_box_count: int = 0
	var wall_box_count: int = 0

static func build(seg, z_offset: int = 0) -> Built:
	var out := Built.new()
	out.root = Node3D.new()
	out.root.name = "Segment_%s" % seg.name

	var body := StaticBody3D.new()
	body.name = "Structure"
	# Layer 1 is "world"; players are layer 2 and mask 3, so they collide here.
	body.collision_layer = 1
	body.collision_mask = 0
	out.root.add_child(body)

	var meshes := Node3D.new()
	meshes.name = "Meshes"
	out.root.add_child(meshes)

	_build_deck(seg, z_offset, body, meshes, out)
	_build_ramps(seg, z_offset, body, meshes)
	_build_walls(seg, z_offset, body, meshes, out)
	_collect_content(seg, out)
	return out

# --- Deck ---------------------------------------------------------------------

static func _build_deck(seg, z_offset: int, body: StaticBody3D, meshes: Node3D, out: Built) -> void:
	for z in seg.length:
		var x := 0
		while x < seg.width:
			# RAMP cells are skipped here; they are wedges, built separately.
			if seg.kind_at(x, z) != GridConfig.Kind.DECK and seg.kind_at(x, z) != GridConfig.Kind.WATER:
				x += 1
				continue
			var height: int = seg.height_at(x, z)
			var kind: int = seg.kind_at(x, z)
			var run := 1
			while x + run < seg.width \
					and seg.kind_at(x + run, z) == kind \
					and seg.height_at(x + run, z) == height:
				run += 1

			# Water sits a little below its cell's nominal top so it reads as a
			# channel rather than as deck of a different colour. The flow force
			# that makes it dangerous is M7.
			var top: float = GridConfig.height_to_world(height)
			if kind == GridConfig.Kind.WATER:
				top -= 0.4

			var size := Vector3(float(run) * GridConfig.CELL_SIZE, GridConfig.DECK_THICKNESS, GridConfig.CELL_SIZE)
			var centre := Vector3(
				GridConfig.cell_origin_x(x) + float(run) * GridConfig.CELL_SIZE * 0.5,
				top - GridConfig.DECK_THICKNESS * 0.5,
				GridConfig.cell_z_world(z + z_offset)
			)
			_add_box(body, meshes, centre, size)
			out.deck_box_count += 1
			x += run

# --- Ramps --------------------------------------------------------------------
#
# A ramp cell rises from the height of the cell BEHIND it (z - 1) to its own
# height, across one cell of length. Rise per cell is therefore what sets the
# slope, and gentle versus steep is authored by spreading a climb over more
# cells -- which is the whole co-op gate: below max_walk_slope anyone walks up,
# above it you need a shove or a rope.

static func _build_ramps(seg, z_offset: int, body: StaticBody3D, meshes: Node3D) -> void:
	for z in seg.length:
		for x in seg.width:
			if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
				continue
			var top: float = GridConfig.height_to_world(seg.height_at(x, z))
			var bottom: float = GridConfig.height_to_world(_height_behind(seg, x, z))
			var rise: float = top - bottom
			var run: float = GridConfig.CELL_SIZE

			var shape := BoxShape3D.new()
			# Long enough to span the slope; thickness gives it something to
			# stand on rather than a zero-volume plane.
			shape.size = Vector3(GridConfig.CELL_SIZE, GridConfig.DECK_THICKNESS, sqrt(run * run + rise * rise))

			var col := CollisionShape3D.new()
			col.shape = shape
			var centre := Vector3(
				GridConfig.cell_origin_x(x) + GridConfig.CELL_SIZE * 0.5,
				(bottom + top) * 0.5 - GridConfig.DECK_THICKNESS * 0.5,
				GridConfig.cell_z_world(z + z_offset)
			)
			# Rotate about X so the surface climbs toward -Z, which is up the
			# bridge (increasing cell z). Rotating by +theta about X sends the
			# box's local +Z end downward, so the -Z end -- the far end, up the
			# bridge -- rises. Flip this sign and every ramp points backwards.
			var basis := Basis(Vector3.RIGHT, atan2(rise, run))
			col.transform = Transform3D(basis, centre)
			body.add_child(col)

			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = shape.size
			mesh.mesh = box
			mesh.transform = col.transform
			meshes.add_child(mesh)

static func _height_behind(seg, x: int, z: int) -> int:
	if z <= 0:
		return seg.height_at(x, z)
	return seg.height_at(x, z - 1)

# --- Walls --------------------------------------------------------------------

static func _build_walls(seg, z_offset: int, body: StaticBody3D, meshes: Node3D, out: Built) -> void:
	for z in seg.length:
		for x in seg.width:
			for dir in 4:
				if not seg.has_wall(x, z, dir):
					continue
				var height: int = seg.height_at(x, z)
				var top: float = GridConfig.height_to_world(height)
				var centre: Vector3 = GridConfig.cell_centre(x, z + z_offset, height)
				centre.y = top + GridConfig.WALL_HEIGHT * 0.5

				var size: Vector3
				var offset: Vector3 = GridConfig.DIR_VECTORS[dir] * (GridConfig.CELL_SIZE * 0.5 - GridConfig.WALL_THICKNESS * 0.5)
				if dir == GridConfig.DIR_NORTH or dir == GridConfig.DIR_SOUTH:
					size = Vector3(GridConfig.CELL_SIZE, GridConfig.WALL_HEIGHT, GridConfig.WALL_THICKNESS)
				else:
					size = Vector3(GridConfig.WALL_THICKNESS, GridConfig.WALL_HEIGHT, GridConfig.CELL_SIZE)

				_add_box(body, meshes, centre + offset, size)
				out.wall_box_count += 1

# --- Content ------------------------------------------------------------------

static func _collect_content(seg, out: Built) -> void:
	for z in seg.length:
		for x in seg.width:
			match seg.content_at(x, z):
				GridConfig.Content.PILLAR:
					out.stone_cells.append(Vector2i(x, z))
				GridConfig.Content.LADDER:
					out.ladder_cells.append(Vector2i(x, z))
				GridConfig.Content.SPAWN:
					out.spawn_cells.append(Vector2i(x, z))

# --- Helpers ------------------------------------------------------------------

static func _add_box(body: StaticBody3D, meshes: Node3D, centre: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = centre
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = centre
	meshes.add_child(mesh)
