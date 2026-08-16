extends RefCounted

# GENERATED SEGMENTS. M17 layers 1 and the lobby.
#
# Produces a `SegmentData` in memory rather than a file, so everything
# downstream -- the validator, the builder, the dressing pass, the run assembler
# -- cannot tell the difference between a generated segment and an authored one.
# That is the whole architecture: this file only has to fill in cell records.
#
# THE LOBBY CAME FIRST ON PURPOSE (phase 4). It is trivially parametric -- a
# solid rectangle, a rack, some hats, a band at each end -- and it is the one
# piece of content where being wrong is CHEAP: a lobby has no hazards, so a
# generation bug costs a strange-looking room rather than a run nobody can
# finish. It proves generate, validate, assemble and play end to end before any
# of that meets terrain full of holes and shooters. Getting the first generator
# wrong on hostile terrain means debugging the generator and the level design at
# the same time.
#
# EVERYTHING HERE IS A PURE FUNCTION OF ITS SEED. The bridge is a pure function
# of (seed, count) and must stay one, because a joining client is told two
# numbers and builds the identical world. The mixer is local; the global RNG is
# never touched.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

# THE LOBBY'S OWN FLOOR, independent of its neighbours. A lobby that merely fits
# the section either side could come out three cells wide, and that is not a
# lobby -- it is a corridor with a rack in it. The number is set by what the
# space is FOR: four players standing around without shoving each other off, a
# rack that reads as a row of choices rather than a queue, and room to walk past
# somebody who is deciding.
const LOBBY_MIN_WIDTH := 11
const LOBBY_LENGTH := 12
# Two rows deep at each end, per M16: one row is 2 m, and a party of four told to
# gather on it is four players jostling on a strip narrower than they are.
const GATE_DEPTH := 2

# --- The lobby ----------------------------------------------------------------

static func lobby(width: int, run_seed: int, index: int):
	var seg = _blank("lobby_%d" % index, maxi(width, LOBBY_MIN_WIDTH), LOBBY_LENGTH)
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
	for z in GATE_DEPTH:
		for x in seg.width:
			seg.contents[z][x] = GridConfig.Content.GATE
			seg.contents[seg.length - 1 - z][x] = GridConfig.Content.GATE

	# THE RACK: one of each special, spread the full width so it reads as a CHOICE
	# rather than a conveyor you walk down collecting all four. You leave with
	# one, because the slot holds one.
	var rack: Array = [
		GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
		GridConfig.Content.PICKUP_ROCKET, GridConfig.Content.PICKUP_MINE,
		GridConfig.Content.PICKUP_SHIELD,
	]
	_spread(seg, GATE_DEPTH + 2, rack)

	# HATS past the rack. Hats are the score, so how many you can carry OUT is the
	# question the section asks; which one you take is not a decision.
	var hats: Array = []
	for _i in 4:
		hats.append(GridConfig.Content.HAT)
	_spread(seg, GATE_DEPTH + 5, hats)
	return seg

# Evenly across the row, inset from the parapet so nothing sits against a wall.
static func _spread(seg, row: int, items: Array) -> void:
	if items.is_empty() or row < 0 or row >= seg.length:
		return
	var usable: int = seg.width - 2
	for i in items.size():
		var x: int = 1 + int(round(float(i + 1) * float(usable) / float(items.size() + 1)))
		if x >= 0 and x < seg.width:
			seg.contents[row][x] = int(items[i])

# --- The terrain skeleton (phase 5) -------------------------------------------

# A SECTION, GENERATED. Width, a height profile, gap density and a lane split are
# the properties a player reads as "a different place", and they are also the
# ones a person is worst at varying: hand authoring drifts to the same
# comfortable width and the same comfortable gap every time.
#
# GENERATE, VALIDATE, REJECT, REROLL. Never construct-and-hope. The oracle is the
# same flood the authoring validator uses, so a generated segment has to clear
# the bar an authored one does -- and `attempts` is bounded, because a generator
# that cannot satisfy its own constraints must say so rather than spin.
static func section(width: int, run_seed: int, index: int, attempts: int = 24):
	for attempt in attempts:
		var seg = _section_attempt(width, run_seed, index, attempt)
		# THE SAME BAR AS AN AUTHORED SEGMENT, including the solo flood: a section
		# only a cooperating pair can cross strands a lone player, and drop-in
		# makes that a real case rather than a hypothetical.
		if SegmentValidator.validate(seg).is_empty():
			return seg
	# EVERY ATTEMPT REJECTED. Fall back to something that cannot fail rather than
	# returning null and making every caller handle it: a flat deck is a boring
	# section and a boring section is infinitely better than a broken run.
	var flat = _blank("section_%d_flat" % index, width, 16)
	var flat_tags: Array[String] = ["foot", "generated", "fallback"]
	flat.tags = flat_tags
	return flat

static func _section_attempt(width: int, run_seed: int, index: int, attempt: int):
	var salt: int = _mix(run_seed + index * 15485863 + attempt * 97)
	var length: int = 14 + salt % 8
	var seg = _blank("section_%d" % index, width, length)
	var section_tags: Array[String] = ["foot", "generated"]
	seg.tags = section_tags

	# THE HEIGHT PROFILE. A run climbs, so the profile trends up -- but a STEP
	# DOWN is valid and is one of the things hand authoring never does.
	var height := 0
	var heights: Array = []
	for z in length:
		if z > 0 and z % (2 + salt % 3) == 0:
			var roll: int = _mix(salt + z * 7717) % 10
			# Up four times as often as down, and never more than one unit at a
			# time: SOLO_RISE is 1, so a two-unit step is a wall to a lone player
			# and the validator would reject the whole attempt.
			if roll < 4:
				height += 1
			elif roll < 5 and height > 0:
				height -= 1
		heights.append(height)

	# THE LANE SPLIT. Narrowness is drawn as HOLES in the outer columns, never as
	# a width change: the loader refuses a width mismatch, and a fiction is
	# cheaper than a format. Interior holes carry no parapet by a deliberate M2
	# decision, so a thin section is unrailed and dangerous for free.
	var narrow_from: int = 3 + salt % 4
	var narrow_len: int = 3 + (salt / 3) % 5
	var margin: int = 1 + (salt / 5) % maxi(1, width / 4)
	var split: bool = (salt / 11) % 3 == 0

	for z in length:
		var narrow: bool = z >= narrow_from and z < narrow_from + narrow_len
		for x in width:
			seg.heights[z][x] = int(heights[z])
			var solid := true
			if narrow:
				if x < margin or x >= width - margin:
					solid = false
				elif split and absi(x - width / 2) < 1:
					# A LANE SPLIT between two regroup rows. Free, because the
					# boundary bands either side are full width and the party can
					# be anywhere on them -- each lane is an ordinary route from
					# one band to the next.
					solid = false
			seg.kinds[z][x] = GridConfig.Kind.DECK if solid else GridConfig.Kind.HOLE

	# THE ENTRY AND EXIT ROWS ARE ALWAYS FULL WIDTH AND FLAT. That is the join
	# contract's easiest possible satisfaction -- any neighbour overlaps -- and it
	# is also what makes the height profile safe, since a segment is stacked on
	# the one before by its exit height.
	for x in width:
		seg.kinds[0][x] = GridConfig.Kind.DECK
		seg.kinds[length - 1][x] = GridConfig.Kind.DECK
		seg.heights[0][x] = int(heights[0])
		seg.heights[length - 1][x] = int(heights[length - 1])
	return seg

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

static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)
