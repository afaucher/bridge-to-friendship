extends RefCounted

# THE LOBBY: the room between rounds. Always base, whatever mode the rounds
# either side of it are -- a broken mode must never be able to strand the party
# somewhere they cannot choose again.

const GridConfig = preload("res://scripts/level/grid_config.gd")
const SegmentData = preload("res://scripts/level/segment_data.gd")
const GenUtil = preload("res://scripts/level/gen/gen_util.gd")

const LOBBY_LENGTH := 12



# --- The lobby ----------------------------------------------------------------

static func lobby(width: int, run_seed: int, index: int):
	var seg = GenUtil._blank("lobby_%d" % index, maxi(width, GenUtil.LOBBY_MIN_WIDTH), LOBBY_LENGTH)
	# THE LOBBY IS BASELINE WIDTH, NOT CANVAS WIDTH (M22 phase C). `_blank` fills
	# the whole canvas, which was right while the canvas WAS the bridge; at a 21
	# canvas it would make every lobby six cells wider than the sections either
	# side of it and wider than the authored `lobby.seg` it alternates with. A
	# lobby is punctuation and should read as the same bridge, standing still.
	#
	# EVERY ROW, INCLUDING THE GATE BANDS. A band six cells wider than the section
	# it opens onto is a step at the exact row the party is told to gather on, and
	# `_check_gates` counts STANDABLE cells, so a baseline-wide band satisfies it
	# the same way a canvas-wide one did.
	var lobby_inset: int = mini(GridConfig.BASELINE_INSET,
		maxi(0, (seg.width - GenUtil.LOBBY_MIN_WIDTH) / 2))
	for z in seg.length:
		for x in seg.width:
			if x < lobby_inset or x >= seg.width - lobby_inset:
				seg.kinds[z][x] = GridConfig.Kind.HOLE
	# TYPED, because SegmentData.tags is Array[String] and assigning a plain Array
	# RAISES -- which aborts the rest of this function and returns null, and the
	# caller then fails on a Nil with the real cause three frames back. The gate
	# went green through all of it: a GDScript runtime error changes neither the
	# exit code nor the pass marker (CLAUDE.md).
	var lobby_tags: Array[String] = ["foot", "lobby", "safe", "generated"]
	seg.tags = lobby_tags

	# The boundary bands. Full width by rule -- _check_gates refuses a strip with
	# a gap, and that full-width row is also the REGROUP ROW the whole run leans
	# on: it is where the party can be anywhere, which is what lets a section
	# between two of them split into lanes and rejoin.
	#
	# ON THE STANDABLE CELLS ONLY, now that a lobby is narrower than its canvas.
	# Content on a hole is refused by `_check_content_placement`, and rightly: a
	# gate cell nobody can stand on is a boundary marker floating in the air.
	for z in GenUtil.GATE_DEPTH:
		for x in seg.width:
			if not seg.is_solid(x, z):
				continue
			seg.contents[z][x] = GridConfig.Content.GATE
			seg.contents[seg.length - 1 - z][x] = GridConfig.Content.GATE

	# THE RACK: one of each special, spread the full width so it reads as a CHOICE
	# rather than a conveyor you walk down collecting all six. You leave with
	# one, because the slot holds one.
	var rack: Array = [
		GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
		GridConfig.Content.PICKUP_ROCKET, GridConfig.Content.PICKUP_MINE,
		GridConfig.Content.PICKUP_SHIELD, GridConfig.Content.PICKUP_LEGS,
		GridConfig.Content.PICKUP_SHOTGUN, GridConfig.Content.PICKUP_RIFLE,
		GridConfig.Content.PICKUP_HEAVY,
	]
	_spread(seg, GenUtil.GATE_DEPTH + 2, rack)

	# THE MODE SELECTOR, ON THE CENTRE LINE AND PAST THE HATS (M25 phase 2).
	#
	# ONE PER LOBBY AND ONLY IN A LOBBY, which is what makes it safe to be dashable
	# at all: the lobby is always base, the corridor past it is speculative, and
	# the party is standing still behind a wall while a change re-cuts it.
	#
	# LATE IN THE ROOM, so it is the last thing on the way out rather than the
	# first thing on the way in. You choose where you are going after you have
	# picked up what you are taking, and a control by the entrance would be dashed
	# into by somebody still arriving.
	var post_row: int = seg.length - GenUtil.GATE_DEPTH - 2
	var post_x: int = seg.width / 2
	if post_row > GenUtil.GATE_DEPTH and seg.is_solid(post_x, post_row):
		seg.contents[post_row][post_x] = GridConfig.Content.MODE_POST

	# HATS past the rack. Hats are the score, so how many you can carry OUT is the
	# question the section asks; which one you take is not a decision.
	var hats: Array = []
	for _i in 4:
		hats.append(GridConfig.Content.HAT)
	_spread(seg, GenUtil.GATE_DEPTH + 5, hats)
	return seg


# Evenly across the row, inset from the parapet so nothing sits against a wall.
#
# ACROSS THE SOLID PART OF THE ROW, not across the canvas. A lobby is narrower
# than its canvas now, so spreading a nine-item rack over all 21 columns would put
# the first two and the last three on HOLES -- which `_check_content_placement`
# refuses, and which would otherwise be a pickup hanging in the air beside the
# bridge. Read off the row rather than from BASELINE_INSET so this stays right if
# the lobby's own width ever changes.
static func _spread(seg, row: int, items: Array) -> void:
	if items.is_empty() or row < 0 or row >= seg.length:
		return
	var first := -1
	var last := -1
	for x in seg.width:
		if not seg.is_solid(x, row):
			continue
		if first < 0:
			first = x
		last = x
	if first < 0:
		return
	var usable: int = maxi(1, (last - first + 1) - 2)
	for i in items.size():
		var x: int = first + 1 + int(round(float(i + 1) * float(usable) / float(items.size() + 1)))
		if x >= first and x <= last and seg.is_solid(x, row):
			seg.contents[row][x] = int(items[i])
