extends "res://scripts/test_support/test_case.gd"

# M23 PHASE 3: A PIECE NARROWER THAN THE BRIDGE.
#
# Until now every set-piece spanned the whole canvas and OWNED its rows: the
# stamping loop wrote `for x in width` and then `continue`d, skipping the insets,
# the lane split, the ramps, the lifts and the height split. That is right for a
# full-width composition and impossible for a tower, which needs terrain running
# past it on both sides.
#
# `design_ideas/world_generation.md` named this in M17 -- "a 4-8 row full-width
# slice, OR A SMALLER PATCH WITH A DECLARED FOOTPRINT" -- and nothing could
# express it, because `for_width` matched on equality.
#
# WHAT IS ASSERTED:
#   1. Patches are SELECTED and PLACED, in real sections. Phase 2 established
#      that a generator which validates and rerolls turns a placement bug into an
#      ABSENCE, so the count of the thing happening at all is the assertion that
#      bites.
#   2. They MOVE. A patch always at one offset is being centred, not placed.
#
# AND THAT IS NEARLY ALL THAT CAN BE ASSERTED HERE, which is worth knowing
# before adding to it. `section()` returns only a segment the validator
# accepted, so every property the validator checks -- crossable, no marooned
# deck, no island -- is true of everything this test can see, whatever the
# generator did. Those numbers are printed instead.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const SEEDS := 400
const WIDTH := GridConfig.DEFAULT_WIDTH
const LOOKOUT := "res://segments/piece_lookout.seg"

func setup(_main) -> void:
	_test_the_library_offers_one()
	_test_the_generator_places_them()
	finish()

# --- 1. It exists and is selectable -------------------------------------------

func _test_the_library_offers_one() -> void:
	var lookout = SegmentData.from_file(LOOKOUT)
	check(lookout.is_valid(), "the lookout parses (%s)" % str(lookout.errors))
	check(lookout.width < WIDTH,
		"and is NARROWER than the bridge (%d against %d) -- which is the whole "
			% [lookout.width, WIDTH]
		+ "of what a patch is")
	check(SetPieces.is_patch(lookout, WIDTH), "so it reads as a patch")
	eq(int(lookout.piece_exit), 0,
		"and claims no exit height. Terrain runs past a patch on both sides at the "
		+ "plateau it was stamped at, so a patch that raised the deck would desync "
		+ "the running height from the ground either side of itself")

	var offered: Array = SetPieces.for_width(WIDTH)
	var found := false
	for p in offered:
		if p.name == "piece_lookout":
			found = true
	check(found,
		"and `for_width` offers it (%d pieces) -- it matched on EQUALITY until "
			% offered.size()
		+ "now, so a piece narrower than the canvas could never be picked")

# --- 2..4. The generator really uses it ----------------------------------------

func _test_the_generator_places_them() -> void:
	var sections := 0
	var with_patch := 0
	var patch_rows := 0
	var off_ground := 0
	var flattened := 0
	var uncrossable := 0
	var offsets: Dictionary = {}
	var against_deck: Array = []

	for s in SEEDS:
		var seg = SegmentGen.section(WIDTH, 313370 + s * 809, 2 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		sections += 1
		if not SegmentValidator.validate(seg).is_empty():
			uncrossable += 1

		# A patch row is a piece row that is NOT solid across: the terrain either
		# side of it carries the section's own width insets, so a patch row still
		# looks like ordinary deck at its edges.
		# READ OFF THE RECORD, NOT INFERRED FROM THE GEOMETRY. The first version of
		# this looked for "a narrow run of raised cells" and called that a patch --
		# which also catches a FULL-WIDTH piece that happens to hold a narrow raised
		# feature, and those rows are legitimately mostly holes. It reported 53
		# flattened rows and 3 off solid ground, every one of them a causeway or a
		# shelf being measured against a rule that was never about it.
		var here := false
		for z in seg.piece_rows:
			var span: Vector2i = seg.piece_footprints.get(int(z), Vector2i(0, seg.width))
			if span.y - span.x >= seg.width:
				continue          # a full-width piece doing full-width things
			var from: int = span.x
			var to: int = span.y - 1
			here = true
			patch_rows += 1
			offsets[from] = int(offsets.get(from, 0)) + 1

			# WHERE IT SITS RELATIVE TO THE DECK AT THIS ROW, as -1 (hard against
			# the left rail) through 0 (centred) to +1 (hard right). The canvas
			# offset above cannot say this: it is the same number on a deck that
			# has shifted six columns.
			var d_lo := -1
			var d_hi := -1
			for x in seg.width:
				if not seg.is_solid(x, int(z)):
					continue
				if d_lo < 0:
					d_lo = x
				d_hi = x
			var room: float = float(d_hi - d_lo + 1 - (to - from + 1))
			if room > 0.5:
				var mid: float = float(from - d_lo) / room
				against_deck.append(mid * 2.0 - 1.0)

			# 3. ON SOLID GROUND. A patch dropped over a hole is a tower with no
			# bottom, and `safe` is the guarantee that already stops ramps and
			# lifts doing it.
			for x in range(from, to + 1):
				if not seg.is_solid(x, int(z)):
					off_ground += 1
					break

			# 2. AND THE ROW IS STILL A ROW. If the stamping loop had kept its
			# `continue`, a patch row would be written entirely by the piece and
			# the columns beyond the footprint would be whatever the piece's file
			# happens to hold -- which for a five-wide file is nothing at all.
			var solid_outside := 0
			for x in seg.width:
				if x >= from and x <= to:
					continue
				if seg.is_solid(x, int(z)):
					solid_outside += 1
			if solid_outside == 0:
				flattened += 1
		if here:
			with_patch += 1

	var seen: Array = offsets.keys()
	seen.sort()
	print("[patch] %d sections, %d carry a patch (%d rows); placed at columns %s"
		% [sections, with_patch, patch_rows, str(seen)])

	check(sections > 0, "the generator produced sections to measure")

	# 1. THE ASSERTION THAT BITES, per phase 2's lesson: a generator that
	# validates and rerolls turns a placement bug into an ABSENCE, and every rule
	# asserted ABOUT patches then passes over an empty set.
	check(with_patch > 0,
		"the generator really does place a patch (%d of %d sections) -- "
			% [with_patch, sections]
		+ "`for_width` matched on equality until now, so a piece narrower than "
		+ "the canvas could not be selected at any seed. This is also what "
		+ "catches a patch that fails to fit or fails to validate: those sections "
		+ "are rerolled, and the feature disappears rather than breaking")

	# AND IT MOVES. A patch pinned to one column is a patch the generator is not
	# really placing -- it would read as part of the terrain rule rather than as
	# something dropped into it.
	check(seen.size() >= 2,
		"and lands at more than one column across the sweep (%s) -- a patch "
			% str(seen)
		+ "always at the same offset is not being placed, it is being centred")

	# AND IT LANDS ON THE DECK, NOT ON THE CANVAS -- which is the assertion this
	# file was missing, and the bug it missed.
	#
	# Reported from play: "I don't see any towers in the middle of the field, all
	# are to one side or the other". Every column offset above was inside the safe
	# corridor and looked healthy, because the corridor is fixed at the worst-case
	# inset while the DECK moves with the profile. A patch at column 9 is central
	# on a deck spanning 3..17 and jammed against the rail on one spanning 6..20,
	# and M22 made 38 per cent of rows asymmetric.
	#
	# So the measurement is the patch's offset from each edge OF ITS OWN ROW, and
	# what it has to show is both: sometimes nearer the left, sometimes nearer the
	# right, and mostly neither.
	# THE CLAIM IS THAT ALL THREE THIRDS HAPPEN, not that the edges do not.
	#
	# The first version of this asserted that few placements were near a rail, and
	# that is the wrong shape: a patch is placed uniformly in whatever room its
	# rows leave, and with a five-wide piece in a nine-wide span there are five
	# offsets, two of which ARE the extremes. Penalising them measures uniformity
	# and calls it a bug.
	#
	# What was actually reported is narrower and sharper -- "I don't see any
	# towers in the middle of the field" -- so the thing to assert is that the
	# middle is REACHED, and that neither side is systematically preferred.
	var thirds: Array = [0, 0, 0]
	var total := 0.0
	for entry in against_deck:
		var bias: float = float(entry)          # -1 hard left .. +1 hard right
		total += bias
		if bias < -0.34:
			thirds[0] += 1
		elif bias > 0.34:
			thirds[2] += 1
		else:
			thirds[1] += 1
	var placements: int = against_deck.size()
	var mean: float = total / float(maxi(1, placements))
	print("[patch] within its own row's deck: %d placements, left/middle/right %s, mean bias %+.2f"
		% [placements, str(thirds), mean])

	check(placements > 0, "there were placements to measure against the deck")
	check(int(thirds[1]) > 0,
		"some towers land in the MIDDLE of the deck (%s) -- which is the whole of "
			% str(thirds)
		+ "what was reported missing, and it was missing because the safe corridor "
		+ "is fixed while the deck moves with the inset profile: a patch at column "
		+ "9 is central on a deck spanning 3..17 and against the rail on one "
		+ "spanning 6..20")
	check(int(thirds[0]) > 0 and int(thirds[2]) > 0,
		"and some land either side of it (%s) -- a patch that only ever went one "
			% str(thirds)
		+ "way would be following something other than the deck")
	check(absf(mean) < 0.35,
		"with no systematic lean to one side (mean %+.2f). A mean well off zero "
			% mean
		+ "is the signature of the bug that was just fixed: placement measured "
		+ "against a frame the deck had moved out of")

	# --- AND THREE NUMBERS THAT ARE REPORTED RATHER THAN ASSERTED ---------------
	#
	# `flattened`, `off_ground` and `uncrossable` were all `eq(x, 0)` in the first
	# draft, and all three are zeros that CANNOT MOVE. `SegmentGen.section()`
	# returns only a segment `SegmentValidator` accepted, or a flat fallback -- so
	# any property the validator checks is true of everything this loop can ever
	# see, and asserting it here is a wall of green over a filter one layer down.
	#
	# Measured, not reasoned: giving a patch the same `continue` a full-width piece
	# takes leaves a five-wide island in a row of holes. `flattened` did not rise
	# to 53 -- it stayed at 0 while `with_patch` fell to 0, because every one of
	# those sections was rejected and rerolled.
	#
	# THE DISTINCTION THAT DECIDES WHICH IS WHICH: a rule the validator enforces
	# gives an absence, and a rule it does not gives a bad section. `ragged_ends`
	# in test_split_plateau really does fire, because a split running into the exit
	# row is LEVELLED by the fixup rather than rejected -- the section stays
	# crossable and comes out wrong.
	print("[patch] reported (all filtered by the validator, so all structurally 0): %d flattened, %d off solid ground, %d uncrossable"
		% [flattened, off_ground, uncrossable])
