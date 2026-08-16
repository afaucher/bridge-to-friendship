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
	# rather than a conveyor you walk down collecting all six. You leave with
	# one, because the slot holds one.
	var rack: Array = [
		GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
		GridConfig.Content.PICKUP_ROCKET, GridConfig.Content.PICKUP_MINE,
		GridConfig.Content.PICKUP_SHIELD, GridConfig.Content.PICKUP_LEGS,
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

	# THE HEIGHT PROFILE, AS PLATEAUS AND TRANSITIONS.
	#
	# THE FIRST VERSION HAD NO ASCENDERS AT ALL, which meant every height change
	# had to be a single unit -- SOLO_RISE is 1, so anything taller is a wall a
	# lone player cannot pass and the validator rejects the attempt. The terrain
	# came out as a gentle staircase and could never be anything else. Caught by a
	# playtest question rather than by a test: everything validated, because
	# "accessible" was true and "interesting" is not something a flood has an
	# opinion about.
	#
	# UP NEEDS A RAMP; DOWN NEEDS NOTHING. That asymmetry is the whole trick.
	# Falling is free, so a DROP can be as tall as it likes and is a real cliff --
	# which is where split level comes from, and what the thickness rule of phase
	# 2 exists to make solid. A CLIMB gets a ramp row per unit, each rising one,
	# which stays inside the solo budget however tall the climb is.
	#
	# A RAMP IS NARROW, AND THAT IS THE POINT. The second version ramped the FULL
	# WIDTH, which reads as a staircase: the whole bridge tilts and there is no
	# decision in it. Two or three cells of a fifteen-wide deck makes the climb a
	# PLACE -- a choke the party has to converge on, with a cliff either side that
	# the thickness rule turns into a real face. Occasionally one (a scramble) or
	# four (a broad approach), never more.
	#
	# LADDERS ARE DELIBERATELY NOT USED, and this is a trap worth naming. The
	# validator counts LADDER as an ascender (ASCENDER_CONTENTS, since M2) but
	# there is no climb mechanic yet -- playtest_bridge's own header says so. A
	# generator placing ladders would produce runs that VALIDATE and cannot be
	# walked, the worst possible failure for a rejection oracle. Phase 6, not
	# before.
	#
	# THE NARROWING IS DECIDED FIRST, because a ramp has to be placed somewhere
	# the deck still exists two rows later. Narrowness is drawn as HOLES in the
	# outer columns rather than a width change: the loader refuses a width
	# mismatch, a fiction is cheaper than a format, and interior holes carry no
	# parapet by a deliberate M2 decision, so a thin section is unrailed and
	# dangerous for free.
	var narrow_from: int = 3 + salt % 4
	var narrow_len: int = 3 + (salt / 3) % 5
	var margin: int = 1 + (salt / 5) % maxi(1, width / 4)
	var split: bool = (salt / 11) % 3 == 0
	# The columns that are solid EVERYWHERE in this segment. A ramp must land in
	# these or it climbs into a hole -- measured 2026-08-16, 40 of 231 ramp tops
	# led nowhere because the ramp was placed before the narrowing was known and
	# the row above it had been cut away.
	var safe: Array = []
	for x in range(margin, width - margin):
		if split and absi(x - width / 2) < 1:
			continue
		safe.append(x)
	if safe.is_empty():
		safe.append(width / 2)

	# Per row: the height for ordinary cells, and (for a transition row) the ramp
	# columns and the height those columns climb to.
	var low: Array = []            # height of the non-ramp part of the row
	var ramp_h: Array = []         # height of the ramp columns, or -1
	var ramp_x0: Array = []
	var ramp_w: Array = []
	# A LIFT IS THE OTHER WAY UP (M17 phase 9), and it belongs in the SKELETON
	# rather than in the dressing pass: an elevator only means anything where
	# there is a height change, and a height change is terrain. Per row: the
	# column an elevator stands in, or -1.
	var lift_x: Array = []
	var lift_h: Array = []

	var height := 0
	var row := 0
	while row < length:
		var flat: int = 2 + _mix(salt + row * 3301) % 3
		for _f in flat:
			if row >= length:
				break
			low.append(height)
			ramp_h.append(-1)
			ramp_x0.append(0)
			ramp_w.append(0)
			lift_x.append(-1)
			lift_h.append(0)
			row += 1
		if row >= length:
			break

		var roll: int = _mix(salt + row * 7717) % 10
		if roll < 6:
			var rise: int = 1 + _mix(salt + row * 911) % 3
			# A CLIMB MUST FINISH WITH ROOM TO SPARE, or its top row is the EXIT
			# ROW -- which the fixup below stamps flat at `low`, the height of the
			# plateau BELOW. The ramp then climbs to h5 and its own top is reset to
			# h3, which is a ramp leading to nothing. Reported from a playtest and
			# measured at 23 of 239 ramp tops.
			#
			# Two rows of margin: one so the climb lands on real ground, one so the
			# exit row is flat deck at the height the climb reached.
			rise = mini(rise, length - 2 - row)
			if rise < 1:
				continue
			# RAMP OR LIFT, and the trade is floor space against time. A ramp
			# spends a ROW PER UNIT of climb — three units is three rows out of a
			# section that only has `length` of them — and it is walkable the
			# moment you reach it. A lift does any rise in ONE row and charges the
			# party up to a full cycle of standing there waiting for it.
			#
			# ONLY FOR A RISE OF TWO OR MORE. A one-unit climb is a one-row ramp
			# already, so replacing it with a wait is a cost that buys nothing.
			#
			# AND A MINORITY, about one qualifying climb in three. A section whose
			# every ascent is a lift is a section spent standing still, and a ramp
			# is still what this game is mostly made of.
			if rise >= 2 and _mix(salt + row * 6151) % 3 == 0:
				low.append(height)
				ramp_h.append(-1)
				ramp_x0.append(0)
				ramp_w.append(0)
				# One column, anchored in the safe corridor for the same reason a
				# ramp is: a shaft with a hole beside it is somewhere a player
				# falls off while standing still waiting.
				lift_x.append(_safe_ramp_x0(safe, 1, _mix(salt + row * 2087)))
				lift_h.append(height + rise)
				row += 1
				height += rise
				continue

			var w: int = _ramp_width(salt + row * 4093)
			# ANCHORED IN THE SAFE CORRIDOR, and clamped to a run of it that is
			# actually contiguous -- landing half a ramp on a hole is the same bug
			# as landing all of it there.
			var x0: int = _safe_ramp_x0(safe, w, _mix(salt + row * 1543))
			w = mini(w, _safe_run_from(safe, x0))
			for k in rise:
				if row >= length:
					break
				# The ordinary cells stay DOWN at the plateau below; only the ramp
				# columns climb. What that leaves either side of the ramp is a
				# cliff, which is exactly what it should be.
				low.append(height)
				ramp_h.append(height + k + 1)
				ramp_x0.append(x0)
				ramp_w.append(w)
				lift_x.append(-1)
				lift_h.append(0)
				row += 1
			height += rise
		elif roll < 8 and height > 0:
			# A DROP, and no ramp: falling is free. The cliff that makes a split
			# level, and the thing hand authoring almost never does because in a
			# text file it looks like a mistake.
			height -= mini(height, 1 + _mix(salt + row * 577) % 3)

	while low.size() < length:
		low.append(height)
		ramp_h.append(-1)
		ramp_x0.append(0)
		ramp_w.append(0)
		lift_x.append(-1)
		lift_h.append(0)

	for z in length:
		var narrow: bool = z >= narrow_from and z < narrow_from + narrow_len
		# A LIFT ROW IS A TRANSITION ROW TOO, so it is never narrowed: a shaft
		# with a hole beside it is somewhere a player falls while standing still.
		var is_transition: bool = int(ramp_h[z]) >= 0 or int(lift_x[z]) >= 0
		for x in width:
			var on_ramp: bool = int(ramp_h[z]) >= 0 \
				and x >= int(ramp_x0[z]) and x < int(ramp_x0[z]) + int(ramp_w[z])
			# AUTHORED AT THE HEIGHT IT RISES TO. Where it comes back down to is
			# read off the terrain by BridgeGrid, so the two ends of a lift cannot
			# be written separately and allowed to disagree.
			var on_lift: bool = x == int(lift_x[z])
			if on_lift:
				seg.heights[z][x] = int(lift_h[z])
			elif on_ramp:
				seg.heights[z][x] = int(ramp_h[z])
			else:
				seg.heights[z][x] = int(low[z])

			var solid := true
			# A TRANSITION ROW IS NEVER NARROWED. A wedge with a hole beside it is
			# a wedge somebody falls off while climbing, and a climb is the one
			# place a player has no lateral control to spare.
			if narrow and not is_transition:
				if x < margin or x >= width - margin:
					solid = false
				elif split and absi(x - width / 2) < 1:
					# A LANE SPLIT between two regroup rows. Free, because the
					# boundary bands either side are full width and the party can
					# be anywhere on them -- each lane is an ordinary route from
					# one band to the next.
					solid = false

			if not solid:
				seg.kinds[z][x] = GridConfig.Kind.HOLE
			elif on_ramp:
				seg.kinds[z][x] = GridConfig.Kind.RAMP
			else:
				seg.kinds[z][x] = GridConfig.Kind.DECK
				if on_lift:
					# DECK, with the elevator as its CONTENT. The platform is built
					# from that record and the cell is kept out of the deck merge,
					# so the "deck" here is really the shaft the lift travels in.
					seg.contents[z][x] = GridConfig.Content.ELEVATOR

	# THE ENTRY AND EXIT ROWS ARE FLAT DECK, never a ramp: a segment is stacked on
	# the one before it by its exit HEIGHT, and joining a wedge to a flat row
	# leaves a step nobody authored.
	for x in width:
		seg.kinds[0][x] = GridConfig.Kind.DECK
		seg.kinds[length - 1][x] = GridConfig.Kind.DECK
		seg.heights[0][x] = int(low[0])
		seg.heights[length - 1][x] = int(low[length - 1])
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

# Where a ramp of width `w` can start so every one of its columns survives the
# narrowing. Falls back to the middle of the corridor, which is always solid.
static func _safe_ramp_x0(safe: Array, w: int, salt: int) -> int:
	var starts: Array = []
	for i in safe.size():
		var x0: int = int(safe[i])
		var run := 0
		for k in w:
			if safe.has(x0 + k):
				run += 1
		if run == w:
			starts.append(x0)
	if starts.is_empty():
		return int(safe[safe.size() / 2])
	return int(starts[salt % starts.size()])

# How many contiguous safe columns follow x0, so a ramp is never wider than the
# ground it lands on.
static func _safe_run_from(safe: Array, x0: int) -> int:
	var run := 0
	while safe.has(x0 + run):
		run += 1
	return maxi(1, run)

# TWO OR THREE, MOSTLY. One is a scramble and four is a broad approach; both are
# worth having occasionally and neither should be the norm. Never more, because a
# ramp wider than that stops being a place and becomes the whole deck tilting.
static func _ramp_width(salt: int) -> int:
	var roll: int = _mix(salt) % 10
	if roll == 0:
		return 1
	if roll == 9:
		return 4
	return 2 + roll % 2

static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)
