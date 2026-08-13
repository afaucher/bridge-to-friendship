extends "res://scripts/test_support/test_case.gd"

# A RAMP HAS TO BE AS SOLID AS THE DECK IT JOINS.
#
# Reported in playtest 2026-08-13: "you can fall through a gap near the bottom of
# a ramp". Measured rather than guessed, and the geometry was the culprit.
#
# A ramp is built as a WEDGE, which tapers to nothing at its lower end -- and a
# ramp cell gets no deck slab of its own, because _build_deck emits boxes for
# DECK and WATER only. So the first few centimetres of every ramp in the game were
# a PAPER EDGE over a DECK_THICKNESS-deep void with no floor under it. Measured on
# test_ascent's gentle ramp: the deck behind it is 1.002 m of solid, and five
# centimetres onto the ramp it was 0.053 m, with its underside at the deck's TOP
# rather than its bottom. Sink a few millimetres there and you are inside a metre
# deep hole that has no bottom.
#
# The fix is a skirt: the box the deck would have had, under the whole run.
#
# WHY test_ramp_traversal DID NOT CATCH IT, which is the useful part. That test
# walks a body up the same ramp on every run and passes -- a body arriving at
# WALK_SPEED crosses two centimetres of paper in a third of a tick and never has
# time to sink into it. The bug needed a body that ARRIVES rather than crosses:
# slowly, or landing on it. A gate can walk over a hole for months.
#
# So this test asserts the STRUCTURE and not the walk. The structure is what was
# wrong, it is cheap to measure exactly, and it cannot be crossed quickly enough
# to hide.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# test_ascent's two ramps. Gentle is 4 cells rising 1 unit each (x2..x5, rows
# 3..6); steep is 2 cells rising 2 each (x12..x13, rows 5..6). Both are checked:
# the defect was in how a wedge is built, so it was in every ramp regardless of
# slope, and a fix that only held for one of them would not be a fix.
const RAMPS := [
	{"name": "gentle", "x": 3, "first": 3, "last": 6},
	{"name": "steep", "x": 12, "first": 5, "last": 6},
]

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "RampWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# A HAZARD-FREE FIXTURE, and that is load-bearing. The first version of this
	# investigation ran on the playtest bridge, where live shooters and rushers
	# were tumbling the probe body -- and every one of those reads as "the ramp
	# threw me off". test_ascent has ramps, a ladder and two pillars, and nothing
	# that moves.
	world.segment_paths = ["res://segments/test_ascent.seg"]
	world.start(true, 1, false)

	for ramp in RAMPS:
		_check_solid(ramp)
	finish()

# Walk the length of a ramp in 5 cm steps, from a cell before it to a cell after,
# and measure how much material is under the walking surface at every step.
func _check_solid(ramp: Dictionary) -> void:
	var space := world.get_world_3d().direct_space_state
	var x: float = world.grid.cell_surface_world(Vector2i(int(ramp["x"]), int(ramp["first"]))).x
	# One cell before the ramp starts, to one cell past its top.
	var z_start: float = world.grid.cell_surface_world(
		Vector2i(int(ramp["x"]), int(ramp["first"]) - 1)).z
	var cells: int = int(ramp["last"]) - int(ramp["first"]) + 3
	var steps: int = int(float(cells) * GridConfig.CELL_SIZE / 0.05)

	var thinnest: float = INF
	var thinnest_z: float = 0.0
	var voids: int = 0
	var gaps: int = 0

	for i in steps + 1:
		var z: float = z_start - float(i) * 0.05
		var top := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			world.to_global(Vector3(x, 14.0, z)),
			world.to_global(Vector3(x, -8.0, z)), 1))
		if top.is_empty():
			gaps += 1
			continue
		var top_y: float = world.to_local(top["position"]).y
		# Up from well below, to find what the surface is standing ON. An empty
		# result is a surface with nothing under it at all.
		var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			world.to_global(Vector3(x, -8.0, z)),
			world.to_global(Vector3(x, top_y - 0.001, z)), 1))
		if under.is_empty():
			voids += 1
			continue
		var thickness: float = top_y - world.to_local(under["position"]).y
		if thickness < thinnest:
			thinnest = thickness
			thinnest_z = z

	eq(gaps, 0, "%s ramp: the walking surface is unbroken from the deck below to the deck above"
		% ramp["name"])
	eq(voids, 0, "%s ramp: and nothing you can stand on is floating over nothing"
		% ramp["name"])

	# THE CLAIM THE FIX IS FOR. Anything thinner than the deck is somewhere a body
	# can sink through before the solver has anything to push it out with -- and at
	# the bottom of an unskirted wedge it was 5 cm and falling to zero.
	check(thinnest >= GridConfig.DECK_THICKNESS - 0.01,
		"%s ramp: never thinner than the deck it joins (%.3f m at z %.2f, deck is %.2f)"
			% [ramp["name"], thinnest, thinnest_z, GridConfig.DECK_THICKNESS])
