extends "res://scripts/test_support/test_case.gd"

# M17 Phase 2: split level, and the adjacency thickness rule that makes it safe.
#
# The rule alone is untestable and a split-level segment alone falls through, so
# they are one phase. `test_split.seg` is the left half of a deck standing three
# height units above the right half with no ramp between them.
#
# WHAT GOES WRONG WITHOUT THE RULE, and it is the ramp-skirt bug of 2026-08-13
# wearing a different hat: a deck cell is a slab hanging DECK_THICKNESS below its
# top face, so the raised half floats six metres up with an open void under it.
# You see straight under the raised section, and a body walking on the low side
# walks through empty air where a cliff face should be.
#
# The claims:
#   1. THE CLIFF FACE IS SOLID all the way down to the deck below it. Measured
#      with a horizontal ray at the low deck's own height -- the height a player
#      standing down there actually occupies.
#   2. THE INTERIOR OF THE PLATEAU IS NOT THICKENED. This is the half that stops
#      the rule being "make everything solid to the ground", which would work and
#      would be wasteful; the geometry may only grow where the terrain steps.
#   3. A cell with NO solid neighbour stays thin.
#   4. Both halves are still walkable deck, and the box count has not exploded.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# test_split.seg: columns 0-4 are high (height 3), 5-9 are low (height 0).
const HIGH_X := 2
const LOW_X := 7
const EDGE_X := 4          # the last high column, so its right neighbour is low

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "SplitWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_split.seg"]
	world.start(true, 1, false)

	_check_the_rule()
	_check_the_cliff_is_solid()
	_check_both_halves_walkable()
	finish()

# --- 1 to 3. The rule, on the data ------------------------------------------

func _check_the_rule() -> void:
	var seg = SegmentData.from_file("res://segments/test_split.seg")
	check(seg.is_valid(), "the fixture parses")

	var unit: float = GridConfig.HEIGHT_UNIT
	var high_top: float = 3.0 * unit
	var low_top: float = 0.0

	# THE EDGE reaches down to the low deck beside it.
	var edge_under: float = SegmentBuilder.cell_underside(seg, EDGE_X, 3, 0)
	near(edge_under, low_top, 0.01,
		"a cell at the height CHANGE reaches down to its lowest neighbour (%.2f)"
			% edge_under)
	check(high_top - edge_under > 2.0,
		"which is a real cliff face, not a slab (%.1f m of it)" % (high_top - edge_under))

	# THE INTERIOR IS UNTOUCHED. Column 1 is high with high neighbours on all
	# eight sides, so it keeps the ordinary thickness. Without this assertion the
	# rule could be "everything is solid to the ground" and still pass above.
	var interior_under: float = SegmentBuilder.cell_underside(seg, 1, 3, 0)
	near(interior_under, high_top - GridConfig.DECK_THICKNESS, 0.01,
		"while the INTERIOR of the plateau stays exactly as thin as before (%.2f)"
			% interior_under)

	# AND A LONE PLATFORM STAYS THIN. Built by hand: one solid cell in a field of
	# holes has no floor beneath it to hide, so there is nothing to close.
	var lonely = SegmentData.from_file("res://segments/test_split.seg")
	for z in lonely.length:
		for x in lonely.width:
			lonely.kinds[z][x] = GridConfig.Kind.HOLE
	lonely.kinds[4][4] = GridConfig.Kind.DECK
	var lone_under: float = SegmentBuilder.cell_underside(lonely, 4, 4, 0)
	var lone_top: float = float(lonely.height_at(4, 4)) * unit
	near(lone_under, lone_top - GridConfig.DECK_THICKNESS, 0.01,
		"a platform with no solid neighbour stays thin -- there is no floor under "
		+ "it to hide, and a thin platform over nothing is what it is")

# --- The cliff really exists in the physics world ----------------------------

func _check_the_cliff_is_solid() -> void:
	var space := world.get_world_3d().direct_space_state
	# A ray at the LOW deck's head height, fired from the low side into the cliff.
	# This is the exact line a player standing on the low deck occupies, and the
	# thing that used to be empty air.
	var low: Vector3 = world.grid.cell_surface_world(Vector2i(LOW_X, 3))
	var into: Vector3 = world.grid.cell_surface_world(Vector2i(HIGH_X, 3))
	var query := PhysicsRayQueryParameters3D.create(
		low + Vector3(0.0, 1.0, 0.0),
		Vector3(into.x, low.y + 1.0, into.z))
	query.collision_mask = 1
	check(not space.intersect_ray(query).is_empty(),
		"the cliff face is SOLID at the height a player on the low deck stands -- "
		+ "before the thickness rule this ray passed through open air")

# --- Both halves are still deck ----------------------------------------------

func _check_both_halves_walkable() -> void:
	var space := world.get_world_3d().direct_space_state
	for cell in [Vector2i(HIGH_X, 3), Vector2i(LOW_X, 3)]:
		var top: Vector3 = world.grid.cell_surface_world(cell)
		var query := PhysicsRayQueryParameters3D.create(
			top + Vector3(0.0, 0.6, 0.0), top - Vector3(0.0, 0.6, 0.0))
		query.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(query)
		check(not hit.is_empty(), "cell %s is standable" % str(cell))
		if not hit.is_empty():
			check(absf(float(hit["position"].y) - top.y) < 0.05,
				"at its own surface (%s)" % str(cell))
