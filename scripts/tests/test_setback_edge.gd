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
	_test_the_railing_turns_the_corner()
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

	# OPEN DECK IS NOT WALLED ALONG THE BRIDGE. Row 10 is solid across and so are
	# its neighbours, so there is no exterior edge here in either Z direction.
	check(not seg.has_wall(7, OPEN_ROW, GridConfig.DIR_NORTH),
		"a cell with solid deck ahead of it is not railed along the bridge")
	check(not seg.has_wall(7, OPEN_ROW, GridConfig.DIR_SOUTH), "or behind it")

	# THE SEGMENT'S OWN ENDS ARE OPEN, or every segment seals shut and no run
	# joins. This is the case that kept the whole Z branch a blanket `false` for
	# three milestones, so it is asserted rather than assumed.
	check(not seg.has_wall(7, 0, GridConfig.DIR_SOUTH),
		"and the segment's entry row is open along the bridge -- walling the Z "
		+ "ends would seal every segment shut and no run would join")
	check(not seg.has_wall(7, seg.length - 1, GridConfig.DIR_NORTH),
		"as is its exit row")

# --- 1b. The railing follows the outline, not just the sides ------------------
#
# Reported from a playtest: "walls for all exterior edges except where marked --
# the always to the side thing looks funny". A railing that only ran across X
# left every taper step as an L-shaped corner with a rail down one face and
# nothing along the other, so the deck came out fenced in dashes.
func _test_the_railing_turns_the_corner() -> void:
	# Row 1 is solid across; row 2 is set back three columns. So the cell at the
	# END of row 1's overhang has void AHEAD of it, and that void runs off the
	# side of the canvas -- an exterior edge facing along the bridge.
	check(seg.has_wall(0, 1, GridConfig.DIR_NORTH),
		"a cell with an exterior void AHEAD of it is railed along the bridge "
		+ "(col 0, row 1 -> row 2's setback) -- this is the corner that used to "
		+ "be left open, and it is the same void the cell beside it is railed "
		+ "against")

	# AND A PIT IS STILL A PIT FROM EVERY DIRECTION. The gap at columns 7-8 on
	# rows 4-6 has deck closing around it, so the cell just before it must not be
	# railed -- otherwise "exterior" has quietly come to mean "any hole", and you
	# could no longer shove a stone into one.
	check(not seg.has_wall(7, 3, GridConfig.DIR_NORTH),
		"and a cell with an INTERIOR gap ahead of it is not (col 7, row 3 -> the "
		+ "mid-deck gap) -- a pit is a pit whichever way you walk into it")
	_test_a_chasm_is_not_an_edge()

# --- 1c. A GAP ACROSS THE BRIDGE IS NOT THE SIDE OF THE BRIDGE ----------------
#
# The case the first version of the Z rule got wrong, and it went straight to
# the two pieces whose entire subject is a gap. Asking only "does the void ahead
# reach the side of the canvas" is far too loose: a chasm ACROSS the deck reaches
# the side trivially, by spanning it. That railed the front lip of every
# full-width gap -- measured at 20 rails on piece_timed_crossing and 16 on
# piece_crumble_causeway -- turning a gap you may walk into off the front into a
# corridor you are funnelled down.
#
# Built inline rather than on a `.seg` in the library, because this is a property
# of the RULE and a fixture somebody authors for feel is not the place to pin one.
func _test_a_chasm_is_not_an_edge() -> void:
	var chasm = SegmentData.parse("""
name = inline_chasm
width = 9
length = 5
tags = fixture

[deck]
.........
.........
_________
.........
.........

[height]
000000000
000000000
000000000
000000000
000000000

[content]
.........
.........
.........
.........
.........
""")
	if not check(chasm.is_valid(), "the inline chasm parses (%s)" % str(chasm.errors)):
		return

	# THE MIDDLE OF THE LIP IS OPEN. You are meant to be able to walk off the
	# front of a chasm into it.
	check(not chasm.has_wall(4, 1, GridConfig.DIR_NORTH),
		"the front lip of a full-width chasm is NOT railed in its middle -- a gap "
		+ "across the bridge reaches the side of the canvas by SPANNING it, which "
		+ "is not the same as being the side of the bridge")

	# THE CORNER IS RAILED, and only the corner: that one cell is where the
	# bridge's own side edge meets the chasm, which IS the outline turning.
	check(chasm.has_wall(0, 1, GridConfig.DIR_NORTH),
		"while the cell at the bridge's own EDGE is (col 0) -- that is the side "
		+ "railing turning the corner, not the chasm being fenced")
	check(chasm.has_wall(8, 1, GridConfig.DIR_NORTH), "on both sides")

	var lip := 0
	for x in chasm.width:
		if chasm.has_wall(x, 1, GridConfig.DIR_NORTH):
			lip += 1
	eq(lip, 2,
		"and exactly two cells of a nine-wide lip are railed (%d) -- counted, "
			% lip
		+ "because 'the middle is open' and 'the corners are closed' are both "
		+ "satisfied by a rule that rails half the row")

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
		var sideways := 0
		var along := 0
		# ALL FOUR DIRECTIONS. This walked only WEST and EAST, which meant the
		# report could not see the change that added Z railings AT ALL -- it was
		# measuring the half of the rule that had not moved. Asked for directly:
		# "did we check that interior holes and thin bridges stayed untouched?"
		for z in s.length:
			for x in s.width:
				for dir in [GridConfig.DIR_WEST, GridConfig.DIR_EAST,
						GridConfig.DIR_NORTH, GridConfig.DIR_SOUTH]:
					var was: bool = _old_rule(s, x, z, dir)
					var now: bool = s.has_wall(x, z, dir)
					if now and not was:
						if GridConfig.DIR_CELLS[dir].x != 0:
							sideways += 1
						else:
							along += 1
					elif was and not now:
						lost += 1
		total_gained += sideways + along
		if sideways + along > 0:
			print("[setback] %s gains %d sideways, %d ALONG the bridge"
				% [String(path).get_file(), sideways, along])
	print("[setback] authored content gains %d parapets in total, loses %d"
		% [total_gained, lost])

	eq(lost, 0,
		"NO authored parapet disappears. The old rule is a strict subset of the "
		+ "new one -- one step off the canvas is the trivial walk off the canvas "
		+ "-- so a railing that vanished would mean the walk itself is wrong, not "
		+ "that a level changed")
