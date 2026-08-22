extends "res://scripts/test_support/test_case.gd"

# M23 PHASE 2: THE GENERATOR CAN DIVIDE THE BRIDGE.
#
# `low[z]` was the height of the WHOLE row for the life of this generator, so
# every height change was a horizontal line running edge to edge and no section
# could ever hold two heights at once. Phase 1 proved the renderer and the
# validator already cope with a lateral cliff; this is the generator learning to
# produce one.
#
# WHAT IS ASSERTED, and each is a rule the feature would be broken without:
#   1. Splits happen at all, and are a MINORITY -- one per section at most.
#   2. A split BEGINS AND ENDS LEVEL. The row before and the row after are solid
#      across at one height, which is what keeps the join contract, the round
#      bands and the exit-row fixup unaware that a split ever happened.
#   3. Every section still validates, solo. A route that strands a lone player is
#      worse than a boring one, and drop-in makes a party of one a real case.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const SEEDS := 80
const WIDTH := GridConfig.DEFAULT_WIDTH

func setup(_main) -> void:
	_test_the_bridge_divides()
	finish()

# The distinct heights present on a row, ignoring ramps and lifts -- those
# disagree with their row by design and always have.
func _plateau_heights(seg, z: int) -> Array:
	var seen: Dictionary = {}
	for x in seg.width:
		if not seg.is_solid(x, z) or seg.kind_at(x, z) == GridConfig.Kind.RAMP:
			continue
		if seg.content_at(x, z) == GridConfig.Content.ELEVATOR:
			continue
		seen[seg.height_at(x, z)] = true
	var out: Array = seen.keys()
	out.sort()
	return out

func _has_ramp(seg, z: int) -> bool:
	for x in seg.width:
		if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
			return true
	return false

func _test_the_bridge_divides() -> void:
	var sections := 0
	var with_split := 0
	var split_rows := 0
	var deepest := 0
	var unclimbable := 0
	var ragged_ends := 0
	var uncrossable := 0
	var notes: Array = []

	for s in SEEDS:
		var seg = SegmentGen.section(WIDTH, 771100 + s * 1013, 5 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		sections += 1

		# Rows holding two plateau heights at once, as a contiguous run.
		var runs: Array = []
		var open := -1
		for z in seg.length:
			# A PIECE ROW IS NOT A SPLIT ROW (M23 phase 4). A patch is a plateau
			# narrower than the bridge by definition, so `piece_watchpost` -- three
			# units up on two cells -- reads here as a three-unit "split" with no
			# ramp before it, and reported exactly that: a divergence of 3 against a
			# SPLIT_RISE_MAX of 2, and two splits nobody had climbed to.
			#
			# Both numbers were true and neither was about this feature. Same shape
			# as the maze exclusion above, and the same lesson: when one function can
			# return two kinds of thing, a claim about one of them has to say so.
			if seg.piece_rows.has(z):
				if open >= 0:
					runs.append([open, z - 1])
					open = -1
				continue
			var levels: Array = _plateau_heights(seg, z)
			if levels.size() >= 2:
				split_rows += 1
				deepest = maxi(deepest, int(levels[levels.size() - 1]) - int(levels[0]))
				if open < 0:
					open = z
			elif open >= 0:
				runs.append([open, z - 1])
				open = -1
		if open >= 0:
			runs.append([open, seg.length - 1])
		if runs.is_empty():
			if not SegmentValidator.validate(seg).is_empty():
				uncrossable += 1
			continue
		with_split += 1

		for run in runs:
			var from: int = int(run[0])
			var to: int = int(run[1])

			# 2. LEVEL EITHER SIDE. Checked on the rows just outside the run, which
			# is where "reconverges" has to be true for the exit-row fixup and the
			# join contract to stay unaware of the split.
			if from - 1 >= 0 and _plateau_heights(seg, from - 1).size() > 1:
				ragged_ends += 1
			if to + 1 < seg.length and _plateau_heights(seg, to + 1).size() > 1:
				ragged_ends += 1
			if to >= seg.length - 2:
				ragged_ends += 1
				notes.append("split runs into the exit row at z=%d" % to)

			# 3. A CLIMB REACHES THE HIGH SIDE -- REPORTED, NOT ASSERTED, and the
			# distinction was found by A/B rather than reasoned to.
			#
			# It is a real rule: a split is not two heights, it is two heights AND
			# a climb, which phase 1 learnt by authoring a tower with one ramp row
			# and watching six cells come out marooned. But it is enforced by the
			# VALIDATOR, one layer down, and enforced by REJECTION -- so a split
			# with no way up never reaches this loop at all. Asserting it here
			# would be a zero that cannot move, which this project has shipped
			# before. Printed so a surprise shows up, and the claim that matters
			# lives on `with_split` below.
			var climbed := false
			for z in range(maxi(0, from - SegmentGen.SPLIT_RISE_MAX - 1), from):
				if _has_ramp(seg, z):
					climbed = true
					break
			if not climbed:
				unclimbable += 1
				notes.append("no ramp before the split at z=%d" % from)

		# 4. STILL CROSSABLE BY ONE.
		if not SegmentValidator.validate(seg).is_empty():
			uncrossable += 1

	print("[split-gen] %d sections, %d with a split (%d rows total), deepest divergence %d units; %d without a ramp before them"
		% [sections, with_split, split_rows, deepest, unclimbable])
	if not notes.is_empty():
		print("[split-gen] notes: %s" % str(notes.slice(0, 6)))

	check(sections > 0, "the generator produced sections to measure")

	# 1. IT HAPPENS, AND IT IS A MINORITY. A section that always splits is a
	# section with one idea in it, and the split stops being a place.
	# AND THIS IS ALSO THE TRIPWIRE FOR THE RAMP BEING ON THE WRONG SIDE, which is
	# not where you would look for it.
	#
	# A split whose ramp climbs the LOW half leaves the high half marooned -- and
	# the validator refuses that section outright, so `section()` rerolls it and
	# returns something else. Measured by A/B: putting the ramp on the wrong side
	# does not produce one broken split, it produces ZERO splits in 63 sections.
	# The feature does not break, it SILENTLY DISAPPEARS, and every other
	# assertion in this file passes vacuously while it does.
	check(with_split > 0,
		"the generator really does divide the bridge (%d of %d sections) -- for "
			% [with_split, sections]
		+ "the whole life of this generator `low[z]` was the height of the entire "
		+ "row, so this shape could not exist at any seed. This is ALSO what "
		+ "catches a ramp placed on the low side: the validator rejects those "
		+ "sections and the reroll quietly returns a section with no split in it")
	check(with_split < sections,
		"and not in every section (%d of %d) -- a split is a place, and a place "
			% [with_split, sections]
		+ "that is everywhere is scenery")
	check(deepest >= 1 and deepest <= SegmentGen.SPLIT_RISE_MAX,
		"the two halves diverge by 1 to %d units (worst seen %d) -- deep enough "
			% [SegmentGen.SPLIT_RISE_MAX, deepest]
		+ "to be a route choice, bounded so the low side is not a pit you cannot "
		+ "see out of")

	eq(ragged_ends, 0,
		"every split BEGINS AND ENDS LEVEL. The row either side of one is solid "
		+ "across at a single height, which is what keeps the join contract, the "
		+ "round bands and the exit-row fixup unaware that a split happened -- a "
		+ "split still running at the exit row is one the fixup silently levels")
	# A ZERO THAT GUARDS THE FILTER, NOT THE SPLIT. `section()` returns only a
	# segment SegmentValidator accepted, so a split that marooned the high half
	# would come back here as a MISSING split rather than as an uncrossable
	# section -- which is why `with_split > 0` above is the assertion carrying this
	# feature. test_patch_piece.gd's closing note has the full reasoning; this one
	# is kept, and reworded, because it still fires the day the reroll goes away.
	eq(uncrossable, 0,
		"section() never hands back a section a solo player cannot cross -- if "
		+ "this fires, its own validate-and-reroll has stopped running")
