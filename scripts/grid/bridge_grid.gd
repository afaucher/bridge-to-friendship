extends Node3D

# The bridge at runtime: the authoritative cell data, the stones sitting on it,
# and the rules for pushing one.
#
# THE GRID IS DATA; THE NODES ARE A VIEW. A stone's position is a CELL, recorded
# here; the body that draws and collides with it follows. That is what lets a
# push be tested headless in milliseconds, and what makes a drop-in join cheap --
# the world is an authored segment plus a short list of what has moved, not a
# scene tree that has to be walked and invented a format for.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const StoneScene = preload("res://scenes/stone.tscn")
# The SCRIPT as well as the scene: enum values are script constants, and reading
# one through an instance (`stone.Mode.SETTLED`) raises a runtime error that
# ABORTS THE REST OF THE FUNCTION for that frame without halting the engine. A
# push then silently does nothing, which reads as "the shove missed".
const StoneBody = preload("res://scripts/sim/stone_body.gd")
const HeartScene = preload("res://scenes/heart.tscn")
const ShooterScene = preload("res://scenes/shooter.tscn")
const MoundScene = preload("res://scenes/mound.tscn")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

enum PushResult { BLOCKED, MOVED, FELL }

# The bridge's width in cells, taken from the first segment loaded. Every
# cell<->world conversion needs it, because the deck is centred on x = 0 -- so a
# bridge of a different width is a different mapping, not just a shorter row.
# Segments of differing widths would produce a step in the side of the bridge;
# the loader refuses them.
var width: int = GridConfig.DEFAULT_WIDTH

# The deck height the next segment will be stacked at -- the running total of
# every loaded segment's climb.
var _next_height: int = 0

# The run this bridge was assembled from. Held so a joining client can be told
# what to build rather than being sent the world.
var run_seed: int = 0

func segment_count() -> int:
	return _segments.size()

# Which segment a cell row belongs to. Segments vary in length, so this walks
# rather than dividing by a nominal size.
func segment_index_of_row(row: int) -> int:
	for i in _segments.size():
		var start: int = int(_segments[i]["z_offset"])
		if row >= start and row < start + int(_segments[i]["data"].length):
			return i
	return maxi(0, _segments.size() - 1)

func first_row_of_segment(index: int) -> int:
	if index < 0 or index >= _segments.size():
		return 0
	return int(_segments[index]["z_offset"])

# Build (or extend) a run from the pool. Deterministic in the seed, so every
# machine that is told the same seed and count builds the same bridge.
func build_run(seed_value: int, segment_count_wanted: int) -> void:
	run_seed = seed_value
	var plan: Array = SegmentPool.plan(seed_value, segment_count_wanted)
	for i in range(_segments.size(), plan.size()):
		load_segment_file(String(plan[i]))

# Loaded segments, each with the z at which it starts.
var _segments: Array = []          # [{data, z_offset}]
var _stones: Dictionary = {}       # Vector2i -> StoneBody
var _stone_root: Node3D = null
var _falling: Array = []           # stones no longer in the cell map

# Stones in creation order. Both machines load the same segments in the same
# order, so the index is a stable identity across the network -- which the cell
# is not, since the whole point of a stone is that its cell changes.
var _stone_list: Array = []

# Authored plinko shooter cells, in bridge coordinates. Collected by the loader
# so M6 only has to build the thing that stands on them.
var shooter_cells: Array = []

# Where the author put loose hats, in bridge coordinates. Reported rather than
# spawned: the hat pool owns hat bodies, and it drains this list as segments load
# so a hat authored in a segment streamed in later still appears.
var authored_hat_cells: Array = []

# Take the authored hat cells nobody has spawned yet. Emptied by the caller, so a
# segment loaded mid-run contributes its hats exactly once.
func take_authored_hat_cells() -> Array:
	var out: Array = authored_hat_cells.duplicate()
	authored_hat_cells.clear()
	return out

# Where the author put specials. Same arrangement as hats and for the same
# reason: the special pool owns the bodies, and it drains this list as segments
# load so a weapon authored in a segment streamed in later still appears.
var authored_special_cells: Array = []

func take_authored_special_cells() -> Array:
	var out: Array = authored_special_cells.duplicate()
	authored_special_cells.clear()
	return out

# Where players enter the bridge. Taken from authored SPAWN cells when a segment
# has them; otherwise a spread across the entry row, which is what every segment
# so far relies on.
func entry_spawn_cell(index: int) -> Vector2i:
	var lane: int = clampi(width / 2 - 3 + index * 2, 0, width - 1)
	return Vector2i(lane, 1)

func _ready() -> void:
	# Pitch the whole bridge so up-bridge is uphill. Rotating by +pitch about X
	# sends +Z down, and up the bridge is -Z, so the far end rises. Everything
	# built as a child inherits it, which is why the slope needs no rule
	# anywhere in the sim -- a loose ball simply rolls back at the players.
	rotation.x = deg_to_rad(GridConfig.BRIDGE_PITCH_DEG)

	_stone_root = Node3D.new()
	_stone_root.name = "Stones"
	add_child(_stone_root)

func load_segment_file(path: String) -> bool:
	var seg = SegmentData.from_file(path)
	if not seg.is_valid():
		printerr("[BridgeGrid] ", path, " failed to parse: ", ", ".join(seg.errors))
		return false
	load_segment(seg)
	return true

func load_segment(seg) -> void:
	if _segments.is_empty():
		width = seg.width
	elif seg.width != width:
		printerr("[BridgeGrid] segment '", seg.name, "' is ", seg.width,
			" cells wide but the bridge is ", width, " -- refusing to join a step into the deck")
		return

	var z_offset := next_z()
	# Every pool segment is authored starting at its own height 0 and climbing.
	# The run stacks them: each one is raised by wherever the previous one
	# finished, so the bridge keeps going up without any segment having to know
	# what came before it.
	var h_offset := _next_height
	_segments.append({"data": seg, "z_offset": z_offset, "h_offset": h_offset})
	_next_height = h_offset + seg.exit_height()

	var built = SegmentBuilder.build(seg, z_offset, h_offset)
	add_child(built.root)

	for local_cell in built.stone_cells:
		var cell := Vector2i(local_cell.x, local_cell.y + z_offset)
		_spawn_stone(cell)

	for local_cell in built.shooter_cells:
		var cell := Vector2i(local_cell.x, local_cell.y + z_offset)
		shooter_cells.append(cell)
		_spawn_shooter(cell)

	for local_cell in built.heart_cells:
		_spawn_heart(Vector2i(local_cell.x, local_cell.y + z_offset))

	for local_cell in built.mound_cells:
		_spawn_mound(Vector2i(local_cell.x, local_cell.y + z_offset))

	# Authored hats are recorded, not spawned here. A hat is a free sim body owned
	# by the world's hat pool, not grid-resident data like a stone or a heart --
	# it lands wherever it lands once somebody knocks it off a head, and a cell
	# record would mean two representations of one object.
	for local_cell in built.hat_cells:
		authored_hat_cells.append(Vector2i(local_cell.x, local_cell.y + z_offset))

	for local_cell in built.special_cells:
		authored_special_cells.append(Vector2i(local_cell.x, local_cell.y + z_offset))

func next_z() -> int:
	var total := 0
	for s in _segments:
		total += s["data"].length
	return total

func total_length() -> int:
	return next_z()

# --- Cell queries -------------------------------------------------------------
#
# Every query resolves the owning segment and converts to its local z. Callers
# work in bridge coordinates and never think about segment boundaries.

func _resolve(cell: Vector2i) -> Array:
	for s in _segments:
		var local_z: int = cell.y - int(s["z_offset"])
		if local_z >= 0 and local_z < s["data"].length:
			return [s["data"], local_z, int(s["h_offset"])]
	return []

func kind_at(cell: Vector2i) -> int:
	var r := _resolve(cell)
	if r.is_empty():
		return GridConfig.Kind.HOLE
	return r[0].kind_at(cell.x, r[1])

func height_at(cell: Vector2i) -> int:
	var r := _resolve(cell)
	if r.is_empty():
		return 0
	# Plus the segment's stacking offset -- a cell's height is where it sits in
	# the RUN, not where it sits in the file it was authored in.
	return r[0].height_at(cell.x, r[1]) + int(r[2])

func is_solid(cell: Vector2i) -> bool:
	var r := _resolve(cell)
	if r.is_empty():
		return false
	return r[0].is_solid(cell.x, r[1])

func has_wall(cell: Vector2i, dir: int) -> bool:
	var r := _resolve(cell)
	if r.is_empty():
		return false
	return r[0].has_wall(cell.x, r[1], dir)

func cell_of(local_position: Vector3) -> Vector2i:
	return GridConfig.world_to_cell(local_position, width)

# The cell under a point given in the PARENT's space (where players live). The
# bridge is pitched, so anything holding a player position needs this rather
# than cell_of().
func cell_of_world(world_position: Vector3) -> Vector2i:
	return GridConfig.world_to_cell(transform.affine_inverse() * world_position, width)

func cell_surface(cell: Vector2i) -> Vector3:
	return GridConfig.cell_centre(cell.x, cell.y, height_at(cell), width)

# The same point in the PARENT's space (the GameWorld's), which is where players
# live. The bridge is pitched, so grid-local and world coordinates are not the
# same thing -- anything placing a body by cell wants this one.
func cell_surface_world(cell: Vector2i) -> Vector3:
	return transform * cell_surface(cell)

# --- Stones -------------------------------------------------------------------

func stone_at(cell: Vector2i) -> Node:
	return _stones.get(cell)

func stone_count() -> int:
	return _stones.size()

func _spawn_stone(cell: Vector2i) -> void:
	var stone: Node3D = StoneScene.instantiate()
	stone.name = "Stone_%d_%d" % [cell.x, cell.y]
	stone.cell = cell
	stone.position = _stone_rest_position(cell)
	_stone_root.add_child(stone)
	_stones[cell] = stone
	_stone_list.append(stone)

func _stone_rest_position(cell: Vector2i) -> Vector3:
	var surface := cell_surface(cell)
	# Sitting ON the deck, not sunk into it.
	surface.y += GridConfig.CELL_SIZE * 0.5
	return surface

# A dashing player shoves the stone in `cell` one cell along `dir`.
#
# ONE CELL, ALWAYS -- never a variable distance that depends on approach angle or
# how fast the shover happened to be going. That legibility is the point: a
# player across the bridge can see what happened.
func try_push(cell: Vector2i, dir: int) -> int:
	var stone: Node = _stones.get(cell)
	if stone == null or stone.mode != StoneBody.Mode.SETTLED:
		return PushResult.BLOCKED

	var step: Vector2i = GridConfig.DIR_CELLS[dir]
	var destination := cell + step

	# A parapet between the two cells stops it, as does another stone.
	if has_wall(cell, dir) or _stones.has(destination):
		return PushResult.BLOCKED

	if not is_solid(destination):
		# Pushed off the edge or into a hole. The reward for rearranging the
		# bridge -- and the way a blocked route gets opened.
		_stones.erase(cell)
		_falling.append(stone)
		stone.start_falling(GridConfig.DIR_VECTORS[dir])
		return PushResult.FELL

	# Cannot be shoved up a step; the stone would have to climb.
	if height_at(destination) > height_at(cell):
		return PushResult.BLOCKED

	_stones.erase(cell)
	_stones[destination] = stone
	stone.slide_to(destination, _stone_rest_position(destination))
	return PushResult.MOVED

# --- Stepping -----------------------------------------------------------------

func step_stones() -> void:
	for key in _stones.keys():
		_stones[key].step()
	for i in range(_falling.size() - 1, -1, -1):
		var stone: Node = _falling[i]
		stone.step()
		if stone.is_gone():
			_falling.remove_at(i)
			stone.queue_free()

# --- Shooters -----------------------------------------------------------------
#
# The grid builds the shooter as SCENERY only. Firing is the world's job, because
# a ball is authoritative gameplay and the grid is a view of authored data -- the
# same split that keeps stones' cells in the grid and stones' motion in the sim.

var _shooter_root: Node3D = null

func _spawn_shooter(cell: Vector2i) -> void:
	if _shooter_root == null:
		_shooter_root = Node3D.new()
		_shooter_root.name = "Shooters"
		add_child(_shooter_root)
	var shooter: Node3D = ShooterScene.instantiate()
	shooter.name = "Shooter_%d_%d" % [cell.x, cell.y]
	shooter.position = cell_surface(cell) + Vector3(0.0, GridConfig.CELL_SIZE * 0.5, 0.0)
	_shooter_root.add_child(shooter)

# Where a ball leaves the barrel, in the world's space. Above the pillar, so a
# ball never spawns inside the thing that fired it.
func shooter_muzzle(cell: Vector2i) -> Vector3:
	return cell_surface_world(cell) + Vector3(0.0, GridConfig.CELL_SIZE + 0.9, 0.0)

# --- Hearts -------------------------------------------------------------------
#
# First come, first served: a thing to communicate about rather than a thing to
# collect. Exclusivity is by construction -- taking one removes it, so a second
# player arriving a tick later finds nothing.

var _hearts: Dictionary = {}     # Vector2i -> the node drawn there
var _heart_root: Node3D = null

func _spawn_heart(cell: Vector2i) -> void:
	if _heart_root == null:
		_heart_root = Node3D.new()
		_heart_root.name = "Hearts"
		add_child(_heart_root)
	var heart: Node3D = HeartScene.instantiate()
	heart.name = "Heart_%d_%d" % [cell.x, cell.y]
	heart.position = cell_surface(cell) + Vector3(0.0, 0.8, 0.0)
	_heart_root.add_child(heart)
	_hearts[cell] = heart

func heart_count() -> int:
	return _hearts.size()

# Take the heart within reach of `world_position`, if there is one. Returns true
# exactly once per heart.
func try_take_heart(world_position: Vector3) -> bool:
	if _hearts.is_empty():
		return false
	var local: Vector3 = transform.affine_inverse() * world_position
	for cell in _hearts.keys():
		var heart: Node3D = _hearts[cell]
		if not is_instance_valid(heart):
			continue
		if heart.position.distance_to(local) <= SimConfig.HEART_PICKUP_RADIUS:
			_hearts.erase(cell)
			heart.queue_free()
			return true
	return false

# --- Mounds -------------------------------------------------------------------
#
# A dormant rusher: an authored cell that becomes an enemy when someone walks
# close enough. Kept on the GRID rather than in GameWorld for the same reason
# everything else is -- a mound is authored terrain, so it is a property of the
# bridge, and a client that built the same segments already has every one of them
# without being told.
#
# A MOUND IS SPENT ONCE. Answering the open question in hazards.md the simple
# way: a mound that refilled would make authored density meaningless, because the
# hazard would then be a function of how long you loiter rather than of where the
# level designer put it.

var _mounds: Dictionary = {}     # Vector2i -> the node drawn there
var _mound_root: Node3D = null
# Which cells have already been used, so a client that joins mid-run can be told
# in one message rather than being left drawing lumps that are not there.
var _spent_mounds: Array = []    # Vector2i

func _spawn_mound(cell: Vector2i) -> void:
	if _mound_root == null:
		_mound_root = Node3D.new()
		_mound_root.name = "Mounds"
		add_child(_mound_root)
	var mound: Node3D = MoundScene.instantiate()
	mound.name = "Mound_%d_%d" % [cell.x, cell.y]
	# Sitting ON the deck, half its own height proud of it.
	mound.position = cell_surface(cell) + Vector3(0.0, 0.17, 0.0)
	_mound_root.add_child(mound)
	_mounds[cell] = mound

func mound_count() -> int:
	return _mounds.size()

func mound_cells() -> Array:
	return _mounds.keys()

# Where a rusher stands once it has finished emerging, in the world's space.
func mound_surface_world(cell: Vector2i) -> Vector3:
	return cell_surface_world(cell) + Vector3(0.0, SimConfig.RUSHER_HEIGHT * 0.5, 0.0)

# Wake the mound at `cell`: the lump goes, and it never comes back. Returns false
# if there was nothing there, so the caller cannot spawn two rushers from one
# mound by asking twice in a frame.
func take_mound(cell: Vector2i) -> bool:
	if not _mounds.has(cell):
		return false
	var mound: Node3D = _mounds[cell]
	_mounds.erase(cell)
	_spent_mounds.append(cell)
	if is_instance_valid(mound):
		mound.queue_free()
	return true

# The spent set as flat x,z pairs -- the same shape as stone_layout(), and for
# the same reason: a joining client rebuilds the bridge from the seed, which
# gives it every mound INCLUDING the ones already used. One compact message
# reconciles that, and it is sent once on join rather than every tick, because a
# mound changes state exactly once in its life.
func spent_mound_layout() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in _spent_mounds:
		out.append(cell.x)
		out.append(cell.y)
	return out

func apply_spent_mounds(layout: PackedInt32Array) -> void:
	var i := 0
	while i + 1 < layout.size():
		take_mound(Vector2i(layout[i], layout[i + 1]))
		i += 2

func all_stones() -> Array:
	var out: Array = _stones.values().duplicate()
	out.append_array(_falling)
	return out

# --- Replication --------------------------------------------------------------
#
# Stones are host-authoritative and are NOT predicted by clients: a push is
# resolved by a collision with a body the client does not own, so predicting it
# would be guessing. Indexed by creation order, which both machines agree on
# because both loaded the same segments.

# MOST STONES NEVER MOVE, so most ticks send nothing about them.
#
# Sending every stone every tick was measured at 4595 bytes on a three-segment
# run -- over ENet's 1392-byte MTU, which fragments an UNRELIABLE packet and
# raises the loss rate on exactly the channel that can least afford it. A run is
# mostly scenery standing still; only the handful mid-slide are news.
#
# `full` is the periodic resync: a client that missed the one tick a push
# happened on would otherwise hold a stale cell forever, so the whole list goes
# out on a slow cadence and any drift heals within half a second.
func stone_snapshot() -> Array:
	var out: Array = []
	for i in _stone_list.size():
		var stone: Node = _stone_list[i]
		if is_instance_valid(stone) and stone.mode != StoneBody.Mode.SETTLED:
			out.append([i, stone.capture_state()])
	return out

# The resync: just WHERE EACH STONE IS, as three ints. A settled stone's position
# is derivable from its cell, so sending its full state is sending the same fact
# twice in a much more expensive format -- measured 4582 bytes for one run's
# worth against roughly 800 for this.
func stone_layout() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in _stone_list.size():
		var stone: Node = _stone_list[i]
		if not is_instance_valid(stone):
			continue
		out.append(i)
		out.append(stone.cell.x)
		out.append(stone.cell.y)
	return out

func apply_stone_layout(data: PackedInt32Array) -> void:
	var i := 0
	while i + 2 < data.size():
		var index: int = data[i]
		var cell := Vector2i(data[i + 1], data[i + 2])
		i += 3
		if index < 0 or index >= _stone_list.size():
			continue
		var stone: Node = _stone_list[index]
		# A stone mid-slide is being driven by the per-tick entries; snapping it
		# to a cell here would fight them.
		if not is_instance_valid(stone) or stone.mode != StoneBody.Mode.SETTLED:
			continue
		if stone.cell != cell:
			stone.cell = cell
			stone.position = _stone_rest_position(cell)
	_rebuild_cell_map()

func apply_stone_snapshot(entries: Array) -> void:
	for e in entries:
		var index: int = int(e[0])
		if index < 0 or index >= _stone_list.size():
			continue
		var stone: Node = _stone_list[index]
		if is_instance_valid(stone):
			stone.apply_state(e[1])
	_rebuild_cell_map()

# The cell map is derived from where the stones actually are, so a client that
# misses a push still converges: it is never the client's own bookkeeping that
# decides which cell a stone occupies.
func _rebuild_cell_map() -> void:
	_stones.clear()
	for stone in _stone_list:
		if is_instance_valid(stone) and stone.mode != StoneBody.Mode.FALLING:
			_stones[stone.cell] = stone
