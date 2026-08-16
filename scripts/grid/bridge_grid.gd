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
#
# A ROW BEFORE THE BRIDGE IS THE FIRST SEGMENT, NOT THE LAST. This function used
# to answer "the last one" for ANY row it could not place, and a row behind the
# start is exactly that -- so a player standing off the back end of the bridge
# was reported as being at the very front of everything built. Two playtest bugs
# on 2026-08-15, both of them this line:
#
#   THE GAME DIED IF YOU STEPPED OFF THE BACK AT SPAWN. _extend_run keeps
#   RUN_LOOKAHEAD_SEGMENTS ahead of the front, so "the front is the last segment"
#   means build more, which moves the last segment, which means build more.
#   Measured: 199 segments and 4198 rows -- 8.4 km of bridge geometry -- within
#   two seconds of walking backwards off the edge.
#   RESPAWNS LANDED WAY AHEAD OF WHERE THE PARTY GOT. _bank_checkpoint banks off
#   the same answer, so it banked a row thousands up the bridge and the wipe
#   returned everyone there, past ground nobody had crossed.
#
# The clamp at the end is still right for a row PAST the end -- that is a party
# at the front of a bridge still being built, which is the ordinary case every
# frame. It was only ever wrong in the other direction.
func segment_index_of_row(row: int) -> int:
	if _segments.is_empty():
		return 0
	if row < int(_segments[0]["z_offset"]):
		return 0
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

# Enemies that shoot, reported rather than spawned -- the same arrangement hats
# and specials use. An enemy is a body the WORLD owns and steps; the grid's job
# ends at saying where the author put one.
var authored_gunner_cells: Array = []      # [[cell, kind], ...]

func take_authored_gunner_cells() -> Array:
	var out: Array = authored_gunner_cells.duplicate()
	authored_gunner_cells.clear()
	return out

# --- Round boundaries (M16) ---------------------------------------------------
#
# A boundary is a BAND of rows, not one row. Two deep as authored, which is a
# playtest decision (2026-08-15): one row is 2 m, and a party of four told to
# stand on it together is a party jostling on a strip narrower than they are,
# with the barrier in their faces. Two rows gives them somewhere to be.
#
# STORED AS BANDS RATHER THAN LOOSE ROWS, because every question about a boundary
# is about its EDGES: the target is where the band begins, the front wall stands
# past where it ends, and the rear wall behind where it begins. A flat list of
# rows would make each of those a scan with an off-by-one in it.
#
# THE ROUND MACHINE ASKS THE GRID, AND NEVER DOES ARITHMETIC ON A POSITION. The
# bridge is assembled from a seed and segments vary in length, so the only stable
# name for a place is the cell an author drew it in.
var gate_rows: Array = []          # int, run-space z, ascending -- every marked row
var gate_bands: Array = []         # [[first_row, last_row], ...] ascending

func is_gate_row(row: int) -> bool:
	return gate_rows.has(row)

# The band containing `row`, or an empty array.
func gate_band_at(row: int) -> Array:
	for band in gate_bands:
		if row >= int(band[0]) and row <= int(band[1]):
			return band
	return []

# Where the next boundary BEGINS, strictly up-bridge of `row`. -1 rather than a
# guess: "there is no next boundary" is a real state during a run whose next
# segment has not been appended, and a caller handed a plausible wrong number
# cannot tell.
func gate_after(row: int) -> int:
	for band in gate_bands:
		if int(band[0]) > row:
			return int(band[0])
	return -1

# The last row of the band that BEGINS at `row`. The front wall stands past this,
# so the whole band is standable.
func gate_band_end(row: int) -> int:
	for band in gate_bands:
		if int(band[0]) == row:
			return int(band[1])
	return row

func gate_at_or_before(row: int) -> int:
	var best := -1
	for band in gate_bands:
		if int(band[0]) <= row:
			best = int(band[0])
	return best

# Contiguous marked rows collapse into one band. Rebuilt from scratch each time a
# segment lands, because a band can SPAN A SEGMENT JOIN -- a lobby whose last row
# is marked butted against a section whose first row is marked is one boundary,
# not two, and treating it as two would put a wall in the middle of it.
func _rebuild_gate_bands() -> void:
	gate_bands.clear()
	if gate_rows.is_empty():
		return
	var start: int = int(gate_rows[0])
	var prev: int = start
	for i in range(1, gate_rows.size()):
		var r: int = int(gate_rows[i])
		if r == prev + 1:
			prev = r
			continue
		gate_bands.append([start, prev])
		start = r
		prev = r
	gate_bands.append([start, prev])

# Where players enter the bridge. Taken from authored SPAWN cells when a segment
# has them; otherwise a spread across the entry row, which is what every segment
# so far relies on.
# TWO INDICES MUST NEVER GIVE ONE CELL, which is why this wraps rather than
# clamps. A clamp folds every out-of-range index onto the last column, and the
# thing that then happens is not "somebody spawns at the edge" -- it is TWO
# BODIES IN ONE PLACE, which depenetrate into a degenerate normal and are driven
# down through the floor (CLAUDE.md). Observed 2026-08-15 when a caller passed a
# peer id here: over the network those are large random ints, so every straggler
# folded onto the outer column together.
#
# The caller was fixed too. This is the half that means the next caller to get it
# wrong produces a player standing somewhere odd rather than a party falling
# through the bridge.
func entry_spawn_cell(index: int) -> Vector2i:
	var lanes: int = maxi(1, width / 2)
	var slot: int = posmod(index, lanes)
	var lane: int = clampi(width / 2 - 3 + slot * 2, 0, width - 1)
	return Vector2i(lane, _first_standable_row())

# ROW 1 UNLESS ROW 1 IS A BOUNDARY. It was a flat `1` until the round bands went
# two deep (2026-08-15), at which point a lobby's entry band covered rows 0 and 1
# and the whole party spawned STANDING ON THE LINE they are supposed to walk up
# to. Harmless to the machine -- the target is the band ahead either way -- and
# wrong for the player, who is told to gather on a strip they are already on.
#
# Walked rather than assumed to be band-length + 1: a segment may open with no
# band at all (every test fixture does), and a fixed offset would push those
# spawns a row up the bridge for no reason.
func _first_standable_row() -> int:
	var row := 1
	while row < 8 and is_gate_row(row):
		row += 1
	return row

func _ready() -> void:
	# Pitch the whole bridge so up-bridge is uphill. Rotating by +pitch about X
	# sends +Z down, and up the bridge is -Z, so the far end rises. Everything
	# built as a child inherits it, which is why the slope needs no rule
	# anywhere in the sim -- a loose ball simply rolls back at the players.
	rotation.x = deg_to_rad(GridConfig.BRIDGE_PITCH_DEG)

	_stone_root = Node3D.new()
	_stone_root.name = "Stones"
	add_child(_stone_root)

const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")

# Themes are OFF for an explicit segment list and ON for an assembled run. A map
# pinned by name is pinned on purpose -- playtest_bridge is authored for feel and
# every test fixture is authored to be measured, and dressing either would change
# what they are. `assemble_run` is the same switch _extend_run uses for the same
# reason.
var dress_hazards: bool = false

func load_segment_file(path: String) -> bool:
	var seg = SegmentData.from_file(path)
	if not seg.is_valid():
		printerr("[BridgeGrid] ", path, " failed to parse: ", ", ".join(seg.errors))
		return false
	# BEFORE load_segment, because dressing writes cell records and load_segment
	# turns cell records into bodies and meshes. The other order would mean
	# building the segment twice.
	if dress_hazards and not seg.tags.has("lobby"):
		var index: int = _segments.size()
		var theme: String = HazardDressing.theme_for(run_seed, index)
		HazardDressing.dress(seg, theme, run_seed, index)
	load_segment(seg)
	return true

func load_segment(seg) -> void:
	if _segments.is_empty():
		width = seg.width
	elif seg.width != width:
		printerr("[BridgeGrid] segment '", seg.name, "' is ", seg.width,
			" cells wide but the bridge is ", width, " -- refusing to join a step into the deck")
		return

	# THE JOIN CONTRACT (M17). Refused here for the same reason a width mismatch is
	# refused two lines up: a segment that cannot be entered from the one before it
	# is a dead end, and a dead end nobody printed is an unfinishable run that
	# looks like a bug in the player's own movement.
	#
	# Overlap only, which is the weakest rule that works -- ONE cell solid on both
	# sides. Whether the party can then CROSS the segment is SegmentValidator's
	# question and is checked in the gate over many seeds; this is the cheap guard
	# that runs on every real assembly.
	if not _segments.is_empty():
		var prev = _segments[-1]["data"]
		var overlap := 0
		for x in mini(prev.width, seg.width):
			if prev.is_solid(x, prev.length - 1) and seg.is_solid(x, 0):
				overlap += 1
		if overlap == 0:
			printerr("[BridgeGrid] segment '", seg.name, "' cannot be entered from '",
				prev.name, "' -- no column is solid on both sides of the join")
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

	for local_cell in built.tree_cells:
		_spawn_cover(Vector2i(local_cell.x, local_cell.y + z_offset), true)
	for local_cell in built.half_wall_cells:
		_spawn_cover(Vector2i(local_cell.x, local_cell.y + z_offset), false)
	for local_cell in built.spike_cells:
		var sc := Vector2i(local_cell.x, local_cell.y + z_offset)
		spike_cells.append(sc)
		_spawn_spikes(sc)

	# Authored hats are recorded, not spawned here. A hat is a free sim body owned
	# by the world's hat pool, not grid-resident data like a stone or a heart --
	# it lands wherever it lands once somebody knocks it off a head, and a cell
	# record would mean two representations of one object.
	for local_cell in built.hat_cells:
		authored_hat_cells.append(Vector2i(local_cell.x, local_cell.y + z_offset))

	for entry in built.special_cells:
		var sc: Vector2i = entry[0]
		authored_special_cells.append([Vector2i(sc.x, sc.y + z_offset), int(entry[1])])

	for entry in built.gunner_cells:
		var gc: Vector2i = entry[0]
		authored_gunner_cells.append([Vector2i(gc.x, gc.y + z_offset), int(entry[1])])

	# Boundaries are recorded in RUN space and kept sorted, because gate_after
	# walks them in order. Segments only ever append, so this stays sorted by
	# construction -- but a run that ever loaded out of order would break
	# gate_after silently, which is the kind of thing worth one line to prevent.
	for local_row in built.gate_rows:
		var run_row: int = int(local_row) + z_offset
		if not gate_rows.has(run_row):
			gate_rows.append(run_row)
	gate_rows.sort()
	_rebuild_gate_bands()

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
	stone.grid = self
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

# Live shooters by cell, and the ones that have been destroyed. Exactly the shape
# `_mounds` / `_spent_mounds` uses, and for the same reasons.
var _shooters: Dictionary = {}
var _spent_shooters: Array = []

func _spawn_shooter(cell: Vector2i) -> void:
	if _shooter_root == null:
		_shooter_root = Node3D.new()
		_shooter_root.name = "Shooters"
		add_child(_shooter_root)
	var shooter: Node3D = ShooterScene.instantiate()
	shooter.name = "Shooter_%d_%d" % [cell.x, cell.y]
	shooter.position = cell_surface(cell) + Vector3(0.0, GridConfig.CELL_SIZE * 0.5, 0.0)
	_shooter_root.add_child(shooter)
	_shooters[cell] = shooter

# Where a ball leaves the barrel, in the world's space. Above the pillar, so a
# ball never spawns inside the thing that fired it.
func shooter_muzzle(cell: Vector2i) -> Vector3:
	return cell_surface_world(cell) + Vector3(0.0, GridConfig.CELL_SIZE + 0.9, 0.0)

# The body itself, which is what a blast has to reach -- a metre up on its pillar,
# not at the muzzle and not on the deck.
func shooter_body_world(cell: Vector2i) -> Vector3:
	return cell_surface_world(cell) + Vector3(0.0, GridConfig.CELL_SIZE * 0.5, 0.0)

# BLOWN UP, AND ONLY BLOWN UP. Asked for 2026-08-14, and it is the same rule a
# mound already follows: a structure is not answered by gunfire.
#
# WHAT IT CHANGES, which is more than it looks: the plinko arena stops being
# weather and becomes a PROBLEM WITH A SOLUTION. Until now the balls were a
# permanent condition of that stretch of bridge and the only verb against them was
# moving; a party carrying a grenade can now decide to end the source instead.
# That is the second thing explosives can kill that nothing else can -- the mound
# is the first -- which is exactly the niche design_ideas/damage_model.md wants
# them to have.
#
# DELIBERATELY NOT SHOOTABLE. A machine gun that could clear the arena from the
# far side would delete the reason to walk into it, and the whole point of the
# field is that it has to be crossed.
func blast_shooters(centre: Vector3, radius: float) -> int:
	var removed := 0
	# Over a COPY of the keys: take_shooter mutates the dictionary underneath.
	for cell in _shooters.keys().duplicate():
		if shooter_body_world(cell).distance_to(centre) <= radius:
			if take_shooter(cell):
				removed += 1
	return removed

func take_shooter(cell: Vector2i) -> bool:
	if not _shooters.has(cell):
		return false
	var shooter: Node3D = _shooters[cell]
	_shooters.erase(cell)
	_spent_shooters.append(cell)
	# AND OUT OF THE FIRING LIST, which is what actually stops the balls --
	# GameWorld._process_plinko walks `shooter_cells` and nothing else.
	shooter_cells.erase(cell)
	if is_instance_valid(shooter):
		shooter.queue_free()
	return true

func spent_shooter_layout() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in _spent_shooters:
		out.append(cell.x)
		out.append(cell.y)
	return out

func apply_spent_shooters(layout: PackedInt32Array) -> void:
	var i := 0
	while i + 1 < layout.size():
		take_shooter(Vector2i(layout[i], layout[i + 1]))
		i += 2

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

# --- Cover and spikes (M17) ---------------------------------------------------
#
# Grid-resident scenery, like a shooter's pillar: authored in a cell, owned here,
# and doing its job purely by existing. A collider on the WORLD layer is in
# SIGHT_BLOCKERS, so cover breaks a gunner's line of sight with no code in the
# gunner at all.
var spike_cells: Array = []            # Vector2i, run space
var _cover_root: Node3D = null
var _spike_root: Node3D = null
var _spikes: Dictionary = {}           # Vector2i -> the spike mesh, so the world can raise it

func _spawn_cover(cell: Vector2i, is_tree: bool) -> void:
	if _cover_root == null:
		_cover_root = Node3D.new()
		_cover_root.name = "Cover"
		add_child(_cover_root)

	var body := StaticBody3D.new()
	body.name = ("Tree_%d_%d" if is_tree else "HalfWall_%d_%d") % [cell.x, cell.y]
	body.collision_layer = 1        # world: solid, and a sight blocker for free
	body.collision_mask = 0
	body.position = cell_surface(cell)

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

# THE BLOCK ITSELF IS NOT THE HAZARD. It is ordinary deck you can stand on; what
# hurts is the spikes it drives into the cells AROUND it, which is why it is
# authored where a player must pass BESIDE something rather than over it.
func _spawn_spikes(cell: Vector2i) -> void:
	if _spike_root == null:
		_spike_root = Node3D.new()
		_spike_root.name = "Spikes"
		add_child(_spike_root)
	var prop := MeshInstance3D.new()
	prop.name = "Spikes_%d_%d" % [cell.x, cell.y]
	var box := BoxMesh.new()
	box.size = Vector3(GridConfig.CELL_SIZE * 0.9, 0.7, GridConfig.CELL_SIZE * 0.9)
	prop.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GridConfig.SPIKE_COLOUR
	mat.roughness = 0.4
	prop.material_override = mat
	prop.position = cell_surface(cell) + Vector3(0.0, 0.35, 0.0)
	prop.visible = false
	_spike_root.add_child(prop)
	_spikes[cell] = prop

# Raised or withdrawn. The WORLD decides, from the tick, so every machine agrees
# without anything being sent.
func set_spikes_out(cell: Vector2i, out: bool) -> void:
	var prop: Node = _spikes.get(cell)
	if prop != null and is_instance_valid(prop):
		prop.visible = out

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
# A MOUND IS IMMUNE TO BULLETS AND KILLED BY A BLAST, and the rule lives here
# because the grid is what owns mounds -- they are authored cells, not bodies.
#
# It is dormant and flush with the deck: there is nothing above ground to shoot,
# so a round passes over it. A blast reaches down, which turns a grenade into the
# way to PRE-EMPT a hazard before it wakes -- spend a charge and the rusher never
# rises. That is a genuinely new decision built entirely out of parts that already
# existed, and it is the best thing to come out of the damage model.
#
# Returns how many it removed, so a caller can tell whether the charge was worth
# spending.
func blast_mounds(centre: Vector3, radius: float) -> int:
	var removed := 0
	for cell in mound_cells():
		if mound_surface_world(cell).distance_to(centre) <= radius:
			if take_mound(cell):
				removed += 1
	return removed

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
