extends "res://scripts/test_support/test_case.gd"

# M16 Step 1: the round boundary in the `.seg` format.
#
# A checker strip is the thing every later step points at -- the barrier stands
# on one, "is everyone across" is asked about one, and who lived through a round
# is decided by who touched one. This step proves a text file can say where one
# is, and that the strip is ORDINARY DECK in every physical respect.
#
# THE STRIP IS `Content`, NOT A NEW `Kind`, and that is the design decision this
# file is really pinning. A gate cell is solid, walkable, has a slab under it and
# takes parapets normally; the only thing that makes it a gate is that the round
# machine reads it. A fourth Kind would have had to be added to every
# `kind == DECK` test in the builder -- there are two, guarding the mesh and the
# collision separately -- and missing the second one makes the strip a walkable
# surface with NOTHING UNDER IT. That is the ramp-skirt bug of 2026-08-13, whose
# symptom was "sometimes I fall through near the bottom of a ramp" and which a
# walking test passed for months. So this asserts the SOLIDITY of the strip
# rather than assuming it.
#
# The claims:
#   1. A strip parses, and lands on the rows the author drew it on.
#   2. IT IS SOLID GROUND, with real collision under it -- measured, not assumed.
#   3. It is BLACK AND WHITE, on the same parity as the brown deck. The parity
#      rule is what makes distance readable; a boundary changes the palette and
#      never the rule.
#   4. `gate_after` and `gate_at_or_before` answer correctly, including at the
#      boundaries themselves and past the end.
#   5. A STRIP WITH A GAP IS REFUSED. That is the half of the gate that says
#      something is impossible, and this project has a standing note about
#      skipping those.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# The rows the fixture draws its strips on.
const FIRST_GATE := 2
const SECOND_GATE := 10

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "GateWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_gate.seg"]
	world.start(true, 1, false)

	_check_parsed()
	_check_solid()
	_check_colours()
	_check_queries()
	_check_a_gap_is_refused()
	finish()

# --- 1. It parses, where the author put it ------------------------------------

func _check_parsed() -> void:
	var grid: Node = world.grid
	eq(grid.gate_rows.size(), 2,
		"a segment with two strips reports two boundaries, not two per cell")
	check(grid.is_gate_row(FIRST_GATE), "the first is on row %d" % FIRST_GATE)
	check(grid.is_gate_row(SECOND_GATE), "the second on row %d" % SECOND_GATE)
	check(not grid.is_gate_row(FIRST_GATE + 1),
		"and the row after one is not one -- a strip is a line, not a region")

# --- 2. Solid ground, measured ------------------------------------------------

func _check_solid() -> void:
	var grid: Node = world.grid
	for x in 10:
		if not grid.is_solid(Vector2i(x, FIRST_GATE)):
			check(false, "the strip has a hole in it at x = %d" % x)
			return
	check(true, "every cell of the strip is solid deck")

	# AND THERE IS REALLY SOMETHING UNDER IT. `is_solid` is the grid's opinion;
	# this is the physics server's. The two disagreeing is exactly the ramp-skirt
	# bug -- a cell the data called walkable with no collider beneath it.
	var space := world.get_world_3d().direct_space_state
	var top: Vector3 = grid.cell_surface_world(Vector2i(5, FIRST_GATE))
	var query := PhysicsRayQueryParameters3D.create(
		top + Vector3(0.0, 0.5, 0.0), top - Vector3(0.0, 2.0, 0.0))
	query.collision_mask = 1        # the world layer, which is what the deck is on
	var hit: Dictionary = space.intersect_ray(query)
	check(not hit.is_empty(),
		"and a ray dropped onto the strip hits real collision, not just data")
	if not hit.is_empty():
		var depth: float = float(hit["position"].y) - (top.y - GridConfig.DECK_THICKNESS)
		check(absf(float(hit["position"].y) - top.y) < 0.05,
			"at the deck's own surface (%.3f m off)"
				% absf(float(hit["position"].y) - top.y))
		check(depth > 0.0, "with the slab under it (%.2f m)" % depth)

# --- 3. Black and white, same parity ------------------------------------------

func _check_colours() -> void:
	# The rule, not the pixels: adjacent cells differ, and the light/dark split
	# falls on the same (x + z) parity the brown deck uses. Assert the RULE --
	# reading the meshes back would be asserting Godot's material handling.
	eq(GridConfig.gate_colour(0, 0), GridConfig.GATE_LIGHT, "even parity is light")
	eq(GridConfig.gate_colour(1, 0), GridConfig.GATE_DARK, "odd is dark")
	eq(GridConfig.gate_colour(0, 1), GridConfig.GATE_DARK, "and it alternates down Z too")

	check(GridConfig.gate_colour(0, 0) != GridConfig.deck_colour(0, 0),
		"a boundary does not look like deck")
	check(GridConfig.gate_colour(1, 0) != GridConfig.deck_colour(1, 0),
		"in either phase of the checker")

	# NOT PURE BLACK. A boundary strip that reads as a hole from across the
	# bridge is the one thing it must never be, on a deck lit like this one.
	check(GridConfig.GATE_DARK.v > 0.05,
		"and the dark squares are dark, not a hole (value %.2f)"
			% GridConfig.GATE_DARK.v)

	# AND THE BUILDER REALLY PAINTS THEM. Everything above is about the rule; this
	# is about the branch in _build_deck that chooses the palette, which is our
	# code and can be wrong in a way nothing else notices -- a mistyped palette key
	# returns null and the cell renders with no material at all, silently.
	#
	# Counted rather than sampled: two strips ten cells wide is twenty painted
	# cells and not one more, so this also catches a branch that paints the whole
	# deck black and white.
	var painted := 0
	for mesh in _meshes(world.grid):
		var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
		if mat == null:
			continue
		if mat.albedo_color == GridConfig.GATE_LIGHT or mat.albedo_color == GridConfig.GATE_DARK:
			painted += 1
	eq(painted, 20,
		"the builder paints exactly the two strips -- 20 cells of a 140-cell deck")

func _meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out

# --- 4. The queries the round machine will actually ask -----------------------

func _check_queries() -> void:
	var grid: Node = world.grid
	eq(grid.gate_after(0), FIRST_GATE, "from the start, the next boundary is the first")
	eq(grid.gate_after(FIRST_GATE), SECOND_GATE,
		"STANDING ON ONE, the next is the one after it -- not the one underfoot")
	eq(grid.gate_after(SECOND_GATE), -1,
		"and past the last, there is no next: -1, never a plausible guess")

	eq(grid.gate_at_or_before(FIRST_GATE), FIRST_GATE, "the one you are standing on counts")
	eq(grid.gate_at_or_before(FIRST_GATE + 3), FIRST_GATE, "and the one you came over")
	eq(grid.gate_at_or_before(0), -1, "before any of them, there is none")

# --- 5. A gap is refused ------------------------------------------------------

func _check_a_gap_is_refused() -> void:
	# Authored by hand rather than by file, so the broken case cannot be
	# accidentally loaded by anything else.
	var good = SegmentData.from_file("res://segments/test_gate.seg")
	check(good.is_valid(), "the fixture itself parses")
	eq(SegmentValidator.validate(good).size(), 0,
		"and a full-width strip is accepted (%s)"
			% ", ".join(SegmentValidator.validate(good)))

	# One cell of ordinary deck in the middle of the strip: a strip players walk
	# around. Every rule about crossing then fails somewhere far from the cause.
	good.contents[FIRST_GATE][4] = GridConfig.Content.NONE
	var problems: Array = SegmentValidator.validate(good)
	check(problems.size() > 0, "a strip with a GAP in it is refused")
	if problems.size() > 0:
		check(str(problems[0]).contains("z = %d" % FIRST_GATE),
			"and the message names the row: %s" % problems[0])
