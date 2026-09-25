extends "res://scripts/test_support/test_case.gd"

# THE GENERATOR MAKES CHANNELS, AND THEY FLOW.
#
# Water existed in one authored map and nowhere else; the generator had never
# emitted any. M27 phase 2 gave water a direction, so now it is worth generating.
#
# THE CLAIM THAT MATTERS IS THAT THEY HAPPEN AT ALL. Where a generator validates
# and rerolls, a bug does not produce broken output -- it produces NO output, and
# every assertion about the output passes over an empty set. `section()` returns
# only a segment `SegmentValidator` accepted, so "no channel is malformed" is a
# wall of green whether or not one has ever been built. The live assertion is a
# count of the thing happening.
#
# AND FLOWING IS A SECOND QUESTION FROM EXISTING. A channel penned in by the
# derived parapet has no outlet, so no source, so no current -- a decorative
# puddle, which is exactly what the authored map had for four milestones. The
# parapet suppression is the difference, and it is invisible in the deck grid.

const SegmentGen = preload("res://scripts/level/segment_gen.gd")
const SegmentPool = preload("res://scripts/level/segment_pool.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const GameMode = preload("res://scripts/sim/modes/game_mode.gd")
const BridgeGridScript = preload("res://scripts/level/bridge_grid.gd")

const WIDTH := 21
const SAMPLES := 60

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "GenWaterWorld"
	main.add_child(world)

func _physics_process(_delta: float) -> void:
	if done:
		return
	done = true
	set_physics_process(false)
	_channels_are_generated()
	_and_they_run()
	finish()

# --- 1. They happen -------------------------------------------------------------

func _channels_are_generated() -> void:
	var with_water := 0
	var water_cells := 0
	var open_lips := 0
	var on_a_ramp := 0
	var dressed := 0
	var shapes := {}
	var fenced := 0
	for i in SAMPLES:
		var seg = SegmentGen.section(WIDTH, 4000 + i * 13, i + 1)
		if seg == null:
			continue
		var had := false
		for z in seg.length:
			for x in seg.width:
				if seg.kinds[z][x] != GridConfig.Kind.WATER:
					continue
				had = true
				water_cells += 1
				if seg.no_wall[z][x]:
					open_lips += 1
				# NO FENCES IN A RIVER. A parapet is derived on any solid cell
				# whose edge faces off the side of the bridge, and water is
				# solid -- so water reaching a rail without the railing
				# suppressed grows one. Reported in those words, from a pool that
				# spanned rail to rail with only its two corners open.
				for dir in 4:
					if seg.has_wall(x, z, dir):
						fenced += 1
				# NOTHING IS PLACED IN A RIVER. Water is solid, so without the
				# filter in the dressing pass it is an ordinary candidate -- and a
				# merchant in a current is a shop you cannot stand still at.
				if seg.contents[z][x] != GridConfig.Content.NONE:
					dressed += 1
				# A ramp is a wedge and a lift is a shaft; water in either is a
				# hazard aimed at somebody with no verbs.
				if z > 0 and seg.kinds[z - 1][x] == GridConfig.Kind.RAMP:
					on_a_ramp += 1
		if not had:
			continue
		with_water += 1
		# WHICH SHAPE, BY HOW MANY ROWS IT OCCUPIES. Straight bands are
		# CHANNEL_ROWS deep, a pool is POOL_ROWS, and a dog-leg spans its drop
		# plus both runs -- so the row count tells them apart without the
		# generator having to record what it chose.
		var wet_rows := 0
		for z in seg.length:
			for x in seg.width:
				if seg.kinds[z][x] == GridConfig.Kind.WATER:
					wet_rows += 1
					break
		var shape: String = "straight" if wet_rows <= 2 				else ("pool" if wet_rows <= 3 else "zigzag")
		shapes[shape] = int(shapes.get(shape, 0)) + 1
	print("[genwater] %d of %d sections carry a channel: %d cells, %d open lips"
		% [with_water, SAMPLES, water_cells, open_lips])
	check(with_water > 0,
		"the generator really emits channels (%d of %d) -- where a generator "
			% [with_water, SAMPLES]
		+ "validates and rerolls, a bug is an ABSENCE, and every rule asserted "
		+ "about a channel passes over an empty set")
	check(with_water < SAMPLES,
		"and not in every section (%d of %d) -- a thing in every one is terrain, "
			% [with_water, SAMPLES]
		+ "not an event")
	print("[genwater] shapes: %s" % shapes)
	# THE COUNT OF EACH SHAPE HAPPENING AT ALL is the live claim, and this file
	# already learned why: the dog-leg and the pool were rolled, failed their
	# preconditions every time, and fell through to a straight band -- so the
	# generator emitted exactly one shape while "13 sections carry a channel"
	# stayed green. Nine sections were dumped and drawn before anyone noticed.
	for want in ["straight", "pool", "zigzag"]:
		check(int(shapes.get(want, 0)) > 0,
			"the generator really produces a %s channel (%d of %d wet sections) "
				% [want, int(shapes.get(want, 0)), with_water]
			+ "-- a rolled shape that never fits is an absence, and every rule "
			+ "asserted about channels passes over the one shape that does")
	check(open_lips > 0,
		"and the railing is suppressed where the water leaves (%d cells) -- "
			% open_lips
		+ "without that the parapet pens the channel in, the flood finds no "
		+ "outlet, and the result is a decorative puddle")
	eq(dressed, 0,
		"nothing is placed IN the water (%d cells) -- it is solid, so it was an "
			% dressed
		+ "ordinary dressing candidate, and a shop in a current is one you "
		+ "cannot stand still at")
	eq(on_a_ramp, 0, "and no channel is cut into a ramp (%d)" % on_a_ramp)
	eq(fenced, 0,
		"and no water cell carries a parapet (%d) -- water is solid, so a cell "
			% fenced
		+ "that reaches a rail grows a railing unless it is suppressed, and a "
		+ "fence standing in a river is what got reported. Water either spills "
		+ "at an edge or stays a column short of one")

# --- 2. And they run ------------------------------------------------------------
#
# ASKED OF A BUILT RUN, not of the generator's output. Whether a channel FLOWS is
# decided by the grid's flood at load, from outlets it finds in run space -- so a
# section that looks perfect in its own grid can still be a puddle once the
# parapets are derived around it. Two different questions, and only the second is
# the one a player meets.

func _and_they_run() -> void:
	var flowing := 0
	var still := 0
	var runs := 0
	for seed_value in [4000, 4321, 4777]:
		var grid = BridgeGridScript.new()
		grid.name = "FlowRun%d" % seed_value
		grid.width = WIDTH
		grid.dress_hazards = true
		world.add_child(grid)
		grid.build_run(seed_value, (SegmentPool.SECTIONS_PER_ROUND + 1) * 2,
			[GameMode.BASE, GameMode.BASE])
		runs += 1
		for z in grid.total_length():
			for x in WIDTH:
				var cell := Vector2i(x, z)
				if grid.kind_at(cell) != GridConfig.Kind.WATER:
					continue
				if grid.water_flow_at(cell) != Vector3.ZERO:
					flowing += 1
				else:
					still += 1
		grid.queue_free()
	print("[genwater] over %d runs: %d flowing water cells, %d still"
		% [runs, flowing, still])
	check(flowing > 0,
		"generated channels really flow once built (%d cells) -- existing and "
			% flowing
		+ "flowing are two different questions, and a channel the derived railing "
		+ "pens in is a puddle however good it looks in the deck grid")
	check(flowing > still,
		"and most of the water in a run is moving (%d against %d still) -- a "
			% [flowing, still]
		+ "generator that mostly makes ponds has not made the feature")
