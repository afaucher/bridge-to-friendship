extends "res://scripts/test_support/test_case.gd"

# The .seg parser, the derived-wall rule, and the ascender validator.
#
# MVP criteria C2 (walls are derived, missing walls are authored) and the grid
# half of A4 / E1b (every elevation change has an ascender, and none is
# solo-impossible).
#
# It also asserts that the shipped segments PARSE AND VALIDATE. A broken segment
# is otherwise found by walking into it.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

func setup(_main) -> void:
	_test_shipped_segments()
	_test_wall_derivation()
	_test_row_width_is_checked()
	_test_ascender_rules()
	finish()

# --- The real files -----------------------------------------------------------

func _test_shipped_segments() -> void:
	# The playtest map is included on purpose. It is not a fixture -- no
	# assertion below depends on its contents, so it stays free to be retuned --
	# but a map that does not parse or does not validate should fail the gate
	# rather than be discovered by walking into it.
	for name in ["test_flat", "test_ascent", "playtest_bridge"]:
		var seg = SegmentData.from_file("res://segments/%s.seg" % name)
		if not check(seg.is_valid(), "%s parses (%s)" % [name, ", ".join(seg.errors)]):
			continue
		# Width is a property of the bridge, not a global -- the fixtures declare
		# 30 and the playtest map 15, and both are legitimate.
		check(seg.width > 0, "%s declares a width" % name)
		check(seg.length > 0, "%s has rows" % name)
		var problems: Array = SegmentValidator.validate(seg)
		check(problems.is_empty(), "%s validates (%s)" % [name, ", ".join(problems)])

	# The ascent segment's three routes are what the milestone is for, so assert
	# they are actually there rather than trusting the drawing.
	var ascent = SegmentData.from_file("res://segments/test_ascent.seg")
	if not ascent.is_valid():
		return
	eq(ascent.kind_at(2, 3), GridConfig.Kind.RAMP, "the gentle ramp is a ramp")
	eq(ascent.height_at(2, 3) - ascent.height_at(2, 2), 1,
		"the gentle ramp rises 1 unit per cell (~27 deg, walkable)")
	eq(ascent.kind_at(12, 5), GridConfig.Kind.RAMP, "the steep ramp is a ramp")
	eq(ascent.height_at(12, 5) - ascent.height_at(12, 4), 2,
		"the steep ramp rises 2 units per cell (45 deg, needs help)")
	eq(ascent.content_at(24, 6), GridConfig.Content.LADDER, "the ladder is where it was drawn")
	eq(ascent.kind_at(8, 6), GridConfig.Kind.HOLE,
		"the cliff row is a hole everywhere that is not an ascender")

# --- Derived walls ------------------------------------------------------------

func _test_wall_derivation() -> void:
	var seg = SegmentData.parse("""
name = walls
width = 4
length = 3

[deck]
....
._..
....

[no_wall]
....
....
X...
""")
	if not check(seg.is_valid(), "the wall fixture parses (%s)" % ", ".join(seg.errors)):
		return

	# The parapet is the bridge's OUTER edge, and only that.
	check(seg.has_wall(0, 1, GridConfig.DIR_WEST), "the bridge's outer edge gets a wall")
	check(seg.has_wall(3, 1, GridConfig.DIR_EAST), "on both sides")

	# An INTERIOR hole gets no railing. A gap in the decking is broken structure,
	# not a balcony -- and railing it would make shoving a stone through one
	# impossible, which the design calls out as the reward for rearranging the
	# bridge.
	check(not seg.has_wall(0, 1, GridConfig.DIR_EAST), "a cell facing an interior hole gets no wall")
	check(not seg.has_wall(2, 1, GridConfig.DIR_WEST), "nor does the hole's other side")

	# The Z ends stay open, or every segment would be sealed shut.
	check(not seg.has_wall(1, 2, GridConfig.DIR_NORTH), "the segment exit is left open")
	check(not seg.has_wall(1, 0, GridConfig.DIR_SOUTH), "and so is the entry")

	# Interior edges between two solid cells have no wall.
	check(not seg.has_wall(0, 0, GridConfig.DIR_EAST), "no wall between two deck cells")

	# An authored [no_wall] suppresses the parapet -- the hazard the design asks
	# for is the ABSENCE of one.
	check(not seg.has_wall(0, 2, GridConfig.DIR_WEST), "no_wall suppresses the outer parapet")

	# A hole itself has no walls to speak of.
	check(not seg.has_wall(1, 1, GridConfig.DIR_WEST), "a hole has no walls of its own")

# --- The strictness that protects hand-authoring ------------------------------

func _test_row_width_is_checked() -> void:
	var short_row = SegmentData.parse("""
name = short
width = 4
length = 2

[deck]
....
...
""")
	check(not short_row.is_valid(), "a row of the wrong width is rejected")

	var bad_glyph = SegmentData.parse("""
name = bad
width = 4
length = 1

[deck]
..Z.
""")
	check(not bad_glyph.is_valid(), "an unknown glyph is rejected")

	# Holes are `_` and not a space precisely so that an editor stripping
	# trailing whitespace cannot silently narrow a row. Prove a space is not
	# quietly accepted as a hole.
	var space_hole = SegmentData.parse("""
name = spaces
width = 4
length = 1

[deck]
.. .
""")
	check(not space_hole.is_valid(), "a space is not accepted as a hole glyph")

# --- Ascenders ----------------------------------------------------------------

func _test_ascender_rules() -> void:
	# A cliff taller than the assisted budget: no way up at all, by any means.
	# 4 units is deliberately NOT enough to trigger this -- a rope from a player
	# already up there is worth exactly that much climb (ASSISTED_RISE), so a
	# 4 m wall is a cooperation problem, not an impossible one.
	var no_way_up = SegmentData.parse("""
name = cliff
width = 3
length = 3

[deck]
...
...
...

[height]
000
000
666
""")
	var problems: Array = SegmentValidator.validate(no_way_up)
	check(problems.size() > 0, "a cliff with no ascender is rejected")
	check(_mentions(problems, "no way up"), "and says so plainly (%s)" % ", ".join(problems))

	# The same cliff with a ladder on it is fine.
	var laddered = SegmentData.parse("""
name = laddered
width = 3
length = 3

[deck]
...
...
...

[height]
000
000
444

[content]
...
...
.L.
""")
	check(SegmentValidator.validate(laddered).is_empty(),
		"a ladder makes the same cliff passable (%s)" % ", ".join(SegmentValidator.validate(laddered)))

	# A cliff crossable only with help strands a lone player -- the rule that
	# exists because drop-in means the party can be one person at any moment.
	var assisted_only = SegmentData.parse("""
name = assisted
width = 3
length = 3

[deck]
...
...
...

[height]
000
000
333
""")
	var stranded: Array = SegmentValidator.validate(assisted_only)
	check(stranded.size() > 0, "a help-only route is rejected")
	check(_mentions(stranded, "solo player is stranded"),
		"and names the reason (%s)" % ", ".join(stranded))

func _mentions(problems: Array, fragment: String) -> bool:
	for p in problems:
		if str(p).findn(fragment) != -1:
			return true
	return false
