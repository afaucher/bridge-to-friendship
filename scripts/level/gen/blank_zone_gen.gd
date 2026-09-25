extends RefCounted

# THE BLANK ZONE'S GROUND: flat, empty, undressed, canvas-wide. See BlankMode.

const SegmentData = preload("res://scripts/level/segment_data.gd")
const GenUtil = preload("res://scripts/level/gen/gen_util.gd")
const ModeProps = preload("res://scripts/level/gen/mode_props.gd")

# HOW LONG A BLANK ZONE IS. Mid-range for a generated section (they run 14 to 21),
# so a zone reads as a section-sized stretch of nothing rather than as a pause.
const BLANK_ZONE_ROWS := 16


# A ZONE WITH NOTHING IN IT (M25 phase 1b). The blank mode's whole terrain.
#
# WHY THE SECOND MODE IS THIS AND NOT A GAMEPLAY VARIANT. What the bus and the
# shooter will both need is not a different rule about hazards -- it is that a
# mode GENERATES ITS OWN GROUND. A bus wants a route and a shooter wants a
# corridor, and neither is `section()` with knobs on. So the cheapest honest
# second mode is the smallest instance of that: its own generator, producing the
# simplest thing a generator can produce.
#
# It is also the sharpest thing available to test. Every claim about it is a
# PRESENCE claim -- no hazards, no set pieces, one height everywhere -- and this
# project trusts those, because a rejection oracle turns "wrong" into "absent" and
# a correctness counter then passes over an empty set.
#
# THE FULL CANVAS, WHICH IS THE WIDEST THING THIS GAME CAN BUILD -- 21 cells at
# 2 m each, so 42 m across, against the 30 m of the lobby either side of it.
#
# IT WAS BASELINE WIDTH, copying the lobby on the argument that the width
# conventions are not this mode's to reinvent. That was the safe default and the
# wrong instinct: a blank zone that is exactly as wide as everything else is a
# stretch of bridge with the furniture removed, and what makes an empty space read
# as A PLACE is that it opens out.
#
# A STEP AT THE JOIN IS THE THING TO CHECK, and there is none: the zone is FLAT at
# one height and so is the lobby's exit, so the extra six cells a side are deck
# continuing outward rather than a lip to trip over. The join contract only asks
# that one column be solid on both sides, and fifteen are.
#
# WIDER THAN THIS NEEDS THE CANVAS RAISED, which CLAUDE.md records as expensive:
# the 15-to-21 bump broke four separate rules that had each been reading `width`
# to mean one of the four things it meant at once.
#
# NO GATE BANDS AND NO RACK. Those are the LOBBY's furniture and the lobby is
# always base -- a zone sits where a section sits, between two lobbies that
# already carry them.
static func blank_zone(width: int, run_seed: int, index: int):
	var length: int = BLANK_ZONE_ROWS
	var seg = GenUtil._blank("blank_%d" % index, maxi(width, GenUtil.LOBBY_MIN_WIDTH), length)
	# NO INSET AT ALL: `_blank` already fills the canvas, so the zone is every cell
	# of it. Nothing is cut away, which is the whole change.
	# TYPED, because SegmentData.tags is Array[String] and assigning a plain Array
	# RAISES -- which aborts the rest of this function and returns null, with the
	# caller then failing on a Nil three frames later and the gate green through
	# all of it. The same trap `lobby()` carries a note about.
	var zone_tags: Array[String] = ["foot", "generated", "blank"]
	seg.tags = zone_tags
	# `no_dress` is what keeps it blank against the DRESSING pass, which is a
	# separate thing from the generator and would otherwise scatter hazards over
	# ground that was made empty on purpose. Without it this mode would be "flat
	# terrain with the usual threats on it", which is not what was asked for and,
	# worse, would look like the mode had failed to take effect.
	seg.no_dress = true
	# THE ONE THING IN AN EMPTY ROOM BESIDES THE BUS: somewhere to get another.
	# A blank zone with a bus in the river and no way to fetch one is a blank
	# zone with nothing in it at all.
	ModeProps._place_bus_post(seg)
	return seg
