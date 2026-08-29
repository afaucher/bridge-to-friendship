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
const BusBody = preload("res://scripts/sim/bus_body.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")

# THE LOBBY'S OWN FLOOR, independent of its neighbours. A lobby that merely fits
# the section either side could come out three cells wide, and that is not a
# lobby -- it is a corridor with a rack in it. The number is set by what the
# space is FOR: four players standing around without shoving each other off, a
# rack that reads as a row of choices rather than a queue, and room to walk past
# somebody who is deciding.
const LOBBY_MIN_WIDTH := 11
const LOBBY_LENGTH := 12

# HOW LONG A BLANK ZONE IS. Mid-range for a generated section (they run 14 to 21),
# so a zone reads as a section-sized stretch of nothing rather than as a pause.
const BLANK_ZONE_ROWS := 16
# Two rows deep at each end, per M16: one row is 2 m, and a party of four told to
# gather on it is four players jostling on a strip narrower than they are.
const GATE_DEPTH := 2

# The longest a piece may be, mirrored from SetPieces so the profile loop can
# reserve room before it has picked one. Checked again against the actual pick,
# because a mirrored constant is a constant that can drift.
const MAX_PIECE_ROWS := SetPieces.MAX_ROWS

# HOW OFTEN A ROW THAT COULD CARRY A PATCH DOES. Its own roll, separate from the
# full-width piece above it, because a patch is the thing a player is meant to
# MEET -- a tower they never encounter is a tower that does not exist. Tuned
# against the measured encounter rate rather than picked: see test_piece_rate.
const PATCH_ONE_IN := 3

# --- Split plateaus (M23 phase 2) ---------------------------------------------

# HOW FAR THE TWO HALVES MAY DIVERGE. Bounded at two units because the drop back
# down is taken by falling, and because the whole point is a route CHOICE rather
# than a cliff: at three or more the low side stops being an alternative and
# starts being a place you cannot see out of.
const SPLIT_RISE_MAX := 2

# HOW LONG THEY STAY APART. Under about three rows the split is over before a
# player has decided anything, which makes it read as a bump rather than as two
# routes; much beyond six and one section is nothing else.
const SPLIT_HOLD_MIN := 3
const SPLIT_HOLD_MAX := 6


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
	var post_row: int = seg.length - GATE_DEPTH - 2
	var post_x: int = seg.width / 2
	if post_row > GATE_DEPTH and seg.is_solid(post_x, post_row):
		seg.contents[post_row][post_x] = GridConfig.Content.MODE_POST

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
# A SERPENTINE TRACK FOR THE BUS. M25 phase 3, the skeleton.
#
# THE LONG RUNS ARE LATERAL. Full-width lanes stacked up-bridge, joined at
# ALTERNATING ends by a narrow link, so the only way forward is to drive the width
# of the canvas, turn, and drive back. Rows still advance monotonically -- nothing
# doubles back, which is what the leash, the checkpoint, `rear_row`/`target_row`
# and the front wall all require -- but almost none of the DRIVING is up-bridge.
#
# IT MULTIPLIES THE TRACK BY THE LANE COUNT, which is the point. A 28-row segment
# is 56 m of bridge and about 300 m of driving, so terrain worth authoring is not
# over in three seconds.
#
# THE TURN ROWS ARE THE SPEED LIMIT, and that is the whole tuning dial. A 180
# degree turn sweeps a semicircle ACROSS the direction of travel, so what bounds
# it is the ROW DEPTH between two lanes, not how far the bay reaches sideways.
# Above about 5.9 m/s the bus turns at a flat TURN_RATE, so the fastest speed that
# can be carried through a link is `TURN_ROWS * CELL_SIZE * TURN_RATE / 2`:
#
#     4 rows -> 7.6 m/s      6 rows -> 11.4 m/s      8 rows -> 15.2 m/s
#
# Set it below the bus's top speed and every hairpin demands a lift; set it above
# and nobody ever brakes. That braking decision is the only driving skill the mode
# has, so this number is the mode.
#
# NO HEIGHT CHANGES, so the ordinary walking validator can still certify it -- a
# serpentine is crossable on foot. The per-mode traversal model the plan warns
# about is still owed, but not by this shape.
# THE BANDS ARE ROLLED PER BAND, NOT FIXED. The first version had exactly one bit
# of variation -- which end the first link was on -- so every section was the same
# shape or its mirror, and three previews side by side were three identical
# pictures. A generator with one bit is a layout with a coin flip attached.
#
# WHAT VARYING THE LINK DEPTH BUYS IS THE WHOLE POINT: it is the speed limit, so
# rolling it per corner means some corners are taken flat and some demand a lift.
# A track whose every corner is the same corner has one decision in it, made once.
const TRACK_ROWS_MIN := 24
const TRACK_ROWS_MAX := 32
# The straight. Longer lanes are more speed carried into the next corner.
const TRACK_LANE_MIN := 3
const TRACK_LANE_MAX := 6
# The corner. 4 rows is 7.6 m/s and 7 is 13.3 -- so this range spans "brake hard"
# to "take it flat" against a top speed of 13.
const TRACK_TURN_MIN := 4
const TRACK_TURN_MAX := 7
# How far the link reaches in from its end. Room to swing the nose through, and
# nothing to do with the speed limit -- see the note above.
const TRACK_BAY_MIN := 5
const TRACK_BAY_MAX := 8

# HOW MANY LINKS A SECTION MUST HAVE, and it is not a taste number.
#
# ONE LINK IS A STRAIGHT THROUGH-ROUTE. Links alternate ends, so a column solid at
# a right-hand link is void at the next left-hand one -- with two, no column
# survives both. With ONE, every column in its bay is solid end to end and the bus
# drives up the middle, and the serpentine becomes decoration.
#
# It regressed exactly that way the moment lanes got tall enough that only one
# link fitted in a 30-row section, and `test_bus_track` caught it by asking a
# property of the OUTPUT -- no column solid end to end -- rather than by trusting
# the layout arithmetic that produced it.
const TRACK_MIN_LINKS := 2

# WHAT A LANE IS LIKE. The skeleton makes every lane a plain full-width straight;
# these are what make one lane different from the next.
#
# A CHARACTER IS APPLIED TO A LANE, NEVER TO A LINK. A link is the corner and the
# corner is already the decision -- narrowing one, or putting a shooter in one,
# takes the one moment the driver has no attention to spare and adds something
# else to it.
#
# AND EVERY CHARACTER LEAVES THE ENDS ALONE. The last `bay` columns at each end
# are where the lane meets its links, so a character that carved them would
# disconnect the track -- and `bus_track` does NOT reroll, so that would produce a
# BROKEN section rather than none. The crossability assertion in test_bus_track is
# what catches it, which is the right way round: a rejection oracle would have
# turned it into a silent absence.
const LANE_PLAIN := 0
const LANE_STRIP := 1
const LANE_WAVE := 2
const LANE_GAUNTLET := 3
const LANE_KINDS := [LANE_PLAIN, LANE_STRIP, LANE_WAVE, LANE_GAUNTLET]

# How deep the fast strip is, in rows. Two rows is 4 m against a bus 1.1 m wide --
# tight enough to be a line to hold and not so tight that a lean puts you off it.
const STRIP_ROWS := 2
# How far apart the timed blocks sit along it. Wide enough that they read as a
# rhythm rather than as a wall.
const STRIP_BLOCK_STEP := 5
# How far the wave wanders, in rows, either side of the band's middle.
# How deep the road stays while it wanders. Three rows is 6 m against a bus 1.1 m
# wide -- a lane you steer along rather than a ribbon you thread.
const WAVE_BAND := 3
# ONE GENTLE S ACROSS THE LANE, not a slalom. A full cycle is twice this, so 10
# gives roughly one cycle over a 21-cell canvas.
#
# It was 4, which is 2.6 cycles across the width -- and traced column by column
# that really was a coherent three-row ribbon, just one that zigzagged every four
# cells. Correct, unreadable, and undrivable: at 13 m/s the bus covers four cells
# in half a second and could not follow it. "The wave looks like noise" turned out
# to mean "the wave is right and far too fast".
const WAVE_PERIOD := 10
# Cells between shooters on a gauntlet lane.
const GAUNTLET_STEP := 6

# A NARROW STRIP YOU HOLD A LINE ON, with timed floor along it. The fast lane:
# nothing to steer around, everything to time.
static func _lane_strip(seg, z0: int, rows: int, ends: int) -> void:
	if rows <= STRIP_ROWS:
		return
	var keep_from: int = z0 + (rows - STRIP_ROWS) / 2
	for z in range(z0, z0 + rows):
		if z >= keep_from and z < keep_from + STRIP_ROWS:
			continue
		for x in seg.width:
			# THE ENDS STAY FULL DEPTH, so the strip opens out where it meets each
			# corner. That is also what keeps it connected -- see the note above.
			if x < ends or x >= seg.width - ends:
				continue
			seg.kinds[z][x] = GridConfig.Kind.HOLE
	var mid: int = keep_from + STRIP_ROWS / 2
	var x2: int = ends + 2
	while x2 < seg.width - ends - 2:
		if seg.is_solid(x2, mid):
			seg.contents[mid][x2] = GridConfig.Content.TIMED
		x2 += STRIP_BLOCK_STEP

# A BAND THAT WANDERS. The same width of road, not going where you expect it --
# so the line through it is a curve rather than a straight.
static func _lane_wave(seg, z0: int, rows: int, ends: int, salt: int) -> void:
	# THE AMPLITUDE TAPERS TO NOTHING AT BOTH ENDS rather than the ends being left
	# flat, and that is what makes this read as a curve at all.
	#
	# Leaving `ends` columns untouched -- the same trick the strip uses -- left only
	# `width - 2*bay` columns to wave across, which at a bay of 5 to 8 is between 5
	# and 11. A wave needs many more columns than that to look like one, and the
	# preview showed exactly what few columns give you: scattered holes.
	#
	# Tapering keeps the one thing `ends` was protecting. The band has to reach the
	# lane's top and bottom rows where the links meet it, or the track is cut in
	# two -- and a taper reaches full depth at both ends by construction, so it
	# connects for the same reason a flat end did, while still waving across almost
	# the whole width.
	# THE ROAD IS NARROW AND THE WANDER IS WIDE, which is the whole geometry of a
	# curve and took three attempts to get right. Tying the band to `rows - amp`
	# left a road 4 to 6 rows deep inside a lane of 7 to 9 -- so only about three
	# rows were ever carved, split between the top and the bottom, and it rendered
	# as a wide road with nibbled edges rather than as a road that goes somewhere.
	#
	# Fixing the ROAD at WAVE_BAND and giving the wander everything else inverts
	# that: a three-row ribbon inside a nine-row lane has six rows to move through.
	var band: int = mini(WAVE_BAND, rows - 2)
	var amp: int = rows - band
	if amp < 2:
		return
	var taper: int = maxi(1, ends)
	for x in seg.width:
		# How much of the amplitude this column gets: none at the very ends, all of
		# it once clear of them.
		var from_end: int = mini(x, seg.width - 1 - x)
		if from_end <= 0:
			continue
		var local_amp: int = amp * mini(from_end, taper) / taper
		if local_amp < 1:
			continue
		var phase: int = (x + salt) % (WAVE_PERIOD * 2)
		var lift: int = phase if phase < WAVE_PERIOD else WAVE_PERIOD * 2 - phase
		var offset: int = lift * local_amp / WAVE_PERIOD
		for z in range(z0, z0 + rows):
			var inside: bool = z >= z0 + offset and z < z0 + offset + band + (amp - local_amp)
			if not inside:
				seg.kinds[z][x] = GridConfig.Kind.HOLE

# SHOOTERS DOWN BOTH SIDES. Full width, nothing to hit -- the lane is a straight
# and the threat is that crossing it takes time.
#
# NO COVER, AND THAT IS NOT AN OVERSIGHT. The authoring rules say cover pairs with
# shooters, and they are right about a WALKING player: a gallery with nothing to
# hide behind is a punishment. A bus cannot take cover -- it cannot stop, and a
# tree is something it crashes into at 13 m/s. Its answers are speed and the
# passengers' own guns, which is why the driver gives up the trigger. Cover here
# would be scenery that kills you.
# WHETHER A WHOLE PACK HAS SOMEWHERE TO STAND. A grave is the only content in
# this game that occupies its NEIGHBOURS as well as its own cell, so "is this cell
# solid and empty" -- the question every other placement asks -- is the wrong
# question for it by eight cells.
#
# Asked of the footprint rather than trusting an inset, because the inset is
# right for a lane edge and says nothing about a hole the wave carved two cells
# in. Cheap, and it means a new lane character cannot reintroduce this.
static func _pack_fits(seg, x: int, z: int) -> bool:
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var cx: int = x + dx
			var cz: int = z + dz
			if cx < 0 or cx >= seg.width or cz < 0 or cz >= seg.length:
				return false
			if not seg.is_solid(cx, cz):
				return false
	return seg.content_at(x, z) == GridConfig.Content.NONE

static func _lane_gauntlet(seg, z0: int, rows: int, ends: int, salt: int) -> void:
	var top: int = z0
	var bottom: int = z0 + rows - 1
	var x2: int = ends + 1
	var flip: bool = salt % 2 == 0
	while x2 < seg.width - ends - 1:
		var z: int = top if flip else bottom
		if seg.is_solid(x2, z) and seg.content_at(x2, z) == GridConfig.Content.NONE:
			seg.contents[z][x2] = GridConfig.Content.SKIRMISHER
		# A GRAVE ON THE FAR SIDE, so the lane threatens from both edges at once
		# and a bus down the middle is inside the pincer rather than hugging the
		# safe rail. A pack rises as you pass and the passengers have to answer it
		# while the driver keeps going -- which is the division of labour the bus
		# exists for, and the first thing on the track that tests it.
		#
		# OFFSET BY HALF A STEP so a grave never shares a column with the shooter
		# opposite it: two threats on the same line is one moment, and two threats
		# a beat apart is two.
		# ONE ROW IN FROM THE EDGE, because a grave is not one cell. It raises a
		# PACK across its own neighbours, so one on the outermost row of a lane
		# puts half its zombies over the void beyond it -- and `SegmentValidator`
		# says so rather than letting it through, which is the oracle earning its
		# keep on the first thing that ever needed it here.
		var gz: int = (bottom - 1) if flip else (top + 1)
		var gx: int = x2 + GAUNTLET_STEP / 2
		if rows >= 3 and gx < seg.width - ends - 1 and _pack_fits(seg, gx, gz):
			seg.contents[gz][gx] = GridConfig.Content.GRAVE
		flip = not flip
		x2 += GAUNTLET_STEP

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
	return low + _mix(salt + band * kind) % (high - low + 1)

# HOW DEEP A LANE OF THIS CHARACTER WANTS TO BE. Rolled AFTER the character rather
# than before it, because the two are not independent.
#
# A WAVE IN A THREE-ROW LANE IS NOT A CURVE. It can wander one row, over eleven
# carveable columns, which renders as scattered holes and drives as nothing at
# all -- the first version did exactly that and the preview showed noise. A wave
# needs room to wander in, so it asks for one.
#
# A STRIP needs room to be NARROW in: carving two rows out of three leaves a lane
# that was already thin. GAUNTLET and PLAIN are straights and do not care.
# The shallowest band a character still reads in. Below it the character is
# dropped rather than drawn badly.
static func _lane_min_rows(kind: int) -> int:
	match kind:
		LANE_WAVE:
			return 6
		LANE_STRIP:
			return 5
	return TRACK_LANE_MIN

static func _lane_rows_for(kind: int, salt: int, band: int) -> int:
	match kind:
		LANE_WAVE:
			return _band_roll(salt, band, 40503, 7, 9)
		LANE_STRIP:
			return _band_roll(salt, band, 40503, 5, 7)
	return _band_roll(salt, band, 40503, TRACK_LANE_MIN, TRACK_LANE_MAX)

# One lane, dressed. Split out so the generator reads as layout and this reads as
# character, and so a new flavour is an entry here rather than a branch in there.
static func _apply_lane(seg, z0: int, rows: int, ends: int, kind: int, salt: int) -> void:
	match kind:
		LANE_STRIP:
			_lane_strip(seg, z0, rows, ends)
		LANE_WAVE:
			_lane_wave(seg, z0, rows, ends, salt)
		LANE_GAUNTLET:
			_lane_gauntlet(seg, z0, rows, ends, salt)

static func bus_track(width: int, run_seed: int, index: int):
	var w: int = maxi(width, LOBBY_MIN_WIDTH)
	var salt: int = _mix(run_seed + index * 6151)
	var length: int = TRACK_ROWS_MIN + salt % (TRACK_ROWS_MAX - TRACK_ROWS_MIN + 1)
	var seg = _blank("track_%d" % index, w, length)
	var track_tags: Array[String] = ["foot", "generated", "track"]
	seg.tags = track_tags
	# The dressing pass would scatter bridge hazards over a race track. What goes
	# on a lane is the lane's own business and belongs to the character library
	# that comes next, not to layer 3.
	seg.no_dress = true

	# ENTRY AND EXIT ARE FULL-WIDTH PLATES, left as `_blank` made them: the join
	# contract wants a solid column on both sides of the seam, and a party arrives
	# at the entry row from anywhere across it.
	var z: int = 1
	var band: int = 0
	# WHICH END THE FIRST LINK IS AT, so consecutive sections do not all open the
	# same way.
	var right: bool = salt % 2 == 0
	while true:
		# ROLLED FROM (seed, index, band), so the same section is the same track on
		# every machine -- the bridge is a pure function of the seed and a track
		# that varied per client would be a different level for each player.
		# THE CHARACTER FIRST, then the depth it wants. See _lane_rows_for.
		var kind: int = _band_roll(salt, band, 8191, 0, LANE_KINDS.size() - 1)
		var lane: int = _lane_rows_for(kind, salt, band)
		var turn: int = _band_roll(salt, band, 104729, TRACK_TURN_MIN, TRACK_TURN_MAX)
		var bay: int = _band_roll(salt, band, 2654435, TRACK_BAY_MIN, TRACK_BAY_MAX)
		bay = mini(bay, seg.width - 2)
		# ROOM RESERVED FOR THE LINKS STILL OWED, AND THE LAST ONE SHRINKS TO FIT.
		#
		# One link is a straight through-route (see TRACK_MIN_LINKS), so the layout
		# has to guarantee two. Reserving rows for them is half the job: the first
		# attempt reserved `TRACK_LANE_MIN + TRACK_TURN_MIN` and then let the next
		# band roll a MAXIMUM turn into that minimum reservation, so the second link
		# did not fit, the loop broke, and a section came out with one link and
		# eight columns running end to end.
		#
		# So the turn is clamped to what is actually left rather than the band being
		# abandoned. A shallower final corner is a faster corner, which is a fine
		# thing for a section to end on; no second corner at all is not.
		var space: int = length - 1 - z
		var owed: int = maxi(0, TRACK_MIN_LINKS - band - 1)
		var reserve: int = owed * (TRACK_LANE_MIN + TRACK_TURN_MIN)
		lane = mini(lane, space - TRACK_TURN_MIN - reserve)
		if lane < TRACK_LANE_MIN:
			break
		# A CHARACTER THAT NO LONGER FITS ITS OWN BAND GIVES WAY. A wave clamped to
		# three rows is the fragmented noise this shape started as; a plain straight
		# is an honest lane.
		if lane < _lane_min_rows(kind):
			kind = LANE_PLAIN
		turn = mini(turn, space - lane - reserve)
		if turn < TRACK_TURN_MIN:
			break
		_apply_lane(seg, z, lane, bay, kind, salt + band)
		z += lane
		# The link: solid only at one end, void across the rest. This is what makes
		# the serpentine FORCED rather than suggested -- with the lane either side
		# full width, the link is the only cell that advances.
		for k in turn:
			for x in seg.width:
				var inside: bool = x >= seg.width - bay if right else x < bay
				if not inside:
					seg.kinds[z + k][x] = GridConfig.Kind.HOLE
		z += turn
		right = not right
		band += 1
	_place_bus_post(seg)
	# ARMED MINES, on the serpentine as well as on the circuit. Same scatter, and
	# no gates to keep clear of here.
	_scatter_mines(seg, salt, [])
	return seg

static func track_speed_limit(turn_rows: int) -> float:
	return float(turn_rows) * GridConfig.CELL_SIZE * BusBody.TURN_RATE * 0.5

static func blank_zone(width: int, run_seed: int, index: int):
	var length: int = BLANK_ZONE_ROWS
	var seg = _blank("blank_%d" % index, maxi(width, LOBBY_MIN_WIDTH), length)
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
	_place_bus_post(seg)
	return seg

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
	# WHERE THE PIECE STARTS ACROSS THE BRIDGE (M23 phase 3). Always 0 for a
	# canvas-wide piece, which is every piece that existed before patches.
	var piece_x: Array = []
	# A PATCH AND A FULL-WIDTH PIECE ARE DIFFERENT BUDGETS (M23, 2026-08-21).
	#
	# "ONE PER SECTION" was written for a piece that OWNS its rows: a section is
	# 16 rows and a piece is 4 to 8 of them, so two would leave almost no
	# generated terrain between them. A patch leaves the terrain either side of it
	# intact, so that argument barely applies -- and holding both to one slot,
	# picked uniformly from eleven pieces, is why a tower turned up in 2.9% of
	# sections. A round is five sections, so a player met one about once every
	# seven rounds. Reported as "still nothing that really looks like a tower... I
	# am just not seeing anything like that", with the height explicitly fine.
	#
	# So they roll separately and a section may carry one of each.
	var wide_pieces: Array = []
	var patches: Array = []
	# PINNED, IF SOMEBODY IS TRYING TO LOOK AT ONE. See the `force_piece` knob:
	# a specific piece turns up in a few per cent of sections, so reviewing the
	# one you just authored means replaying rounds until it happens.
	var forced: String = DebugSettings.get_choice_name("force_piece")
	# AND THEY COME FROM THIS SECTION'S THEME, not the whole library. Every piece
	# has carried a theme tag since M18 and nothing read them, so a rusher pit
	# landed in a `quiet` section as readily as a survival one. The theme is a
	# pure function of (run_seed, index) and both are in hand, so this asks
	# HazardDressing rather than taking another argument -- which keeps the
	# skeleton and the dressing pass agreeing about which theme a section is by
	# construction rather than by two callers being careful.
	for candidate in SetPieces.for_theme(width,
			HazardDressing.theme_for(run_seed, index)):
		if forced != "off" and String(candidate.name) != "piece_" + forced:
			continue
		if SetPieces.is_patch(candidate, width):
			patches.append(candidate)
		else:
			wide_pieces.append(candidate)
	var placed = null
	var patched = null

	# THE TWO HALVES OF THE DECK AT DIFFERENT HEIGHTS (M23 phase 2).
	#
	# Recorded as EVENTS and applied after the loop rather than appended row by
	# row, because `low`, `ramp_h`, `ramp_x0`, `ramp_w`, `lift_x`, `lift_h` and
	# the three piece arrays are already nine parallel appends at five separate
	# sites, and adding two more to each is nine chances to get one wrong in a way
	# that silently misaligns every row after it.
	#
	# Each entry is {from, to, at, up}: the rows the split covers, the column it
	# divides at, and how much higher the RIGHT side is than the left (signed, so
	# one field covers both directions).
	var splits: Array = []
	var did_split := false

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
			piece_x.append(0)
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
		# TWO OFFERS, ONE STAMP. `elif` so a single pass places at most one piece,
		# while a section may still end up with one of each across passes.
		var pick = null
		if placed == null and not wide_pieces.is_empty() 				and row + MAX_PIECE_ROWS + 2 <= length 				and (forced != "off" or _mix(salt + row * 3571) % 4 == 0):
			pick = wide_pieces[_mix(salt + row * 5023) % wide_pieces.size()]
		elif patched == null and not patches.is_empty() 				and row + MAX_PIECE_ROWS + 2 <= length 				and (forced != "off" or _mix(salt + row * 2909) % PATCH_ONE_IN == 0):
			pick = patches[_mix(salt + row * 6763) % patches.size()]
		if pick != null:
			# WHERE IT SITS ACROSS THE BRIDGE (M23 phase 3). A canvas-wide piece has
			# exactly one answer -- column 0 -- and that is the case this has always
			# been. A PATCH is narrower than the section, so it needs choosing, and it
			# has to land on ground that is solid for every one of its rows: `safe` is
			# already that guarantee for ramps and lifts, so it is that guarantee here
			# too rather than a second rule that can disagree with it.
			# WHETHER IT FITS IS DECIDED HERE; WHERE IT SITS IS NOT.
			#
			# `safe` is the conservative corridor -- the columns solid at EVERY
			# profile this generator can produce -- so a spot in it proves the patch
			# can be placed at all, which is what this branch needs to know before
			# it spends rows. It is the wrong answer to "where", and that was the
			# bug: `safe` is FIXED at the worst-case inset while the deck MOVES with
			# the profile, so on any section whose two edges were cut by different
			# amounts the patch stayed pinned near the canvas centre while the deck
			# had shifted out from under it. Reported from play as "I don't see any
			# towers in the middle of the field -- all are to one side or the
			# other", and M22 made 38% of rows asymmetric, so it was most of them.
			#
			# The column is chosen after the profile exists. See `_place_patches`.
			var px: int = 0
			var fits := true
			if SetPieces.is_patch(pick, width):
				fits = false
				for col in safe:
					var run := true
					for k in pick.width:
						if not safe.has(int(col) + k):
							run = false
							break
					if run:
						fits = true
						break
			if fits and row + pick.length + 2 <= length:
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
					piece_x.append(px)
					row += 1
				# A PATCH NEVER MOVES THE DECK. Terrain runs past it on both sides at
				# `height`, so a patch that claimed an exit height would desync the
				# running plateau from the ground either side of itself. Refused at
				# load by `_check_piece`, and ignored here as the belt to that brace.
				if SetPieces.is_patch(pick, width):
					patched = pick
				else:
					height += int(pick.piece_exit)
					placed = pick
				continue

		# A SPLIT PLATEAU (M23 phase 2), offered before the climb roll for the same
		# reason a piece is: it IS a climb, and rolling the ordinary terrain first
		# would be deciding the same question twice.
		#
		# ONE PER SECTION. A split is 5 to 9 rows of a 14-to-21-row section, so two
		# would leave almost nothing between them and the section would read as a
		# staircase rather than as a place where the bridge divides.
		#
		# THE HIGH SIDE CLIMBS AND THE LOW SIDE DOES NOT, which is what makes this
		# expressible at all: `low[z]` has always been the height of the WHOLE row,
		# and the ramp band is the only thing that has ever disagreed with it. A
		# split is that disagreement made to last for more than a transition row.
		if not did_split and safe.size() >= 5 \
				and _mix(salt + row * 9721) % 4 == 0 \
				and row + SPLIT_RISE_MAX + SPLIT_HOLD_MIN + 2 <= length:
			var rise: int = 1 + _mix(salt + row * 4801) % SPLIT_RISE_MAX
			var hold: int = SPLIT_HOLD_MIN \
				+ _mix(salt + row * 6491) % maxi(1, SPLIT_HOLD_MAX - SPLIT_HOLD_MIN + 1)
			# TWO ROWS OF MARGIN AT THE END, exactly as a plain climb keeps: the exit
			# row is stamped flat by the fixup below, so a split still running when it
			# arrives is a split whose high half is silently levelled.
			hold = mini(hold, length - 2 - row - rise)
			if hold >= SPLIT_HOLD_MIN:
				# THE BOUNDARY, and then the ramp is confined to the high side of it.
				# A ramp on the LOW side would climb to a height its own half of the
				# deck does not have, which is a ramp leading nowhere -- the bug this
				# generator already paid for once at 23 of 239 ramp tops.
				var high_right: bool = _mix(salt + row * 5407) % 2 == 0
				var boundary: int = (int(safe[0]) + int(safe[safe.size() - 1])) / 2 + 1
				var lane: Array = []
				for col in safe:
					if high_right == (int(col) >= boundary):
						lane.append(int(col))
				if lane.size() >= 2:
					var sw: int = mini(_ramp_width(salt + row * 2237), lane.size())
					var sx0: int = _safe_ramp_x0(lane, sw, _mix(salt + row * 3319))
					sw = mini(sw, _safe_run_from(lane, sx0))
					# The climb, on the high side only. Ordinary cells stay down.
					for k in rise:
						low.append(height)
						ramp_h.append(height + k + 1)
						ramp_x0.append(sx0)
						ramp_w.append(sw)
						lift_x.append(-1)
						lift_h.append(0)
						piece_ref.append(null)
						piece_row.append(0)
						piece_base.append(0)
						piece_x.append(0)
						row += 1
					# The split proper: `low` carries the LEFT height and the event
					# carries the difference.
					var left_h: int = height if high_right else height + rise
					var up: int = rise if high_right else -rise
					splits.append({"from": row, "to": row + hold - 1,
						"at": boundary, "up": up})
					for _k in hold:
						low.append(left_h)
						ramp_h.append(-1)
						ramp_x0.append(0)
						ramp_w.append(0)
						lift_x.append(-1)
						lift_h.append(0)
						piece_ref.append(null)
						piece_row.append(0)
						piece_base.append(0)
						piece_x.append(0)
						row += 1
					# AND IT RECONVERGES BY FALLING. `height` never moved, so the row
					# after the split is level across at the plateau both halves
					# started from -- the high side simply drops, which costs nothing
					# because falling is free and is why a split needs one ramp rather
					# than two.
					did_split = true
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
				piece_x.append(0)
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
				piece_x.append(0)
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
		piece_x.append(0)

	# THE SPLIT EVENTS, EXPANDED TO ONE ENTRY PER ROW. Built here rather than
	# appended in the loop so the nine parallel arrays above stay nine.
	var split_at: Array = []
	var split_up: Array = []
	for _z in length:
		split_at.append(-1)
		split_up.append(0)
	for event in splits:
		for z in range(int(event["from"]), mini(length, int(event["to"]) + 1)):
			split_at[z] = int(event["at"])
			split_up[z] = int(event["up"])

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

	# WHERE EACH PATCH SITS, DECIDED NOW THAT THE DECK'S REAL EDGES ARE KNOWN.
	# See `_place_patches` -- this is the last thing settled about a patch, and it
	# has to be, because the profile it depends on is built below the loop.
	_place_patches(width, length, piece_ref, piece_x, left_inset, right_inset,
		split, salt)

	for z in length:
		# A CANVAS-WIDE PIECE IS STAMPED WHOLE, and before anything else looks at
		# the row. It wrote its own heights, kinds and contents; narrowing, ramps
		# and lifts have nothing to say about rows that are not theirs.
		#
		# A PATCH IS NOT, and that is the whole of M23 phase 3. It covers
		# `piece.width` columns starting at `piece_x[z]`, and the terrain either
		# side of it still needs every rule this loop applies -- the insets, the
		# lane split, the height split. So the `continue` cannot be taken.
		#
		# TWO AUTHORS, ONE RULE, WHICH IS THE PART WORTH SAYING OUT LOUD. The
		# comment on `piece_ref` warns that "building a skeleton and overwriting
		# part of it afterwards leaves every cell with two authors and no rule
		# about which wins", and names the bug that came of it: a ramp whose top row
		# was eaten by a piece. That warning is about the ABSENCE of a rule, not
		# about two authors. Here the rule is stated and is per-CELL: inside the
		# footprint the piece wins, outside it the terrain does, and no cell is
		# ever written by both.
		var piece = piece_ref[z]
		var patch_from: int = width
		var patch_to: int = width
		if piece != null:
			patch_from = int(piece_x[z])
			patch_to = patch_from + int(piece.width)
			if not SetPieces.is_patch(piece, width):
				var pz: int = int(piece_row[z])
				var base: int = int(piece_base[z])
				for x in width:
					seg.heights[z][x] = base + piece.height_at(x, pz)
					seg.kinds[z][x] = piece.kind_at(x, pz)
					seg.contents[z][x] = piece.content_at(x, pz)
				# RECORDED AS THE ROWS ARE WRITTEN, so the record cannot disagree
				# with what was stamped. Layer 3 reads it and keeps out.
				seg.piece_rows.append(z)
				seg.piece_footprints[z] = Vector2i(0, width)
				continue
			# A PATCH ROW IS STILL A PIECE ROW FOR THE DRESSING PASS. Coarser than
			# it needs to be -- only the footprint COLUMNS belong to the piece, and
			# the deck either side is ordinary ground a hazard could legitimately
			# stand on. Kept coarse deliberately: the alternative is a second,
			# per-cell record for layer 3 to read, and a keep-out that is too big
			# costs a few hazard slots while one that is too small lets somebody
			# else edit the composition.
			seg.piece_rows.append(z)
			seg.piece_footprints[z] = Vector2i(patch_from, patch_to)

		var cut_left: int = int(left_inset[z])
		var cut_right: int = int(right_inset[z])
		# THE LANE SPLIT SKIPS A LIFT ROW, for exactly the reason the inset does
		# (see the re-cone above): a rider is stationary and out of verbs, so the
		# one row where they cannot move stays whole. The insets are already zero
		# here by construction; the split is a separate mechanism and needs saying
		# separately.
		var split_here: bool = split and int(lift_x[z]) < 0
		for x in width:
			# INSIDE THE FOOTPRINT THE PIECE WINS (M23 phase 3). Written before the
			# terrain rather than over it, so no cell is ever authored twice and the
			# `continue` keeps every later rule off the patch's own columns.
			if x >= patch_from and x < patch_to:
				var ppz: int = int(piece_row[z])
				var pbase: int = int(piece_base[z])
				var lx: int = x - patch_from
				seg.heights[z][x] = pbase + piece.height_at(lx, ppz)
				seg.kinds[z][x] = piece.kind_at(lx, ppz)
				seg.contents[z][x] = piece.content_at(lx, ppz)
				continue

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
				# THE ONE LINE THAT MAKES A PLATEAU NARROWER THAN THE BRIDGE.
				# `low[z]` was the height of the whole row for the life of this
				# generator, so every height change was a horizontal line running
				# edge to edge and no section could ever divide. It is now the
				# height of the LEFT side, and a split row carries the difference.
				var h: int = int(low[z])
				if int(split_at[z]) >= 0 and x >= int(split_at[z]):
					h += int(split_up[z])
				seg.heights[z][x] = h

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
# SOLID cell in the outermost column. The boundary was being paid for twice.
#
# THE TWO WERE THE SAME HEIGHT WHEN THAT CHANGED, and are not any more:
# WALL_HEIGHT went to 1.0 on 2026-08-20 so the bridge reads as a structure rather
# than a trench, while a maze wall is still MAZE_WALL_HEIGHT (2 units). The
# argument survives the difference because it never rested on them matching --
# there is no jump and no step-up in this game, so a 1 m railing is exactly as
# impassable as a 2 m one, and the outer lane is bounded either way. What DID
# change is how it looks: the maze's outer lane now has a low rail beside it and
# the interior has tall walls, which is either "the maze is built ON a bridge"
# or "the outside wall is missing" depending on the eye. Worth a look next time
# a maze comes up in play.
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

# A WIDE LANE. One row or one column of the lattice, laid out two cells across
# instead of one, so the maze has somewhere in it that is not single file.
#
# THE PROBLEM IT ANSWERS is that a one-cell corridor is a place where nothing can
# happen. Two players cannot pass, a dash is a commitment with no room to correct,
# and a party of four is a queue for the whole section -- which is the same
# complaint the braid answers for ROUTES ("a single-route maze is not a puzzle, it
# is a queue") arriving one level down, about the corridor rather than the map.
#
# IT IS A LAYOUT DECISION AND NOT A CARVE. The lattice is built, braided and
# pruned exactly as it always was; the only thing that changes is how far apart
# the finished cells are placed. So the maze's topology -- every route, every
# loop, every dead end and every reward -- is bit-identical to the maze the same
# seed would have produced without it, and none of the reasoning above about
# braids or dead ends has to be re-checked. What a wall crosses the lane, it
# crosses two cells wide.
#
# HALF OF THEM, because a maze is already one section in five. A rarity inside a
# rarity is a feature nobody sees: at one in five it would be one section in
# twenty-five and most parties would never meet one.
const MAZE_WIDE_PERCENT := 50

# THE LANE IS PAID FOR OUT OF THE LATTICE, not added to the section. A wide lane
# costs one grid column or one grid row; taking it from the lattice keeps a maze
# the same size on the bridge whichever way the roll went, and the alternative --
# growing the section by a row -- makes the length of a section depend on a dice
# roll nobody can see, which the round machine and every walk-budget number are
# denominated in.

static func _maze_attempt(width: int, run_seed: int, index: int, attempt: int):
	var salt: int = _mix(run_seed + index * 15485863 + attempt * 97 + 0x5EED)
	var cols: int = (width + 1) / 2
	# Below three columns it is a corridor with kinks in it, not a maze.
	if cols < 3:
		return null
	var rows: int = MAZE_MIN_ROWS + salt % (MAZE_MAX_ROWS - MAZE_MIN_ROWS + 1)

	# THE WIDE LANE, ROLLED BEFORE ANYTHING IS BUILT, because it is paid for out of
	# the lattice and the lattice is the first thing decided.
	#
	# THE AXIS IT ROLLS MAY NOT BE AFFORDABLE, so it takes the other one rather
	# than dropping the lane. A horizontal lane spends a lattice ROW and rows have
	# a floor (MAZE_MIN_ROWS, below which a maze is a corridor with kinks in it);
	# a vertical lane spends a COLUMN and needs three left to still be a maze. At
	# the current tuning a 7-row maze is a quarter of them, so without the swap a
	# quarter of the horizontal rolls would silently become no lane at all.
	#
	# IT BIASES THE AXIS AND THAT IS THE PRICE: measured over 250 sections, 12
	# lanes ran along the maze and 8 across it, because the swap only ever runs one
	# way. The alternative was rolling `rows` from a range that can always afford a
	# row, which buys an even split by making every maze with a lane across it
	# shorter than one with a lane along it -- a correlation between the axis and
	# the length of the section, which is a worse thing to have than a 60/40.
	var wide: bool = _mix(salt + 0x717D) % 100 < MAZE_WIDE_PERCENT
	var wide_across: bool = _mix(salt + 0x717E) % 2 == 0
	if wide:
		var can_across: bool = rows - 1 >= MAZE_MIN_ROWS
		var can_along: bool = cols - 1 >= 3
		if wide_across and not can_across:
			wide_across = false
		elif not wide_across and not can_along:
			wide_across = true
		# And if the axis it swapped TO cannot afford one either, there is no lane.
		# Unreachable at the 21 canvas, where a column is always affordable; it is
		# here so a narrower bridge degrades into an ordinary maze rather than into
		# a lattice with two columns in it.
		wide = can_across if wide_across else can_along
	if wide:
		if wide_across:
			rows -= 1
		else:
			cols -= 1

	# Entry deck, a wall row with the door, the lattice, the far wall row, then two
	# rows of deck to arrive on. Derived rather than picked so the two ends cannot
	# disagree with the lattice between them.
	#
	# TWO LENGTHS, AND THEY ARE DIFFERENT QUESTIONS. `compact` is the coordinate
	# frame the carve works in -- every cell, link and door below is a compact
	# coordinate -- and `length` is what the section really measures once a wide
	# lane has pushed everything past it over by one. Keeping them apart is the
	# whole reason the carve needed no changes at all: it never learns there is
	# such a thing as a wide lane.
	var compact: int = rows * 2 + 4
	var length: int = compact + (1 if wide and wide_across else 0)

	# WHICH LANE, IN COMPACT COORDINATES. -1 for "no wide lane on this axis", which
	# is what every mapping below tests.
	var wide_x: int = -1
	var wide_z: int = -1
	if wide:
		if wide_across:
			wide_z = 2 + 2 * (_mix(salt + 0x717F) % rows)
		else:
			wide_x = 2 * (_mix(salt + 0x7180) % cols)

	# THE COLUMN THE LATTICE DOES NOT USE, offered to either side. A lattice of
	# `cols` columns spans 2*cols-1 cells and a wide one spans 2*cols, so at the
	# 21 canvas a wide maze has exactly one column spare -- and always parking it
	# on the same side would make every wide maze lean the same way. Rolled ONLY
	# when there is a wide lane, so a maze without one lays out exactly where it
	# always did.
	var used: int = 2 * cols - 1 + (1 if wide_x >= 0 else 0)
	var x0: int = 0
	if wide_x >= 0 and width - used > 0:
		x0 = _mix(salt + 0x7181) % (width - used + 1)
	var lay: Dictionary = {"wide_x": wide_x, "wide_z": wide_z, "x0": x0}

	var seg = _blank("section_%d_maze" % index, width, length)
	var maze_tags: Array[String] = ["foot", "generated", "maze"]
	if wide:
		# TAGGED SO THE INTENT CAN BE CHECKED AGAINST THE ARTIFACT. Nothing in the
		# game reads it; test_segment_gen does, and a claim that the geometry
		# matches what the generator meant needs both halves to be readable.
		maze_tags.append("wide_across" if wide_across else "wide_along")
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
	# IN THE COMPACT FRAME, like every other cell here -- `_maze_at` puts the exit
	# door back on `length - 3` once a wide row has moved it.
	var doors: Dictionary = {
		Vector2i(in_door, 1): true,
		Vector2i(out_door, compact - 3): true,
	}
	for door in doors:
		open_cells[door] = true

	# LAY THE LATTICE OUT. Up to here every coordinate has been compact; this is
	# the only place that knows a wide lane exists.
	#
	# A DOOR IS NEVER WIDENED, even when the wide lane runs through it. "One door
	# each end" is a design decision with its own reasoning -- a single opening
	# makes the entrance a PLACE and puts the whole party in one corridor for the
	# first moment -- and it is worth more than the two cells it costs. Walking a
	# one-cell door into a two-cell lane reads correctly; it is the mouth of the
	# avenue.
	for cell in open_cells:
		var here: Array = [_maze_at(cell, lay)] if doors.has(cell) \
			else _maze_cells(cell, lay)
		for at in here:
			seg.kinds[at.y][at.x] = GridConfig.Kind.DECK
			seg.heights[at.y][at.x] = 0

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
		var at: Vector2i = _maze_at(_maze_lattice(kept[n]), lay)
		seg.contents[at.y][at.x] = \
			GridConfig.Content.HEART if n == 1 else GridConfig.Content.HAT

	_maze_traps(seg, open_cells, cols, rows, salt,
		Vector2i((in_door) / 2, 0), Vector2i((out_door) / 2, rows - 1), kept, lay)

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
		var deep_at: Vector2i = _maze_at(_maze_lattice(deep), lay)
		seg.contents[deep_at.y][deep_at.x] = GridConfig.Content.HAT
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
		salt: int, entry: Vector2i, exit_cell: Vector2i, rewards: Array,
		lay: Dictionary) -> void:
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
			# ON THE FIRST OF THE PAIR when the cell is in a wide lane, which
			# leaves the other half clear. That is the wide lane paying for itself:
			# a spike in a one-cell corridor is a toll you cannot refuse, and the
			# same spike in a two-cell one is a thing to walk around.
			var at: Vector2i = _maze_at(_maze_lattice(here), lay)
			seg.contents[at.y][at.x] = kind
			taken[here] = true
			placed.append(here)
			break

# --- Laying the lattice out ---------------------------------------------------
#
# Three functions, and they are the ONLY code that knows a lane can be two cells
# wide. Everything above them works in the compact frame where a lattice cell
# (i, j) is the grid cell (2i, 2 + 2j) and the cell between two neighbours is the
# wall that separates them.

# A lattice cell in the compact frame.
static func _maze_lattice(cell: Vector2i) -> Vector2i:
	return Vector2i(2 * cell.x, 2 + 2 * cell.y)

# Compact -> laid out. Everything past a wide lane moves over by one, and the
# whole lattice moves over by the spare column the wide one did not take.
static func _maze_at(cell: Vector2i, lay: Dictionary) -> Vector2i:
	var x: int = int(cell.x) + int(lay["x0"])
	if int(lay["wide_x"]) >= 0 and int(cell.x) > int(lay["wide_x"]):
		x += 1
	var z: int = int(cell.y)
	if int(lay["wide_z"]) >= 0 and int(cell.y) > int(lay["wide_z"]):
		z += 1
	return Vector2i(x, z)

# The one or two cells a compact cell becomes. TWO for anything in the wide lane
# -- its cells AND the links between them, which is what makes the lane a lane
# rather than a row of wider rooms.
#
# Only one axis is ever wide, so this returns at most two cells; a maze wide both
# ways would need the diagonal as well, and the roll above does not produce one.
static func _maze_cells(cell: Vector2i, lay: Dictionary) -> Array:
	var at: Vector2i = _maze_at(cell, lay)
	var out: Array = [at]
	if int(lay["wide_x"]) >= 0 and int(cell.x) == int(lay["wide_x"]):
		out.append(at + Vector2i(1, 0))
	elif int(lay["wide_z"]) >= 0 and int(cell.y) == int(lay["wide_z"]):
		out.append(at + Vector2i(0, 1))
	return out

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

# --- Where a patch sits across the bridge (M23 phase 3) -----------------------

# THE LAST THING DECIDED ABOUT A PATCH, and it has to be.
#
# The terrain loop knows a patch WILL fit -- `safe` is the corridor of columns
# solid at every profile the generator can produce, so a spot in it proves the
# thing can be placed. It does not know WHERE, because the deck's real edges are
# the inset profile and the profile is built after the loop that reserves the
# rows.
#
# PLACING IT FROM `safe` WAS THE BUG. That corridor is FIXED at the worst-case
# inset while the deck MOVES with the profile: at a 21 canvas `safe` is columns
# 7 to 13 whatever happens, so a section whose edges were cut 6 and 0 has its
# deck at columns 6 to 20 and its tower pinned near column 9 -- hard against the
# left rail, on ground that is nowhere near the middle of anything. Reported
# from play as "I don't see any towers in the middle of the field, all are to one
# side or the other", and M22 made 38 per cent of rows asymmetric, so it was most
# of them.
#
# THE SPAN IS THE INTERSECTION OVER THE PATCH'S OWN ROWS, not the span at one of
# them. An edge may move a column per row, so the columns solid for the WHOLE
# piece are narrower than the columns solid at its first row -- and a tower whose
# last row overhangs is the thing the `safe` guarantee existed to prevent in the
# first place.
static func _place_patches(width: int, length: int, piece_ref: Array,
		piece_x: Array, left_inset: Array, right_inset: Array,
		split: bool, salt: int) -> void:
	var from := -1
	for z in range(0, length + 1):
		var patch_row: bool = z < length and piece_ref[z] != null \
			and SetPieces.is_patch(piece_ref[z], width)
		if patch_row and from < 0:
			from = z
			continue
		if patch_row or from < 0:
			continue

		var piece = piece_ref[from]
		var lo := 0
		var hi := width
		for r in range(from, z):
			lo = maxi(lo, int(left_inset[r]))
			hi = mini(hi, width - int(right_inset[r]))

		# A LANE SPLIT IS A HOLE DOWN THE MIDDLE, and a patch is written over the
		# terrain -- so one laid across the centre column would FILL that hole and
		# quietly delete the split. Kept to whichever side has more room, which is
		# also the honest answer for a section that really is two lanes: there is
		# no middle to be in.
		if split:
			var mid: int = width / 2
			if mid - lo >= hi - (mid + 1):
				hi = mini(hi, mid)
			else:
				lo = maxi(lo, mid + 1)

		# NO EXTRA MARGIN, AND THIS WAS NEARLY A MISTAKE. A draft kept a column of
		# deck either side on the reasoning that a tower flush with the rail has no
		# lane past it -- but every patch in the library already carries flat
		# height-0 columns at its OWN edges (see piece_lookout, piece_watchpost,
		# piece_bunker), so the piece is its own margin and the rule would have been
		# buying a second time something already paid for. It would also have
		# narrowed the placement range for no reason, against a report that asked
		# for MORE spread rather than less.
		var span: int = hi - lo - int(piece.width)
		var at: int = lo
		if span > 0:
			at = lo + _mix(salt + from * 8677) % (span + 1)
		for r in range(from, z):
			piece_x[r] = clampi(at, 0, maxi(0, width - int(piece.width)))
		from = -1

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

# --- The race circuit ---------------------------------------------------------

# A CLOSED RING WITH A HOLE IN THE MIDDLE. See implementation_plans/m26_race_track.md.
#
# THE INFIELD IS VOID, AND THAT IS THE WHOLE DESIGN. A ring drawn on solid deck
# is a field with markings on it: you can cut the corner, the racing line is a
# suggestion, and nothing is at stake in a corner. A hole in the middle makes the
# route a route.
#
# WIDTH IS THE POINT, so this uses the canvas edge to edge -- no setback, no
# rail, no margin. Every other generator here insets from the sides because a
# bridge has edges you fall off; a circuit's edges are the outside of the track
# and the fastest line is right up against them.
#
# ROLLED PER SIDE, in the same shape as `bus_track` rolls its bands: each of the
# four sides gets its own width from (seed, index, side), so a circuit has a
# character -- a long fast straight into a tight left, a pinched top, a wide
# sweeping bottom -- rather than being a rounded rectangle with the numbers
# changed. What it deliberately does NOT do is roll them independently enough to
# close the ring by accident: see the clamp below.
const RACE_ROWS_MIN := 44
const RACE_ROWS_MAX := 56
# How wide the road is on any one side, in cells.
#
# THE ORDINARY NARROW, AND THEN A REAL PINCH. A cell is 2 m and the bus is 1.1 m
# across, so the old minimum of four was EIGHT METRES -- seven bus widths, at the
# narrowest point of any circuit in the game. Nothing on the track ever obliged
# anybody to lift, which is what "the minimum has to get smaller if we want speed
# variance" means: a track whose tightest corner is still flat out has one speed.
#
# RACE_LANE_PINCH is 4 m: a metre and a half either side of the bus. That is a
# squeeze you take slowly and a corner you can get wrong, and it is deliberately
# not 2 m -- one cell leaves 45 cm of clearance, which is not a corner, it is a
# wall with a gap in it.
#
# PINCHES ARE SHORT BY CONSTRUCTION. A whole lap at pinch width is not a
# challenging circuit, it is a corridor; `RACE_PINCH_ROWS` is what makes it a
# feature you slow for and then get back on the power out of.
const RACE_LANE_MIN := 3
const RACE_LANE_PINCH := 2
const RACE_LANE_MAX := 7
# How many rows a pinch holds for, and how many a circuit gets. The rate cap
# means the funnel in and out costs several rows either side, so this is the flat
# bottom of the squeeze rather than the whole event.
const RACE_PINCH_ROWS := 3
const RACE_PINCH_MIN := 1
const RACE_PINCH_MAX := 3
# The infield has to be a real hole rather than a slot, or the ring is just a
# thick border and there is nothing to fall into.
const RACE_INFIELD_MIN := 6
# The narrowest canvas a circuit can BEND in. See race_loop.
const RACE_MIN_CANVAS := 19

# WHAT KIND OF CIRCUIT THIS IS.
#
# The same idea as the serpentine's lane characters, one level up: the layout is
# a ring either way, and the CHARACTER is what the road does on the way round.
# All four are expressed through the hole -- where its middle is and how wide it
# is, per row -- so none of them can open the ring, and every claim in
# test_race_loop applies to all of them without knowing they exist.
#
#   OVAL       one long bend; the fast one.
#   CHICANE    the middle third alternates hard, so the road kinks left-right-
#              left and neither rail is the line for long.
#   HAIRPIN    the hole leans on one rail and STAYS there, so one side is at its
#              minimum for half the lap -- a long tight inside with a long fast
#              outside opposite it.
#   BOTTLENECK the hole swells to its widest in one place, squeezing BOTH sides
#              at once: the one corner you cannot take wide.
const CIRCUIT_OVAL := 0
const CIRCUIT_CHICANE := 1
const CIRCUIT_HAIRPIN := 2
const CIRCUIT_BOTTLENECK := 3
const CIRCUIT_KINDS := [CIRCUIT_OVAL, CIRCUIT_CHICANE, CIRCUIT_HAIRPIN,
	CIRCUIT_BOTTLENECK]
# How tightly a chicane alternates, in rows per swing. Short enough to be a kink
# and long enough that the rate cap can actually get there and back.
const CIRCUIT_CHICANE_PERIOD := 9
# How much wider than the minimum a road may be rolled. The outer edge moves by
# whatever this leaves over once the hole has taken its share, so it is also the
# amount of outside wall there is to carve away.
const RACE_OUTER_SWING := 5
# How many checkpoints go round, start line included. Enough that cutting across
# the middle skips one; few enough that they read as gates rather than fencing.
const RACE_CHECKPOINTS := 4

# ONE CIRCUIT, HANDED OUT A SLICE AT A TIME.
#
# "We want one track between lobbies", and the obvious way to get it is to make
# a race round one section long -- which means the number of sections in a round
# stops being a constant. It is a constant in 49 places, `SECTIONS_PER_ROUND`
# means both "the run's cycle" and "how long a round is", and those are exactly
# the two meanings CLAUDE.md warns come apart the day they differ.
#
# SO THE ROUND KEEPS ITS FIVE SLOTS AND THE CIRCUIT SPANS THEM. Segments stack
# along -Z into one continuous strip of ground -- that is what a run IS -- so a
# circuit cut into five consecutive slices and laid into five consecutive slots
# is one circuit, joined seamlessly because the slices came from one grid. No
# slot arithmetic changes, no constant acquires a second meaning, and the party
# drives a single track between lobbies.
#
# THE SEAMS ARE FREE, which is the part worth checking rather than assuming. A
# slice boundary is an ordinary row of the circuit: whatever is solid on the last
# row of one slice is solid on the first row of the next, because they were the
# same row of the same computation a moment earlier. There is nothing to line up.
#
# `slices` DEFAULTS TO ONE, so a caller that wants a whole circuit in a single
# section -- every test of the generator does -- gets exactly what it did before.
static func race_loop(width: int, run_seed: int, index: int, slice: int = 0,
		slices: int = 1):
	var full = _race_circuit(width, run_seed, index)
	if slices <= 1:
		return full
	return _race_slice(full, slice, slices, "race_%d_%d" % [index, slice])

# ONE SLICE OF A BUILT CIRCUIT, as its own segment.
#
# THE CONTENTS COME WITH IT, rebased. A gate or a mine outside these rows simply
# is not in this section, which is right: it belongs to the slot that holds its
# ground, and the grid puts every slot's records into RUN coordinates anyway, so
# the circuit reassembles itself the moment the run is built.
static func _race_slice(full, slice: int, slices: int, name: String):
	var from_z: int = full.length * slice / slices
	var to_z: int = full.length * (slice + 1) / slices
	var seg = _blank(name, full.width, to_z - from_z)
	seg.tags = full.tags.duplicate()
	seg.no_dress = true
	for z in range(from_z, to_z):
		for x in full.width:
			seg.kinds[z - from_z][x] = full.kinds[z][x]
			seg.heights[z - from_z][x] = full.heights[z][x]
			seg.contents[z - from_z][x] = full.contents[z][x]
	for entry in full.checker_cells:
		var c: Vector2i = entry[0]
		if c.y >= from_z and c.y < to_z:
			seg.checker_cells.append([Vector2i(c.x, c.y - from_z), int(entry[1])])
	for c in full.mine_cells:
		if c.y >= from_z and c.y < to_z:
			seg.mine_cells.append(Vector2i(c.x, c.y - from_z))
	return seg

static func _race_circuit(width: int, run_seed: int, index: int):
	# WIDENED IF ASKED FOR LESS, because a circuit needs room to BE one.
	#
	# Four cells of road, six of hole and four more of road is fourteen -- so a
	# fourteen-wide canvas can hold a circuit and cannot hold a CORNER, because
	# there is nowhere for the hole to swing to. Measured: at fifteen cells every
	# roll produced the same rectangle and half the sweep reported no bend at all.
	# RACE_MIN_CANVAS leaves five cells of swing, which is the difference between
	# a track and a rounded rectangle. The game's own canvas is wider than this,
	# so it never fires in play; it is here so a narrower caller gets a circuit
	# rather than a square with no explanation.
	var w: int = maxi(width, RACE_MIN_CANVAS)
	var salt: int = _mix(run_seed + index * 7919)
	var length: int = RACE_ROWS_MIN + salt % (RACE_ROWS_MAX - RACE_ROWS_MIN + 1)
	var seg = _blank("race_%d" % index, w, length)
	var race_tags: Array[String] = ["foot", "generated", "race"]
	seg.tags = race_tags
	# Same reason the serpentine refuses it: what goes on a circuit belongs to the
	# circuit, not to the bridge's hazard dressing.
	seg.no_dress = true

	# THE TOP AND BOTTOM CAPS, rolled. These are the only two straight bits: the
	# rest of the circuit is whatever the hole leaves behind.
	#
	# THE SIDES ARE NOT ROLLED HERE ANY MORE, and their absence is the fix for
	# "we are still a square". They used to be two scalars that bounded the edge
	# profiles below -- so a side that rolled its minimum could not move at all,
	# and the circuit came out rectangular with one rail that breathed. The sides
	# ARE the profile now; there is nothing left to roll separately, and the two
	# clamps that kept those scalars apart went with them (both were unreachable
	# at any canvas this game builds, which a sweep at 15 cells found).
	var north: int = _band_roll(salt, 0, 8191, RACE_LANE_MIN, RACE_LANE_MAX)
	var south: int = _band_roll(salt, 1, 104729, RACE_LANE_MIN, RACE_LANE_MAX)

	# CARVED, NOT DRAWN, AND THAT IS WHAT MAKES AN INTERESTING SHAPE SAFE.
	#
	# `_blank` gives solid deck and the circuit is what is LEFT after the infield
	# is taken out. So the road is closed by construction, and it stays closed for
	# ANY infield that does not touch the canvas edge -- which means the shape of
	# the track is entirely a question of the shape of the hole, and a wilder hole
	# cannot produce a broken ring. Drawing the road instead would put four edges
	# in play and an off-by-one in any of them opens the circuit.
	#
	# THE HOLE WANDERS, which is the whole difference between a circuit and a
	# rectangle. Its left and right bounds are per-row profiles built the way M22
	# builds the bridge's edges -- rolled waypoints joined by straight ramps, then
	# rate-capped -- so the infield bulges toward one rail and away from the other
	# and the road pinches and opens as it goes round. A pinch is a corner you
	# have to slow for; an opening is somewhere to get back on the throttle.
	var in_z0: int = north
	var in_z1: int = length - 1 - south
	var rows: int = in_z1 - in_z0 + 1
	# ROLLED AS A CENTRE AND A WIDTH, not as two edges, and the difference is the
	# whole reason the first attempt came out as a rectangle with a wobble.
	#
	# Two independent edge profiles were each bounded by the side width rolled
	# BEFORE them -- so when a side rolled its minimum, that edge could not move
	# at all, and the circuit was a rectangle with one rail that breathed. Rolling
	# where the hole IS and how big it is instead lets it swing right across the
	# canvas: the road pinches on one rail and opens on the other at the same
	# time, which is a corner rather than a bulge.
	var swing: int = RACE_LANE_MIN + RACE_INFIELD_MIN / 2
	var centre: PackedInt32Array = _race_profile(salt, 11, rows,
		swing, maxi(swing, w - 1 - swing))
	var span: PackedInt32Array = _race_profile(salt, 23, rows, RACE_INFIELD_MIN,
		maxi(RACE_INFIELD_MIN, w - 2 * RACE_LANE_MIN - RACE_LANE_MIN))
	# THE CHARACTER, ROLLED AND THEN APPLIED TO THE PROFILES. Everything after
	# this point is the same code for every kind, which is what keeps a new
	# character from being able to break the ring: it only ever changes where the
	# hole is, and the carve is what guarantees the road.
	var kind: int = _band_roll(salt, 5, 16769023, 0, CIRCUIT_KINDS.size() - 1)
	_race_character(kind, centre, span, salt, swing, maxi(swing, w - 1 - swing))
	seg.tags.append("circuit_%d" % kind)
	# AND THE OUTSIDE IS CARVED TOO, which is the difference between a circuit and
	# a wiggly hole in a rectangle.
	#
	# THE OUTER RAIL USED TO BE THE CANVAS EDGE ON EVERY TRACK -- straight, all the
	# way round -- so a driver could hug the outside wall and the whole shape of
	# the infield became irrelevant. All that careful wandering was jaggedness you
	# drive PAST. Reported straight off the atlas render, and it is the kind of
	# thing no assertion in the file could have said: every claim was about the
	# road being valid, and a rectangle with a wobbly hole is perfectly valid.
	#
	# So the ROAD WIDTH is rolled per side and per row, and the outer edge is
	# wherever that puts it. The invariant survives by construction rather than by
	# clamping afterwards: the road is measured inward from the hole, so it cannot
	# be thinner than what was rolled, and what was rolled is never below the
	# minimum.
	var road_l: PackedInt32Array = _race_profile(salt, 37, rows, RACE_LANE_MIN,
		RACE_LANE_MIN + RACE_OUTER_SWING)
	var road_r: PackedInt32Array = _race_profile(salt, 53, rows, RACE_LANE_MIN,
		RACE_LANE_MIN + RACE_OUTER_SWING)
	_race_outer_character(kind, road_l, road_r, salt)
	for i in rows:
		var z: int = in_z0 + i
		var half: int = span[i] / 2
		var x0: int = maxi(RACE_LANE_MIN, centre[i] - half)
		var x1: int = mini(w - 1 - RACE_LANE_MIN, centre[i] + half)
		# THE HOLE STAYS A HOLE. Widened from the middle rather than refusing the
		# row: a profile that pinched the infield shut would split it in two, and
		# two holes with road between them is a wall down the track rather than a
		# corner. The clamp is symmetric so neither rail is systematically favoured.
		while x1 - x0 + 1 < RACE_INFIELD_MIN:
			if x0 > RACE_LANE_MIN:
				x0 -= 1
			elif x1 < w - 1 - RACE_LANE_MIN:
				x1 += 1
			else:
				break
		for x in range(x0, x1 + 1):
			seg.kinds[z][x] = GridConfig.Kind.HOLE
		# The road runs INWARD from the hole, and everything beyond it is off the
		# track. Where the hole is already against a rail there is nothing outside
		# to take away, and the arithmetic says so without a special case.
		for x in range(0, maxi(0, x0 - road_l[i])):
			seg.kinds[z][x] = GridConfig.Kind.HOLE
		for x in range(mini(w, x1 + 1 + road_r[i]), w):
			seg.kinds[z][x] = GridConfig.Kind.HOLE

	# THE START LINE ON THE NORTH STRAIGHT, and the rest spaced round from it.
	# Recorded as (cell, index) pairs rather than as content, so the ORDER is a
	# fact the mode reads rather than something it has to infer from positions --
	# a sequence inferred from geometry is a sequence that argues with itself the
	# first time a circuit is not a rectangle.
	seg.checker_cells = _race_checkpoints(seg, north, south)
	# BEFORE THE MINES, so the post takes the cell it wants and the scatter works
	# around it rather than the other way about -- `_scatter_mines` already skips
	# an occupied cell, and nothing would have made the post skip a mine.
	_place_bus_post(seg)
	_scatter_mines(seg, salt, seg.checker_cells)
	return seg

# EVENLY ROUND THE RING, one gate per side, each spanning its own road. Index 0
# is the start line and the walk is clockwise from it, so "the next one" is
# always +1 and the mode never has to know the shape.
# HOW MANY TIMES THE HOLE CHANGES ITS MIND on the way down, and how fast it is
# allowed to. Four waypoints over ~45 rows is a bend every ten rows -- long
# enough to be a corner rather than a wobble. The rate cap is what turns
# waypoints into a curve: without it the profile steps between them and the road
# has a wall in it.
const RACE_WAYPOINTS := 4
const RACE_EDGE_RATE := 1

# HOW MINES ARE SCATTERED, and the two numbers are about spacing rather than
# density. A stride down the rows so they never bunch, and a clear band at each
# end so nothing lethal sits on a seam.
const MINE_ROW_STRIDE := 7
const MINE_END_CLEAR := 3

# A BUS POST JUST INSIDE THE ENTRANCE.
#
# AT THE BEGINNING, NOT THE MIDDLE, and the first version got that backwards
# for a reason worth keeping. Halfway minimises the worst case: it is the
# furthest you can ever be from a post, so a bus lost at either end costs the
# same half-level walk. That is the right optimisation for RECOVERY and the
# wrong one for the common case, because nothing hands out a bus automatically
# any more -- so the first thing that happens in every bus level is arriving
# without one. Reported from play as having to walk a way to find it, which is
# exactly what optimising the rare case does to the frequent one.
#
# THE TRADE IS REAL AND IT IS ACCEPTED. A bus lost at the far end of a
# serpentine is now a walk back down the whole level rather than half of it. On
# a CIRCUIT it costs nothing at all -- the entrance is on the lap, so you pass
# the post every time round -- and the circuit is the mode this matters most in.
#
# A COUPLE OF ROWS IN, never on the seam itself. An entry row is where a party
# arrives with no warning, and a post standing on it is something you walk into
# before you have seen it.
const BUS_POST_ROW := 2

static func _place_bus_post(seg) -> void:
	for dz in seg.length:
		var z: int = BUS_POST_ROW + dz
		if z >= seg.length - 1:
			break
		for dx in seg.width:
			for side in [1, -1]:
				var x: int = seg.width / 2 + dx * side
				if x < 0 or x >= seg.width:
					continue
				if not seg.is_solid(x, z):
					continue
				if seg.content_at(x, z) != GridConfig.Content.NONE:
					continue
				seg.contents[z][x] = GridConfig.Content.BUS_POST
				return

# ARMED MINES ON THE ROAD, scattered rather than placed.
#
# ONE STRIDE DOWN THE ROWS AND A ROLLED COLUMN. Spacing is the whole design: a
# mine every seven rows is something you steer around, and a cluster is a wall.
# The column is rolled per row so they do not line up into a lane nobody drives
# in -- which is what a fixed column would be after the second lap.
#
# CLEAR OF BOTH ENDS, because the authoring rules say nothing lethal goes on an
# entry or exit row: a party meets those with no warning, and on a circuit the
# entry row is also where a lap starts. And clear of the GATES, because a mine on
# a checkpoint is a lap you are punished for completing.
static func _scatter_mines(seg, salt: int, gates: Array) -> void:
	var blocked := {}
	for entry in gates:
		blocked[entry[0]] = true
	var z: int = MINE_END_CLEAR + _band_roll(salt, 91, 6151, 0, MINE_ROW_STRIDE - 1)
	while z < seg.length - MINE_END_CLEAR:
		var x: int = _band_roll(salt, z, 3557, 0, seg.width - 1)
		# WALK TO THE NEAREST ROAD rather than skipping the row. On a circuit the
		# rolled column lands in the hole about half the time, and skipping would
		# put every mine on whichever side the roll happened to favour.
		var placed := false
		for step in seg.width:
			for dir in [1, -1]:
				var cx: int = x + step * dir
				if cx < 0 or cx >= seg.width:
					continue
				var cell := Vector2i(cx, z)
				if not seg.is_solid(cx, z) or blocked.has(cell):
					continue
				if seg.content_at(cx, z) != GridConfig.Content.NONE:
					continue
				# NEVER IN A PINCH. A mine on a four-metre squeeze is not a hazard
				# you steer around, it is a road block -- the bus is 1.1 m wide and
				# a blast radius is four. Hazards go where there is a line past
				# them; the pinch is already the difficulty there.
				if _run_width_at(seg, cx, z) <= RACE_LANE_PINCH:
					continue
				seg.mine_cells.append(cell)
				placed = true
				break
			if placed:
				break
		z += MINE_ROW_STRIDE

# WHAT A CIRCUIT OF THIS KIND DOES TO ITS HOLE.
#
# Applied AFTER the base profiles rather than instead of them, so a character is
# a deformation of a circuit rather than a separate generator -- and an OVAL is
# the honest no-op, not an absence. Every kind is re-rate-capped at the end,
# because a character that stepped would put a wall across the road: the rate cap
# is what turns any of these into something you can drive.
static func _race_character(kind: int, centre: PackedInt32Array,
		span: PackedInt32Array, salt: int, lo: int, hi: int) -> void:
	var rows: int = centre.size()
	match kind:
		CIRCUIT_CHICANE:
			# THE MIDDLE THIRD ONLY. A circuit that kinked end to end is not a
			# chicane, it is a slalom -- and the corners either side of it are what
			# make the kink read as one thing rather than as the whole track.
			var from_z: int = rows / 3
			var to_z: int = rows * 2 / 3
			for z in range(from_z, to_z):
				var phase: int = (z - from_z) % (CIRCUIT_CHICANE_PERIOD * 2)
				centre[z] = lo if phase < CIRCUIT_CHICANE_PERIOD else hi
		CIRCUIT_HAIRPIN:
			# LEANING ON ONE RAIL AND STAYING THERE. Which rail is rolled, so a
			# hairpin is not always a left-hander.
			var rail: int = lo if _band_roll(salt, 7, 33223, 0, 1) == 0 else hi
			for z in range(rows / 4, rows * 3 / 4):
				centre[z] = rail
		CIRCUIT_BOTTLENECK:
			pass                        # done on the roads -- see _race_outer_character
	_rate_cap(centre)
	_rate_cap(span)

# WHAT A CHARACTER DOES TO THE ROAD WIDTHS, as opposed to the hole.
#
# Split from `_race_character` because the two shape different things and a
# character may use either or both. The bottleneck lives here entirely: squeezing
# both roads at one point is a statement about the ROAD, and doing it by swelling
# the hole instead was an indirect way of saying the same thing that also moved
# the infield around for no reason.
static func _race_outer_character(kind: int, road_l: PackedInt32Array,
		road_r: PackedInt32Array, salt: int) -> void:
	var rows: int = road_l.size()
	if kind == CIRCUIT_BOTTLENECK:
		var at: int = _band_roll(salt, 9, 51203, rows / 4, maxi(rows / 4, rows * 3 / 4))
		for z in range(maxi(0, at - RACE_PINCH_ROWS), mini(rows, at + RACE_PINCH_ROWS + 1)):
			road_l[z] = RACE_LANE_PINCH
			road_r[z] = RACE_LANE_PINCH

	# AND EVERY CIRCUIT GETS PINCHES, whatever its character. A bottleneck is the
	# one that squeezes BOTH sides at once; these are single-sided, so there is a
	# line through them and the cost is having to find it slowly.
	#
	# ROLLED COUNT AND ROLLED SIDE, so a track is not a metronome. Spread across
	# the length rather than placed freely: two pinches three rows apart is one
	# long pinch with a bump in it, and the rate cap would smear them together
	# anyway.
	var pinches: int = _band_roll(salt, 13, 92821, RACE_PINCH_MIN, RACE_PINCH_MAX)
	for i in pinches:
		var at: int = rows * (i * 2 + 1) / (pinches * 2)
		var side: PackedInt32Array = road_l if _band_roll(salt, 17 + i, 7541, 0, 1) == 0 else road_r
		for z in range(maxi(0, at - RACE_PINCH_ROWS / 2),
				mini(rows, at + RACE_PINCH_ROWS / 2 + 1)):
			side[z] = RACE_LANE_PINCH

	_rate_cap(road_l)
	_rate_cap(road_r)

# THE BACKSTOP, walked forwards then backwards so neither end is favoured. Split
# out because every character needs it and one that forgot would draw a wall.
static func _rate_cap(profile: PackedInt32Array) -> void:
	for z in range(1, profile.size()):
		profile[z] = clampi(profile[z], profile[z - 1] - RACE_EDGE_RATE,
			profile[z - 1] + RACE_EDGE_RATE)
	for z in range(profile.size() - 2, -1, -1):
		profile[z] = clampi(profile[z], profile[z + 1] - RACE_EDGE_RATE,
			profile[z + 1] + RACE_EDGE_RATE)

# How wide the piece of road under (x, z) is, across the row. Used to keep mines
# out of pinches, and it asks the geometry rather than the profile that made it.
static func _run_width_at(seg, x: int, z: int) -> int:
	if not seg.is_solid(x, z):
		return 0
	var lo: int = x
	while lo > 0 and seg.is_solid(lo - 1, z):
		lo -= 1
	var hi: int = x
	while hi < seg.width - 1 and seg.is_solid(hi + 1, z):
		hi += 1
	return hi - lo + 1

# A WANDERING EDGE: rolled waypoints joined by straight ramps, then rate-capped.
#
# THE SAME LESSON AS M22'S BRIDGE EDGES, and it is worth restating because the
# obvious version is wrong in a way that looks right. Rolling a value per row and
# capping the change gives NOISE at the cap -- the edge moves every row, always by
# the maximum, because that is the largest step the cap allows. A cap is not a
# gradient. State the shape instead: a handful of waypoints, straight ramps
# between them, and the cap only as a backstop.
static func _race_profile(salt: int, key: int, rows: int, lo: int,
		hi: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(rows)
	var prev: int = _band_roll(salt, key, 7717, lo, hi)
	for i in RACE_WAYPOINTS:
		var next: int = _band_roll(salt, key * 31 + i * 7, 5171, lo, hi)
		var from_z: int = rows * i / RACE_WAYPOINTS
		var to_z: int = rows * (i + 1) / RACE_WAYPOINTS
		for z in range(from_z, to_z):
			var t: float = float(z - from_z) / float(maxi(1, to_z - from_z))
			out[z] = int(round(lerpf(float(prev), float(next), t)))
		prev = next
	_rate_cap(out)
	return out

static func _race_checkpoints(seg, north: int, south: int) -> Array:
	var out: Array = []
	var w: int = seg.width
	var l: int = seg.length
	# 0: the start line, across the north straight -- a COLUMN, because the north
	# straight is the top of the ring and you drive along it east-west.
	#
	# PLACED OVER THE HOLE, NOT OVER THE MIDDLE OF THE CANVAS. The column has to
	# be one where the straight actually ENDS -- where the infield begins directly
	# below it -- or the run of solid carries on down the side road and the gate
	# becomes a stripe down half the track. That was free while the hole always
	# sat around the centre; once it swings and the outside is carved, the canvas
	# midline is over road as often as not, and six circuits came out with a start
	# line you could simply drive past.
	var top_x: int = _hole_middle(seg, north)
	for z in range(0, seg.length):
		if not seg.is_solid(top_x, z):
			break
		out.append([Vector2i(top_x, z), 0])
	# 1: ACROSS the east side. 2: across the south. 3: across the west.
	#
	# ACROSS, NOT ALONG, AND "ACROSS" IS DIFFERENT ON EVERY SIDE.
	#
	# A gate is a line you drive THROUGH, so it is perpendicular to the direction
	# of travel where it sits -- and the direction of travel goes round. On the
	# north and south straights you drive EAST-WEST, so a gate there is a COLUMN
	# spanning the straight's depth. On the east and west sides you drive
	# NORTH-SOUTH, so a gate there is a ROW spanning that side's width. Four
	# gates, two orientations.
	#
	# THIS WAS WRONG TWICE, IN OPPOSITE DIRECTIONS, AND NO ASSERTION SAW EITHER.
	# First the side gates were drawn as stripes two hundred feet DOWN their
	# straights; the fix reasoned "the road runs east-west so the gate is a row"
	# -- which is exactly backwards, and left the start line lying ALONG the north
	# straight instead of across it. Both versions had all four gates present,
	# none in the void and all in order, because every assertion was about WHICH
	# CELLS and none about the shape they made.
	#
	# The claim that catches both is in test_race_loop and it is not about
	# orientation at all: YOU CANNOT DRIVE AROUND A GATE. Step one cell past
	# either end and you must be off the road. A stripe fails it (its ends run
	# into the corners), a half-width gate fails it, and it needs to know nothing
	# about which way anything is pointing.
	# MEASURED OFF THE CARVED GRID, not off the rolled side widths. The infield
	# wanders now, so "the east road" is a different width at every row and a gate
	# sized from a constant would leave a gap at one end -- which is a gate you
	# drive around, and the reason the test asks that question of the geometry
	# rather than of the generator.
	# THE ROAD RUNS ON THIS ROW, found rather than assumed.
	#
	# WALKING IN FROM THE CANVAS EDGE STOPPED WORKING the moment the OUTER edge
	# was carved: x = 0 and x = w-1 are void on most rows now, so a walk inward
	# broke on its first step and built a gate of nothing. 59 of 80 circuits came
	# out with fewer than four gates. A row is `void road hole road void`, so the
	# thing to find is the runs, and the two that matter are the outer pair.
	var half: int = (north + (l - 1 - south)) / 2
	var runs: Array = _road_runs(seg, half)
	if runs.size() >= 2:
		var right: Vector2i = runs[runs.size() - 1]
		for x in range(right.x, right.y + 1):
			out.append([Vector2i(x, half), 1])
	var bot_x: int = _hole_middle(seg, l - 1 - south)
	for z in range(l - 1, -1, -1):
		if not seg.is_solid(bot_x, z):
			break
		out.append([Vector2i(bot_x, z), 2])
	if runs.size() >= 2:
		var left: Vector2i = runs[0]
		for x in range(left.x, left.y + 1):
			out.append([Vector2i(x, half), 3])
	return out

# THE MIDDLE OF THE HOLE ON A GIVEN ROW, which is the column a cap gate belongs
# in: directly above (or below) the infield, so the straight it crosses stops
# there instead of running on into the side road.
static func _hole_middle(seg, z: int) -> int:
	# BETWEEN THE TWO ROADS, not between the first and last void.
	#
	# Since the OUTER edge is carved, the first and last void on a side row are
	# the outsides of the track, not the infield -- so taking their midpoint gave
	# the middle of the CANVAS, which is over road as often as not. The cap gate
	# was then a column of road with road below it, running on down the side until
	# it met the far cap: twenty-odd cells of gate down half the circuit.
	#
	# The row is `void road hole road void`, so the infield is the gap between the
	# two road runs, and that is what to ask for.
	var runs: Array = _road_runs(seg, z)
	if runs.size() < 2:
		return seg.width / 2
	var lo: int = int(runs[0].y) + 1
	var hi: int = int(runs[runs.size() - 1].x) - 1
	if hi < lo:
		return seg.width / 2
	return (lo + hi) / 2

# THE MAXIMAL RUNS OF SOLID ROAD ACROSS ONE ROW, as (from, to) inclusive.
#
# The shape every reader of a circuit row needs, now that both edges are carved.
# On a side row there are exactly two, and that is itself a property worth
# knowing: a third means the road has fragmented, which is not a circuit.
static func _road_runs(seg, z: int) -> Array:
	var out: Array = []
	var start := -1
	for x in seg.width:
		if seg.is_solid(x, z):
			if start < 0:
				start = x
		elif start >= 0:
			out.append(Vector2i(start, x - 1))
			start = -1
	if start >= 0:
		out.append(Vector2i(start, seg.width - 1))
	return out
