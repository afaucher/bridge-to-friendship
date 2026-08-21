extends "res://scripts/test_support/test_case.gd"

# M22 PHASE B: THE BRIDGE IS NOT THE SAME WIDTH EVERYWHERE.
#
# The complaint that started this: "we did a whole milestone around map variety
# but I don't see a lot of map width variety". It was true and it was one
# variable. `_section_attempt` narrowed with a single symmetric `margin` applied
# to one contiguous band of rows, so the deck could only ever pinch evenly toward
# its own centre line, once, by one to three columns.
#
# Now each side carries its own inset per row. What is asserted here is that the
# variety is REAL -- measured over many seeds, not eyeballed on one -- and that
# it is bounded by the two rules that keep it safe: a rate cap so an edge tapers
# rather than appearing underfoot, and full-width ends so the join contract and
# the round bands still hold.
#
# WHY A RATE CAP IS A CORRECTNESS RULE AND NOT A STYLE ONE. Deck thickness is
# derived from a cell's EIGHT neighbours, so an edge that jumps several columns
# in one row leaves solid cells with nothing under them -- the same shape as the
# ramp that was 5 cm of paper over a DECK_THICKNESS void, which reached playtest
# as "sometimes I fall through".

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const SEEDS := 60
const WIDTH := GridConfig.DEFAULT_WIDTH

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const RUN_SEED := 20260820
const RUN_SEGMENTS := 12

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 60.0
	_test_edges_move_and_move_apart()
	_test_the_rules_that_keep_it_safe()

	# AND THEN THE OBJECT THE PLAYER ACTUALLY WALKS ON. Everything above calls
	# SegmentGen.section() directly, which is the same function BridgeGrid calls
	# -- but "the same function" is the reasoning that has produced a wrong answer
	# in this project more than once, so a real assembled run gets measured too.
	world = Node3D.new()
	world.name = "WidthRunWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)

func _physics_process(_delta: float) -> void:
	if done or world == null or world.tick < 2:
		return
	done = true
	_test_a_real_run_has_them()
	finish()

# --- The taper, as arithmetic -------------------------------------------------
#
# `_cone` and its unit test lived here. It found the taper by taking a two-pass
# minimum over flat setback bands, and was replaced because it always produced
# the STEEPEST taper the rate cap allows -- finding the largest profile that fits
# means tapering as late and as hard as it can. What replaced it states the
# gradient rather than discovering it, so the property worth asserting moved from
# "the cone is Lipschitz" to "the deck holds still on most rows", which is
# _test_it_gets_there_gradually below.

# --- The variety itself -------------------------------------------------------

# The first and last solid column of a row, or (-1, -1) for an empty one.
func _span(seg, z: int) -> Vector2i:
	var first := -1
	var last := -1
	for x in seg.width:
		if not seg.is_solid(x, z):
			continue
		if first < 0:
			first = x
		last = x
	return Vector2i(first, last)

# MAZES AND PIECE ROWS ARE EXCLUDED FROM EVERY NUMBER BELOW, and finding out why
# was the whole value of A/B-ing this test.
#
# The first version measured all of `section()`'s output and PASSED against the
# pre-M22 code with the mutation verified applied -- so it was proving nothing. A
# maze is asymmetric and one cell wide by design, and a set-piece authored its own
# silhouette, so both were supplying "variety" that had nothing to do with the
# inset profile. Same shape as the note already in CLAUDE.md about a test run on
# the wrong object: widening the sample made it slower and no more able to fail.
func _sampled(seg, z: int) -> bool:
	return not seg.tags.has("maze") and not seg.piece_rows.has(z)

func _test_edges_move_and_move_apart() -> void:
	var widths: Dictionary = {}
	var asymmetric := 0
	var rows := 0
	var sections := 0
	var narrowest: int = WIDTH
	for s in SEEDS:
		var seg = SegmentGen.section(WIDTH, 90210 + s * 977, 1 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		sections += 1
		for z in seg.length:
			if not _sampled(seg, z):
				continue
			var span: Vector2i = _span(seg, z)
			if span.x < 0:
				continue
			rows += 1
			var left: int = span.x
			var right: int = seg.width - 1 - span.y
			var usable: int = span.y - span.x + 1
			widths[usable] = int(widths.get(usable, 0)) + 1
			narrowest = mini(narrowest, usable)
			if left != right:
				asymmetric += 1

	var seen: Array = widths.keys()
	seen.sort()
	# THE MEDIAN IS THE NUMBER THAT SAYS HOW THE GAME PLAYS. A range is easy to
	# read as success -- nine distinct widths! -- while the bridge is quietly
	# narrower than the 15 cells everything else was tuned against.
	var median := 0
	var counted := 0
	for w in seen:
		counted += int(widths[w])
		if counted * 2 >= rows:
			median = int(w)
			break
	var baseline: int = WIDTH - 2 * GridConfig.BASELINE_INSET
	print("[width] %d non-maze sections, %d generated rows; usable widths seen %s, median %d (baseline %d)"
		% [sections, rows, str(seen), median, baseline])
	check(absi(median - baseline) <= 1,
		"and the MEDIAN width is the baseline (%d against %d). A range is easy to "
			% [median, baseline]
		+ "read as success while the bridge is quietly narrower than the number "
		+ "every other system was tuned against -- variety should depart from "
		+ "normal, not replace it")
	print("[width] %d of %d rows are ASYMMETRIC (one edge cut further than the other)"
		% [asymmetric, rows])

	check(sections > 0, "the generator produced sections to measure")
	check(rows > 0, "and rows the profile actually drew")

	# THE CLAIM THE OLD CODE CANNOT SATISFY, and the reason it is phrased as a
	# PARITY argument rather than as a count. At an odd canvas a single symmetric
	# margin can only ever produce ODD usable widths -- 15 - 2m is 15, 13, 11, 9
	# and nothing else, whatever the margin rolls. An EVEN width is therefore
	# arithmetic proof that the two edges were cut by different amounts, and no
	# amount of re-rolling the old generator can produce one.
	var evens := 0
	for w in seen:
		if int(w) % 2 == 0:
			evens += 1
	check(evens > 0,
		"the deck comes out an EVEN number of cells wide somewhere (%s). At an "
			% str(seen)
		+ "odd canvas that is only possible if the two edges were cut by "
		+ "different amounts, so it is proof of independence rather than a "
		+ "threshold somebody tuned")
	check(asymmetric > 0,
		"and %d rows are cut further on one side than the other -- a bridge that "
			% asymmetric
		+ "hugs one edge is a shape ONE symmetric margin could not express at all")

	# AND MORE DISTINCT WIDTHS THAN THE OLD SHAPE COULD REACH. Four is its whole
	# vocabulary at this canvas ({9, 11, 13, 15}), so five is the first count that
	# says something new happened.
	check(seen.size() >= 5,
		"a run holds at least five different bridge widths (%s) -- the old "
			% str(seen)
		+ "symmetric margin's entire vocabulary at this canvas was four")
	check(narrowest <= WIDTH - 4,
		"and gets genuinely narrow somewhere (%d of %d)" % [narrowest, WIDTH])
	_test_it_gets_there_gradually()

# --- IT TAPERS RATHER THAN SNAPPING -------------------------------------------
#
# The rate cap is a correctness floor -- never steeper than a column per row,
# because deck thickness reads a cell's eight neighbours. Built AT that floor a
# three-column setback completes in three rows, which is six metres: a player
# crosses it in a second and it reads as the bridge snapping.
#
# So the measurement here is not "is it legal" but "how much of the section does
# a change take". A run of rows where the edge is MOVING should be a minority of
# a section and each move should be spaced, not a burst of consecutive steps.
func _test_it_gets_there_gradually() -> void:
	var moves := 0          # rows where an edge moved at all
	var rows := 0
	var longest_burst := 0  # consecutive rows of movement -- the snap, if any
	for s in SEEDS:
		var seg = SegmentGen.section(WIDTH, 4242 + s * 653, 2 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		var prev := Vector2i(-1, -1)
		var burst := 0
		for z in seg.length:
			if not _sampled(seg, z):
				prev = Vector2i(-1, -1)
				burst = 0
				continue
			var span: Vector2i = _span(seg, z)
			if span.x < 0:
				continue
			if prev.x >= 0:
				rows += 1
				if span.x != prev.x or span.y != prev.y:
					moves += 1
					burst += 1
					longest_burst = maxi(longest_burst, burst)
				else:
					burst = 0
			prev = span

	var moving: float = 100.0 * float(moves) / float(maxi(1, rows))
	print("[width] the edge is MOVING on %.0f%% of rows (%d of %d); longest unbroken run of moves %d"
		% [moving, moves, rows, longest_burst])

	# A CHANGE IS SPREAD OVER SEVERAL ROWS, so most rows are holding still. At the
	# rate cap with no stride every transition row moves, and a section that
	# narrowed and widened once would be moving on most of its rows.
	check(moving < 55.0,
		"the deck is holding still on most rows (%.0f%% moving) -- a width change "
			% moving
		+ "spread over several rows means most rows are not a change, which is "
		+ "what 'gradual' means when you measure it")
	# AND NOT AS A BURST. The failure mode this replaced was a legal-but-instant
	# taper: three consecutive rows each moving a column, which satisfies the rate
	# cap perfectly and reads as a step.
	check(longest_burst <= SegmentGen.INSET_STEP_ROWS_MAX,
		"and never moves for more than %d rows unbroken (worst %d) -- consecutive "
			% [SegmentGen.INSET_STEP_ROWS_MAX, longest_burst]
		+ "single-column steps are a staircase, which is the rate cap being "
		+ "satisfied and the intent being missed")

func _test_the_rules_that_keep_it_safe() -> void:
	var rate_breaks := 0
	var open_ends := 0
	var checked := 0
	var uncrossable := 0
	var mazes := 0
	var break_notes: Array = []
	for s in SEEDS:
		var seg = SegmentGen.section(WIDTH, 5150 + s * 1409, 3 + s)
		if seg == null or not seg.is_valid():
			continue
		checked += 1

		# EVERY SEGMENT BOUNDARY IS THE SAME FAMILIAR WIDTH. The join contract
		# (M17) and the round bands (M16) both rest on the ends being predictable,
		# and M22 leans on it a third time: it is why a setback never needs a
		# special case at a boundary.
		#
		# THE BASELINE, NOT THE CANVAS (phase C). Every authored file is padded to
		# the baseline, so a canvas-wide generated end would butt a 15-wide
		# authored one and put a six-cell step at the seam. Asserted on both sides
		# rather than as "at least this wide", because too wide is the failure that
		# actually happened.
		var edge: int = GridConfig.BASELINE_INSET
		for z in [0, seg.length - 1]:
			var span: Vector2i = _span(seg, z)
			if span.x != edge or span.y != seg.width - 1 - edge:
				open_ends += 1

		# CROSSABILITY IS ASKED OF EVERY SECTION, mazes included -- it is the one
		# claim that has nothing to do with which generator drew the thing, and
		# skipping mazes here would quietly halve the population of the assertion
		# that matters most.
		if not SegmentValidator.validate(seg).is_empty():
			uncrossable += 1

		# A MAZE IS A DIFFERENT GENERATOR AND KEEPS ITS OWN SHAPE. `section()` may
		# return `_maze_attempt`, which lays corridors and walls rather than a
		# plateau with edges, and its solid span jumps by design -- a corridor
		# mouth is supposed to be one cell wide next to a wall. Measured before it
		# was excluded: 64 "rate breaks", every one of them a maze doing its job.
		# The inset profile is `_section_attempt`'s, so this is the population the
		# claim is about.
		if seg.tags.has("maze"):
			mazes += 1
			continue

		# THE RATE CAP, measured on the OUTPUT rather than on the profile that
		# produced it -- the profile is an intention and the deck is what a player
		# walks on. Piece rows are skipped: a set-piece owns its rows outright and
		# authored its own silhouette, so it is not the generator's taper to keep.
		var prev := Vector2i(-1, -1)
		for z in seg.length:
			var span: Vector2i = _span(seg, z)
			if span.x < 0 or seg.piece_rows.has(z) or seg.piece_rows.has(z - 1):
				prev = span
				continue
			if prev.x >= 0:
				if absi(span.x - prev.x) > SegmentGen.INSET_RATE \
						or absi(span.y - prev.y) > SegmentGen.INSET_RATE:
					rate_breaks += 1
					if break_notes.size() < 6:
						break_notes.append("z=%d span %s->%s" % [z, str(prev), str(span)])
			prev = span

	if not break_notes.is_empty():
		print("[width] rate breaks: %s" % str(break_notes))
	print("[width] %d sections (%d of them mazes, exempt from the rate cap): %d rate breaks, %d open ends, %d uncrossable"
		% [checked, mazes, rate_breaks, open_ends, uncrossable])
	check(checked - mazes > 0,
		"and there were non-maze sections to measure -- if the maze exemption ate "
		+ "the whole sample the rate assertion below is vacuous")

	eq(rate_breaks, 0,
		"no edge moves more than %d column between adjacent rows. Deck thickness "
			% SegmentGen.INSET_RATE
		+ "is derived from a cell's EIGHT neighbours, so an edge that jumps "
		+ "leaves solid cells with nothing under them -- the paper-thin ramp bug "
		+ "wearing a new hat, and it presents as 'sometimes I fall through'")
	eq(open_ends, 0,
		"every section's entry and exit row is solid ACROSS -- the invariant the "
		+ "join contract, the round bands and M22's own 'no special case at a "
		+ "boundary' argument all rest on")
	eq(uncrossable, 0, "and every section still validates")

# --- The run a player is actually dropped into --------------------------------
#
# THE ANSWER TO "DO WE EVER USE THIS?", asked of the assembled bridge rather than
# of the generator. `BridgeGrid.build_run` fills roughly two slots in three with
# GENERATED_SECTION and the rest with a lobby or an authored file, so the share
# of a real run that carries a generated profile is a smaller number than the
# generator's own output -- and it is the number that matters.
func _test_a_real_run_has_them() -> void:
	var grid: Node = world.grid
	var rows: int = grid.next_z()
	var asymmetric := 0
	var narrowed := 0
	var measured := 0
	var widths: Dictionary = {}
	for z in rows:
		var first := -1
		var last := -1
		for x in grid.width:
			if not grid.is_solid(Vector2i(x, z)):
				continue
			if first < 0:
				first = x
			last = x
		if first < 0:
			continue
		measured += 1
		var left: int = first
		var right: int = grid.width - 1 - last
		widths[last - first + 1] = int(widths.get(last - first + 1, 0)) + 1
		if left != right:
			asymmetric += 1
		if left > 0 or right > 0:
			narrowed += 1

	var seen: Array = widths.keys()
	seen.sort()
	print("[width] REAL RUN: %d segments, %d rows; widths %s"
		% [grid.segment_count(), measured, str(seen)])
	print("[width] REAL RUN: %d rows narrowed, %d of those ASYMMETRIC"
		% [narrowed, asymmetric])

	check(measured > 0, "the run built rows to measure")
	check(narrowed > 0,
		"a run a player is dropped into really does narrow somewhere (%d of %d "
			% [narrowed, measured]
		+ "rows) -- the generator producing setbacks is not the same claim as a "
		+ "RUN containing them, and this project has been caught by that gap")
	check(asymmetric > 0,
		"and %d of those rows are cut further on one side than the other. This is "
			% asymmetric
		+ "the assertion that says the independent edges are USED rather than "
		+ "merely implemented")
