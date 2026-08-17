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
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
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
		var path: String = String(plan[i])
		# GENERATED SLOTS ARE NAMED, NOT PATHS. The plan is still a list of
		# strings so everything that reads it is unchanged; a slot the generator
		# fills carries a marker instead of a file name.
		if path == SegmentPool.GENERATED_LOBBY:
			_load_generated(SegmentGen.lobby(width, seed_value, i), i)
		elif path == SegmentPool.GENERATED_SECTION:
			_load_generated(SegmentGen.section(width, seed_value, i), i)
		else:
			load_segment_file(path)

# A segment that was never a file. Everything after parsing is identical, which
# is the point of generating SegmentData rather than text: the validator, the
# builder, the dressing pass and the join contract cannot tell the difference.
func _load_generated(seg, index: int) -> void:
	if seg == null:
		printerr("[BridgeGrid] the generator produced nothing for slot ", index)
		return
	if dress_hazards and not seg.tags.has("lobby") and not seg.no_dress:
		HazardDressing.dress(seg, HazardDressing.theme_for(run_seed, index), run_seed, index)
	load_segment(seg)

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
	# AN AUTHORED SEGMENT IS NOT DRESSED. It was authored COMPLETE.
	#
	# It was, until a playtest on 2026-08-16 reported the opening section as "WAY
	# too busy" -- and measured, it was: playtest_bridge carries 66 authored
	# contents and the survival theme took it to 90, adding six more rushers and
	# four more plinko shooters to the densest map in the game. The commit that
	# shipped it even claimed authored maps were spared; the guard only excluded
	# lobbies.
	#
	# So the rule is now the simple one, and it matches what the layers were for:
	# GENERATED terrain gets a generated theme, because it arrives empty and
	# something has to fill it. An authored map arrives full, and a person already
	# decided what is in it — which is the entire difference between layer 2 and
	# layer 3.
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

	for local_cell in built.ladder_cells:
		_spawn_ladder(Vector2i(local_cell.x, local_cell.y + z_offset))

	for local_cell in built.tree_cells:
		_spawn_cover(Vector2i(local_cell.x, local_cell.y + z_offset), true)
	for local_cell in built.half_wall_cells:
		_spawn_cover(Vector2i(local_cell.x, local_cell.y + z_offset), false)
	for local_cell in built.elevator_cells:
		var ec := Vector2i(local_cell.x, local_cell.y + z_offset)
		elevator_cells.append(ec)
		_spawn_elevator(ec)
	for entry in built.mutable_cells:
		var mc := Vector2i(entry[0].x, entry[0].y + z_offset)
		mutable_cells.append(mc)
		_spawn_mutable(mc, int(entry[1]))
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

# What the AUTHOR put in a cell, in run space. The pools take their contents at
# load and clear them, so this answers about the segment's record rather than
# about anything alive -- which is exactly what a ladder is: a fixed feature, not
# a body.
func content_at(cell: Vector2i) -> int:
	var r := _resolve(cell)
	if r.is_empty():
		return GridConfig.Content.NONE
	return r[0].content_at(cell.x, r[1])

func height_at(cell: Vector2i) -> int:
	var r := _resolve(cell)
	if r.is_empty():
		return 0
	# Plus the segment's stacking offset -- a cell's height is where it sits in
	# the RUN, not where it sits in the file it was authored in.
	return r[0].height_at(cell.x, r[1]) + int(r[2])

func is_solid(cell: Vector2i) -> bool:
	# A CELL THAT IS CURRENTLY GONE IS A HOLE, and every caller downstream — the
	# ledge catch, the ladder foot, the carrier probe — has to be told so. This is
	# the only place mutable terrain touches the rest of the game, which is what
	# makes it a small feature: the deck answers a different question, and nothing
	# else changes.
	if _open_cells.has(cell):
		return false
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
func _spawn_elevator(cell: Vector2i) -> void:
	if _mutable_root == null:
		_mutable_root = Node3D.new()
		_mutable_root.name = "Mutable"
		add_child(_mutable_root)

	var high: float = cell_surface(cell).y
	# THE DECK IT SERVES is the lowest solid neighbour: an elevator is authored at
	# the height it RISES TO, and where it comes back down to is read off the
	# terrain rather than authored twice and allowed to disagree with it.
	var low: float = high
	for dir in 4:
		var side: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if is_solid(side):
			low = minf(low, cell_surface(side).y)

	var thick: float = GridConfig.DECK_THICKNESS
	# ANIMATABLE, NOT STATIC. A StaticBody3D moved by hand does not push what is
	# standing on it -- it teleports through it -- and the whole point of this slab
	# is that it carries somebody.
	var body := AnimatableBody3D.new()
	body.name = "Elevator_%d_%d" % [cell.x, cell.y]
	body.collision_layer = 1
	body.collision_mask = 0
	body.sync_to_physics = true
	body.position = Vector3(cell_surface(cell).x, low - thick * 0.5, cell_surface(cell).z)
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
	var centre: Vector3 = cell_surface(cell)
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
func _spawn_mutable(cell: Vector2i, content: int) -> void:
	if _mutable_root == null:
		_mutable_root = Node3D.new()
		_mutable_root.name = "Mutable"
		add_child(_mutable_root)

	var top: Vector3 = cell_surface(cell)
	var thick: float = GridConfig.DECK_THICKNESS

	var body := StaticBody3D.new()
	body.name = "Mutable_%d_%d" % [cell.x, cell.y]
	body.collision_layer = 1     # world, like the deck it stands in for
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

# --- Cover and spikes (M17) ---------------------------------------------------
#
# Grid-resident scenery, like a shooter's pillar: authored in a cell, owned here,
# and doing its job purely by existing. A collider on the WORLD layer is in
# SIGHT_BLOCKERS, so cover breaks a gunner's line of sight with no code in the
# gunner at all.
var spike_cells: Array = []            # Vector2i, run space
# MUTABLE TERRAIN (M17 phase 8). One slab per authored cell, deliberately NOT
# merged into the deck rectangles — see SegmentBuilder.is_mutable for why that
# is the whole reason this feature is cheap.
var mutable_cells: Array = []          # Vector2i, run space, in load order
var _mutable_root: Node3D = null
var _mutable: Dictionary = {}          # Vector2i -> {"body":, "mesh":, "content":}
var _open_cells: Dictionary = {}       # Vector2i -> true while the slab is GONE
# ELEVATORS (M17 phase 9).
var elevator_cells: Array = []         # Vector2i, run space
var _elevators: Dictionary = {}        # Vector2i -> {"body":, "mesh":, "low":, "high":}
var _cover_root: Node3D = null
var _ladder_root: Node3D = null
var _spike_root: Node3D = null
var _spikes: Dictionary = {}           # Vector2i -> the spike prop, so the world can raise it
var spike_lift: Dictionary = {}        # Vector2i -> 0..1, how far out they are

# A LADDER, AT LAST GIVEN A BODY. The glyph has been authorable since M2 and the
# loader has collected it since M2, and until M17 phase 6 nothing was ever built
# from it -- playtest_bridge's header has said "today it is a 2 m wall" the whole
# time.
#
# NO COLLIDER. The climb is a player STATE driven by the grid's cell record, so a
# ladder that also had a body would be a second, disagreeing description of the
# same thing -- and the one you collided with would fight the one you climbed.
# This is scenery that tells you where the state can be entered.
func _spawn_ladder(cell: Vector2i) -> void:
	if _ladder_root == null:
		_ladder_root = Node3D.new()
		_ladder_root.name = "Ladders"
		add_child(_ladder_root)

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
	var drop: float = 0.0
	var face: Vector3 = GridConfig.DIR_VECTORS[GridConfig.DIR_SOUTH]
	var lowest: float = cell_surface(cell).y
	for dir in 4:
		var side: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if not is_solid(side):
			continue
		var y: float = cell_surface(side).y
		if y < lowest:
			lowest = y
			face = GridConfig.DIR_VECTORS[dir]
	drop = maxf(cell_surface(cell).y - lowest, GridConfig.HEIGHT_UNIT)
	# Half a cell out, plus a hair so the rails stand PROUD of the face rather
	# than z-fighting with it.
	rungs.position = cell_surface(cell) + face * (GridConfig.CELL_SIZE * 0.5 + 0.06)
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
#
# NINE CONES, NOT A BOX. The first version was a single white slab that blinked
# on and off, which reads as a tile changing colour rather than as something
# coming out of the floor -- and "there is a thing in that square" is exactly what
# a player has to judge at a glance from a fixed camera 30 m away. A cluster of
# points reads as spikes from any angle, and it reads as spikes even at the top
# of the screen where a slab is four pixels tall.
#
# THEY RISE RATHER THAN APPEAR. The lift is driven by the world from the same
# tick-derived phase that decides the damage, so the movement IS the telegraph:
# a player sees them coming up and has the length of the ramp to step off.
const SPIKE_COUNT := 3                 # 3 x 3 across the cell
const SPIKE_HEIGHT := 0.8

func _spawn_spikes(cell: Vector2i) -> void:
	if _spike_root == null:
		_spike_root = Node3D.new()
		_spike_root.name = "Spikes"
		add_child(_spike_root)

	var prop := Node3D.new()
	prop.name = "Spikes_%d_%d" % [cell.x, cell.y]
	prop.position = cell_surface(cell)

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
	var base: Vector3 = cell_surface(cell)
	prop.position = Vector3(base.x, base.y - SPIKE_HEIGHT * (1.0 - lift), base.z)

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
