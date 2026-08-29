extends "res://scripts/test_support/test_case.gd"

# ARMED MINES SCATTERED ON A TRACK.
#
# Terrain that goes off. The generator picks the cells, the grid records them,
# and the world builds a live Deployable at each -- three hops, and the whole
# point is the state it arrives in.
#
# ARMED IS THE CLAIM. `place_at` starts a MINE_ARM_SECONDS fuse, which is
# exactly right for a mine a player has just thrown: it is the window in which
# you can still get away from your own mistake. A mine that is part of the track
# was not thrown by anybody -- it has been there since the section was built --
# so a fuse would mean the first car past is safe and the second is not. That is
# a hazard that behaves differently on lap one, which is the worst thing a lap
# timer can be measured against.
#
# THROWN BY NOBODY, TOO. Peer 0 is what `_spawn_round` already means by the
# world, and it matters downstream: a mine with a thrower would credit its kills
# to whichever player id happened to be lowest.
#
# The claims:
#   1. The world really builds them, and they are armed on the tick they appear.
#   2. They belong to nobody.
#   3. A mode that places mines RUNS the deployables pool. This is the one the
#      content-vs-pools grid could not catch on its own: mines are carried beside
#      the grid rather than as content glyphs, so the correspondence check in
#      test_bus_route looks straight past them.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")

const WIDTH := 21

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	test_mode = GameMode.TRACK
	world = Node3D.new()
	world.name = "MineWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.TRACK]

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)
	_a_mode_that_places_mines_runs_them()
	_a_real_run_records_them()
	_the_world_builds_them_armed()
	finish()

func _a_mode_that_places_mines_runs_them() -> void:
	# THE CORRESPONDENCE THE CONTENT GRID CANNOT SEE. `GameMode.CONTENT_POOLS`
	# maps content GLYPHS to pools, and a mine is not a glyph -- it rides beside
	# the grid in `mine_cells`, the way a lap gate does. So the check that catches
	# "placed for a pool that is switched off" for skirmishers and timed floor
	# looks straight past mines, and this is the same claim asked the other way.
	var placing: Array = []
	for mode in GameMode.MODES.keys():
		var seg = null
		match GameMode.terrain(mode):
			GameMode.TERRAIN_TRACK:
				seg = SegmentGen.bus_track(WIDTH, 4242, 0)
			GameMode.TERRAIN_BLANK:
				seg = SegmentGen.blank_zone(WIDTH, 4242, 0)
			_:
				seg = SegmentGen.section(WIDTH, 4242, 0)
		if seg != null and seg.mine_cells.size() > 0:
			placing.append(mode)
			check(GameMode.runs(mode, "deployables"),
				"%s scatters %d armed mines, so it must run `deployables` -- a "
					% [GameMode.MODES[mode]["name"], seg.mine_cells.size()]
				+ "mine whose pool is off never ticks, so it is drawn, never "
				+ "detonates, and is scenery in the shape of a hazard")
	print("[mines] %d of %d modes scatter mines" % [placing.size(), GameMode.MODES.size()])
	check(placing.size() > 0,
		"at least one mode places mines at all (%d) -- without this the "
			% placing.size()
		+ "correspondence above is a wall of green over an empty set, which is "
		+ "the shape this project keeps being caught by")

# THROUGH THE WHOLE PATH: generator -> builder -> grid. Nothing hand-fed.
#
# THE CLAIM THIS FILE DID NOT HAVE, AND IT COST A REAL BUG. Everything below
# pushes cells into `authored_mine_cells` by hand and then checks what the world
# does with them -- which tests the world and says nothing about whether a
# generated section's mines ever ARRIVE there. They did not: `Built` is not a
# SegmentData, so BridgeGrid asking `built.mine_cells` raised, and a raise in
# GDScript aborts the rest of the function in silence. Mines were scattered by
# the generator, dropped on the floor by the builder, and every assertion in this
# file was green.
func _a_real_run_records_them() -> void:
	var built = BridgeGridScript.new()
	built.name = "MineRun"
	world.add_child(built)
	built.width = WIDTH
	built.build_run(31337, SegmentPool.SECTIONS_PER_ROUND + 1, [GameMode.TRACK])
	var recorded: int = built.authored_mine_cells.size()
	var on_road := 0
	for cell in built.authored_mine_cells:
		if built.is_solid(cell):
			on_road += 1
	print("[mines] a real TRACK run recorded %d, %d of them on road"
		% [recorded, on_road])
	check(recorded > 0,
		"a generated run really records the mines its terrain scattered (%d) -- "
			% recorded
		+ "hand-feeding the grid tests the world and says nothing about whether "
		+ "a section's mines ever reach it")
	eq(on_road, recorded,
		"and every one is on solid road (%d of %d) -- a mine over a hole is a "
			% [on_road, recorded]
		+ "mine that falls out of the world the moment it exists")
	built.queue_free()

func _the_world_builds_them_armed() -> void:
	# PUSHED THROUGH THE REAL SEAM. The grid's record is what the world consumes,
	# so putting cells there and letting the pass run tests the caller rather than
	# a copy of its arithmetic.
	var cells: Array = [Vector2i(7, 5), Vector2i(9, 8), Vector2i(11, 11)]
	for cell in cells:
		world.grid.authored_mine_cells.append(cell)
	var before: int = world._deployables.size()
	world._process_deployables()
	var built: int = world._deployables.size() - before
	print("[mines] the world built %d of %d" % [built, cells.size()])
	eq(built, cells.size(),
		"the world builds a mine for every cell the terrain placed (%d of %d)"
			% [built, cells.size()])

	for i in range(before, world._deployables.size()):
		var m: Node = world._deployables[i]
		var deck: float = world.grid.cell_surface_world(cells[i - before]).y
		var aabb: AABB = m.get_node("CollisionShape3D").shape.get_debug_mesh().get_aabb() 			if m.get_node_or_null("CollisionShape3D") != null else AABB()
		print("[mines] mine at y %.3f, deck %.3f, gap %.3f; shape height %.3f"
			% [m.position.y, deck, m.position.y - deck, aabb.size.y])
	var armed := 0
	var owned := 0
	for i in range(before, world._deployables.size()):
		var mine: Node = world._deployables[i]
		if mine.is_armed():
			armed += 1
		if int(mine.thrower) != 0:
			owned += 1
	print("[mines] %d armed on the tick they appeared, %d with an owner"
		% [armed, owned])
	eq(armed, built,
		"and every one of them is ARMED on the tick it appears (%d of %d) -- "
			% [armed, built]
		+ "`place_at` starts a fuse, which is right for a mine somebody just "
		+ "threw and wrong for one that has been part of the track since it was "
		+ "built. A fuse here means the first car past is safe and the second is "
		+ "not, which is a hazard that changes between laps")
	eq(owned, 0,
		"and belongs to nobody (%d have a thrower) -- peer 0 is the world, the "
			% owned
		+ "same as an unattributed round, so a mine's kills are not credited to "
		+ "whichever player id happened to be lowest")

	# AND THE GRID HANDS EACH CELL OVER ONCE. `take_` empties as it reads, for the
	# same reason the special and hat records do: a mine rebuilt every tick is a
	# minefield that grows without bound and a frame rate that does not survive it.
	world._process_deployables()
	eq(world._deployables.size() - before, built,
		"and the cells are handed over ONCE (%d after a second pass) -- taking "
			% (world._deployables.size() - before)
		+ "empties the record, or every tick lays the whole minefield again")
