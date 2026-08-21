extends "res://scripts/test_support/test_case.gd"

# THE KNOB THAT MAKES A SET-PIECE FINDABLE.
#
# A specific piece turns up in a few per cent of sections, so judging the one you
# just authored means replaying rounds until it happens -- three exchanges of a
# playtest went on "I am just not seeing anything like that" before anybody
# measured the encounter rate. `force_piece` pins the generator to one.
#
# TWO CLAIMS, and the second is the one that rots.
#   1. Forcing a piece really produces that piece, in far more sections than it
#      would otherwise appear in.
#   2. THE KNOB'S CHOICE LIST AND THE PIECE LIBRARY AGREE. `DebugSettings.OPTIONS`
#      is a const, so the names cannot be computed from `SetPieces.LIBRARY` and
#      have to be written out -- two lists of the same thing in two files, which
#      is a drift waiting to happen and exactly the shape this project has been
#      bitten by before.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")

const WIDTH := GridConfig.DEFAULT_WIDTH

func setup(_main) -> void:
	_test_the_names_agree()
	_test_forcing_works()
	DebugSettings.set_choice("force_piece", 0)
	finish()

func _test_the_names_agree() -> void:
	var choices: Array = DebugSettings.OPTIONS["force_piece"]["choices"]
	var named: Array = []
	for i in range(1, choices.size()):       # index 0 is "off"
		named.append("piece_" + str(choices[i]))
	var library: Array = []
	for path in SetPieces.LIBRARY:
		library.append(String(path).get_file().get_basename())
	named.sort()
	library.sort()
	eq(named, library,
		"the force_piece choices name exactly the pieces in the library. OPTIONS "
		+ "is a const so the list cannot be computed, which makes this two copies "
		+ "of the same fact in two files -- and a knob that silently cannot select "
		+ "a piece is worse than no knob, because it looks like the piece is the "
		+ "thing that is broken")

func _test_forcing_works() -> void:
	# THE WATCHPOST, because it is the one the playtest could not find.
	var target := "watchpost"
	var choices: Array = DebugSettings.OPTIONS["force_piece"]["choices"]
	var index: int = choices.find(target)
	if not check(index > 0, "the knob offers `%s`" % target):
		return

	DebugSettings.set_choice("force_piece", index)
	var forced := 0
	var sections := 0
	for s in 40:
		var seg = SegmentGen.section(WIDTH, 90210 + s * 977, 2 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		sections += 1
		if not seg.piece_rows.is_empty():
			forced += 1

	DebugSettings.set_choice("force_piece", 0)
	var loose := 0
	var loose_sections := 0
	for s in 40:
		var seg = SegmentGen.section(WIDTH, 90210 + s * 977, 2 + s)
		if seg == null or not seg.is_valid() or seg.tags.has("maze"):
			continue
		loose_sections += 1
		if not seg.piece_rows.is_empty():
			loose += 1

	print("[force] watchpost forced: %d of %d sections carry a piece; unforced: %d of %d"
		% [forced, sections, loose, loose_sections])
	check(sections > 0 and loose_sections > 0, "there were sections to compare")
	check(forced > loose,
		"forcing a piece puts it in MORE sections than leaving the generator to "
		+ "choose (%d against %d) -- the whole point is that the thing you are "
			% [forced, loose]
		+ "trying to look at stops being a matter of luck")
