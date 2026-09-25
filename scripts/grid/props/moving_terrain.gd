extends RefCounted

# TERRAIN THAT MOVES: the elevators (M17 phase 9), which ride up and down on a
# clock both machines share, and the mutable slabs (M17 phase 8) -- crumbling and
# timed floor -- which open and close. They share a root, and they are the two
# props whose state the world steps and the wire has to agree about: an elevator
# is a pure function of the tick, an open slab is sent as the whole open set.
#
# The CELLS (elevator_cells, mutable_cells) stay on the grid, where load_segment
# records them and the world reads them; this holds the bodies and their state.

const Layers = preload("res://scripts/core/layers.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

var grid = null

func attach(g) -> void:
	grid = g

var _mutable_root: Node3D = null
var _mutable: Dictionary = {}          # Vector2i -> {"body":, "mesh":, "content":}
var _open_cells: Dictionary = {}       # Vector2i -> true while the slab is GONE
var _elevators: Dictionary = {}        # Vector2i -> {"body":, "mesh":, "low":, "high":}

# --- Elevators (M17 phase 9) --------------------------------------------------
#
# THE PHASE THE PLAN CALLED THE WORST NETCODE CASE IN THE DOCUMENT, and the
# reason it is not is one restriction: AN ELEVATOR MOVES ONLY VERTICALLY.
#
# The warning was real and is in CLAUDE.md: Godot transports a rider on a moving
# body using engine-internal state that `capture_state()` cannot restore, so a
# client replaying a correction while riding would replay it with the wrong
# carry. A vertical platform needs no carry at all. Going up it PUSHES the body
# standing on it, which is ordinary collision and rewinds like any other; going
# down, gravity keeps the body in contact. There is nothing horizontal to
# transport, so there is no engine state to fail to rewind.
#
# AND ITS POSITION IS A PURE FUNCTION OF THE TICK. No wire, no host authority, no
# join catch-up: a client that agrees about the tick agrees about where every
# platform in the world is, INCLUDING at a tick it is replaying. That is the
# opposite of mutable terrain next door, which had to be broadcast precisely
# because its rule has an authoritative exception. The difference is worth
# stating: an elevator never has to refuse to move, so nothing about it is a
# decision.
func spawn_elevator(cell: Vector2i) -> void:
	if _mutable_root == null:
		_mutable_root = Node3D.new()
		_mutable_root.name = "Mutable"
		grid.add_child(_mutable_root)

	var high: float = grid.cell_surface(cell).y
	# THE DECK IT SERVES is the lowest solid neighbour: an elevator is authored at
	# the height it RISES TO, and where it comes back down to is read off the
	# terrain rather than authored twice and allowed to disagree with it.
	var low: float = high
	for dir in 4:
		var side: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if grid.is_solid(side):
			low = minf(low, grid.cell_surface(side).y)

	var thick: float = GridConfig.DECK_THICKNESS
	# ANIMATABLE, NOT STATIC. A StaticBody3D moved by hand does not push what is
	# standing on it -- it teleports through it -- and the whole point of this slab
	# is that it carries somebody.
	var body := AnimatableBody3D.new()
	body.name = "Elevator_%d_%d" % [cell.x, cell.y]
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	body.sync_to_physics = true
	body.position = Vector3(grid.cell_surface(cell).x, low - thick * 0.5, grid.cell_surface(cell).z)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# OVERSIZED BY A HAIR, and the first version had it INSET by one -- which is
	# the same seam trap CLAUDE.md carries from the ramps, except this box moves.
	#
	# Measured: with a 4 cm gap between the platform and the deck beside it, a body
	# walking on at full stick STOPPED DEAD at the boundary and stayed there, with
	# the platform level and nothing above foot height in the way. A flat-bottomed
	# cylinder does not cross a gap, it catches the far lip of one — and two boxes
	# placed exactly face to face are the same problem with the gap set to zero.
	# Overlapping buries the platform's vertical face INSIDE the deck box, so a
	# body crossing at deck height never meets an exposed edge at all.
	box.size = Vector3(GridConfig.CELL_SIZE + 0.06, thick, GridConfig.CELL_SIZE + 0.06)
	shape.shape = box
	body.add_child(shape)
	_mutable_root.add_child(body)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.ELEVATOR_COLOUR
	mat.metallic = 0.5
	mat.roughness = 0.4
	var mesh := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = box.size
	mesh.mesh = cube
	mesh.material_override = mat
	body.add_child(mesh)

	_shaft_frame(cell, low, high)
	_elevators[cell] = {"body": body, "low": low, "high": high}

# FOUR POSTS THAT DO NOT MOVE, marking where the shaft is.
#
# Without them a lift is unreadable in both of its states, and each failure is
# its own kind of unfair. DOWN, it is a slab flush with the deck: you walk over
# the way up without noticing it. UP, its cell is an open hole with nothing
# around it, which is a trap rather than a hazard — you cannot avoid a thing
# whose only tell is that the floor is missing.
#
# NO COLLIDER. The posts are at the corners, which is exactly where a body
# squeezes past a doorway, and a decoration that catches a player is worse than
# no decoration. They are scenery, and the platform is the only solid thing here.
func _shaft_frame(cell: Vector2i, low: float, high: float) -> void:
	if is_equal_approx(low, high):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.ELEVATOR_COLOUR.darkened(0.35)
	mat.metallic = 0.6
	mat.roughness = 0.5

	var span: float = high - low
	var post := BoxMesh.new()
	# Up to the top of the travel, so the frame is as tall as the thing is
	# capable of being. A frame that stopped short would say the lift did too.
	post.size = Vector3(0.12, span, 0.12)
	var half: float = GridConfig.CELL_SIZE * 0.5 - 0.06
	var centre: Vector3 = grid.cell_surface(cell)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var bar := MeshInstance3D.new()
			bar.mesh = post
			bar.material_override = mat
			bar.position = Vector3(centre.x + sx * half, low + span * 0.5,
				centre.z + sz * half)
			_mutable_root.add_child(bar)

# WHERE A PLATFORM'S SURFACE IS AT TICK `t`. Rise, dwell, fall, dwell -- and the
# dwells are not decoration: a platform that reverses the instant it arrives is
# one you cannot step onto, because stepping on takes longer than nothing.
#
# The phase comes off the CELL so neighbours are not synchronised, the same way
# timed blocks are, and for the same reason.
func elevator_surface_y(cell: Vector2i, at_tick: int) -> float:
	if not _elevators.has(cell):
		return 0.0
	var record: Dictionary = _elevators[cell]
	var low: float = record["low"]
	var high: float = record["high"]
	if is_equal_approx(low, high):
		return high
	var rise: int = SimConfig.ELEVATOR_RISE_TICKS
	var dwell: int = SimConfig.ELEVATOR_DWELL_TICKS
	var period: int = (rise + dwell) * 2
	var phase: int = absi(cell.x * 11 + cell.y * 17) % period
	var at: int = (at_tick + phase) % period
	if at < rise:
		return lerpf(low, high, float(at) / float(rise))
	at -= rise
	if at < dwell:
		return high
	at -= dwell
	if at < rise:
		return lerpf(high, low, float(at) / float(rise))
	return low

# Called once per sim tick, on BOTH machines, because there is nothing to agree
# about beyond the tick itself.
func step_elevators(at_tick: int) -> void:
	for cell in _elevators:
		var body: Node = _elevators[cell]["body"]
		if not is_instance_valid(body):
			continue
		body.position.y = elevator_surface_y(cell, at_tick) - GridConfig.DECK_THICKNESS * 0.5

func elevator_low_high(cell: Vector2i) -> Vector2:
	if not _elevators.has(cell):
		return Vector2.ZERO
	return Vector2(_elevators[cell]["low"], _elevators[cell]["high"])

# --- Mutable terrain (M17 phase 8) -------------------------------------------
#
# A cell that stops being solid at runtime, and comes back. Two authored triggers
# on one mechanism: CRUMBLE goes when somebody stands on it, TIMED goes on a
# clock. The design doc lists "destroyable squares" and "timed blocks" as separate
# wishes; they are the same sentence with a different subject.
#
# WHY THIS IS CHEAP, when the doc expected it to be the expensive one: deck
# collision is merged into greedy rectangles, so removing a cell from a merged
# box means re-merging a segment and re-uploading its shape. The answer is not to
# make the re-merge fast — it is to keep these cells OUT of the merge in the
# first place. Each is its own slab, removal is `queue_free`, and the merge still
# does its 30-boxes-to-one job on all the deck that never moves.
#
# THE HOST OWNS THE STATE, and it is broadcast rather than derived. A timed block
# could be a pure function of the tick, and that was the first design: no traffic
# at all. It was dropped because the RESTORE cannot be — a slab must not
# re-appear inside a body standing in its volume (the coincident-body trap in
# CLAUDE.md is exactly this, one body inside another), so the host has to be able
# to DEFER a close. A rule with one authoritative exception is not deterministic,
# and two mechanisms agreeing most of the time is worse than one that always does.
func spawn_mutable(cell: Vector2i, content: int) -> void:
	if _mutable_root == null:
		_mutable_root = Node3D.new()
		_mutable_root.name = "Mutable"
		grid.add_child(_mutable_root)

	var top: Vector3 = grid.cell_surface(cell)
	var thick: float = GridConfig.DECK_THICKNESS

	var body := StaticBody3D.new()
	body.name = "Mutable_%d_%d" % [cell.x, cell.y]
	body.collision_layer = Layers.WORLD     # world, like the deck it stands in for
	body.collision_mask = 0
	body.position = top - Vector3(0.0, thick * 0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GridConfig.CELL_SIZE, thick, GridConfig.CELL_SIZE)
	shape.shape = box
	body.add_child(shape)
	_mutable_root.add_child(body)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.CRUMBLE_COLOUR if content == GridConfig.Content.CRUMBLE 		else GridConfig.TIMED_COLOUR
	var mesh := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = box.size
	mesh.mesh = cube
	mesh.material_override = mat
	mesh.position = body.position
	_mutable_root.add_child(mesh)

	_mutable[cell] = {"body": body, "mesh": mesh, "content": content}

func mutable_content(cell: Vector2i) -> int:
	if not _mutable.has(cell):
		return GridConfig.Content.NONE
	return int(_mutable[cell]["content"])

func is_cell_open(cell: Vector2i) -> bool:
	return _open_cells.has(cell)

# Returns whether anything CHANGED, so the caller knows when to spend a packet.
# The nodes are hidden and disabled rather than freed: a cell that comes back has
# to come back identical, and rebuilding it would be a second construction path
# for a thing that already exists.
func set_cell_open(cell: Vector2i, open: bool) -> bool:
	if not _mutable.has(cell):
		return false
	if open == _open_cells.has(cell):
		return false
	if open:
		_open_cells[cell] = true
	else:
		_open_cells.erase(cell)
	var record: Dictionary = _mutable[cell]
	var body: Node = record["body"]
	var mesh: Node = record["mesh"]
	if is_instance_valid(body):
		# DISABLED DEFERRED. Godot forbids changing a body's collision state from
		# inside the physics step, and this is called from the sim tick.
		body.set_deferred("process_mode", Node.PROCESS_MODE_DISABLED if open else Node.PROCESS_MODE_INHERIT)
		body.set_deferred("collision_layer", 0 if open else 1)
	if is_instance_valid(mesh):
		mesh.visible = not open

	return true

# The open set as flat x,z pairs, the same shape as spent_mound_layout() and for
# the same reason: a joining client rebuilds the bridge from the seed, which
# gives it every mutable cell CLOSED. One compact message reconciles that.
func open_cell_layout() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in _open_cells:
		out.append(cell.x)
		out.append(cell.y)
	return out

func apply_open_cells(layout: PackedInt32Array) -> void:
	var wanted: Dictionary = {}
	var i := 0
	while i + 1 < layout.size():
		wanted[Vector2i(layout[i], layout[i + 1])] = true
		i += 2
	# BOTH DIRECTIONS. A layout is the whole truth about the open set, so a cell
	# this machine thinks is open and the host does not has to CLOSE — a
	# one-directional apply would leave a client standing on air the host filled in.
	for cell in _mutable:
		set_cell_open(cell, wanted.has(cell))
