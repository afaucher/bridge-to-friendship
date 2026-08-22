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
	_check_a_grave_owns_its_neighbours()
	_check_the_stride_reaches_everything()
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

# WHERE things are, not merely how many. A census is the right instrument for a
# BUDGET question and the wrong one for a DETERMINISM question, and the two got
# confused here: two dressings that place four spikes in four different places
# have identical censuses.
#
# It went unnoticed because the stride bug meant two indices usually fell short of
# their budgets by DIFFERENT amounts, so the counts happened to differ and the
# assertion happened to pass. Fixing the stride made every index hit its budget
# exactly -- and the "a different index dresses differently" claim failed against
# code that was more correct than before. The assertion was reading a symptom.
func _layout(seg) -> Array:
	var out: Array = []
	for z in seg.length:
		for x in seg.width:
			var c: int = seg.content_at(x, z)
			if c != GridConfig.Content.NONE:
				out.append([x, z, c])
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
	eq(_layout(a), _layout(b),
		"the same seed and index dress identically, cell for cell -- which is what "
		+ "lets a client be told two numbers instead of a world")

	var c = _fresh()
	HazardDressing.dress(c, "survival", SEED, 5)
	check(_layout(a) != _layout(c), "and a different index does not")

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

# --- 6. A GRAVE OWNS ITS NEIGHBOURS -------------------------------------------
#
# The only content in this game that occupies cells it is not in. Three to five
# bodies rise on a ring 0.95 m out, reaching 1.4 m from the centre of a 2.0 m
# cell, so anything standing in an adjacent cell is something the pack spawns
# INSIDE -- and a body ejected by the solver is the coincident-bodies trap
# reached sideways.
#
# MEASURED ON `horde`, WHICH IS THE ONLY THEME WHERE IT CAN FAIL. It asks for
# four graves and twelve cover, on one section: the two budgets are competing for
# the same floor, which is exactly the arrangement `_near_grave` exists for. On a
# theme with one grave and five cover the rule would be green whether or not it
# was there -- the 2026-08-16 note about a sweep that survives its own rule being
# deleted.

func _check_a_grave_owns_its_neighbours() -> void:
	# NOT `run_pillars`, WHICH IS THIS FILE'S FIXTURE EVERYWHERE ELSE. Measured:
	# it offers 225 non-ramp solid cells and exactly ZERO grave candidates, because
	# only 17 of them are two cells clear of a pillar. That is the rule working, not
	# failing -- but a fixture that can never hold a grave cannot test a rule about
	# what stands next to one, and the loop below would be a loop over nothing.
	#
	# `test_flat` is flat, empty and 79 candidates deep, so the graves and the
	# twelve cover this theme asks for are really competing for the same floor,
	# which is the only arrangement in which _near_grave can fail.
	var seg = SegmentData.from_file("res://segments/test_flat.seg")
	if not check(seg != null and seg.is_valid(), "the flat fixture parses"):
		return
	HazardDressing.dress(seg, "horde", SEED, 7)
	var graves: Array = []
	for z in seg.length:
		for x in seg.width:
			if seg.content_at(x, z) == GridConfig.Content.GRAVE:
				graves.append(Vector2i(x, z))
	# Without this the loop below is a loop over nothing, which passes.
	check(graves.size() >= 2,
		"the horde theme really placed graves to check -- %d" % graves.size())

	var crowded := 0
	for cell in graves:
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dz == 0:
					continue
				if not seg.in_bounds(cell.x + dx, cell.y + dz):
					continue
				if seg.content_at(cell.x + dx, cell.y + dz) != GridConfig.Content.NONE:
					crowded += 1
	eq(crowded, 0,
		"nothing at all stands on a grave's ring, not even cover -- %d neighbouring "
			% crowded + "cells are occupied")

	# AND THE HORDE THEME IS REALLY A DIFFERENT TABLE, not survival with a
	# rename. Nothing that shoots, because a pack asks you to choose ground and
	# hold it while a shooter asks you to keep moving, and asking for both at once
	# is no decision at all.
	var budget: Dictionary = HazardDressing.THEMES["horde"]
	eq(int(budget.get("shooters", -1)), 0, "horde has no skirmishers")
	eq(int(budget.get("turrets", -1)), 0, "and no turrets")
	check(int(budget.get("zombies", 0)) > int(HazardDressing.THEMES["survival"].get("zombies", 0)),
		"and more graves than any other theme")

	# AND A SECTION WITH NO ROOM GETS NO GRAVES, rather than a pack squeezed in
	# beside a pillar. run_pillars is that section -- 225 solid cells and not one
	# of them two cells clear of something -- and it is the other half of the rule:
	# without this, "nothing stands on a grave's ring" is satisfied just as well by
	# a pass that never places a grave at all.
	var dense = _fresh()
	HazardDressing.dress(dense, "horde", SEED, 7)
	var in_dense := 0
	for z in dense.length:
		for x in dense.width:
			if dense.content_at(x, z) == GridConfig.Content.GRAVE:
				in_dense += 1
	eq(in_dense, 0,
		"and a section with no clear ground anywhere gets none at all rather than "
		+ "one wedged against a pillar")

# --- 7. THE STRIDE REACHES THE WHOLE LIST -------------------------------------
#
# A budget is a TARGET, and until 2026-08-21 it was a soft ceiling nobody had
# measured. The placement walk used a stride that could share a factor with the
# candidate count, so it revisited a short cycle: over 320 generated sections, 68
# of 117 budget shortfalls were this, worst case a list of 44 cells whose walk
# reached 2 of them.
#
# ASSERTED THROUGH `dress`, NOT ON `_coprime_stride` ALONE. The first version of
# this checked only the helper, and A/B proved it worthless: disconnecting the
# helper from the placement loop -- putting the bug back exactly -- left it GREEN,
# because the function it was asking still existed and was still correct. That is
# CLAUDE.md's score-screen note in miniature: asserting the input to a layout is
# not asserting the layout.
#
# The reason it was written that way was a real worry -- a placement shortfall has
# a second explanation, that the section is genuinely too full -- and the fix is to
# remove the second explanation rather than to stop asking the question. So it runs
# on a roomy fixture and only asserts budgets for kinds with at least three times
# the candidates they need.

func _check_the_stride_reaches_everything() -> void:
	# MANY INDICES, because the stride is drawn from the salt and only SOME salts
	# share a factor with the candidate count. One index proves nothing either way.
	var flat_shortfalls := 0
	var checked := 0
	for index in range(1, 25):
		for theme in ["environmental", "firefight", "horde"]:
			var seg = SegmentData.from_file("res://segments/test_flat.seg")
			if seg == null or not seg.is_valid():
				continue
			var room := {}
			for kind in HazardDressing.KINDS:
				room[kind] = HazardDressing._candidates(seg, kind).size()
			var placed: Dictionary = HazardDressing.dress(seg, theme, SEED, index)
			for kind in HazardDressing.KINDS:
				var want: int = int(HazardDressing.THEMES[theme].get(kind, 0))
				# THREE TIMES THE ROOM IT NEEDS. That is what removes the second
				# explanation: a kind with this much space to choose from can only
				# fall short because the WALK failed to reach the space.
				if want <= 0 or int(room[kind]) < want * 3:
					continue
				checked += 1
				if int(placed.get(kind, 0)) < want:
					flat_shortfalls += 1
	check(checked > 100, "the sweep really asked about budgets -- %d of them" % checked)
	eq(flat_shortfalls, 0,
		"a budget with three times the room it needs is always met in full -- "
		+ "%d of %d fell short" % [flat_shortfalls, checked])

	var worst := 0
	for n in range(1, 200):
		for want in range(1, n + 1):
			var stride: int = HazardDressing._coprime_stride(want, n)
			# The walk visits n / gcd(stride, n) distinct cells. Coprime means all
			# of them.
			var a: int = stride
			var b: int = n
			while b != 0:
				var t: int = b
				b = a % b
				a = t
			if a != 1:
				worst = n
	eq(worst, 0, "every stride the pass can pick walks the WHOLE candidate list")

	# And it is still a SPREAD rather than a scan. A stride of 1 walks the list in
	# order, which clusters every pick of a kind into one corner of the section --
	# the thing the stride exists to avoid. It is the correct answer only when
	# nothing else is coprime, which for n > 2 is never.
	var scanning := 0
	for n in range(8, 200):
		for want in range(2, n):
			if HazardDressing._coprime_stride(want, n) == 1 and want != 1:
				scanning += 1
	check(scanning < 60,
		"and hardly ever falls all the way back to walking in order -- %d of the "
			% scanning + "37000 cases tried")
