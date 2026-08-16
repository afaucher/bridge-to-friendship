extends "res://scripts/test_support/test_case.gd"

# M17 Phase 3: the dressing pass.
#
# The whole ask it answers, in one sentence: **the same ground played as
# enemy-dense or hazard-dense is a different table, not a different map.** So the
# claims are about the DIFFERENCE between themes over identical terrain, which is
# the thing that would silently stop being true.
#
# The claims:
#   1. TWO THEMES OVER THE SAME SEGMENT PRODUCE DIFFERENT CONTENT. Asserted as
#      the actual counts, because "it ran" is satisfied by a pass that places
#      nothing.
#   2. A THEME PLACES WHAT IT ASKED FOR AND NOTHING IT DID NOT. `environmental`
#      has no shooters at all; if it grew some, the difference between the themes
#      would erode and nobody would notice until the game felt samey.
#   3. IT NEVER OVERWRITES AUTHORED CONTENT. A cell somebody filled is a decision
#      somebody made.
#   4. IT IS DETERMINISTIC IN (seed, index) -- the same guarantee the terrain
#      rides, and what lets a client be told two numbers instead of a world.
#   5. PLACEMENT IS BY RULE: nothing lands on a ramp or on the entry and exit
#      rows, whatever the budget says.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")

const SEG := "res://segments/run_pillars.seg"
const SEED := 20260816

func setup(_main) -> void:
	timeout_seconds = 30.0
	_check_themes_differ()
	_check_budget_respected()
	_check_authored_content_survives()
	_check_deterministic()
	_check_placement_rules()
	finish()

func _fresh():
	var seg = SegmentData.from_file(SEG)
	check(seg.is_valid(), "the fixture parses")
	return seg

func _census(seg) -> Dictionary:
	var out := {}
	for z in seg.length:
		for x in seg.width:
			var c: int = seg.content_at(x, z)
			if c == GridConfig.Content.NONE:
				continue
			out[c] = int(out.get(c, 0)) + 1
	return out

# --- 1 and 2. The same ground, two ways --------------------------------------

func _check_themes_differ() -> void:
	var fight = _fresh()
	var env = _fresh()
	HazardDressing.dress(fight, "firefight", SEED, 1)
	HazardDressing.dress(env, "environmental", SEED, 1)

	var f: Dictionary = _census(fight)
	var e: Dictionary = _census(env)
	print("[dressing] firefight     %s" % str(f))
	print("[dressing] environmental %s" % str(e))

	# THE HEADLINE. Identical terrain in, different content out.
	check(f != e, "two themes over the SAME segment produce different content")

	var f_shoot: int = int(f.get(GridConfig.Content.SKIRMISHER, 0)) + int(f.get(GridConfig.Content.TURRET, 0))
	var e_shoot: int = int(e.get(GridConfig.Content.SKIRMISHER, 0)) + int(e.get(GridConfig.Content.TURRET, 0))
	var f_spike: int = int(f.get(GridConfig.Content.SPIKES, 0))
	var e_spike: int = int(e.get(GridConfig.Content.SPIKES, 0))

	check(f_shoot > 0, "the firefight has things that shoot (%d)" % f_shoot)
	eq(e_shoot, 0,
		"and the environmental theme has NONE -- a budget of zero means zero, or "
		+ "the themes erode into each other and nobody notices")
	check(e_spike > f_spike,
		"while the environmental theme is the one with the spikes (%d vs %d)"
			% [e_spike, f_spike])

	# COVER COMES WITH SHOOTERS. Pairing them in the theme table is what stops a
	# shooting gallery being authored as a corridor you cross while being shot.
	var f_cover: int = int(f.get(GridConfig.Content.TREE, 0)) + int(f.get(GridConfig.Content.HALF_WALL, 0))
	check(f_cover > 0, "and the firefight brought cover with it (%d)" % f_cover)

func _check_budget_respected() -> void:
	var seg = _fresh()
	var placed: Dictionary = HazardDressing.dress(seg, "firefight", SEED, 3)
	var budget: Dictionary = HazardDressing.THEMES["firefight"]
	for kind in placed.keys():
		check(int(placed[kind]) <= int(budget.get(kind, 0)),
			"never places more %s than the budget allows (%d of %d)"
				% [kind, int(placed[kind]), int(budget.get(kind, 0))])

# --- 3. Authored content is a decision somebody made -------------------------

func _check_authored_content_survives() -> void:
	var seg = _fresh()
	# Mark every cell of one row, then dress and confirm the row is untouched.
	var row: int = seg.length / 2
	var marked: Array = []
	for x in seg.width:
		if seg.is_solid(x, row):
			seg.contents[row][x] = GridConfig.Content.HEART
			marked.append(x)
	check(marked.size() > 0, "there is a row to protect")
	HazardDressing.dress(seg, "survival", SEED, 2)
	var kept := 0
	for x in marked:
		if seg.content_at(int(x), row) == GridConfig.Content.HEART:
			kept += 1
	eq(kept, marked.size(),
		"the pass never overwrites authored content -- a filled cell is somebody's "
		+ "decision")

# --- 4. Deterministic in (seed, index) ---------------------------------------

func _check_deterministic() -> void:
	var a = _fresh()
	var b = _fresh()
	HazardDressing.dress(a, "survival", SEED, 4)
	HazardDressing.dress(b, "survival", SEED, 4)
	eq(_census(a), _census(b),
		"the same seed and index dress identically -- which is what lets a client "
		+ "be told two numbers instead of a world")

	var c = _fresh()
	HazardDressing.dress(c, "survival", SEED, 5)
	check(_census(a) != _census(c), "and a different index does not")

	# The theme choice is deterministic too, and never repeats back to back:
	# two firefights in a row read as one long firefight.
	for i in 12:
		check(HazardDressing.theme_for(SEED, i) != HazardDressing.theme_for(SEED, i + 1),
			"consecutive segments get different themes (index %d)" % i)

# --- 5. Placement is by rule --------------------------------------------------

func _check_placement_rules() -> void:
	var seg = _fresh()
	HazardDressing.dress(seg, "survival", SEED, 6)
	for x in seg.width:
		eq(seg.content_at(x, 0), GridConfig.Content.NONE,
			"nothing is placed on the ENTRY row -- a segment has to be enterable")
		eq(seg.content_at(x, seg.length - 1), GridConfig.Content.NONE,
			"or on the exit row")
	for z in seg.length:
		for x in seg.width:
			if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
				continue
			eq(seg.content_at(x, z), GridConfig.Content.NONE,
				"and nothing is placed on a RAMP, where nothing settles")
