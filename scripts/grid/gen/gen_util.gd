extends RefCounted

# WHAT EVERY GENERATOR SHARES: an empty canvas, the per-band roll, the baseline
# ends a generated section must meet an authored one with, and the two widths
# every kind of ground agrees on. See segment_gen.gd for the whole picture.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")

# THE LOBBY'S OWN FLOOR, independent of its neighbours. A lobby that merely fits
# the section either side could come out three cells wide, and that is not a
# lobby -- it is a corridor with a rack in it. The number is set by what the
# space is FOR: four players standing around without shoving each other off, a
# rack that reads as a row of choices rather than a queue, and room to walk past
# somebody who is deciding.
const LOBBY_MIN_WIDTH := 11

# Two rows deep at each end, per M16: one row is 2 m, and a party of four told to
# gather on it is four players jostling on a strip narrower than they are.
const GATE_DEPTH := 2


# ONE BAND'S ROLL. Extracted because the three call sites were written as
# backslash continuations and GDScript collapsed them onto one line, which made
# them unmatchable by every anchored edit -- the third time that has cost
# something in this project. A named helper is also the honest shape: three rolls
# that differ only in their salt and their range.
#
# SALTED PER KIND so the lane, the link and the bay of one band are independent.
# Without it every band would draw the same number three times and a long lane
# would always come with a fast corner.
static func _band_roll(salt: int, band: int, kind: int, low: int, high: int) -> int:
	return low + Hash.mix(salt + band * kind) % (high - low + 1)


# EVERY SEGMENT BOUNDARY IN THE GAME IS THE SAME WIDTH (M22 phase C).
#
# Called last by both generators, and being last is the point. The section's
# entry/exit fixup writes DECK to every column, the maze leaves its end rows as
# whatever `_blank` produced, and the lift re-cone can drag an end off the
# baseline because `_cone` takes a minimum -- three different routes to a
# canvas-wide end, all of them silently overruling the profile. Measured on the
# first phase-C run: 120 open ends and 104 rate breaks, which is a six-cell flare
# at both ends of every generated section.
#
# So the boundary is decided HERE and nowhere else. Baseline, because every
# authored file is padded to the baseline -- a canvas-wide generated end would
# butt a 15-wide authored one and put a step at the seam.
static func _baseline_end_rows(seg) -> void:
	var inset: int = mini(GridConfig.BASELINE_INSET, maxi(0, seg.width / 2 - 1))
	if inset <= 0:
		return
	for z in [0, seg.length - 1]:
		for x in seg.width:
			if x < inset or x >= seg.width - inset:
				seg.kinds[z][x] = GridConfig.Kind.HOLE


# --- Helpers ------------------------------------------------------------------

static func _blank(seg_name: String, width: int, length: int):
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
