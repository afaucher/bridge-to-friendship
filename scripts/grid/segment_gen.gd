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
const SetPieces = preload("res://scripts/grid/set_pieces.gd")

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

# The longest a piece may be, mirrored from SetPieces so the profile loop can
# reserve room before it has picked one. Checked again against the actual pick,
# because a mirrored constant is a constant that can drift.
const MAX_PIECE_ROWS := SetPieces.MAX_ROWS

# --- The lobby ----------------------------------------------------------------

static func lobby(width: int, run_seed: int, index: int):
	var seg = _blank("lobby_%d" % index, maxi(width, LOBBY_MIN_WIDTH), LOBBY_LENGTH)
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
		maxi(0, (seg.width - LOBBY_MIN_WIDTH) / 2))
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
	for z in GATE_DEPTH:
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
	_spread(seg, GATE_DEPTH + 2, rack)

	# HATS past the rack. Hats are the score, so how many you can carry OUT is the
	# question the section asks; which one you take is not a decision.
	var hats: Array = []
	for _i in 4:
		hats.append(GridConfig.Content.HAT)
	_spread(seg, GATE_DEPTH + 5, hats)
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
	# THE FIRST SECTION *KIND*. Until now "generated section" meant exactly one
	# algorithm with knobs on it -- plateaus, ramps, lifts, drops, a narrowing band
	# -- so every generated section in the game had the same silhouette however
	# much the numbers varied. A maze is a different KIND of place, and it cannot
	# ride the profile loop: that loop's whole vocabulary is height, and a maze
	# wants the section end to end.
	#
	# WHY THIS ONE IS GENERATED AND A SET-PIECE IS NOT. A piece is authored because
	# it is a RELATIONSHIP -- cover and the thing it is cover from -- and no
	# distribution produces one. A maze has no relationship in it; it is a graph,
	# which is the one thing an algorithm is strictly better at than a person. And
	# it is the only content in this game whose value is DESTROYED by repetition: a
	# plinko field is re-fought every time, a maze you have walked twice is a
	# corridor. segments/run_maze.seg stays as the fixture test_maze measures on,
	# because a fixture that changes under its test is not one.
	#
	# ONE IN FIVE, and decided from (seed, index) rather than from `attempt` so a
	# rejected maze rerolls into another MAZE rather than quietly becoming a ramp
	# section. A rarity: the maze is the section with no hazard in it at all, and
	# a run that keeps serving them is a run with no threat in it.
	var want_maze: bool = _mix(run_seed + index * 3298541) % 5 == 0
	for attempt in attempts:
		var seg = _maze_attempt(width, run_seed, index, attempt) if want_maze \
			else _section_attempt(width, run_seed, index, attempt)
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
	# mismatch, and a fiction is cheaper than a format.
	#
	# TWO EDGES, MOVING INDEPENDENTLY (M22). This used to be ONE symmetric
	# `margin` applied to one contiguous band of rows, which is why the bridge
	# only ever pinched evenly toward its own centre line and every section looked
	# the same width. Now each side carries its own inset per row, so the deck can
	# hug one edge while opening out the other -- a wall down one side and open air
	# on the other is a shape the old single number could not express at all.
	#
	# AND IT IS NOW RAILED. The old comment here ended "interior holes carry no
	# parapet by a deliberate M2 decision, so a thin section is unrailed and
	# dangerous for free". That was the bug, not the feature: an unrailed setback
	# reads as MISSING FLOOR rather than as a narrower bridge, and you walk off it.
	# `SegmentData.has_wall` now asks whether the void reaches the canvas, so these
	# cuts grow a real edge. See implementation_plans/m22_bridge_width.md.
	var split: bool = (salt / 11) % 3 == 0
	# The columns that are solid EVERYWHERE in this segment. A ramp must land in
	# these or it climbs into a hole -- measured 2026-08-16, 40 of 231 ramp tops
	# led nowhere because the ramp was placed before the narrowing was known and
	# the row above it had been cut away.
	#
	# FROM THE BOUND, NOT FROM THE PROFILE. `_edge_inset_bound` is a pure function
	# of the width, so the safe corridor can be known BEFORE any profile exists --
	# which is what lets the profile be built last, with the lift rows it has to
	# accommodate already decided. Slightly more conservative than reading the
	# deepest inset a particular roll happened to reach, and worth it.
	#
	# ONE COLUMN OF SLACK ON EACH SIDE, which is what lets the transition-row
	# exception go away. A ramp carries no parapet (its top face is a slope and a
	# box at a fixed height either floats or buries), so a ramp sitting AT the
	# inset would be an unrailed edge -- the exact "wedge with a hole beside it"
	# the old code dodged by refusing to narrow a transition row at all. Keeping
	# ramps one column inside the deepest possible cut means the cell beside every
	# ramp and every lift is ordinary deck, and ordinary deck at the edge is now
	# railed.
	var deepest: int = _edge_inset_bound(width)
	var safe: Array = []
	for x in range(deepest + 1, width - deepest - 1):
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
	# A SET-PIECE OWNS ITS ROWS OUTRIGHT (M18 phase 1). Per row: the piece
	# stamped there (or null), which of its rows this is, and the plateau height
	# it was stamped at.
	#
	# RESERVE FIRST, STAMP SECOND. When the loop decides to spend N rows on a
	# piece, those rows are the piece's -- it writes their heights, kinds and
	# contents. Building a skeleton and overwriting part of it afterwards leaves
	# every cell with two authors and no rule about which wins, and the first bug
	# out of that is a ramp whose top row was eaten by a piece that starts flat.
	var piece_ref: Array = []
	var piece_row: Array = []
	var piece_base: Array = []
	var pieces: Array = SetPieces.for_width(width)
	var placed = null

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
			piece_ref.append(null)
			piece_row.append(0)
			piece_base.append(0)
			row += 1
		if row >= length:
			break

		# A PIECE IS THE OTHER THING THE PROFILE CAN DECIDE TO DO, beside a ramp, a
		# lift, a drop and staying flat. Offered before the climb roll because a
		# piece may itself BE a climb -- `piece_exit` says so -- and rolling the
		# terrain first would be deciding the same question twice.
		#
		# ONE PER SECTION. A section is 16 rows and a piece is 4 to 8 of them, so
		# two would leave almost no generated terrain between them and the section
		# would be an authored level with a seam down the middle.
		#
		# ROOM TO SPARE, and this is the margin M17 already paid for once: a climb
		# whose top row IS the exit row gets stamped flat by the fixup below, and a
		# ramp leading nowhere was measured at 23 of 239 before it was fixed. A
		# piece running into the exit row is that bug wearing a composition.
		if placed == null and not pieces.is_empty() 				and row + MAX_PIECE_ROWS + 2 <= length 				and _mix(salt + row * 3571) % 4 == 0:
			var pick = pieces[_mix(salt + row * 5023) % pieces.size()]
			if row + pick.length + 2 <= length:
				for pz in pick.length:
					low.append(height)
					ramp_h.append(-1)
					ramp_x0.append(0)
					ramp_w.append(0)
					lift_x.append(-1)
					lift_h.append(0)
					piece_ref.append(pick)
					piece_row.append(pz)
					piece_base.append(height)
					row += 1
				height += int(pick.piece_exit)
				placed = pick
				continue

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
			# AND CLEAR OF BOTH ENDS, or the two rules collide (M22 phase C). A lift
			# row must be FULL WIDTH and a segment's ends must be BASELINE, and at
			# one column of taper per row those are three rows apart -- so a lift
			# too near an end is a demand the profile cannot satisfy, and whichever
			# pass runs last wins. Measured when this guard was missing: 31 lift
			# rows narrowed, because `_pin_ends` raised the zero back up.
			var lift_clear: int = INSET_END_ROWS + GridConfig.BASELINE_INSET
			if rise >= 2 and row >= lift_clear and row < length - lift_clear \
					and _mix(salt + row * 6151) % 3 == 0:
				low.append(height)
				ramp_h.append(-1)
				ramp_x0.append(0)
				ramp_w.append(0)
				# One column, anchored in the safe corridor for the same reason a
				# ramp is: a shaft with a hole beside it is somewhere a player
				# falls off while standing still waiting.
				lift_x.append(_safe_ramp_x0(safe, 1, _mix(salt + row * 2087)))
				lift_h.append(height + rise)
				piece_ref.append(null)
				piece_row.append(0)
				piece_base.append(0)
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
				piece_ref.append(null)
				piece_row.append(0)
				piece_base.append(0)
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
		piece_ref.append(null)
		piece_row.append(0)
		piece_base.append(0)

	# THE EDGE PROFILE IS BUILT LAST, once the rows that constrain it are known.
	#
	# It used to be built FIRST -- it had to be, because `safe` was derived from
	# it -- and then patched afterwards for the lifts: zero the lift rows, re-cone,
	# re-pin. Every one of those patches was a rate-1 correction, which is the
	# steepest taper the rules allow, so a third of all sections had the deck
	# snapping open around a lift at exactly the moment the goal was to make width
	# change GRADUALLY.
	#
	# Deriving `safe` from `_edge_inset_bound` instead removed the ordering
	# constraint, so the lift rows are simply WAYPOINTS the profile is drawn
	# through. One pass, no patches, and the taper into a lift is as gentle as any
	# other.
	# AND THE LIFT ROWS NEED NO SPECIAL CASE AT ALL, which is the other half of
	# what deriving `safe` from a bound bought.
	#
	# A lift row used to be forced full width, on the rule that "a shaft with a
	# hole beside it is somewhere a player falls off while standing still". That
	# property is real and it is already guaranteed somewhere better: `safe` keeps
	# every lift inside columns 7..13, and the deepest either edge can ever be cut
	# leaves columns 6..14 solid -- so a lift has ordinary deck on both sides at
	# EVERY profile this generator can produce, and the parapet rule railed the
	# setback beyond it. The full-width rule was buying a second time something
	# already paid for, and charging the gradient for it.
	var left_inset: Array = _edge_profile(width, length, salt + 30011)
	var right_inset: Array = _edge_profile(width, length, salt + 40009)

	for z in length:
		# STAMPED WHOLE, and before anything else looks at the row. The piece wrote
		# its own heights, kinds and contents; narrowing, ramps and lifts have
		# nothing to say about rows that are not theirs.
		if piece_ref[z] != null:
			var piece = piece_ref[z]
			var pz: int = int(piece_row[z])
			var base: int = int(piece_base[z])
			for x in width:
				seg.heights[z][x] = base + piece.height_at(x, pz)
				seg.kinds[z][x] = piece.kind_at(x, pz)
				seg.contents[z][x] = piece.content_at(x, pz)
			# RECORDED AS THE ROWS ARE WRITTEN, so the record cannot disagree with
			# what was stamped. Layer 3 reads it and keeps out.
			seg.piece_rows.append(z)
			continue

		var cut_left: int = int(left_inset[z])
		var cut_right: int = int(right_inset[z])
		# THE LANE SPLIT SKIPS A LIFT ROW, for exactly the reason the inset does
		# (see the re-cone above): a rider is stationary and out of verbs, so the
		# one row where they cannot move stays whole. The insets are already zero
		# here by construction; the split is a separate mechanism and needs saying
		# separately.
		var split_here: bool = split and int(lift_x[z]) < 0
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
			# THE TWO EDGES, EACH ON ITS OWN. A ramp or a lift is never cut into,
			# because `safe` keeps both one column inside the deepest inset.
			if not on_ramp and not on_lift:
				if x < cut_left or x >= width - cut_right:
					solid = false
				elif split_here and absi(x - width / 2) < 1:
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
	#
	# ACROSS THE BASELINE, NOT ACROSS THE CANVAS (M22 phase C). This wrote DECK to
	# every column, which was right while the canvas WAS the bridge and is the
	# reason the first phase-C run had a six-cell flare at both ends of every
	# generated section: the profile said baseline and this line overruled it,
	# silently, after all the careful work upstream. Measured: 120 open ends and
	# 104 rate breaks, every one of them here.
	#
	# The lift re-cone can also drag an end off the baseline -- `_cone` takes a
	# minimum and a lift row pinned to zero pulls its neighbours down -- so the
	# ends are written from BASELINE rather than from the profile, which makes
	# this line the single place that decides what a segment boundary looks like.
	for x in width:
		seg.kinds[0][x] = GridConfig.Kind.DECK
		seg.kinds[length - 1][x] = GridConfig.Kind.DECK
		seg.heights[0][x] = int(low[0])
		seg.heights[length - 1][x] = int(low[length - 1])
	_baseline_end_rows(seg)
	return seg

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

# --- The maze section ---------------------------------------------------------

# THE LATTICE. Corridors sit on EVEN columns and EVEN rows; everything between
# them starts as wall and gets carved. So the maze's own coordinates (i, j) map
# to grid cells (2i, 2 + 2j), and the cell halfway between two neighbours is the
# wall that separates them -- carving a link is writing one cell.
#
# EVEN COLUMNS, WHICH PUTS THE OUTER LANES AGAINST THE BRIDGE'S OWN EDGE (changed
# 2026-08-17). It was odd columns, spending x = 0 and x = width-1 on explicit WALL
# blocks -- and the deck already railings itself there: `has_wall` parapets any
# SOLID cell in the outermost column, and WALL_HEIGHT is 2.0, exactly the height a
# maze wall is. The boundary was being paid for twice.
#
# Worth a lane, and worth more than a lane. At width 15 it is eight corridors
# instead of seven, and the maze stops being a sealed box: the outer lanes have
# the real deck edge beside them and the drop past it, which is what every other
# section looks like from a 45-degree camera.
#
# THE LANE IS WALKABLE, AND THAT WAS MEASURED BEFORE THIS CHANGED -- see
# test_edge_lane. A parapet is a 0.3 m slab inset at the cell edge, and this repo
# has three separate notes about flat-bottomed bodies catching on exactly that
# kind of boundary, every one of which presented as "sometimes you just stop". A
# body walks the outer lane its full length and stays dead on its centre line.
const MAZE_MIN_ROWS := 7
const MAZE_MAX_ROWS := 10

# TWO UNITS, AND THE NUMBER IS A SIGHTLINE RATHER THAN A CLIMB. There is no
# step-up in this game, so ANY height blocks and one unit would block just as
# well. At the camera's 45 degrees a wall of height h hides exactly h metres of
# ground behind it and a cell is 2 m, so two units hides the FLOOR of the cell
# beyond and one unit would hide half of it and read as a kerb. A player is
# 1.8 m, so heads still clear it: you lose track of what is on the ground, never
# of where your friends are. Three would start swallowing people.
const MAZE_WALL_HEIGHT := 2

# HOW HARD TO BRAID, as a fraction of the cell count added back as extra links.
#
# A PERFECT MAZE IS THE WRONG SHAPE HERE. The camera is fixed top-down, so the
# whole maze is on screen and nobody is discovering anything -- a single-solution
# maze read from above is not a puzzle, it is a queue, and four players walk it in
# single file. Loops are what make it a co-op section: two routes that both arrive
# means splitting up is a real choice rather than a mistake.
#
# The authored run_maze.seg was carved by dead-end removal alone and came out at
# five loops across seventy cells, which is close to single-file. This adds loops
# DIRECTLY instead of hoping the dead ends supply them.
const MAZE_BRAID := 6      # one extra link per this many cells

# A few dead ends survive to hold the rewards. From above you can SEE the hat, so
# a detour is a decision about time -- which is the only way a dead end earns its
# place in a maze you can see all of.
const MAZE_DEAD_ENDS := 4

# FLOOR TRAPS. A maze with nothing in it is a walking puzzle, and this one is
# read from above -- so the route is never the problem, and the only thing that
# can make choosing it cost anything is what is standing on it.
#
# TIMED FLOORS ARE THE MAZE-FRIENDLY HAZARD. They are periodically solid, so one
# can never make a route impossible -- only slower -- which matters because the
# reachability flood CANNOT SEE CONTENT. A hazard that could seal a corridor would
# be a maze that validates and cannot be crossed, which is the shape CLAUDE.md
# keeps recording. The phase is per-cell (cell.x * 7 + cell.y * 13), so two of
# them side by side open at different moments rather than becoming one wide gap.
#
# SPIKES ARE THE SAME KIND OF THING, and the first version of this file said
# otherwise at length. It claimed a spike could SEAL a corridor -- that it hurts
# the cell it is drawn in, that a maze corridor is one cell wide, and so a spike
# on a cut vertex is a wall with a health bar -- and it refused any placement that
# disconnected the maze.
#
# SPIKES RUN ON A CLOCK. SPIKE_PERIOD is 2 s and they are out for 34% of it, of
# which the leading and trailing quarters are the RAMP -- a deliberate telegraph
# -- so the cell actually hurts for 0.48 s in every 2.0 and is harmless 76% of the
# time. And when it does hit it charges SPIKE_DAMAGE, one of five health. It does
# not block; it takes a toll from somebody who walked through without reading it.
# Corrected on the day it was written, from "the spikes absolutely run on a timer,
# you can walk through them can't you?" -- which is what the constants say and
# what piece_spike_gallery's own header has said all along: a rhythm to read
# rather than a wall.
#
# So a spike on the only route is not a blocked maze, it is a timing gate, which
# is a perfectly good thing for a maze to have. The connectivity check has gone
# and the placements it was suppressing are back.
const MAZE_TIMED := 3
const MAZE_SPIKES := 3

static func _maze_attempt(width: int, run_seed: int, index: int, attempt: int):
	var salt: int = _mix(run_seed + index * 15485863 + attempt * 97 + 0x5EED)
	var cols: int = (width + 1) / 2
	# Below three columns it is a corridor with kinks in it, not a maze.
	if cols < 3:
		return null
	var rows: int = MAZE_MIN_ROWS + salt % (MAZE_MAX_ROWS - MAZE_MIN_ROWS + 1)
	# Entry deck, a wall row with the door, the lattice, the far wall row, then two
	# rows of deck to arrive on. Derived rather than picked so the two ends cannot
	# disagree with the lattice between them.
	var length: int = rows * 2 + 4

	var seg = _blank("section_%d_maze" % index, width, length)
	var maze_tags: Array[String] = ["foot", "generated", "maze"]
	seg.tags = maze_tags
	seg.no_dress = true

	# EVERYTHING IS WALL UNTIL SOMETHING CARVES IT. Building the solid and cutting
	# passages out of it is the only order that cannot leave a stray open cell: the
	# opposite -- start open, add walls -- has to be right everywhere at once.
	for z in range(1, length - 2):
		for x in width:
			seg.kinds[z][x] = GridConfig.Kind.WALL
			seg.heights[z][x] = MAZE_WALL_HEIGHT

	var open_cells: Dictionary = {}
	for j in rows:
		for i in cols:
			open_cells[Vector2i(2 * i, 2 + 2 * j)] = true

	# DEPTH-FIRST CARVE. A spanning tree over the lattice, so every cell is
	# reachable from every other before a single loop is added -- which is what
	# makes the braid below free to be as aggressive as it likes without any risk
	# of cutting the maze in two.
	var visited: Dictionary = {Vector2i(0, 0): true}
	var stack: Array = [Vector2i(0, 0)]
	var step: int = 0
	while not stack.is_empty():
		var cell: Vector2i = stack[stack.size() - 1]
		var options: Array = []
		for d in 4:
			var n: Vector2i = cell + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows:
				continue
			if not visited.has(n):
				options.append(n)
		if options.is_empty():
			stack.pop_back()
			continue
		step += 1
		var pick: Vector2i = options[_mix(salt + step * 2749) % options.size()]
		open_cells[_maze_between(cell, pick)] = true
		visited[pick] = true
		stack.append(pick)

	# BRAID. Extra links between neighbours that are not yet linked, taken at
	# scattered positions rather than by walking the lattice in order -- an
	# in-order pass concentrates every loop in the first rows it visits.
	var extra: int = (cols * rows) / MAZE_BRAID
	for k in extra:
		var i: int = _mix(salt + k * 7523) % cols
		var j: int = _mix(salt + k * 8161) % rows
		var here := Vector2i(i, j)
		var dirs: Array = []
		for d in 4:
			var n: Vector2i = here + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows:
				continue
			if not open_cells.has(_maze_between(here, n)):
				dirs.append(n)
		if dirs.is_empty():
			continue
		open_cells[_maze_between(here, dirs[_mix(salt + k * 6421) % dirs.size()])] = true

	# THEN OPEN THE DEAD ENDS THAT ARE LEFT, past the few kept for rewards. A dead
	# end with nothing in it is a wrong turn the player can see is a wrong turn,
	# which is a walk they take for no reason.
	var dead: Array = []
	for j in rows:
		for i in cols:
			if _maze_degree(open_cells, Vector2i(i, j)) == 1:
				dead.append(Vector2i(i, j))
	for n in dead.size():
		if n < MAZE_DEAD_ENDS:
			continue
		var here: Vector2i = dead[n]
		# Re-checked: opening one dead end can raise a neighbour's degree, so the
		# list goes stale as it is walked.
		if _maze_degree(open_cells, here) != 1:
			continue
		var shut: Array = []
		for d in 4:
			var nb: Vector2i = here + GridConfig.DIR_CELLS[d]
			if nb.x < 0 or nb.x >= cols or nb.y < 0 or nb.y >= rows:
				continue
			if not open_cells.has(_maze_between(here, nb)):
				shut.append(nb)
		if not shut.is_empty():
			open_cells[_maze_between(here, shut[_mix(salt + n * 4133) % shut.size()])] = true

	# ONE DOOR EACH END. A full-width mouth would let the party fan out before the
	# maze had asked them anything; a single opening makes the entrance a PLACE,
	# and puts everybody in the same corridor for the first moment.
	var in_door: int = 2 * (_mix(salt + 1811) % cols)
	var out_door: int = 2 * (_mix(salt + 3181) % cols)
	open_cells[Vector2i(in_door, 1)] = true
	open_cells[Vector2i(out_door, length - 3)] = true

	for cell in open_cells:
		seg.kinds[cell.y][cell.x] = GridConfig.Kind.DECK
		seg.heights[cell.y][cell.x] = 0

	# THE REWARDS, in whichever dead ends survived.
	#
	# A HAT FIRST, AND AT LEAST ONE ALWAYS. Hats are the score, so the hat is what
	# makes a maze worth entering rather than a delay between the sections that
	# have something in them -- every other section pays in hats and this one has
	# no hazard to drop them. The heart comes second because it is the reward that
	# only matters on a bad run, and a maze with nothing but hearts in it is a maze
	# a healthy party walks straight through.
	var kept: Array = []
	for j in rows:
		for i in cols:
			if _maze_degree(open_cells, Vector2i(i, j)) == 1:
				kept.append(Vector2i(i, j))
	for n in mini(kept.size(), MAZE_DEAD_ENDS):
		var at: Vector2i = kept[n]
		seg.contents[2 + 2 * at.y][2 * at.x] = \
			GridConfig.Content.HEART if n == 1 else GridConfig.Content.HAT

	_maze_traps(seg, open_cells, cols, rows, salt,
		Vector2i((in_door) / 2, 0), Vector2i((out_door) / 2, rows - 1), kept)

	# AND IF THE BRAID LEFT NO DEAD END AT ALL, the hat goes at the DEEPEST point
	# instead -- the cell furthest from the entrance by actual walking distance
	# through the maze, not by straight line.
	#
	# IT DOES NOT FIRE AT THE CURRENT TUNING, and that is written down rather than
	# assumed: A/B'd 2026-08-16 by deleting this branch, and 250 sections stayed
	# green -- no maze at MAZE_BRAID = 6 came out with zero dead ends. So it is
	# insurance against the dial moving, not a path the sweep exercises, and
	# `_maze_deepest` is unit-tested directly in test_segment_gen for that reason.
	# An untested branch that only runs after somebody retunes a constant is the
	# branch most likely to be wrong on the day it matters.
	if kept.is_empty():
		var deep: Vector2i = _maze_deepest(open_cells, cols, rows,
			Vector2i((in_door - 1) / 2, 0))
		seg.contents[2 + 2 * deep.y][2 * deep.x] = GridConfig.Content.HAT
	# A MAZE JOINS THE RUN LIKE ANY OTHER SECTION. Its lattice keeps the full
	# canvas -- a maze is a different kind of place and its outer columns are WALL
	# rather than edge -- but the rows it is entered and left by are the baseline,
	# so the mouth is the same width as the bridge that leads to it.
	_baseline_end_rows(seg)
	return seg

# The lattice cell furthest from `from` by walking distance. A breadth-first walk
# over the carved links, which is the only measure that means anything in a maze:
# the cell across the wall from the entrance may be a two-minute detour away.
static func _maze_deepest(open_cells: Dictionary, cols: int, rows: int,
		from: Vector2i) -> Vector2i:
	var seen: Dictionary = {from: true}
	var queue: Array = [from]
	var last: Vector2i = from
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		last = cell
		for d in 4:
			var n: Vector2i = cell + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows or seen.has(n):
				continue
			if not open_cells.has(_maze_between(cell, n)):
				continue
			seen[n] = true
			queue.append(n)
	return last

# Traps, on corridor cells only, spaced apart and never on a door cell or a
# reward. `entry` and `exit` are lattice coordinates.
static func _maze_traps(seg, open_cells: Dictionary, cols: int, rows: int,
		salt: int, entry: Vector2i, exit_cell: Vector2i, rewards: Array) -> void:
	var taken: Dictionary = {entry: true, exit_cell: true}
	for r in rewards:
		taken[r] = true

	# NOT ON TOP OF EACH OTHER, and not next to each other either. Spikes beside a
	# timed floor is a hazard aimed at somebody standing still waiting for the
	# floor to come back -- the same complaint that got hazards banned from beside
	# a lift, arriving by a different route.
	var placed: Array = []
	var wanted: Array = []
	for _t in MAZE_TIMED:
		wanted.append(GridConfig.Content.TIMED)
	for _v in MAZE_SPIKES:
		wanted.append(GridConfig.Content.SPIKES)

	for n in wanted.size():
		var kind: int = int(wanted[n])
		for attempt in 24:
			var i: int = _mix(salt + n * 3701 + attempt * 149) % cols
			var j: int = _mix(salt + n * 6229 + attempt * 271) % rows
			var here := Vector2i(i, j)
			if taken.has(here):
				continue
			var near := false
			for other in placed:
				if absi(int(other.x) - i) + absi(int(other.y) - j) <= 1:
					near = true
					break
			if near:
				continue
			seg.contents[2 + 2 * j][2 * i] = kind
			taken[here] = true
			placed.append(here)
			break

# The grid cell between two lattice neighbours -- the wall that separates them,
# and the single cell that carving a link writes.
static func _maze_between(a: Vector2i, b: Vector2i) -> Vector2i:
	return Vector2i(a.x + b.x, 2 + a.y + b.y)

# How many of a lattice cell's four walls have been carved.
static func _maze_degree(open_cells: Dictionary, cell: Vector2i) -> int:
	var n: int = 0
	for d in 4:
		if open_cells.has(_maze_between(cell, cell + GridConfig.DIR_CELLS[d])):
			n += 1
	return n

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

# --- The edge profile (M22) ---------------------------------------------------

# HOW FAR AN EDGE MAY MOVE IN ONE ROW.
#
# A cap, not a style choice. Deck thickness is derived from a cell's EIGHT
# neighbours (SegmentBuilder.cell_underside), so an edge that jumps several
# columns in a row leaves solid cells whose newly-exposed underside has nothing
# beneath it -- which is the tapered-shape trap that already cost this project a
# ramp with a knife edge over a DECK_THICKNESS-deep void. One column per row also
# happens to be the discipline the HEIGHT profile already keeps, so a bridge
# narrows at the rate it climbs and reads as one material.
const INSET_RATE := 1

# ROWS HELD AT FULL WIDTH AT EACH END. The entry and exit rows join the
# neighbouring segment, and the join contract (M17) plus the round boundary bands
# (M16) both want them solid across. Two rather than one so the taper has
# somewhere to finish rather than ending abruptly on the join itself.
const INSET_END_ROWS := 2

# HOW MANY ROWS ONE COLUMN OF WIDTH CHANGE TAKES.
#
# INSET_RATE is the correctness FLOOR -- never steeper than a column per row.
# This is the FEEL, and the two are different questions. Built at the floor, a
# three-column setback completes in three rows: six metres, which a player crosses
# in a second and reads as the bridge snapping rather than tapering. Spread over
# two to six rows per column the same setback takes 12 to 36 m, which is a shape
# you watch arrive.
#
# A RANGE, AND ROLLED PER EDGE. A fixed stride would make every transition in the
# game the same slope, which is the shape of the problem this milestone started
# with -- one number, applied everywhere, so nothing varies.
const INSET_STEP_ROWS_MIN := 2
const INSET_STEP_ROWS_MAX := 6

# The deepest either edge may ever be cut, as a pure function of the width.
#
# PURE ON PURPOSE. `safe` -- the columns a ramp or a lift may occupy -- needs this
# bound BEFORE any profile exists, which is what lets the profile be built last,
# with the lift rows it must pass through already known. Bounded so a section
# never closes to a thread: at a 21 canvas this is 6, so the narrowest deck is
# 21 - 2*6 = 9 cells and the widest is the full 21.
static func _edge_inset_bound(width: int) -> int:
	var base: int = mini(GridConfig.BASELINE_INSET, maxi(0, width / 2 - 2))
	return base + maxi(1, width / 7)

# One edge's inset, per row: how many columns of THIS side are cut away.
#
# WAYPOINTS AND RAMPS, not events-then-cap. The first version rolled flat setback
# BANDS and let a two-pass minimum cone discover the taper, which meant every
# transition came out at the steepest slope the rules allow -- the cone's whole
# job is to find the largest profile that fits, so it always tapers as late and
# as hard as it can. Correct, and it reads as the bridge snapping.
#
# So the shape is stated instead of derived: a handful of waypoints, each a row
# and an inset, joined by straight ramps. The gradient is then whatever the
# spacing gives, and the spacing is what `stride` controls.
#
# IT MOVES IN BOTH DIRECTIONS. A waypoint deeper than BASELINE_INSET is a pinch,
# shallower is the deck opening out past its usual width, and both are the same
# arithmetic. Before the canvas grew, only the first was expressible at all.
static func _edge_profile(width: int, length: int, salt: int) -> Array:
	var base: int = mini(GridConfig.BASELINE_INSET, maxi(0, width / 2 - 2))
	var deepest: int = _edge_inset_bound(width)
	var stride: int = INSET_STEP_ROWS_MIN \
		+ _mix(salt + 811) % maxi(1, INSET_STEP_ROWS_MAX - INSET_STEP_ROWS_MIN + 1)

	# --- The waypoints, in row order ------------------------------------------
	#
	# Always opening and closing at the baseline: that is what makes every segment
	# boundary in the game the same familiar width, and it is what an authored
	# file (padded to the baseline) joins onto.
	var at: Array = [0]
	var to: Array = [base]

	# ONE OR TWO ROLLED EVENTS PER SIDE. Zero is a straight section at the
	# baseline, which is still wanted and arrives on its own when a roll lands
	# somewhere the ordering below discards.
	var marks: Array = []
	var events: int = 1 + _mix(salt) % 2
	for e in events:
		marks.append(INSET_END_ROWS
			+ _mix(salt + e * 7919) % maxi(1, length - 2 * INSET_END_ROWS))
	marks.sort()

	for row in marks:
		var r: int = clampi(int(row), INSET_END_ROWS, length - 1 - INSET_END_ROWS)
		# STRICTLY INCREASING, or the interpolation below walks backwards over rows
		# it has already written. Two events that rolled the same row is the
		# ordinary case, not an edge one.
		if r <= int(at[at.size() - 1]):
			continue
		at.append(r)
		to.append(_mix(salt + r * 15485863) % (deepest + 1))
	at.append(length - 1)
	to.append(base)

	# --- The gradient is the constraint, so the WAYPOINTS give way -------------
	#
	# Each interior waypoint is pulled toward its neighbours until every leg is
	# walkable at one column per `stride` rows: forward so it is reachable from
	# the one before, backward so the profile can still get home to the baseline.
	# A section that cannot afford the setback it rolled gets a smaller one -- a
	# bridge that narrows less than intended is a shape, and one that narrows
	# faster than the gradient is the snap this whole rewrite exists to remove.
	for i in range(1, at.size() - 1):
		var back: int = (int(at[i]) - int(at[i - 1])) / stride
		to[i] = clampi(int(to[i]), int(to[i - 1]) - back, int(to[i - 1]) + back)
	for i in range(at.size() - 2, 0, -1):
		var fwd: int = (int(at[i + 1]) - int(at[i])) / stride
		to[i] = clampi(int(to[i]), int(to[i + 1]) - fwd, int(to[i + 1]) + fwd)

	# --- Joined by straight ramps ----------------------------------------------
	var out: Array = []
	out.resize(length)
	for i in range(at.size() - 1):
		var z0: int = int(at[i])
		var z1: int = int(at[i + 1])
		var v0: int = int(to[i])
		var v1: int = int(to[i + 1])
		var gap: int = maxi(1, z1 - z0)
		for z in range(z0, z1 + 1):
			out[z] = int(round(lerpf(float(v0), float(v1),
				float(z - z0) / float(gap))))

	# --- The ends, held flat ---------------------------------------------------
	for i in mini(INSET_END_ROWS, length):
		out[i] = base
		out[length - 1 - i] = base
	# Stride is a preference and the waypoints may not have left room for it, so
	# the ends get the same outward clamp they always did -- which is also what
	# repairs the two rows just forced flat.
	return _pin_ends(out, base)

# THE ENDS ARE A HARD CONSTRAINT AND THE CONE IS A SOFT ONE, so the cone cannot
# be the last word.
#
# `_cone` takes a MINIMUM, which means a widening event near either end reaches
# back and drags the pinned end open with it -- a target of 0 two rows in pulls
# row 0 down to 2 whatever it was pinned to. Forcing the end back afterwards then
# leaves a step at row 1, which is precisely the jump INSET_RATE exists to
# forbid. Measured before this existed: 19 rate breaks over 60 sections, and the
# diagnostic said `lift?false end?true` for every single one.
#
# So the ends are re-pinned and the rows next to them are dragged into line
# instead: forward from the pinned start (which makes the whole array Lipschitz),
# then pin the far end and walk backward (which repairs the far end, and only
# perturbs its own neighbourhood because the forward pass already made everything
# else consistent).
static func _pin_ends(profile: Array, base: int) -> Array:
	var out: Array = profile.duplicate()
	var n: int = out.size()
	if n < 2:
		return out
	for i in mini(INSET_END_ROWS, n):
		out[i] = base
	for z in range(1, n):
		out[z] = clampi(int(out[z]),
			int(out[z - 1]) - INSET_RATE, int(out[z - 1]) + INSET_RATE)
	for i in mini(INSET_END_ROWS, n):
		out[n - 1 - i] = base
	for z in range(n - 2, -1, -1):
		out[z] = clampi(int(out[z]),
			int(out[z + 1]) - INSET_RATE, int(out[z + 1]) + INSET_RATE)
	return out

# `_cone` LIVED HERE AND IS GONE (2026-08-20). It found the taper by taking a
# two-pass minimum over a profile of flat setback bands -- which is correct, and
# always produced the STEEPEST taper the rate cap allows, because finding the
# largest profile that fits means tapering as late and as hard as possible. The
# waypoints-and-ramps construction above states the gradient instead of
# discovering it. Recorded rather than silently deleted: the cone was right for
# the question it was asked, and the question changed.

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
