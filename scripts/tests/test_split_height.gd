extends "res://scripts/test_support/test_case.gd"

# M23 PHASE 1: DOES ANYTHING HAVE TO BE BUILT FOR HEIGHT TO VARY ACROSS THE
# BRIDGE AS WELL AS ALONG IT?
#
# The generator's whole vocabulary for terrain is ONE SCALAR PER ROW -- `low[z]`
# is the height of the entire row -- so a plateau is always exactly as wide as
# the bridge and every height change is a horizontal line. Two of M23's three
# asks are shapes that model cannot express: a left/right split, and a raised
# patch smaller than the deck.
#
# THE PLAN CLAIMS THE RENDERER AND THE VALIDATOR ALREADY COPE, on the reasoning
# that `cell_underside` reads a cell's EIGHT neighbours (not just the one behind
# it in Z) and that `_flood_from` steps in all four directions with `_can_step`
# reading the rise between any two adjacent cells regardless of orientation.
# CLAUDE.md is explicit that "should need no change" is a claim to measure rather
# than assume, and this is the measurement. It is deliberately the FIRST thing in
# the milestone: if either of them does need work, every phase after this one is
# built on sand.
#
# NOTHING HERE TESTS THE GENERATOR, which has not been touched. The fixture is
# hand-authored precisely so the two questions -- "can these shapes exist" and
# "can the generator produce them" -- stay separate.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const MAP := "res://segments/test_split_height.seg"

# From the fixture. The cliff runs between columns 5 (height 0) and 6 (height 2)
# on rows 4-7; the tower is columns 11-13 on rows 10-12.
const LOW_COL := 5
const HIGH_COL := 6
const CLIFF_ROW := 5
const TOWER_COL := 11
const TOWER_ROW := 11
const RAMP_COL := 6
const PEER := 640221953

# Long enough to walk the low lane the length of the cliff and be pressed into
# it, short enough not to run off a twelve-row fixture.
const WALK_TICKS := 150

var world: Node3D = null
var seg = null
var body: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	seg = SegmentData.from_file(MAP)
	world = Node3D.new()
	world.name = "SplitHeightWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = [MAP]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	# On the LOW side of the cliff, walking east INTO it for the whole run. A
	# cliff face that is not solid lets the body through; one that is solid but
	# has nothing under it lets the body fall at the join.
	body.position = world.grid.cell_surface_world(Vector2i(LOW_COL, CLIFF_ROW)) \
		+ Vector3(0.0, 1.2, 0.0)
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(1.0, 0.0), 0)

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < WALK_TICKS:
		return
	done = true
	_test_the_shapes_are_legal()
	_test_the_cliff_is_solid_geometry()
	_test_a_body_is_stopped_by_it()
	_test_nothing_is_marooned()
	finish()

# --- 1. The validator accepts both shapes -------------------------------------

func _test_the_shapes_are_legal() -> void:
	if not check(seg.is_valid(), "the fixture parses (%s)" % str(seg.errors)):
		return
	var problems: Array = SegmentValidator.validate(seg)
	check(problems.is_empty(),
		"a segment with a LEFT/RIGHT height split and a raised patch validates "
		+ "with no changes to the validator (%s). `_flood_from` steps in all four "
			% str(problems)
		+ "directions and `_can_step` reads the rise between any two adjacent "
		+ "cells, so a sideways cliff is already a wall by the same rule a "
		+ "forward one is -- asserted rather than assumed")

	# AND IT IS CROSSABLE BY ONE PLAYER. The high half is reached by its own ramp,
	# which is what M23 says a split plateau must always carry: each side may only
	# change height where something exists to climb.
	var solo: Array = SegmentValidator.validate_run([seg], SegmentValidator.party_of(1))
	check(solo.is_empty(),
		"and a SOLO player can cross it (%s) -- a split whose high side needs a "
			% str(solo)
		+ "second player is a section that strands somebody, and drop-in makes a "
		+ "party of one a real case rather than a hypothetical")

# --- 2. The cliff is real geometry, not a seam --------------------------------

func _test_the_cliff_is_solid_geometry() -> void:
	var built = SegmentBuilder.build(seg, 0, 0)
	check(built.deck_box_count > 0, "the fixture builds deck")

	# THE THICKNESS RULE, READ SIDEWAYS. `cell_underside` drops a cell's underside
	# to the lowest of its EIGHT neighbours, which is what turns a height
	# difference into a solid face instead of a slab floating over open air. It has
	# never had to do it for a LATERAL neighbour, because no plateau has ever been
	# narrower than the bridge.
	var top: float = SegmentBuilder._surface_y(seg.kind_at(HIGH_COL, CLIFF_ROW),
		seg.height_at(HIGH_COL, CLIFF_ROW))
	var under: float = SegmentBuilder.cell_underside(seg, HIGH_COL, CLIFF_ROW, 0)
	var thickness: float = top - under
	var drop: float = float(seg.height_at(HIGH_COL, CLIFF_ROW)
		- seg.height_at(LOW_COL, CLIFF_ROW)) * GridConfig.HEIGHT_UNIT
	print("[split] cliff cell (%d, %d): top %.2f, underside %.2f, thickness %.2f; the drop beside it is %.2f"
		% [HIGH_COL, CLIFF_ROW, top, under, thickness, drop])

	check(thickness >= drop - 0.01,
		"the high cell beside a lateral cliff hangs down at least as far as the "
		+ "drop (%.2f against %.2f) -- otherwise there is a face of open air "
			% [thickness, drop]
		+ "where the cliff should be, which is the ramp-skirt bug pointing "
		+ "sideways and presents as 'sometimes I fall through'")

	# THE TOWER, WHICH IS THE SAME RULE WITH THE PATCH SMALLER THAN THE ROW.
	#
	# THE EDGE COLUMN AT A MIDDLE ROW, chosen so only a LATERAL neighbour can
	# thicken it. The first version read a one-row tower's centre and passed with
	# the eight-neighbour scan narrowed to Z only -- the low ground directly behind
	# it was doing the work, so the assertion never touched the property it was
	# written for. Three rows deep and one column in, the cells ahead and behind
	# are both tower and the only low ground is beside it.
	var t_top: float = SegmentBuilder._surface_y(seg.kind_at(TOWER_COL, TOWER_ROW),
		seg.height_at(TOWER_COL, TOWER_ROW))
	var t_thick: float = t_top - SegmentBuilder.cell_underside(seg, TOWER_COL, TOWER_ROW, 0)
	print("[split] tower cell (%d, %d): thickness %.2f" % [TOWER_COL, TOWER_ROW, t_thick])
	check(t_thick >= 2.0 * GridConfig.HEIGHT_UNIT - 0.01,
		"and a raised PATCH is solid all the way down to the deck around it "
		+ "(%.2f) -- a tower you can walk under is a tower with no inside"
			% t_thick)

# --- 3. And it actually stops a body -------------------------------------------

func _test_a_body_is_stopped_by_it() -> void:
	var cell: Vector2i = world.grid.cell_of_world(body.position)
	print("[split] after %d ticks walking EAST into the cliff: cell %s, y %.2f"
		% [WALK_TICKS, str(cell), body.global_position.y])

	# ASSERTING THE FACE EXISTS IS NOT ASSERTING IT BLOCKS. Five bugs in this
	# project have been a collider that was built, positioned, and made of
	# nothing.
	check(body.global_position.y > -5.0,
		"a body walking into a lateral cliff is still on the bridge (y %.2f)"
			% body.global_position.y)
	check(cell.x <= LOW_COL,
		"and did not climb it (col %d, the low side ends at %d) -- there is no "
			% [cell.x, LOW_COL]
		+ "step-up in this game, so a two-unit face is a wall from the side "
		+ "exactly as it is from the front")

# --- 4. Nothing is left marooned ----------------------------------------------

func _test_nothing_is_marooned() -> void:
	# THE RULE A GENERATED SPLIT WILL HAVE TO SATISFY, checked here so the
	# generator phase already knows what it is aiming at: every solid cell of the
	# high side is reachable, because the ramp is there. `_check_orphans` is what
	# refuses a split with no way up, and it is the reason a split plateau cannot
	# just be two heights -- it is two heights and a climb.
	var reachable: Dictionary = SegmentValidator._flood(seg, SegmentValidator.party_of(1))
	var high := 0
	var reached := 0
	for z in seg.length:
		for x in seg.width:
			if not seg.is_solid(x, z) or seg.height_at(x, z) <= 0:
				continue
			high += 1
			if reachable.has(Vector2i(x, z)):
				reached += 1
	print("[split] %d of %d raised cells are reachable on foot, solo" % [reached, high])
	check(high > 0, "the fixture really does have raised ground in it")
	eq(reached, high,
		"and every raised cell is reachable by one player -- a split plateau is "
		+ "not two heights, it is two heights AND a climb, and the half without "
		+ "the climb is marooned deck the validator refuses")
