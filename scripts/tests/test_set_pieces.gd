extends "res://scripts/test_support/test_case.gd"

# M18 phase 0: the set-piece format, the library, and the oracle over it.
#
# Nothing in the game places these yet -- that is phase 1. What this proves is
# that every piece in the library is a thing the generator will be ALLOWED to
# stamp: it parses, it is the right shape, and it is crossable on its own.
#
# THE ORACLE IS THE ONE THAT ALREADY EXISTS. SegmentValidator.validate() floods
# from the entry row and requires the exit row, which is exactly the question a
# piece has to answer, because a piece is stamped between two plateaus and both
# of its ends meet ordinary ground. No second oracle, and therefore no second
# oracle to drift.
#
# The claims:
#   1. Every piece parses, is tagged, and is 4-8 rows of the run's width.
#   2. Its entry and exit rows are full-width solid deck -- the join contract one
#      level down.
#   3. `piece_exit` matches the geometry. It is DECLARED rather than derived, so
#      a piece that says one thing and does another is exactly what this catches.
#   4. Every piece is crossable on its own.
#   5. AND A BROKEN PIECE IS REJECTED by the same check. Without this, claim 4 is
#      satisfied by an oracle that passes everything -- and this project has
#      shipped that hole twice, most recently at 250 seeds.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")

func setup(_main) -> void:
	timeout_seconds = 180.0
	_check_library()
	_check_each_piece()
	_check_a_broken_piece_is_refused()
	_check_the_library_is_ordered()
	_check_every_piece_names_a_real_theme()
	_check_for_theme_filters_and_falls_back()
	_check_generated_sections_stamp_their_own_theme()
	finish()

func _check_library() -> void:
	check(SetPieces.LIBRARY.size() > 0, "the library is not empty")
	var pieces: Array = SetPieces.all()
	eq(pieces.size(), SetPieces.LIBRARY.size(),
		"every path in the library loads -- a typo'd path would otherwise be a "
		+ "piece that silently never appears")
	eq(SetPieces.for_width(GridConfig.DEFAULT_WIDTH).size(), pieces.size(),
		"and all of them are the run's width (%d): a piece is SKIPPED rather "
			% GridConfig.DEFAULT_WIDTH
		+ "than stretched, so one authored at the wrong width is one that never "
		+ "gets stamped and never says why")

func _check_each_piece() -> void:
	for seg in SetPieces.all():
		var who: String = seg.name
		check(seg.is_valid(), "%s parses (%s)" % [who, str(seg.errors)])
		if not seg.is_valid():
			continue
		check(seg.is_piece(), "%s is tagged `piece`" % who)
		check(seg.length >= SetPieces.MIN_ROWS and seg.length <= SetPieces.MAX_ROWS,
			"%s is %d rows, within %d..%d -- smaller than a segment is the point, "
				% [who, seg.length, SetPieces.MIN_ROWS, SetPieces.MAX_ROWS]
			+ "and the upper bound is what stops it becoming a second way to "
			+ "author a whole level")

		# 2. THE JOIN CONTRACT, one level down. A piece is stamped between two
		# plateaus; if either end is not full-width solid, the party meets a step
		# or a hole that nobody authored on the seam.
		for x in seg.width:
			check(seg.is_solid(x, 0),
				"%s: entry row is solid at x=%d" % [who, x])
			check(seg.is_solid(x, seg.length - 1),
				"%s: exit row is solid at x=%d" % [who, x])

		# 3. THE DECLARATION MATCHES THE GEOMETRY.
		var entry_h: int = seg.height_at(0, 0)
		var exit_h: int = seg.height_at(0, seg.length - 1)
		eq(exit_h - entry_h, seg.piece_exit,
			"%s: piece_exit says %d and the deck rises %d -- the generator carries "
				% [who, seg.piece_exit, exit_h - entry_h]
			+ "on from the declared height, so a piece that lies about it leaves a "
			+ "step on the seam behind it")

		# 4. AND IT IS CROSSABLE.
		var problems: Array = SegmentValidator.validate(seg)
		eq(problems.size(), 0, "%s is crossable on its own (%s)" % [who, str(problems)])

# --- 5. The half that makes claim 4 mean something ----------------------------

func _check_a_broken_piece_is_refused() -> void:
	# The ladder shelf with its ladders taken out: a two-unit cliff, no ramp, no
	# ascender, nobody to be shoved by. It must FAIL, or "every piece is
	# crossable" is a sentence about a check that cannot say no.
	var bare = SegmentData.from_file("res://segments/piece_ladder_shelf.seg")
	check(bare != null and bare.is_valid(), "the control piece loads")
	if bare == null:
		return
	var removed := 0
	for z in bare.length:
		for x in bare.width:
			if bare.content_at(x, z) in GridConfig.ASCENDER_CONTENTS:
				bare.contents[z][x] = GridConfig.Content.NONE
				removed += 1
	check(removed > 0, "the control really had ascenders to remove (%d)" % removed)
	check(SegmentValidator.validate(bare).size() > 0,
		"and the same piece without them is REFUSED -- so the oracle above is "
		+ "answering, not nodding")

# --- Determinism ---------------------------------------------------------------

func _check_the_library_is_ordered() -> void:
	# A piece's INDEX in the library is part of the wire protocol in everything
	# but name: selection will be a mix of the seed modulo the library size, so
	# two machines that disagree about the order build different bridges with no
	# error anywhere. Asserting the order is asserting that nothing quietly
	# started sorting or scanning.
	var first: Array = SetPieces.all()
	var second: Array = SetPieces.all()
	eq(first.size(), second.size(), "the library loads the same count twice")
	for i in first.size():
		eq(first[i].name, second[i].name,
			"library entry %d is the same piece on both reads (%s)" % [i, first[i].name])

# --- A PIECE BELONGS TO A THEME ------------------------------------------------
#
# Every piece in the library has carried a theme tag since M18 -- `piece,
# survival`, `piece, firefight` -- and until 2026-08-21 NOTHING READ THEM. The
# generator drew uniformly from everything that fitted the width, so a rusher pit
# landed in a `quiet` section as readily as in a survival one and the tags were
# documentation of an intention the code did not have.
#
# They are load-bearing now, which means a typo in one is a piece that silently
# leaves its theme's pool and falls back into everybody's.

func _check_every_piece_names_a_real_theme() -> void:
	var themes: Array = HazardDressing.theme_names()
	for seg in SetPieces.all():
		var named: Array = []
		for tag in seg.tags:
			if themes.has(tag):
				named.append(tag)
		eq(named.size(), 1,
			"%s names exactly one real theme -- tags %s against themes %s"
				% [seg.name, seg.tags, themes])

func _check_for_theme_filters_and_falls_back() -> void:
	var all_fitting: Array = SetPieces.for_width(GridConfig.DEFAULT_WIDTH)
	check(all_fitting.size() > 1, "there is more than one piece to filter (%d)"
		% all_fitting.size())

	for theme in HazardDressing.theme_names():
		var pool: Array = SetPieces.for_theme(GridConfig.DEFAULT_WIDTH, theme)
		check(pool.size() > 0, "%s always gets SOMETHING to stamp" % theme)
		# Either every piece in the pool is tagged for this theme, or the pool IS
		# the whole library -- the documented fallback, and nothing in between.
		var tagged := 0
		for seg in pool:
			if seg.tags.has(theme):
				tagged += 1
		check(tagged == pool.size() or pool.size() == all_fitting.size(),
			"%s draws only from its own pieces, or from all of them -- %d of %d tagged"
				% [theme, tagged, pool.size()])

	# AND THE FILTER REALLY NARROWS, which the loop above does not say: a for_theme
	# that ignored the tag and returned everything would satisfy every line of it
	# through the fallback clause.
	var narrowed := 0
	for theme in HazardDressing.theme_names():
		if SetPieces.for_theme(GridConfig.DEFAULT_WIDTH, theme).size() < all_fitting.size():
			narrowed += 1
	check(narrowed > 0,
		"and at least one theme really gets a SMALLER pool than the library")

# --- AND THE GENERATOR ACTUALLY USES IT ----------------------------------------
#
# The claim above is about a function; this is about the game. CLAUDE.md's note on
# the score screen is the reason they are separate: asserting the input to a
# layout is not asserting the layout, and a `for_theme` that works perfectly is
# worth nothing if `section()` still calls `for_width`.
#
# Measured through the one piece whose CONTENT names its theme: only
# piece_zombie_choke contains a GRAVE, so a grave inside a piece's rows is a
# horde piece by construction, and it must never appear under another theme.

func _check_generated_sections_stamp_their_own_theme() -> void:
	var horde_graves := 0
	var wrong_theme := 0
	var horde_sections := 0
	# WIDE ON PURPOSE. A piece is stamped at most once per section and only about
	# one section in four gets one, so a narrow sweep leaves the wrong-theme count
	# near zero whether or not the rule is there -- and a count that is zero either
	# way is not an assertion. Measured with the rule REMOVED this sweep reports a
	# handful; with it, none.
	for s in 40:
		var run_seed: int = 700000 + s * 7919
		for i in range(1, 9):
			var seg = SegmentGen.section(GridConfig.DEFAULT_WIDTH, run_seed, i)
			if seg == null:
				continue
			var theme: String = HazardDressing.theme_for(run_seed, i)
			if theme == "horde":
				horde_sections += 1
			for z in seg.piece_rows:
				for x in seg.width:
					if seg.content_at(x, int(z)) != GridConfig.Content.GRAVE:
						continue
					if theme == "horde":
						horde_graves += 1
					else:
						wrong_theme += 1
	# The half that can fail if the generator ignores the tag.
	eq(wrong_theme, 0,
		"a zombie composition is never stamped into a section of another theme")
	# The half that stops the line above passing because nothing was ever stamped.
	check(horde_sections > 0, "the sweep saw horde sections at all (%d)" % horde_sections)
	check(horde_graves > 0,
		"and the horde piece really is being stamped -- %d graves across %d horde sections"
			% [horde_graves, horde_sections])
	print("[pieces] horde sections %d, grave cells inside horde pieces %d, in other themes %d"
		% [horde_sections, horde_graves, wrong_theme])
