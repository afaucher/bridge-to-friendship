extends "res://scripts/test_support/test_case.gd"

# M22 PHASE A: A NARROWED BRIDGE HAS AN EDGE, NOT A MISSING FLOOR.
#
# `has_wall` used to ask `nx < 0 or nx >= width` -- the true grid boundary. The
# generator narrows a section by cutting `margin` columns off each side as HOLE
# and says why in its own comment ("a fiction is cheaper than a format"), and a
# margin hole is INSIDE [0, width), so it never satisfied that check. Every
# narrow stretch in the game was therefore an unrailed drop.
#
# The new rule walks outward: void that reaches the canvas is an EDGE, void the
# deck closes around is a PIT. Both are runs of `_` in the file, which is the
# whole reason the rule has to measure geometry rather than read a tag.
#
# WHAT IS ASSERTED, in the order it matters:
#   1. The distinction exists at all -- setback rails, gap does not.
#   2. A BODY IS ACTUALLY STOPPED by the new railing. This project has shipped
#      five bugs that were one wrong bit in a collision mask, and CLAUDE.md is
#      explicit that "a test that a blocker exists is not a test that it blocks".
#   3. The true edge is unchanged, so nothing that already worked moved.
#   4. What this does to AUTHORED content, reported as a number rather than
#      assumed to be zero.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# From test_setback.seg. Rows 2-8 are set back 3 columns each side; rows 4-6 also
# carry a two-cell gap at columns 7-8.
const SETBACK_ROW := 3          # set back, no gap on this row
const BOTH_ROW := 5             # set back AND holding the mid-deck gap
const OPEN_ROW := 10            # full width, nothing cut
const LEFT_EDGE := 3            # first solid column inside the setback
const RIGHT_EDGE := 12          # last solid column inside the setback
const GAP_LEFT := 6             # solid, with the gap immediately east of it
const GAP_RIGHT := 9            # solid, with the gap immediately west of it

# Long enough to press a body into the railing and have it stay there, short
# enough not to walk off the end of a twelve-row fixture.
const SHOVE_TICKS := 90

var world: Node3D = null
var seg = null
var body: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	seg = SegmentData.from_file("res://segments/test_setback.seg")
	world = Node3D.new()
	world.name = "SetbackWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_setback.seg"]
	world.start(true, 1, false)
	world._spawn_player(704155382, 0)
	body = world.player_body(704155382)
	# Parked on the setback row, hard against its western edge, walking WEST for
	# the whole run. If the railing is not there this walks straight off.
	body.position = world.grid.cell_surface_world(Vector2i(LEFT_EDGE, SETBACK_ROW)) \
		+ Vector3(0.0, 1.2, 0.0)
	world.scripted_inputs[704155382] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(-1.0, 0.0), 0)

# The rule as it was before M22, so the two can be diffed on real content.
func _old_rule(s, x: int, z: int, dir: int) -> bool:
	if not s.is_solid(x, z) or s.no_wall_at(x, z):
		return false
	if s.kind_at(x, z) == GridConfig.Kind.RAMP:
		return false
	var nx: int = x + GridConfig.DIR_CELLS[dir].x
	return nx < 0 or nx >= s.width

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < SHOVE_TICKS:
		return
	done = true

	_test_the_distinction()
	_test_a_body_is_stopped()
	_test_the_true_edge_is_unchanged()
	_report_what_authored_content_gains()
	finish()

# --- 1. Setback rails, gap does not -------------------------------------------

func _test_the_distinction() -> void:
	check(seg.is_valid(), "the fixture parses (%s)" % str(seg.errors))

	# THE SETBACK. Void from column 2 outward reaches the canvas, so column 3 is
	# the bridge's edge here even though its index is not 0.
	check(seg.has_wall(LEFT_EDGE, SETBACK_ROW, GridConfig.DIR_WEST),
		"a solid cell whose westward void runs off the canvas is an EDGE and is "
		+ "railed (col %d, row %d) -- this is the whole fix: the generator's "
			% [LEFT_EDGE, SETBACK_ROW]
		+ "narrowing was unrailed, so a narrow section read as missing floor")
	check(seg.has_wall(RIGHT_EDGE, SETBACK_ROW, GridConfig.DIR_EAST),
		"and the same on the other side (col %d)" % RIGHT_EDGE)

	# THE GAP, on a row that is ALSO set back -- so a rule keyed off "is this row
	# narrowed" would rail it and this is the assertion that catches that.
	check(not seg.has_wall(GAP_LEFT, BOTH_ROW, GridConfig.DIR_EAST),
		"a solid cell beside a gap the deck CLOSES AROUND gets nothing (col %d, "
			% GAP_LEFT
		+ "row %d) -- a gap is broken structure you fall into, and railing it "
			% BOTH_ROW
		+ "would also make it impossible to shove a stone through, which the "
		+ "design calls out as the reward for rearranging the bridge")
	check(not seg.has_wall(GAP_RIGHT, BOTH_ROW, GridConfig.DIR_WEST),
		"from the far side of the same gap too (col %d)" % GAP_RIGHT)

	# AND BOTH ON ONE ROW AT ONCE. The row is set back AND gapped, and the rule
	# has to answer differently for two cells eight columns apart on it.
	check(seg.has_wall(LEFT_EDGE, BOTH_ROW, GridConfig.DIR_WEST)
			and not seg.has_wall(GAP_LEFT, BOTH_ROW, GridConfig.DIR_EAST),
		"one row holds both answers at once -- the same glyph, told apart by "
		+ "where the void GOES rather than by anything the file declares")

# --- 2. It actually blocks -----------------------------------------------------

func _test_a_body_is_stopped() -> void:
	var cell: Vector2i = world.grid.cell_of_world(body.position)
	print("[setback] after %d ticks of walking WEST the body is at cell %s, x %.2f"
		% [SHOVE_TICKS, str(cell), body.global_position.x])

	# STILL ON THE BRIDGE. The failure this catches is not subtle -- with no
	# railing the body walks off the setback and falls, and `is_solid` of where it
	# ended up is the honest way to ask.
	check(body.global_position.y > -5.0,
		"a body walking into the new railing is still on the bridge (y %.2f) -- "
			% body.global_position.y
		+ "asserting the parapet EXISTS is not asserting that it blocks, and this "
		+ "project has shipped five bugs that were exactly that gap")
	check(cell.x >= LEFT_EDGE,
		"and did not cross into the set-back columns (col %d, edge is %d)"
			% [cell.x, LEFT_EDGE])

# --- 3. Nothing that already worked moved -------------------------------------

func _test_the_true_edge_is_unchanged() -> void:
	# The canvas boundary on a full-width row: void reaches the edge in ONE step,
	# which is the old rule's case and must answer identically.
	check(seg.has_wall(0, OPEN_ROW, GridConfig.DIR_WEST),
		"the true grid edge is still railed on a full-width row")
	check(seg.has_wall(seg.width - 1, OPEN_ROW, GridConfig.DIR_EAST),
		"on both sides")

	# THE Z ENDS ARE STILL OPEN, or every segment seals shut and no run joins.
	# Worth its own assertion because the new rule added a loop, and a Z step does
	# not move x -- so the guard that returns early is load-bearing rather than
	# tidy, and without it this call would never return.
	check(not seg.has_wall(7, OPEN_ROW, GridConfig.DIR_NORTH),
		"and the Z ends are still open -- walling them would seal every segment "
		+ "shut, and the loop would never terminate on a step that leaves x alone")
	check(not seg.has_wall(7, OPEN_ROW, GridConfig.DIR_SOUTH), "both of them")

# --- 4. What this does to content somebody already authored -------------------
#
# REPORTED, NOT ASSERTED AT ZERO. The rule is a real behaviour change and it is
# SUPPOSED to add railings where an authored void runs off the side -- that is
# the bug being fixed, and it applies to hand-written files as much as to
# generated ones. What must not happen is a parapet DISAPPEARING: the old rule is
# a strict subset of the new one (one step off the canvas is the trivial case of
# a walk off the canvas), so anything that was railed still is, and a file that
# lost one would mean the walk has a bug in it.
func _report_what_authored_content_gains() -> void:
	var files: Array = [SegmentPool.LOBBY]
	for entry in SegmentPool.POOL:
		files.append(String(entry["path"]))
	for path in SetPieces.LIBRARY:
		files.append(String(path))

	var total_gained := 0
	var lost := 0
	for path in files:
		var s = SegmentData.from_file(String(path))
		if s == null or not s.is_valid():
			continue
		var gained := 0
		for z in s.length:
			for x in s.width:
				for dir in [GridConfig.DIR_WEST, GridConfig.DIR_EAST]:
					var was: bool = _old_rule(s, x, z, dir)
					var now: bool = s.has_wall(x, z, dir)
					if now and not was:
						gained += 1
					elif was and not now:
						lost += 1
		total_gained += gained
		if gained > 0:
			print("[setback] %s gains %d parapet(s)" % [String(path).get_file(), gained])
	print("[setback] authored content gains %d parapets in total, loses %d"
		% [total_gained, lost])

	eq(lost, 0,
		"NO authored parapet disappears. The old rule is a strict subset of the "
		+ "new one -- one step off the canvas is the trivial walk off the canvas "
		+ "-- so a railing that vanished would mean the walk itself is wrong, not "
		+ "that a level changed")
