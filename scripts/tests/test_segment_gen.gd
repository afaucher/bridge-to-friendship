extends "res://scripts/test_support/test_case.gd"

# M17 phases 4 and 5: generated lobbies, and the terrain skeleton.
#
# THE SOAK IS THE POINT. A generator is not proved by looking at one output; it
# is proved by producing hundreds and having every one clear the same bar an
# authored segment clears. So this generates across a spread of seeds and floods
# every single one.
#
# The claims:
#   1. EVERY GENERATED LOBBY IS VALID, at least LOBBY_MIN_WIDTH wide, has a
#      boundary band at each end, and carries a rack and hats. It is the pilot
#      generator because being wrong here is cheap -- no hazards, so a bug is a
#      strange room rather than an unfinishable run.
#   2. EVERY GENERATED SECTION IS CROSSABLE BY A LONE PLAYER. Generate, validate,
#      reject, reroll -- never construct-and-hope.
#   3. THE GENERATOR ACTUALLY VARIES. A generator that emits the same flat deck
#      every time would satisfy (2) perfectly, which is why the variation is
#      measured rather than assumed: heights, lengths and gap counts must differ
#      across seeds.
#   4. GENERATED AND AUTHORED SEGMENTS JOIN. The run contract from phase 0 is
#      applied to a mixed sequence.
#   5. IT IS DETERMINISTIC. Same seed, same segment -- the guarantee a joining
#      client rides.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const WIDTH := 13

func setup(_main) -> void:
	timeout_seconds = 90.0
	_check_lobbies()
	_check_sections()
	_check_variation()
	_check_joins()
	_check_deterministic()
	finish()

# --- 1. The pilot -------------------------------------------------------------

func _check_lobbies() -> void:
	var built := 0
	for seed_value in [1, 99, 5150, 20260816]:
		for index in 3:
			var seg = SegmentGen.lobby(WIDTH, seed_value, index)
			# A NULL HERE IS THE SHAPE OF THE BUG THIS FILE ALREADY HIT ONCE: a
			# raise inside the generator aborts it and returns null, and every
			# assertion after that is dead code in a green run.
			if seg == null:
				check(false, "the lobby generator returned NULL (seed %d, %d)"
					% [seed_value, index])
				return
			var problems: Array = SegmentValidator.validate(seg)
			if problems.size() > 0:
				check(false, "generated lobby (seed %d, %d) is invalid: %s"
					% [seed_value, index, problems[0]])
				return
			if seg.width < SegmentGen.LOBBY_MIN_WIDTH:
				check(false, "a lobby came out %d wide, under the floor" % seg.width)
				return
			# A band at each end, full width. This is the regroup row the whole
			# run leans on, so it is worth asserting rather than trusting.
			for x in seg.width:
				if seg.content_at(x, 0) != GridConfig.Content.GATE:
					check(false, "lobby entry band has a gap at x %d" % x)
					return
				if seg.content_at(x, seg.length - 1) != GridConfig.Content.GATE:
					check(false, "lobby exit band has a gap at x %d" % x)
					return
			built += 1
	check(built == 12, "every generated lobby is valid and banded (%d)" % built)

	# THE RESTOCK IS THERE. A lobby without a rack is a corridor.
	var one = SegmentGen.lobby(WIDTH, 7, 0)
	var racked := 0
	var hats := 0
	for z in one.length:
		for x in one.width:
			var c: int = one.content_at(x, z)
			if c == GridConfig.Content.HAT:
				hats += 1
			elif c in [GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
					GridConfig.Content.PICKUP_MINE, GridConfig.Content.PICKUP_SHIELD,
					GridConfig.Content.PICKUP_ROCKET]:
				racked += 1
	check(racked >= 4, "with a rack of specials to restock from (%d)" % racked)
	check(hats >= 3, "and hats, which are the score (%d)" % hats)

	# WIDER THAN ITS NEIGHBOURS IS FINE, and is the point: a lobby is always at
	# least as wide as everything that connects to it.
	eq(SegmentGen.lobby(3, 7, 0).width, SegmentGen.LOBBY_MIN_WIDTH,
		"a lobby asked to fit a narrow neighbour still gets its own minimum")

# --- 2. Every section is crossable -------------------------------------------

func _check_sections() -> void:
	var made := 0
	var fallbacks := 0
	for seed_value in [3, 11, 777, 20260816, 424242]:
		for index in 6:
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			if seg == null:
				check(false, "the section generator returned NULL (seed %d, %d)"
					% [seed_value, index])
				return
			var problems: Array = SegmentValidator.validate(seg)
			if problems.size() > 0:
				check(false, "generated section (seed %d, %d) is invalid: %s"
					% [seed_value, index, problems[0]])
				return
			if seg.tags.has("fallback"):
				fallbacks += 1
			made += 1
	check(made == 30, "every generated section validates (%d of them)" % made)
	# A fallback is not a failure, but a generator that ALWAYS falls back is one
	# that never really generates -- so the count is printed and bounded.
	print("[gen] %d of %d sections fell back to flat" % [fallbacks, made])
	check(fallbacks < made / 2,
		"and most are really generated rather than falling back (%d of %d)"
			% [fallbacks, made])

# --- 3. It varies ------------------------------------------------------------

func _check_variation() -> void:
	var lengths := {}
	var profiles := {}
	var gap_counts := {}
	for seed_value in [3, 11, 777, 20260816, 424242, 8, 64]:
		for index in 4:
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			lengths[seg.length] = true
			var climb: int = seg.height_at(0, seg.length - 1) - seg.height_at(0, 0)
			profiles[climb] = true
			var gaps := 0
			for z in seg.length:
				for x in seg.width:
					if not seg.is_solid(x, z):
						gaps += 1
			gap_counts[gaps] = true

	# WITHOUT THESE, a generator that emitted one flat deck forever would pass
	# every other assertion in this file.
	check(lengths.size() > 2, "sections vary in length (%d distinct)" % lengths.size())
	check(profiles.size() > 1, "and in how much they climb (%d distinct)" % profiles.size())
	check(gap_counts.size() > 3, "and in how many holes they have (%d distinct)"
		% gap_counts.size())

# --- 4. Generated and authored join ------------------------------------------

func _check_joins() -> void:
	var authored = SegmentData.from_file("res://segments/run_gaps.seg")
	check(authored.is_valid(), "an authored segment to join against")
	var w: int = authored.width
	var run: Array = [
		SegmentGen.lobby(w, 5, 0),
		SegmentGen.section(w, 5, 1),
		authored,
		SegmentGen.section(w, 5, 3),
		SegmentGen.lobby(w, 5, 4),
	]
	var problems: Array = SegmentValidator.validate_run(run, SegmentValidator.SOLO_RISE)
	check(problems.is_empty(),
		"a run of generated and authored segments connects end to end (%s)"
			% ("" if problems.is_empty() else problems[0]))

# --- 5. Deterministic ---------------------------------------------------------

func _check_deterministic() -> void:
	var a = SegmentGen.section(WIDTH, 4242, 2)
	var b = SegmentGen.section(WIDTH, 4242, 2)
	eq(a.length, b.length, "the same seed and index generate the same length")
	var same := true
	for z in a.length:
		for x in a.width:
			if a.kind_at(x, z) != b.kind_at(x, z) or a.height_at(x, z) != b.height_at(x, z):
				same = false
	check(same,
		"and the identical terrain -- the guarantee a joining client rides when it "
		+ "is told two numbers instead of a world")
