extends "res://scripts/test_support/test_case.gd"

# M17 Phase 0: does a RUN connect, not just a segment?
#
# `SegmentValidator.validate` checks one segment in isolation and was, until
# 2026-08-16, the only reachability check anywhere -- and it is called from tests
# and nowhere else. So nothing asked whether a run's segments JOIN. Segment A can
# exit solid only on the left while B enters solid only on the right, and the
# party stops at a seam no pass ever looked at.
#
# It works today by luck: the pool segments are near-solid across their full
# width at both ends. "Thin paths" and "variable width" are both requests to
# spend that luck, and M16 turned one join per round into six.
#
# The claims:
#   1. Every run the assembler can produce is crossable, over a spread of seeds.
#      Not one seed -- the pool picks by seed, so one seed tests one arrangement.
#   2. A BROKEN JOIN IS REFUSED, and the message names the segment. This is the
#      half that says something is impossible, built by hand so the case exists
#      at all: nothing in the pool is narrow enough to fail yet, which is
#      precisely why the check has to be in place BEFORE anything narrow is
#      authored.
#   3. A segment that cannot be crossed at all is refused separately from one
#      that cannot be entered, because those are different authoring mistakes.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")

func setup(_main) -> void:
	timeout_seconds = 60.0
	_check_pool_runs()
	_check_a_broken_join_is_refused()
	_check_an_uncrossable_segment_is_refused()
	finish()

# --- 1. Real runs, over a spread of seeds -------------------------------------

func _check_pool_runs() -> void:
	var checked := 0
	for seed_value in [1, 7, 4242, 20260816, 99991]:
		var plan: Array = SegmentPool.plan(seed_value, 8)
		var segments: Array = []
		for i in plan.size():
			# MATERIALISED THE WAY BridgeGrid DOES IT, generated slots included --
			# since M17 phase 5 most of a run is generated, and a soak that only
			# checked the authored segments would be checking the part that was
			# never in doubt.
			var seg = _materialise(String(plan[i]), seed_value, i)
			if seg == null or not seg.is_valid():
				check(false, "slot %d (%s) did not materialise" % [i, plan[i]])
				return
			segments.append(seg)

		# SOLO, the tighter budget. A run only a cooperating pair can cross is a
		# run a lone player is stranded in, and drop-in makes that a real case.
		var problems: Array = SegmentValidator.validate_run(
			segments, SegmentValidator.SOLO_RISE)
		if problems.size() > 0:
			check(false, "seed %d builds a run a solo player cannot cross: %s"
				% [seed_value, problems[0]])
			return
		checked += 1
	check(checked == 5, "every sampled run is crossable end to end (%d seeds)" % checked)

func _materialise(path: String, seed_value: int, index: int):
	if path == SegmentPool.GENERATED_LOBBY:
		return SegmentGen.lobby(GridConfig.DEFAULT_WIDTH, seed_value, index)
	if path == SegmentPool.GENERATED_SECTION:
		return SegmentGen.section(GridConfig.DEFAULT_WIDTH, seed_value, index)
	return SegmentData.from_file(path)

# --- 2. A broken join is refused ----------------------------------------------

func _check_a_broken_join_is_refused() -> void:
	# Built by hand, because nothing in the pool is narrow enough to fail. A exits
	# solid on the LEFT only; B is entered on the RIGHT only. Each is a perfectly
	# good segment on its own, which is the entire point -- this is a fault that
	# lives in the JOIN and cannot be seen from either side.
	var a = _blank("exit_left", 8, 4)
	var b = _blank("enter_right", 8, 4)
	_solid_only(a, a.length - 1, [0, 1, 2])
	_solid_only(b, 0, [5, 6, 7])

	check(SegmentValidator.validate(a).is_empty(),
		"the first segment is fine on its own (%s)" % ", ".join(SegmentValidator.validate(a)))
	check(SegmentValidator.validate(b).is_empty(),
		"and so is the second (%s)" % ", ".join(SegmentValidator.validate(b)))

	var problems: Array = SegmentValidator.validate_run([a, b], SegmentValidator.SOLO_RISE)
	check(problems.size() > 0,
		"but PUT TOGETHER they are refused -- a fault neither segment can see")
	if problems.size() > 0:
		check(str(problems[0]).contains("enter_right"),
			"and the message names the segment: %s" % problems[0])

	# AND THE SAME TWO WITH AN OVERLAP ARE ACCEPTED, which is the half that stops
	# this passing by refusing everything.
	_solid_only(b, 0, [2, 3, 4, 5, 6, 7])
	eq(SegmentValidator.validate_run([a, b], SegmentValidator.SOLO_RISE).size(), 0,
		"while ONE overlapping column is enough to join them")

# --- 3. Uncrossable is a different fault from unenterable ---------------------

func _check_an_uncrossable_segment_is_refused() -> void:
	# Entered fine, but a full-width band of holes across the middle means the
	# exit row can never be reached.
	var a = _blank("walled_off", 8, 5)
	_solid_only(a, 2, [])
	var problems: Array = SegmentValidator.validate_run([a], SegmentValidator.SOLO_RISE)
	check(problems.size() > 0, "a segment cut in half is refused")
	if problems.size() > 0:
		check(str(problems[0]).contains("cannot be crossed"),
			"as UNCROSSABLE rather than unenterable, which is a different mistake: %s"
				% problems[0])

# --- Builders -----------------------------------------------------------------

func _blank(seg_name: String, width: int, length: int):
	var seg = SegmentData.new()
	seg.name = seg_name
	seg.width = width
	seg.length = length
	seg.kinds = []
	seg.heights = []
	seg.contents = []
	seg.no_wall = []
	for z in length:
		var krow: Array = []
		var hrow: Array = []
		var crow: Array = []
		var wrow: Array = []
		for x in width:
			krow.append(GridConfig.Kind.DECK)
			hrow.append(0)
			crow.append(GridConfig.Content.NONE)
			wrow.append(false)
		seg.kinds.append(krow)
		seg.heights.append(hrow)
		seg.contents.append(crow)
		seg.no_wall.append(wrow)
	return seg

# Make `row` solid ONLY at the given columns; everything else becomes a hole.
func _solid_only(seg, row: int, columns: Array) -> void:
	for x in seg.width:
		seg.kinds[row][x] = GridConfig.Kind.DECK if columns.has(x) else GridConfig.Kind.HOLE
