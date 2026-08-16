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
#   Collision merges deck cells into RECTANGLES -- greedy along X, then extended
#   down Z for as long as the whole run still matches. A segment is mostly long
#   flat stretches, and one collision shape per cell is hundreds of shapes the
#   physics server tests every tick for no benefit.
#
#   IT MERGED ALONG X ONLY UNTIL 2026-08-14, AND THE BRIDGE IS WALKED ALONG Z.
#   That left a collision seam across the player's path every two metres, and a
#   CharacterBody3D catching on the boundary between two static shapes is known
#   Godot behaviour (godotengine/godot#76811, #77485, #46712) -- reported here for
#   two playtests running as "ramps are still buggy" and "it gets worse the
#   further up the map you go", which is what more segments and more seams looks
#   like. CLAUDE.md already carried the rule from the ramp seam bug: merge
#   co-planar geometry into ONE shape. It had never been applied to the deck.
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
	# Dormant rushers. The cell is authored; the enemy does not exist until a
	# player walks close enough to wake it.
	var mound_cells: Array = []
	# Loose hats, waiting on the deck for somebody to walk over them.
	var hat_cells: Array = []
	# Specials -- the `*` glyph, declared in GridConfig since the grid was written
	# and unbuilt until M12 filled it.
	var special_cells: Array = []
	# Enemies that shoot. Authored where they stand, like a shooter pillar.
	var gunner_cells: Array = []       # [[cell, kind], ...]
	# Cover, and spike blocks. Collected like every other authored prop: the grid
	# owns the bodies, the builder only says where the author put one.
	var tree_cells: Array = []
	var half_wall_cells: Array = []
	var spike_cells: Array = []
	# ROWS, NOT CELLS. A round boundary is a line across the bridge; the cells are
	# how it is authored and the row is what it MEANS. Everything downstream asks
	# "is this row a boundary", never "is this cell one" -- a party crosses a line.
	var gate_rows: Array = []          # local z, ascending, no duplicates
	var deck_box_count: int = 0
	var wall_box_count: int = 0

static func build(seg, z_offset: int = 0, h_offset: int = 0) -> Built:
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
		"gate_light": _material(GridConfig.GATE_LIGHT),
		"gate_dark": _material(GridConfig.GATE_DARK),
	}

	_build_deck(seg, z_offset, h_offset, body, meshes, palette, out)
	_build_ramps(seg, z_offset, h_offset, body, meshes, palette)
	_build_walls(seg, z_offset, h_offset, body, meshes, palette, out)
	_collect_content(seg, out)
	return out

static func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.9
	return m

# --- Deck ---------------------------------------------------------------------

static func _build_deck(seg, z_offset: int, h_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary, out: Built) -> void:
	var width: int = seg.width
	_merge_deck_collision(seg, z_offset, h_offset, body, out)

	for z in seg.length:
		# Meshes: one per cell, so the checkerboard exists.
		for cx in width:
			var kind2: int = seg.kind_at(cx, z)
			if kind2 != GridConfig.Kind.DECK and kind2 != GridConfig.Kind.WATER:
				continue
			var h: int = seg.height_at(cx, z) + h_offset
			var top2: float = _surface_y(kind2, h)
			# The same thickness the collision uses, or the two disagree and a
			# player stands on a slab they can see under.
			var under2: float = cell_underside(seg, cx, z, h_offset)
			var thick2: float = maxf(GridConfig.DECK_THICKNESS, top2 - under2)
			var cell_centre := Vector3(
				GridConfig.cell_origin_x(cx, width) + GridConfig.CELL_SIZE * 0.5,
				top2 - thick2 * 0.5,
				GridConfig.cell_z_world(z + z_offset)
			)
			var lit: bool = (cx + z + z_offset) % 2 == 0
			var material: StandardMaterial3D
			if kind2 == GridConfig.Kind.WATER:
				material = palette["water"]
			elif seg.content_at(cx, z) == GridConfig.Content.GATE:
				# The round boundary. Same parity, different palette -- see
				# GridConfig.gate_colour.
				material = palette["gate_light"] if lit else palette["gate_dark"]
			else:
				material = palette["light"] if lit else palette["dark"]
			_add_mesh_box(meshes, cell_centre,
				Vector3(GridConfig.CELL_SIZE, thick2, GridConfig.CELL_SIZE), material)

# Water sits a little below its cell's nominal top so it reads as a channel
# rather than as deck of a different colour. The flow that makes it dangerous is
# M7.
# GREEDY RECTANGLES, NOT ROWS. For each cell not yet covered, take the longest run
# along X of the same kind and height, then push that run down Z for as long as
# EVERY column in it still matches. One box per flat rectangle.
#
# Fewer shapes AND fewer seams, which is unusual -- most fixes for one cost the
# other. A flat 15-wide, 30-long segment goes from 30 boxes to one.
#
# WHAT THIS CANNOT FIX: the boundary BETWEEN segments. Each segment builds its own
# StaticBody3D as it streams in, so two segments that would have merged into one
# rectangle still meet at a seam. If catching remains after this, that join is the
# next place to look -- and it is one seam per SEGMENT now rather than one per
# cell, which is a thirtieth as many chances.
static func _merge_deck_collision(seg, z_offset: int, h_offset: int,
		body: StaticBody3D, out: Built) -> void:
	var width: int = seg.width
	var covered: Dictionary = {}

	for z in seg.length:
		for x in width:
			if covered.has(Vector2i(x, z)):
				continue
			var kind: int = seg.kind_at(x, z)
			if kind != GridConfig.Kind.DECK and kind != GridConfig.Kind.WATER:
				continue
			var height: int = seg.height_at(x, z) + h_offset
			# THE MERGE KEY GAINS THE UNDERSIDE. Cells of the same kind and height
			# no longer necessarily have the same THICKNESS, so a plateau's edge
			# cannot merge with its interior. More boxes, but only ever at a height
			# change, which is where the merge was going to break anyway.
			var under: float = cell_underside(seg, x, z, h_offset)

			var run := 1
			while x + run < width and not covered.has(Vector2i(x + run, z)) and _same_cell(seg, x + run, z, kind, height, h_offset) and is_equal_approx(cell_underside(seg, x + run, z, h_offset), under):
				run += 1

			# The whole run pushed down Z. It stops at the first row where ANY
			# column disagrees -- a rectangle, never a staircase.
			var depth := 1
			while z + depth < seg.length and _row_matches(seg, x, run, z + depth, kind, height, h_offset, covered) and _row_underside_matches(seg, x, run, z + depth, h_offset, under):
				depth += 1

			for dz in depth:
				for dx in run:
					covered[Vector2i(x + dx, z + dz)] = true

			var top: float = _surface_y(kind, height)
			var thickness: float = maxf(GridConfig.DECK_THICKNESS, top - under)
			var size := Vector3(
				float(run) * GridConfig.CELL_SIZE,
				thickness,
				float(depth) * GridConfig.CELL_SIZE)
			# Midway between the first and last cell centres, which is right whichever
			# way world Z runs against cell z.
			var mid_z: float = (GridConfig.cell_z_world(z + z_offset) 				+ GridConfig.cell_z_world(z + depth - 1 + z_offset)) * 0.5
			var centre := Vector3(
				GridConfig.cell_origin_x(x, width) + float(run) * GridConfig.CELL_SIZE * 0.5,
				top - thickness * 0.5,
				mid_z)
			_add_collision_box(body, centre, size)
			out.deck_box_count += 1

# THE ADJACENCY THICKNESS RULE (M17 phase 2).
#
#     underside(cell) = min(own_top - DECK_THICKNESS,
#                           lowest top face among its EIGHT neighbours)
#
# A deck cell is otherwise a slab hanging DECK_THICKNESS below its top face, so a
# cell at height 4 beside one at height 0 floats seven metres up with an open
# void under it: you see straight under the raised section, and a body walking
# beneath it walks through empty air where a cliff face should be. That is the
# ramp-skirt bug of 2026-08-13, whose symptom was "sometimes I fall through" and
# which a walking test passed for months.
#
# ONLY CELLS AT A HEIGHT CHANGE GET THICK. A plateau's interior matches its
# neighbours, so it stays exactly as thin as it is today, and the hollow under it
# is sealed by the thick perimeter — there is no sightline in. The geometry
# grows only where the terrain actually steps.
#
# EIGHT-WAY AND NOT FOUR. A four-way rule leaves a vertical slit at a DIAGONAL
# height change, and the camera looks down the bridge at 45 degrees, which is
# exactly the angle that catches it.
#
# A CELL WITH NO SOLID NEIGHBOUR STAYS THIN, deliberately: there is no floor
# beneath it to stand on, so there is nothing to hide, and a thin platform over
# nothing is what it actually is.
#
# Off the ENDS of a segment there is no neighbour to ask about — that row
# belongs to the next segment and is not loaded here. Heights are stacked so a
# join meets at a matching height; a mismatch there is the one place this rule
# cannot close a slot.
static func cell_underside(seg, x: int, z: int, h_offset: int) -> float:
	var kind: int = seg.kind_at(x, z)
	var top: float = _surface_y(kind, seg.height_at(x, z) + h_offset)
	var lowest: float = top - GridConfig.DECK_THICKNESS
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			var nx: int = x + dx
			var nz: int = z + dz
			if not seg.in_bounds(nx, nz):
				continue
			if not seg.is_solid(nx, nz):
				continue
			var ntop: float = _surface_y(seg.kind_at(nx, nz), seg.height_at(nx, nz) + h_offset)
			lowest = minf(lowest, ntop)
	return lowest

# Every column of a candidate row shares the run's underside. Split out rather
# than folded into _row_matches so "is this the same deck" and "is it the same
# THICKNESS of deck" stay separate questions.
static func _row_underside_matches(seg, x: int, run: int, z: int, h_offset: int, under: float) -> bool:
	for dx in run:
		if not is_equal_approx(cell_underside(seg, x + dx, z, h_offset), under):
			return false
	return true

static func _same_cell(seg, x: int, z: int, kind: int, height: int,
		h_offset: int) -> bool:
	return seg.kind_at(x, z) == kind and seg.height_at(x, z) + h_offset == height

static func _row_matches(seg, x: int, run: int, z: int, kind: int, height: int,
		h_offset: int, covered: Dictionary) -> bool:
	for dx in run:
		if covered.has(Vector2i(x + dx, z)):
			return false
		if not _same_cell(seg, x + dx, z, kind, height, h_offset):
			return false
	return true

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
static func _build_ramps(seg, z_offset: int, h_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary) -> void:
	var width: int = seg.width
	var claimed: Dictionary = {}
	for x in width:
		var z := 0
		while z < seg.length:
			if seg.kind_at(x, z) != GridConfig.Kind.RAMP or claimed.has(Vector2i(x, z)):
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
			var bottom_h: int = _height_behind(seg, x, first)
			var top_h: int = seg.height_at(x, last)

			# ...and then ACROSS the bridge, over every neighbouring column that
			# is the same ramp. A two-cell-wide ramp built as two wedges has a
			# vertical seam down its middle, and a flat-bottomed cylinder walking
			# up the seam catches on it -- which presents as getting stuck
			# "sometimes", depending entirely on which side of the middle you
			# happened to be walking. Merging Z alone was half a fix.
			var columns := 1
			while x + columns < width \
					and _same_ramp_column(seg, x + columns, first, last, bottom_h, top_h) \
					and not claimed.has(Vector2i(x + columns, first)):
				columns += 1

			for cx in range(x, x + columns):
				for cz in range(first, last + 1):
					claimed[Vector2i(cx, cz)] = true

			var bottom: float = GridConfig.height_to_world(bottom_h + h_offset)
			var top: float = GridConfig.height_to_world(top_h + h_offset)
			var cells: int = last - first + 1

			# The run spans cells [first, last]; cell k occupies world z in
			# [-(k+1) * CELL, -k * CELL].
			var span: float = float(columns) * GridConfig.CELL_SIZE
			var centre_x: float = GridConfig.cell_origin_x(x, width) + span * 0.5
			var centre_z: float = -(float(first + z_offset) + float(last + z_offset) + 1.0) * 0.5 * GridConfig.CELL_SIZE
			var length: float = float(cells) * GridConfig.CELL_SIZE

			var mesh_res: Mesh = _wedge_mesh(bottom, top, length, span)
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

			# THE SKIRT, and it is not decoration -- it is the floor of the ramp.
			#
			# A wedge tapers to NOTHING at its lower end, and a ramp cell gets no
			# deck slab of its own (_build_deck emits boxes for DECK and WATER
			# only). So the first few centimetres of every ramp were a PAPER EDGE
			# over a DECK_THICKNESS-deep void with no floor under it. Measured
			# 2026-08-13 on the playtest bridge: the deck behind the ramp is 1.002 m
			# of solid, and 5 cm onto the ramp it is 0.053 m -- with its underside at
			# the deck's TOP, not its bottom. Step on that, sink a few millimetres,
			# and you are inside a metre-deep hole that has no bottom.
			#
			# The skirt is the same box the deck would have had. It closes the void,
			# makes the leading edge as thick as the deck it butts against, and turns
			# the seam into a solid-to-solid joint.
			var skirt_low: float = minf(bottom, top)
			var skirt_centre := Vector3(centre_x, skirt_low - GridConfig.DECK_THICKNESS * 0.5, centre_z)
			var skirt_size := Vector3(span, GridConfig.DECK_THICKNESS, length)
			_add_collision_box(body, skirt_centre, skirt_size)
			_add_mesh_box(meshes, skirt_centre, skirt_size, palette["ramp"])

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
# Is this column the SAME ramp as the one being merged -- same extent up the
# bridge, same climb, and not part of some other run that happens to touch it?
static func _same_ramp_column(seg, x: int, first: int, last: int,
		bottom_h: int, top_h: int) -> bool:
	for z in range(first, last + 1):
		if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
			return false
	# The run must START and END in the same rows, or the merged wedge would
	# cover cells that are not ramp at all.
	if first > 0 and seg.kind_at(x, first - 1) == GridConfig.Kind.RAMP:
		return false
	if last + 1 < seg.length and seg.kind_at(x, last + 1) == GridConfig.Kind.RAMP:
		return false
	return _height_behind(seg, x, first) == bottom_h and seg.height_at(x, last) == top_h

static func _wedge_mesh(bottom: float, top: float, length: float, span: float) -> Mesh:
	var rise: float = absf(top - bottom)
	if rise < 0.001:
		# A ramp that does not rise is authoring nonsense, but a zero-height
		# prism is a degenerate mesh -- fall back to a flat slab rather than
		# emitting geometry with no volume.
		var flat := BoxMesh.new()
		flat.size = Vector3(length, GridConfig.DECK_THICKNESS, span)
		return flat

	var prism := PrismMesh.new()
	# left_to_right = 0 puts the apex hard against one side, giving a RIGHT
	# triangle: one vertical face at full height, the hypotenuse falling away to
	# nothing. That is the shape of a ramp; the default 0.5 is a symmetric roof.
	prism.left_to_right = 0.0
	# Local X is the climb (the transform below turns it into the along-bridge
	# axis) and local Z is the extrusion, which becomes the width across.
	prism.size = Vector3(length, rise, span)
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

static func _build_walls(seg, z_offset: int, h_offset: int, body: StaticBody3D, meshes: Node3D,
		palette: Dictionary, out: Built) -> void:
	var width: int = seg.width
	for z in seg.length:
		for x in width:
			for dir in 4:
				if not seg.has_wall(x, z, dir):
					continue
				var height: int = seg.height_at(x, z) + h_offset
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
				GridConfig.Content.MOUND:
					out.mound_cells.append(Vector2i(x, z))
				GridConfig.Content.HAT:
					out.hat_cells.append(Vector2i(x, z))
				# [cell, kind] like gunner_cells, so which special is authored travels
				# with where it is rather than in a second parallel list.
				GridConfig.Content.PICKUP:
					out.special_cells.append([Vector2i(x, z), 0])
				GridConfig.Content.PICKUP_GRENADE:
					out.special_cells.append([Vector2i(x, z), 1])
				GridConfig.Content.PICKUP_MINE:
					out.special_cells.append([Vector2i(x, z), 2])
				GridConfig.Content.PICKUP_SHIELD:
					out.special_cells.append([Vector2i(x, z), 3])
				GridConfig.Content.PICKUP_ROCKET:
					out.special_cells.append([Vector2i(x, z), 4])
				GridConfig.Content.PICKUP_LEGS:
					out.special_cells.append([Vector2i(x, z), 5])
				GridConfig.Content.SKIRMISHER:
					out.gunner_cells.append([Vector2i(x, z), 0])
				GridConfig.Content.TURRET:
					out.gunner_cells.append([Vector2i(x, z), 1])
				GridConfig.Content.TREE:
					out.tree_cells.append(Vector2i(x, z))
				GridConfig.Content.HALF_WALL:
					out.half_wall_cells.append(Vector2i(x, z))
				GridConfig.Content.SPIKES:
					out.spike_cells.append(Vector2i(x, z))
				GridConfig.Content.GATE:
					# Once per ROW however many cells carry the glyph. The
					# validator has already refused a strip that does not span
					# the width, so any one cell is proof of the whole line.
					if not out.gate_rows.has(z):
						out.gate_rows.append(z)

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
