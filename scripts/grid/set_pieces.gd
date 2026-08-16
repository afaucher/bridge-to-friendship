extends RefCounted

# LAYER 2: set-pieces (M18). The authored compositions the generator slots into a
# generated skeleton.
#
# A set-piece is a `.seg` with a `piece` tag, 4 to 8 rows, full width. Not a new
# format and not a second parser -- SegmentData already reads everything a piece
# needs, and `segments/*.seg` is already in the export include_filter, which is
# the one line between this working in the editor and failing only in the shipped
# build.
#
# WHY THE LAYER EXISTS. A generator scattering the same parts produces texture; a
# composition is a RELATIONSHIP between parts -- cover and the thing it is cover
# from, a climb and what waits at the top -- and no distribution over gap density
# produces one. Variety becomes combinatorial in authoring days rather than
# linear. See implementation_plans/m18_set_pieces.md.

const SegmentData = preload("res://scripts/grid/segment_data.gd")

# LISTED EXPLICITLY, IN A FIXED ORDER, and this is load-bearing rather than tidy.
#
# The bridge is a pure function of (seed, count): a joining client is told two
# numbers and builds the identical world. Selection will be
# `_mix(seed + index * prime) % LIBRARY.size()`, so THE INDEX OF A PIECE IN THIS
# LIST IS PART OF THE WIRE PROTOCOL in everything but name. A DirAccess scan is
# ordered by the filesystem, which is not guaranteed to agree between two
# machines -- and the failure would be two players walking through different
# geometry with no error anywhere.
#
# SegmentPool.POOL is the same shape for the same reason and says so in its own
# comment; this is that pattern again rather than a new one.
#
# APPEND, NEVER REORDER. Inserting at the front renumbers everything after it,
# which silently changes every seed in the game.
const LIBRARY: Array[String] = [
	"res://segments/piece_crossfire.seg",
	"res://segments/piece_ladder_shelf.seg",
	"res://segments/piece_crumble_causeway.seg",
	"res://segments/piece_spike_gallery.seg",
	"res://segments/piece_timed_crossing.seg",
	"res://segments/piece_ramp_duel.seg",
	"res://segments/piece_plinko_funnel.seg",
	"res://segments/piece_rusher_pit.seg",
]

# SMALLER THAN A SEGMENT IS THE POINT. Today a `.seg` is 16 to 30 rows and is a
# whole level; a piece is a slice, so a section can hold one and still be mostly
# generated terrain. The upper bound is what keeps it a slice rather than a
# second way to author a level.
const MIN_ROWS := 4
const MAX_ROWS := 8

# Every piece in the library, parsed. Not cached: this is called by the generator
# once per section and by the test once per run, and a cache would be one more
# thing that can hold a stale parse after an edit.
static func all() -> Array:
	var out: Array = []
	for path in LIBRARY:
		var seg = SegmentData.from_file(path)
		if seg != null:
			out.append(seg)
	return out

# The ones that can be stamped into a section of this width.
#
# SKIPPED, NOT STRETCHED. A composition scaled to fit is a shooter that no longer
# covers the gap it was authored to cover -- the relationship is the piece, and
# stretching is the one operation guaranteed to break it.
static func for_width(width: int) -> Array:
	var out: Array = []
	for seg in all():
		if seg.is_valid() and seg.is_piece() and seg.width == width:
			out.append(seg)
	return out
