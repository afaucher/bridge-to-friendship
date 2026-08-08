extends RefCounted

# Turns a parsed segment into collision and meshes.
#
# The authored file stays the source of truth; this produces a VIEW of it. That
# split is what makes a drop-in join cheap -- a newcomer needs the segment name
# and a diff of what has moved, not a walk of the scene tree inventing a format
# for every node type. See design_ideas/physics_and_authority.md.
#
# COLLISION IS MERGED, MESHES ARE NOT, and the two are deliberately different
# shapes of the same data:
#
#   Collision merges deck cells into runs along X. A segment is mostly long flat
#   stretches, and one collision shape per cell is hundreds of shapes the physics
#   server tests every tick for no benefit.
#
#   Meshes stay per-cell, because the deck is a CHECKERBOARD -- adjacent cells
#   are different colours, so there is nothing to merge. That is the point: the
#   checker is what makes distance readable from a fixed 45-degree camera, and
#   every judgement this game asks for is a judgement about cells.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# Built with the segment so callers can find things without re-walking the grid.
class Built:
	extends RefCounted
	var root: Node3D
	var stone_cells: Array = []      # Vector2i, where pillars were authored
	var ladder_cells: Array = []
	var spawn_cells: Array = []
	# Collected now so M6 only has to put something there. Authoring a shooter is
	# already possible; nothing stands on the cell yet.
	var shooter_cells: Array = []
	var heart_cells: Array = []
	var deck_box_count: int = 0
	var wall_box_count: int = 0

static func build(seg, z_offset: int = 0) -> Built:
	var out := Built.new()
	out.root = Node3D.new()
	out.root.name = "Segment_%s" % seg.name

	var body := StaticBody3D.new()
	body.name = "Structure"
	# Layer 1 is "world"; players are layer 2 and mask 7, so they collide here.
	body.collision_layer = 1
	body.collision_mask = 0
	out.root.add_child(body)

	var meshes := Node3D.new()
	meshes.name = "Meshes"
	out.root.add_child(meshes)

	# One material per colour for the whole segment, rather than per cell: a few
	# hundred MeshInstance3Ds sharing four materials batch; a few hundred
	# materials do not.
	var palette := {
		"light": _material(GridConfig.DECK_LIGHT),
		"dark": _material(GridConfig.DECK_DARK),
		"wall": _material(GridConfig.WALL_COLOUR),
		"ramp": _material(GridConfig.RAMP_COLOUR),
		"water": _material(GridConfig.WATER_COLOUR),
	}

	_build_deck(seg, z_offset, body, meshes, palette, out)
	_build_ramps(seg, z_offset, body, meshes, palette)
	_build_walls(seg, z_offset, body, meshes, palette, out)
	_collect_content(seg, out)
	return out

static func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.9
	return m

# --- Deck ---------------------------------------------------------------------

static func _build_deck(seg, z_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary, out: Built) -> void:
	var width: int = seg.width
	for z in seg.length:
		# Collision: greedy runs of same kind and height along X.
		var x := 0
		while x < width:
			if seg.kind_at(x, z) != GridConfig.Kind.DECK and seg.kind_at(x, z) != GridConfig.Kind.WATER:
				x += 1
				continue
			var height: int = seg.height_at(x, z)
			var kind: int = seg.kind_at(x, z)
			var run := 1
			while x + run < width \
					and seg.kind_at(x + run, z) == kind \
					and seg.height_at(x + run, z) == height:
				run += 1

			var top: float = _surface_y(kind, height)
			var size := Vector3(float(run) * GridConfig.CELL_SIZE, GridConfig.DECK_THICKNESS, GridConfig.CELL_SIZE)
			var centre := Vector3(
				GridConfig.cell_origin_x(x, width) + float(run) * GridConfig.CELL_SIZE * 0.5,
				top - GridConfig.DECK_THICKNESS * 0.5,
				GridConfig.cell_z_world(z + z_offset)
			)
			_add_collision_box(body, centre, size)
			out.deck_box_count += 1
			x += run

		# Meshes: one per cell, so the checkerboard exists.
		for cx in width:
			var kind2: int = seg.kind_at(cx, z)
			if kind2 != GridConfig.Kind.DECK and kind2 != GridConfig.Kind.WATER:
				continue
			var h: int = seg.height_at(cx, z)
			var top2: float = _surface_y(kind2, h)
			var cell_centre := Vector3(
				GridConfig.cell_origin_x(cx, width) + GridConfig.CELL_SIZE * 0.5,
				top2 - GridConfig.DECK_THICKNESS * 0.5,
				GridConfig.cell_z_world(z + z_offset)
			)
			var material: StandardMaterial3D = palette["water"] if kind2 == GridConfig.Kind.WATER \
				else (palette["light"] if (cx + z + z_offset) % 2 == 0 else palette["dark"])
			_add_mesh_box(meshes, cell_centre,
				Vector3(GridConfig.CELL_SIZE, GridConfig.DECK_THICKNESS, GridConfig.CELL_SIZE), material)

# Water sits a little below its cell's nominal top so it reads as a channel
# rather than as deck of a different colour. The flow that makes it dangerous is
# M7.
static func _surface_y(kind: int, height: int) -> float:
	var top: float = GridConfig.height_to_world(height)
	if kind == GridConfig.Kind.WATER:
		top -= 0.4
	return top

# --- Ramps --------------------------------------------------------------------
#
# A ramp cell rises from the height of the cell BEHIND it (z - 1) to its own
# height, across one cell of length. Rise per cell is therefore what sets the
# slope, and gentle versus steep is authored by spreading a climb over more
# cells -- which is the whole co-op gate: below max_walk_slope anyone walks up,
# above it you need a shove or a rope.

# ONE WEDGE PER CONTIGUOUS RUN, not one per cell.
#
# Per-cell wedges produce a seam at every cell boundary, and a flat-bottomed
# cylinder walking uphill catches on them: measured 2026-08-08, a player climbed
# two cells of a four-cell ramp and then stopped dead, on_wall, with both
# reported contacts reading as clean floor. The surface was geometrically
# perfect -- a raycast sweep showed an unbroken 26.6-degree slope -- and the
# player still could not cross the join.
#
# A run merged into a single prism has no internal joins at all, so there is
# nothing to catch on. It is also far fewer collision shapes.
static func _build_ramps(seg, z_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary) -> void:
	var width: int = seg.width
	for x in width:
		var z := 0
		while z < seg.length:
			if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
				z += 1
				continue

			# Walk the run of ramp cells up the bridge.
			var first := z
			while z < seg.length and seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				z += 1
			var last := z - 1

			# The run starts at whatever is behind its first cell and finishes at
			# its last cell's height -- so the slope is the whole climb, and the
			# per-cell heights in between only ever set how steep it is.
			var bottom: float = GridConfig.height_to_world(_height_behind(seg, x, first))
			var top: float = GridConfig.height_to_world(seg.height_at(x, last))
			var cells: int = last - first + 1

			# The run spans cells [first, last]; cell k occupies world z in
			# [-(k+1) * CELL, -k * CELL].
			var centre_x: float = GridConfig.cell_origin_x(x, width) + GridConfig.CELL_SIZE * 0.5
			var centre_z: float = -(float(first + z_offset) + float(last + z_offset) + 1.0) * 0.5 * GridConfig.CELL_SIZE
			var length: float = float(cells) * GridConfig.CELL_SIZE

			var mesh_res: Mesh = _wedge_mesh(bottom, top, length)
			var xform := _wedge_transform(bottom, top, centre_x, centre_z)

			var col := CollisionShape3D.new()
			# The shape is derived FROM the mesh, so the thing you walk on and
			# the thing you see cannot disagree.
			col.shape = mesh_res.create_convex_shape()
			col.transform = xform
			body.add_child(col)

			var mesh := MeshInstance3D.new()
			mesh.mesh = mesh_res
			mesh.material_override = palette["ramp"]
			mesh.transform = xform
			meshes.add_child(mesh)

# A ramp is a WEDGE, not a tilted slab.
#
# The tilted slab it used to be was wrong in a way that was invisible in the
# numbers and obvious on screen: its ends are cut perpendicular to the SLOPE
# rather than vertically, so it never meets the flat deck at either end squarely,
# and offsetting it by half its thickness in world Y (correct only for a flat
# slab) dropped the top face and slid it down-bridge. Every ramp arrived low and
# short of the level it was supposed to join.
#
# A wedge has none of that. Its footprint is exactly the cell, its ends are
# vertical, its flat underside sits at the height behind it, and its top edge
# reaches the cell's height exactly at the cell boundary -- so "the ramp meets
# the deck" is true by construction rather than by arithmetic.
static func _wedge_mesh(bottom: float, top: float, length: float) -> Mesh:
	var rise: float = absf(top - bottom)
	if rise < 0.001:
		# A ramp that does not rise is authoring nonsense, but a zero-height
		# prism is a degenerate mesh -- fall back to a flat slab rather than
		# emitting geometry with no volume.
		var flat := BoxMesh.new()
		flat.size = Vector3(length, GridConfig.DECK_THICKNESS, GridConfig.CELL_SIZE)
		return flat

	var prism := PrismMesh.new()
	# left_to_right = 0 puts the apex hard against one side, giving a RIGHT
	# triangle: one vertical face at full height, the hypotenuse falling away to
	# nothing. That is the shape of a ramp; the default 0.5 is a symmetric roof.
	prism.left_to_right = 0.0
	# Local X is the climb (the transform below turns it into the along-bridge
	# axis) and local Z is the extrusion, which becomes the width across.
	prism.size = Vector3(length, rise, GridConfig.CELL_SIZE)
	return prism

static func _wedge_transform(bottom: float, top: float,
		centre_x: float, centre_z: float) -> Transform3D:
	var rise: float = absf(top - bottom)
	var low: float = minf(bottom, top)

	if rise < 0.001:
		return Transform3D(Basis(), Vector3(centre_x, low - GridConfig.DECK_THICKNESS * 0.5, centre_z))

	# The prism's tall face is on its local -X. Yawing -90 degrees sends that to
	# -Z, which is UP the bridge -- so the ramp climbs the way the player is
	# walking. A descending ramp is the same wedge yawed the other way.
	var yaw: float = -PI * 0.5 if top > bottom else PI * 0.5
	# The prism is centred on its own height, and its flat underside must land on
	# the level behind it.
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(centre_x, low + rise * 0.5, centre_z))

static func _height_behind(seg, x: int, z: int) -> int:
	if z <= 0:
		return seg.height_at(x, z)
	return seg.height_at(x, z - 1)

# --- Walls --------------------------------------------------------------------

static func _build_walls(seg, z_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary, out: Built) -> void:
	var width: int = seg.width
	for z in seg.length:
		for x in width:
			for dir in 4:
				if not seg.has_wall(x, z, dir):
					continue
				var height: int = seg.height_at(x, z)
				var centre: Vector3 = GridConfig.cell_centre(x, z + z_offset, height, width)
				centre.y = GridConfig.height_to_world(height) + GridConfig.WALL_HEIGHT * 0.5

				var size: Vector3
				if dir == GridConfig.DIR_NORTH or dir == GridConfig.DIR_SOUTH:
					size = Vector3(GridConfig.CELL_SIZE, GridConfig.WALL_HEIGHT, GridConfig.WALL_THICKNESS)
				else:
					size = Vector3(GridConfig.WALL_THICKNESS, GridConfig.WALL_HEIGHT, GridConfig.CELL_SIZE)

				var offset: Vector3 = GridConfig.DIR_VECTORS[dir] \
					* (GridConfig.CELL_SIZE * 0.5 - GridConfig.WALL_THICKNESS * 0.5)
				_add_collision_box(body, centre + offset, size)
				_add_mesh_box(meshes, centre + offset, size, palette["wall"])
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
				GridConfig.Content.SHOOTER:
					out.shooter_cells.append(Vector2i(x, z))
				GridConfig.Content.HEART:
					out.heart_cells.append(Vector2i(x, z))

# --- Helpers ------------------------------------------------------------------

static func _add_collision_box(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = centre
	body.add_child(col)

static func _add_mesh_box(meshes: Node3D, centre: Vector3, size: Vector3,
		material: StandardMaterial3D) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = centre
	meshes.add_child(mesh)
