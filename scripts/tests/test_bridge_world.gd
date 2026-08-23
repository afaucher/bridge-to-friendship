extends "res://scripts/test_support/test_case.gd"

# MVP criterion C1: a segment file becomes collision and meshes, and a player can
# walk on it. Plus the geometry claims the builder makes -- deck merging, the
# ramp slope that IS the co-op gate, and stones landing where they were drawn.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var player: CharacterBody3D = null
var frame: int = 0
var start_position: Vector3 = Vector3.ZERO

func setup(main) -> void:
	timeout_seconds = 25.0

	_test_builder_geometry()

	world = Node3D.new()
	world.name = "BridgeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)

	check(world.grid != null, "the world built a bridge grid")
	if world.grid == null:
		finish()
		return

	eq(world.grid.total_length(), 12, "the flat segment contributed its 12 rows")
	eq(world.grid.stone_count(), 3, "all three authored pillars became stones")

	# Cell queries resolve through the segment.
	eq(world.grid.kind_at(Vector2i(10, 2)), GridConfig.Kind.HOLE, "the authored hole is a hole")
	eq(world.grid.kind_at(Vector2i(0, 0)), GridConfig.Kind.DECK, "the deck is deck")

	# Drop a player onto the deck and let it walk. Placed by CELL, which is the
	# whole point of having a grid.
	# Explicitly typed: `world` is an untyped script instance, so anything read
	# through it is a Variant and `:=` cannot infer from it.
	# Column 25 is clear of every authored hole in test_flat, so walking straight
	# up it exercises the deck rather than the fall.
	var drop: Vector3 = world.grid.cell_surface(Vector2i(25, 1))
	world._spawn_player(1, 0)
	player = world.player_body(1)
	player.position = drop + Vector3(0.0, 1.5, 0.0)
	start_position = player.position

func _test_builder_geometry() -> void:
	var seg = SegmentData.from_file("res://segments/test_ascent.seg")
	if not check(seg.is_valid(), "the ascent segment parses"):
		return
	var built = SegmentBuilder.build(seg)

	# Deck merging: 30x14 is 420 cells, and a segment of long flat runs must not
	# become one collision shape per cell. The physics server tests every one of
	# these every tick.
	check(built.deck_box_count < 100,
		"deck cells merge into runs (%d boxes for %d cells)" % [built.deck_box_count, 30 * 14])
	check(built.wall_box_count > 0, "the cliff and the outer edges produced parapets")
	eq(built.ladder_cells.size(), 2, "both ladder cells were collected")
	eq(built.stone_cells.size(), 3, "all three pillars were collected")

	# The slope that decides whether a ramp needs two players. Asserted against
	# the same threshold the body enforces, so a change to one fails here.
	var gentle := rad_to_deg(atan(1.0 * GridConfig.HEIGHT_UNIT / GridConfig.CELL_SIZE))
	var steep := rad_to_deg(atan(2.0 * GridConfig.HEIGHT_UNIT / GridConfig.CELL_SIZE))
	check(gentle < SimConfig.MAX_WALK_ANGLE_DEG,
		"a 1-unit ramp is walkable alone (%.1f deg < %.1f)" % [gentle, SimConfig.MAX_WALK_ANGLE_DEG])
	check(steep > SimConfig.MAX_WALK_ANGLE_DEG,
		"a 2-unit ramp is not (%.1f deg > %.1f)" % [steep, SimConfig.MAX_WALK_ANGLE_DEG])

	built.root.free()

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	frame += 1

	# Walk north along the bridge for two seconds.
	var move := Vector2(0.0, -1.0) if frame > 60 else Vector2.ZERO
	player.step(move, 0)

	# The bridge is PITCHED, so "the deck" is not a fixed height -- the expected
	# resting height has to come from the grid, at whichever cell the player is
	# standing on. A hardcoded y here would only ever be right at one spot.
	if frame == 60:
		near(player.position.y, _expected_rest_y(), 0.08,
			"the player lands on the authored deck (y = %.3f)" % player.position.y)
		check(player.grounded, "and reports standing on it")

	elif frame == 180:
		var travelled: float = start_position.z - player.position.z
		check(travelled > 5.0, "the player walks along the bridge (%.2f m)" % travelled)
		near(player.position.y, _expected_rest_y(), 0.10,
			"and stays on the deck the whole way")
		# THE DECK IS FLAT AS OF 2026-08-23, and this used to assert that walking up
		# the bridge GAINED 0.3 m of height. The tilt existed to roll loose things
		# back at the party and did it to everything -- see
		# GridConfig.BRIDGE_PITCH_DEG. A plinko ball now carries its own force
		# instead (SimConfig.PLINKO_DRIFT), which is what test_plinko checks.
		#
		# ASKED OF THE DECK, NOT OF THE PLAYER. The obvious replacement -- compare
		# the player's y against where it started -- fails for a reason that has
		# nothing to do with slope: `start_position` is taken before the body has
		# settled, so it carries the 0.6 m of spawn drop and reads as a hill.
		# "The player stayed on the deck" is already asserted a line above; what is
		# missing is that the DECK is level, which is a fact about the world.
		#
		# It is worth holding rather than dropping: level is what makes "horizontal"
		# a stable definition for aiming, and a bridge that quietly grew a slope
		# again would break that without looking like anything.
		var here: Vector2i = world.grid.cell_of_world(player.position)
		var back: Vector2i = world.grid.cell_of_world(start_position)
		near(world.grid.cell_surface_world(here).y,
			world.grid.cell_surface_world(back).y, 0.01,
			"and the deck it walked along is LEVEL end to end (%.3f m over %d rows)"
				% [world.grid.cell_surface_world(here).y
					- world.grid.cell_surface_world(back).y, absi(here.y - back.y)])
		finish()

func _expected_rest_y() -> float:
	var cell: Vector2i = world.grid.cell_of_world(player.position)
	return world.grid.cell_surface_world(cell).y + 0.9
