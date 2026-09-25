extends RefCounted

# THE BUS ROUTE'S GROUND: a serpentine of full-width lanes joined at alternating
# ends, with a character rolled per lane. See TrackMode.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const BusBody = preload("res://scripts/sim/actors/bus_body.gd")
const GenUtil = preload("res://scripts/level/gen/gen_util.gd")
const ModeProps = preload("res://scripts/level/gen/mode_props.gd")

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
			return GenUtil._band_roll(salt, band, 40503, 7, 9)
		LANE_STRIP:
			return GenUtil._band_roll(salt, band, 40503, 5, 7)
	return GenUtil._band_roll(salt, band, 40503, TRACK_LANE_MIN, TRACK_LANE_MAX)


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
	var w: int = maxi(width, GenUtil.LOBBY_MIN_WIDTH)
	var salt: int = Hash.mix(run_seed + index * 6151)
	var length: int = TRACK_ROWS_MIN + salt % (TRACK_ROWS_MAX - TRACK_ROWS_MIN + 1)
	var seg = GenUtil._blank("track_%d" % index, w, length)
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
		var kind: int = GenUtil._band_roll(salt, band, 8191, 0, LANE_KINDS.size() - 1)
		var lane: int = _lane_rows_for(kind, salt, band)
		var turn: int = GenUtil._band_roll(salt, band, 104729, TRACK_TURN_MIN, TRACK_TURN_MAX)
		var bay: int = GenUtil._band_roll(salt, band, 2654435, TRACK_BAY_MIN, TRACK_BAY_MAX)
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
	ModeProps._place_bus_post(seg)
	# ARMED MINES, on the serpentine as well as on the circuit. Same scatter, and
	# no gates to keep clear of here.
	ModeProps._scatter_mines(seg, salt, [])
	return seg


static func track_speed_limit(turn_rows: int) -> float:
	return float(turn_rows) * GridConfig.CELL_SIZE * BusBody.TURN_RATE * 0.5
