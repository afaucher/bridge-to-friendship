extends RefCounted

# THE RACE CIRCUIT'S GROUND: one closed ring per round, with a void infield,
# sliced into the round's slots, and its checkpoint gates. See RaceMode and
# implementation_plans/m26_race_track.md.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GenUtil = preload("res://scripts/grid/gen/gen_util.gd")
const ModeProps = preload("res://scripts/grid/gen/mode_props.gd")

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

const RACE_LANE_PINCH := ModeProps.PINCH_WIDTH

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
	var seg = GenUtil._blank(name, full.width, to_z - from_z)
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
	var salt: int = Hash.mix(run_seed + index * 7919)
	var length: int = RACE_ROWS_MIN + salt % (RACE_ROWS_MAX - RACE_ROWS_MIN + 1)
	var seg = GenUtil._blank("race_%d" % index, w, length)
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
	var north: int = GenUtil._band_roll(salt, 0, 8191, RACE_LANE_MIN, RACE_LANE_MAX)
	var south: int = GenUtil._band_roll(salt, 1, 104729, RACE_LANE_MIN, RACE_LANE_MAX)

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
	var kind: int = GenUtil._band_roll(salt, 5, 16769023, 0, CIRCUIT_KINDS.size() - 1)
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
	ModeProps._place_bus_post(seg)
	ModeProps._scatter_mines(seg, salt, seg.checker_cells)
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
			var rail: int = lo if GenUtil._band_roll(salt, 7, 33223, 0, 1) == 0 else hi
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
		var at: int = GenUtil._band_roll(salt, 9, 51203, rows / 4, maxi(rows / 4, rows * 3 / 4))
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
	var pinches: int = GenUtil._band_roll(salt, 13, 92821, RACE_PINCH_MIN, RACE_PINCH_MAX)
	for i in pinches:
		var at: int = rows * (i * 2 + 1) / (pinches * 2)
		var side: PackedInt32Array = road_l if GenUtil._band_roll(salt, 17 + i, 7541, 0, 1) == 0 else road_r
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
	var prev: int = GenUtil._band_roll(salt, key, 7717, lo, hi)
	for i in RACE_WAYPOINTS:
		var next: int = GenUtil._band_roll(salt, key * 31 + i * 7, 5171, lo, hi)
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
