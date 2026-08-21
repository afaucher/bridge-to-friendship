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

func setup(_main) -> void:
	timeout_seconds = 60.0
	_check_library()
	_check_each_piece()
	_check_a_broken_piece_is_refused()
	_check_the_library_is_ordered()
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
		# plateaus; if either end is not solid across the bridge, the party meets a
		# step or a hole that nobody authored on the seam.
		#
		# ACROSS THE BASELINE, NOT ACROSS THE CANVAS (M22 phase C). This asked for
		# every column of `seg.width` and the two were the same thing while the
		# canvas was exactly as wide as the bridge. At a 21 canvas with a 15
		# baseline they are different claims, and the canvas one is wrong twice
		# over: every piece was padded with HOLE either side, so it would fail; and
		# a piece that DID fill the canvas at its ends would be a piece six cells
		# wider than the terrain it is stamped between, which is the seam this
		# assertion exists to refuse.
		# AND A PATCH IS A DIFFERENT CLAIM (M23 phase 3). Both rules below are about
		# a piece that spans the canvas meeting the terrain at its two ENDS. A patch
		# is narrower than the section and meets terrain on all FOUR sides, so its
		# own column 0 is its own edge rather than the canvas's -- "does not reach
		# the canvas edge" is not false for a patch, it is meaningless.
		var patch: bool = SetPieces.is_patch(seg, GridConfig.DEFAULT_WIDTH)
		var edge: int = 0 if patch else GridConfig.BASELINE_INSET
		for x in range(edge, seg.width - edge):
			check(seg.is_solid(x, 0),
				"%s: entry row is solid at x=%d" % [who, x])
			check(seg.is_solid(x, seg.length - 1),
				"%s: exit row is solid at x=%d" % [who, x])
		if patch:
			# A PATCH SITS ON THE PLATEAU IT WAS STAMPED AT, all the way round. The
			# terrain either side of it is at `piece_base`, so an edge row at any
			# other height is a step running down both of its long sides -- which
			# nobody authored and no rule would ever remove.
			for z in [0, seg.length - 1]:
				for x in seg.width:
					eq(seg.height_at(x, z), 0,
						"%s: patch edge row %d is level with the terrain at x=%d"
							% [who, z, x])
		else:
			# NOT WIDER THAN THE BASELINE AT ITS ENDS, which is the other half of
			# the same seam and was never asserted because it could not happen
			# before.
			for x in [0, seg.width - 1]:
				check(not seg.is_solid(x, 0),
					"%s: entry row does NOT reach the canvas edge at x=%d -- a "
						% [who, x]
					+ "piece joins terrain at the baseline width, not at the widest "
					+ "the bridge can ever be")

		# 3. THE DECLARATION MATCHES THE GEOMETRY.
		var entry_h: int = seg.height_at(edge, 0)
		var exit_h: int = seg.height_at(edge, seg.length - 1)
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
