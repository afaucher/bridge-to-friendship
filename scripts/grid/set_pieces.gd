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
	# THE FIRST PATCH (M23 phase 3): five columns wide, so the generator places
	# it across the deck and terrain runs past on both sides. Appended, like
	# everything else here -- the index is the wire protocol in all but name.
	"res://segments/piece_lookout.seg",
	# TWO MORE PATCHES (M23 phase 4), and the axis between them is the ASCENDER:
	# a ladder makes a tall post a commitment, a ramp makes low ground contested.
	"res://segments/piece_watchpost.seg",
	"res://segments/piece_bunker.seg",
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
#
# WHICH IS AN ARGUMENT AGAINST SCALING, NOT AGAINST A SMALLER FOOTPRINT (M23
# phase 3). This asked for `seg.width == width`, so every piece had to span the
# whole canvas -- and `design_ideas/world_generation.md` has named the missing
# capability since M17: "a set-piece is a 4-8 row full-width slice, OR A SMALLER
# PATCH WITH A DECLARED FOOTPRINT". A tower is that patch, and there was no way
# to select one.
#
# A PIECE'S OWN WIDTH IS ITS FOOTPRINT, which is why this needs no new header
# key and no new format. A canvas-wide piece placed at offset 0 covers the row
# exactly as it always did; a five-wide piece placed at offset k covers five
# columns and the terrain runs past on both sides. One rule, one code path.
#
# The alternative was authoring a patch's outer columns as HOLE inside a
# canvas-wide file, and it is worse than it looks: HOLE would then mean both "not
# part of this piece" and "a gap inside this piece", so a tower with a deliberate
# hole in it could not be expressed at all. Declaring the footprint by width has
# no such ambiguity.
static func for_width(width: int) -> Array:
	var out: Array = []
	for seg in all():
		if seg.is_valid() and seg.is_piece() and seg.width <= width:
			out.append(seg)
	return out

# True where a piece is narrower than the section it is going into, and therefore
# has terrain either side of it rather than owning its rows outright.
static func is_patch(piece, width: int) -> bool:
	return piece != null and piece.width < width
