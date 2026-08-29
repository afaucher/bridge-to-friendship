extends "res://scripts/test_support/test_case.gd"

# THE SERPENTINE TRACK, and a preview of it. M25 phase 3, the skeleton.
#
# THIS FILE IS HALF TEST AND HALF INSTRUMENT, deliberately. It asserts the shape
# is what it claims to be, and it PRINTS three real sections as ASCII beside the
# numbers that tune them -- because this project has already learned that two
# rounds of theory lose to printing the map: *"when two explanations of the same
# measurement contradict each other, stop measuring and LOOK."* Tuning a track by
# reading constants is that mistake waiting to happen.
#
#   powershell -File ./test_runner.ps1 -TestName test_bus_track
#   then read test_logs/test_bus_track.log
#
# THE CLAIM THE WHOLE SHAPE RESTS ON is that the serpentine is FORCED. Full-width
# lanes with a narrow link at one end mean the link is the only cell that
# advances -- so if any row is fully solid where it should be void, the bus drives
# straight up the middle and the mode is a corridor again. That is asserted as a
# property of every row rather than by looking at the constants that built it.
#
# The claims:
#   1. IT EXISTS, for every seed. The presence claim first, always: a generator
#      that validates and rerolls turns a bug into an absence, and every assertion
#      about the output then passes over an empty set.
#   2. THE ENDS ARE FULL-WIDTH PLATES, or the join contract breaks and the segment
#      is silently refused at load.
#   3. THE SERPENTINE IS FORCED -- no row lets you drive straight through.
#   4. THE LINKS ALTERNATE ENDS, or it is a spiral rather than a serpentine.
#   5. IT IS CROSSABLE by the ordinary validator, which is what lets this shape
#      ship before the per-mode traversal model the plan still owes.
#   6. AND IT IS WORTH DRIVING: the lateral distance is many times the segment's
#      own length, which is the entire reason for the shape.
#   7. THE BANDS VARY, which the first version did not and this file did not
#      notice. The seed chose only which END the first link was on, so every
#      section was one shape or its mirror -- and three previews side by side were
#      three identical pictures, spotted by eye rather than by the gate.
#
#      THE CLAIM IS AN IMPOSSIBILITY, NOT A THRESHOLD. "At least four distinct
#      link depths" is a number somebody picked; "more than one link depth exists
#      at all" is something the old generator COULD NOT PRODUCE, because it built
#      every link from one constant. That is the shape of assertion this project
#      trusts -- the same reasoning as "the deck is sometimes an EVEN number of
#      cells wide", which was a proof rather than a tuned count.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")

const WIDTH := 21
const SEEDS := 24

func setup(_main) -> void:
	timeout_seconds = 40.0
	_it_exists()
	_the_ends_are_plates()
	_the_serpentine_is_forced()
	_the_links_alternate()
	_it_is_crossable()
	_it_is_worth_driving()
	_the_bands_actually_vary()
	_every_flavour_appears()
	_preview()
	finish()

# --- 1. It exists --------------------------------------------------------------

func _it_exists() -> void:
	var made := 0
	for seed_value in SEEDS:
		if SegmentGen.bus_track(WIDTH, seed_value * 7919, seed_value) != null:
			made += 1
	eq(made, SEEDS,
		"every seed produces a track (%d of %d) -- the presence claim first, "
			% [made, SEEDS]
		+ "because a rejection oracle turns a generator bug into an ABSENCE and "
		+ "every assertion below would then be green over nothing")

# --- 2. The ends -----------------------------------------------------------------

func _the_ends_are_plates() -> void:
	for seed_value in 8:
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 104729, seed_value)
		for x in seg.width:
			if not check(seg.is_solid(x, 0) and seg.is_solid(x, seg.length - 1),
					"seed %d is solid across both end rows (column %d)"
						% [seed_value, x]):
				return

# --- 3. The shape it exists for -------------------------------------------------

func _the_serpentine_is_forced() -> void:
	# NO ROW MAY BE A THROUGH-ROUTE. The lanes are full width and the links are
	# narrow, so a bus can only advance at a link -- unless some row is solid all
	# the way along the direction of travel, in which case it drives straight up
	# the middle and the whole shape is decoration.
	#
	# Asked as a property of the OUTPUT rather than of the constants that made it:
	# a test that recomputed the lane and link rows from TRACK_LANE_ROWS would
	# agree with the generator by construction and could never disagree with it.
	for seed_value in 8:
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 40503, seed_value)
		var straight := 0
		for x in seg.width:
			var clear := true
			for z in seg.length:
				if not seg.is_solid(x, z):
					clear = false
					break
			if clear:
				straight += 1
		if not eq(straight, 0,
				("seed %d has NO column solid end to end (%d) -- one would be a "
					% [seed_value, straight])
				+ "lane straight up the middle, and the serpentine would be a "
				+ "suggestion rather than the only way through"):
			return

# --- 4. Alternating ------------------------------------------------------------

func _the_links_alternate() -> void:
	var seg = SegmentGen.bus_track(WIDTH, 4242, 1)
	# WHICH SIDE EACH LINK IS ON, read off the rows rather than assumed. A link row
	# is one that is not solid across; which end it sits at is where its solid
	# cells are.
	var sides: Array = []
	var last := -2
	for z in seg.length:
		if _row_solid_count(seg, z) == seg.width:
			continue
		var left: bool = seg.is_solid(0, z)
		var side: int = 0 if left else 1
		if z != last + 1 or sides.is_empty() or int(sides[-1]) != side:
			if sides.is_empty() or int(sides[-1]) != side:
				sides.append(side)
		last = z
	print("[track] link sides in order: %s" % str(sides))
	check(sides.size() >= 2,
		"there is more than one link (%d) -- one is a dogleg, not a serpentine"
			% sides.size())
	for i in range(1, sides.size()):
		if not check(int(sides[i]) != int(sides[i - 1]),
				"link %d is at the opposite end from link %d -- two in a row on "
					% [i, i - 1]
				+ "the same side is a spiral, and the party never comes back"):
			return

# --- 5. Still walkable ----------------------------------------------------------

func _it_is_crossable() -> void:
	# BY THE ORDINARY VALIDATOR. The plan warns that a mode with a different BODY
	# needs its own answer to "can this be crossed" -- and it still does, for
	# anything with height in it. A serpentine has none: it is flat, so a walking
	# player crosses it and the existing oracle is telling the truth about this
	# shape. Saying so here is what stops the next reader assuming otherwise.
	for seed_value in 8:
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 2654435761, seed_value)
		var problems: Array = SegmentValidator.validate(seg)
		if not eq(problems.size(), 0,
				"seed %d validates (%s)" % [seed_value, str(problems)]):
			return

# --- 6. And worth the trouble ---------------------------------------------------

func _it_is_worth_driving() -> void:
	var seg = SegmentGen.bus_track(WIDTH, 777, 2)
	# COUNTED AS BANDS, NOT ROWS, and the difference is a factor of four. A lane is
	# four rows deep and you drive along it ONCE -- counting each row as a traverse
	# inflated this to 756 m, which would have made the shape look four times more
	# generous than it is and sent the tuning the wrong way. A number nobody can
	# check is worse than no number.
	# LANE BANDS BY THE SAME DEFINITION EVERYTHING ELSE USES -- rows that are not
	# links. Counting FULL-WIDTH bands instead stopped counting a lane the moment a
	# character carved it, so adding the wave made a section look like it had less
	# driving in it than before. Third time a detector in this file has measured
	# something other than the thing it named.
	var lanes := 0
	var inside := false
	for z in seg.length:
		var lane_row: bool = not _is_link_row(seg, z)
		if lane_row and not inside:
			lanes += 1
		inside = lane_row
	var lateral: float = float(lanes) * float(seg.width) * GridConfig.CELL_SIZE
	var forward: float = float(seg.length) * GridConfig.CELL_SIZE
	print("[track] %d rows (%.0f m of bridge), %d lanes, about %.0f m of driving = %.0f s at %.1f m/s"
		% [seg.length, forward, lanes, lateral,
			lateral / maxf(SegmentGen.track_speed_limit(SegmentGen.TRACK_TURN_MIN), 0.1),
			SegmentGen.track_speed_limit(SegmentGen.TRACK_TURN_MIN)])
	check(lateral > forward * 1.5,
		"the driving is well over the segment's own length (%.0f m against %.0f) "
			% [lateral, forward]
		+ "-- that multiplier IS the reason for the shape, and without it a "
		+ "section is over in three seconds")

# --- 7. Variety -----------------------------------------------------------------

func _the_bands_actually_vary() -> void:
	var lanes: Dictionary = {}
	var turns: Dictionary = {}
	var lengths: Dictionary = {}
	var starts: Dictionary = {}
	for seed_value in SEEDS:
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 91387, seed_value)
		lengths[seg.length] = true
		# LINK ROWS BY THE SAME DEFINITION THE PREVIEW USES -- solid at exactly one
		# end. Counting "not full width" instead swept every carved LANE in as a
		# link, and the numbers said so: link depths of 9, 10 and 12 against a
		# TRACK_TURN_MAX of 7, and lane depths of 1 and 2 against a minimum of 3. A
		# measurement outside its own range is the tell that the thing being counted
		# is not the thing named.
		var run := 0
		var lane_run := 0
		for z in seg.length:
			if _is_link_row(seg, z):
				if lane_run > 0:
					lanes[lane_run] = true
				lane_run = 0
				run += 1
				if run == 1:
					starts[1 if seg.is_solid(0, z) else 0] = true
			else:
				if run > 0:
					turns[run] = true
				run = 0
				lane_run += 1
	print("[track] over %d seeds: %d lane depths %s, %d link depths %s, %d lengths"
		% [SEEDS, lanes.size(), str(lanes.keys()), turns.size(), str(turns.keys()),
			lengths.size()])

	# EACH OF THESE WAS A SINGLE CONSTANT BEFORE, so one distinct value is exactly
	# what the old generator produced and more than one is something it could not.
	check(turns.size() > 1,
		"link depths vary (%d distinct: %s) -- and this is the one that matters, "
			% [turns.size(), str(turns.keys())]
		+ "because the link depth IS the corner's speed limit. Every link the same "
		+ "means every corner the same, which is one decision made once")
	check(lanes.size() > 1,
		"lane depths vary (%d distinct: %s), so the straight before each corner is "
			% [lanes.size(), str(lanes.keys())] + "not always the same straight")
	check(lengths.size() > 1,
		"and sections are not all the same length (%d distinct)" % lengths.size())
	check(starts.size() > 1,
		"and they do not all open with a link at the same end (%d)" % starts.size())

	# AND THE VARIETY REACHES THE THING IT IS FOR. Distinct depths are only
	# interesting if they land either side of the bus's top speed: a spread that
	# was all fast or all slow would vary the picture and not the driving.
	var slowest: float = 1000.0
	var fastest: float = 0.0
	for depth in turns:
		slowest = minf(slowest, SegmentGen.track_speed_limit(int(depth)))
		fastest = maxf(fastest, SegmentGen.track_speed_limit(int(depth)))
	print("[track] corners span %.1f to %.1f m/s (top speed %.1f)"
		% [slowest, fastest, BusBody.TOP_SPEED])
	check(slowest < BusBody.TOP_SPEED * 0.8,
		"some corners really do demand a lift (%.1f m/s against a top speed of "
			% slowest + "%.1f) -- a spread that was all fast would vary the "
			% BusBody.TOP_SPEED + "picture and not the driving")

# --- 8. Every flavour actually reaches the track -------------------------------

func _every_flavour_appears() -> void:
	# THE PRESENCE CLAIM FOR THE CHARACTERS, and it is the one this shape most
	# needs. A lane whose band is clamped below what its character reads in is
	# silently DOWNGRADED to a plain straight -- which is the right behaviour and
	# the exact shape of failure this project keeps writing down: the rejection
	# turns "wrong" into "absent", and absent looks like a track that simply never
	# rolled a wave. Three previews in a row showed no strip and no wave, which is
	# what prompted this.
	#
	# Counted from the OUTPUT, by what is actually drawn: a gauntlet is a full-width
	# lane with a shooter on it, a strip is a carved lane carrying a timed block, a
	# wave is a carved lane without one.
	var seen: Dictionary = {"gauntlet": 0, "strip": 0, "wave": 0, "plain": 0}
	for seed_value in SEEDS * 2:
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 91387, seed_value)
		var z := 0
		while z < seg.length:
			if _is_link_row(seg, z):
				z += 1
				continue
			var z0: int = z
			while z < seg.length and not _is_link_row(seg, z):
				z += 1
			seen[_flavour_of(seg, z0, z)] += 1
	print("[track] flavours over %d seeds: %s" % [SEEDS * 2, str(seen)])
	for name in ["gauntlet", "strip", "wave"]:
		check(int(seen[name]) > 0,
			("no lane of kind '%s' was ever produced (%s) -- a character that is " % [name, str(seen)])
			+ "always downgraded is a character that does not exist, and it would "
			+ "look exactly like one that was simply never rolled")

# Does this seed contain a lane of that character?
func _has_flavour(seed_value: int, wanted: String) -> bool:
	var seg = SegmentGen.bus_track(WIDTH, seed_value * 91387, seed_value)
	return _flavours_in(seg).contains(wanted)

# The characters in a section, in order, as a readable list.
func _flavours_in(seg) -> String:
	var out: Array = []
	var z := 0
	while z < seg.length:
		if _is_link_row(seg, z):
			z += 1
			continue
		var z0: int = z
		while z < seg.length and not _is_link_row(seg, z):
			z += 1
		out.append(_flavour_of(seg, z0, z))
	return " / ".join(out)

# Which character a band of rows z0..z1 was drawn with, read off what is in it.
func _flavour_of(seg, z0: int, z1: int) -> String:
	var carved := false
	var timed := false
	var shooter := false
	for z in range(z0, z1):
		for x in seg.width:
			if not seg.is_solid(x, z):
				carved = true
				continue
			match seg.content_at(x, z):
				GridConfig.Content.TIMED:
					timed = true
				GridConfig.Content.SKIRMISHER:
					shooter = true
	if timed:
		return "strip"
	if carved:
		return "wave"
	if shooter:
		return "gauntlet"
	return "plain"

# --- The preview ----------------------------------------------------------------

func _preview() -> void:
	print("")
	print("[track] === PREVIEW: three sections, %d wide ===" % WIDTH)
	print("[track] lane %d-%d rows, link %d-%d rows, bay %d-%d cells -- rolled PER BAND"
		% [SegmentGen.TRACK_LANE_MIN, SegmentGen.TRACK_LANE_MAX,
			SegmentGen.TRACK_TURN_MIN, SegmentGen.TRACK_TURN_MAX,
			SegmentGen.TRACK_BAY_MIN, SegmentGen.TRACK_BAY_MAX])
	print("[track] so corners run %.1f to %.1f m/s against a top speed of %.1f"
		% [SegmentGen.track_speed_limit(SegmentGen.TRACK_TURN_MIN),
			SegmentGen.track_speed_limit(SegmentGen.TRACK_TURN_MAX),
			BusBody.TOP_SPEED])
	# SEEDS CHOSEN TO SHOW EACH FLAVOUR, not the first three. A preview exists to be
	# looked at, and three plain-heavy sections in a row is what it printed before
	# -- which is how a strip and a wave went unexamined for two rounds while both
	# were being generated all along.
	for wanted in ["strip", "wave", "gauntlet"]:
		var seed_value := 1
		while seed_value < 200 and not _has_flavour(seed_value, wanted):
			seed_value += 1
		var seg = SegmentGen.bus_track(WIDTH, seed_value * 91387, seed_value)
		print("")
		# A LINK ROW IS ONE THAT IS SOLID AT EXACTLY ONE END. That is what tells it
		# apart from a lane a character has carved: a strip and a wave both leave
		# both ends full depth, because that is where the lane meets its corners.
		#
		# The first version just counted rows that were not full width, so a wave
		# lane sitting next to a link merged into one long "corner" and the readout
		# claimed 17.1 m/s -- above what the deepest link can possibly allow. A
		# number outside its own range is the tell that the thing being measured is
		# not the thing named.
		var corners: Array = []
		var depth := 0
		for z in seg.length:
			if _is_link_row(seg, z):
				depth += 1
			else:
				if depth > 0:
					corners.append("%.1f" % SegmentGen.track_speed_limit(depth))
				depth = 0
		if depth > 0:
			corners.append("%.1f" % SegmentGen.track_speed_limit(depth))
		print("[track] --- seed %d (%s): %d rows, corners at %s m/s ---"
			% [seed_value, _flavours_in(seg), seg.length, ", ".join(corners)])
		for z in seg.length:
			var row := ""
			for x in seg.width:
				if not seg.is_solid(x, z):
					row += "_"
					continue
				# CONTENT OVER THE DECK, in the project's own glyphs, so the
				# flavours are visible at all -- a deck-only picture cannot show a
				# timed block or a shooter, which is most of what was just added.
				match seg.content_at(x, z):
					GridConfig.Content.TIMED:
						row += "%"
					GridConfig.Content.SKIRMISHER:
						row += "k"
					GridConfig.Content.TURRET:
						row += "T"
					_:
						row += "."
			print("[track] %s" % row)

	# AND WHAT OTHER SETTINGS WOULD GIVE, so the dial can be turned by looking at
	# numbers rather than by rebuilding three times.
	print("")
	print("[track] link depth against the speed it allows:")
	for rows in [3, 4, 5, 6, 7, 8]:
		print("[track]   %d rows (%2.0f m) -> %5.1f m/s%s"
			% [rows, float(rows) * GridConfig.CELL_SIZE,
				SegmentGen.track_speed_limit(rows),
				"   <- in range" if rows >= SegmentGen.TRACK_TURN_MIN
					and rows <= SegmentGen.TRACK_TURN_MAX else ""])

# Solid at one end and not the other, and not solid across: the shape of a link.
func _is_link_row(seg, z: int) -> bool:
	if _row_solid_count(seg, z) == seg.width:
		return false
	var left: bool = seg.is_solid(0, z)
	var right: bool = seg.is_solid(seg.width - 1, z)
	return left != right

func _row_solid_count(seg, z: int) -> int:
	var n := 0
	for x in seg.width:
		if seg.is_solid(x, z):
			n += 1
	return n
