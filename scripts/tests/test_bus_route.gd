extends "res://scripts/test_support/test_case.gd"

# THE BUS ROUTE: THE TRACK, WIRED TO A MODE.
#
# `bus_track` has existed and been measured since the day it was written, and
# nothing called it. A generator nothing calls is a picture of a level, so this
# file is about the three joins that turn it into ground you can drive on, and
# every one of them is a place this project has already been bitten.
#
#   1. THE WORLD BUILDS IT WHEN THE MODE SAYS SO. The blank zone's first draft
#      passed with `GameMode.terrain()` hardwired, because every assertion in it
#      called the generator by hand. A test that builds its own input has not
#      tested the caller, and the caller is the entire seam.
#
#   2. THE MODE RUNS THE POOLS ITS OWN TERRAIN PLACES CONTENT FOR. This is the
#      subsystem x mode grid finally doing the job it was built for, and from the
#      direction nobody watches: not a pool running where it should not, but
#      content placed for a pool that is switched OFF. A gauntlet lane writes
#      skirmishers and a strip lane writes timed floor; declare `gunners: OFF`
#      and the track fills with statues, with nothing anywhere reporting it.
#      Asked of EVERY mode, so the next lane flavour is covered before it is
#      written.
#
#   3. A BUS IS PUT DOWN ON ROAD. A fixed offset ahead of the party was correct
#      while the only mode with a bus was a solid plane. A track is mostly void,
#      and a bus dropped in void does not error -- it falls, and the party stands
#      on a race track with no vehicle. Swept over every row of a real run,
#      because the failure is positional: a fixed offset lands on road wherever
#      the party is over a lane and in void wherever it is over a gap, so a
#      single sample is a coin flip that passes half the time.
#
# Note what is NOT claimed here: that the track is crossable ON FOOT. It is not,
# and it is not meant to be -- `SegmentValidator` models a walking player and the
# thing that crosses this is a bus. `test_bus_track` owns the traversal claim in
# the bus's own terms (lane depth against turn radius); this file owns the wiring.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")

const WIDTH := 21
const SEEDS := 40

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "RouteHarness"
	main.add_child(world)

func _physics_process(_delta: float) -> void:
	if done:
		return
	done = true
	_the_run_uses_the_mode_it_was_given()
	_a_mode_runs_what_its_terrain_places()
	_a_bus_is_put_down_on_road()
	finish()

# --- 1. The caller ------------------------------------------------------------

func _the_run_uses_the_mode_it_was_given() -> void:
	var cycle: int = SegmentPool.SECTIONS_PER_ROUND + 1
	var built = BridgeGridScript.new()
	built.name = "TrackRun"
	world.add_child(built)
	built.width = WIDTH
	# ROUND 0 BASE, ROUND 1 TRACK, in ONE run -- so the claim is that the builder
	# SWITCHES, not that it can be configured. A run that was track throughout
	# would pass with the mode ignored and a constant swapped.
	built.build_run(4242, cycle * 2, [GameMode.BASE, GameMode.TRACK])

	var counts := {0: [0, 0], 1: [0, 0]}   # round -> [track sections, sections]
	for i in built.segment_count():
		if SegmentPool.is_lobby_slot(i):
			continue                        # a lobby is always base and never asks
		var seg = built.segment_data(i)
		if seg == null:
			continue
		var r: int = SegmentPool.round_of_slot(i)
		if not counts.has(r):
			continue
		counts[r][1] += 1
		if seg.tags.has("track"):
			counts[r][0] += 1
	print("[route] round 0: %d/%d track; round 1: %d/%d track"
		% [counts[0][0], counts[0][1], counts[1][0], counts[1][1]])

	check(counts[0][1] > 0 and counts[1][1] > 0,
		"the run really covers two rounds (%d + %d sections)"
			% [counts[0][1], counts[1][1]])
	eq(counts[1][0], counts[1][1],
		"every section of the round chosen as TRACK is a bus track (%d of %d) -- "
			% [counts[1][0], counts[1][1]]
		+ "the world reads the mode's terrain declaration and calls the generator "
		+ "it names")
	eq(counts[0][0], 0,
		"and none of the base round's sections are (%d of %d)"
			% [counts[0][0], counts[0][1]])
	built.queue_free()

# --- 2. Content against pools -------------------------------------------------

func _a_mode_runs_what_its_terrain_places() -> void:
	var checked := 0
	for mode in GameMode.MODES.keys():
		var placed := {}                      # content -> how many
		for seed_value in SEEDS:
			var seg = _terrain_for(mode, seed_value)
			if seg == null:
				continue
			for z in seg.length:
				for x in seg.width:
					var c: int = seg.content_at(x, z)
					if GameMode.CONTENT_POOLS.has(c):
						placed[c] = int(placed.get(c, 0)) + 1
		for c in placed.keys():
			var pool: String = GameMode.CONTENT_POOLS[c]
			checked += 1
			check(GameMode.runs(mode, pool),
				"%s places %d of content %d over %d seeds, so it must run `%s` -- "
					% [GameMode.MODES[mode]["name"], int(placed[c]), c, SEEDS, pool]
				+ "content placed for a pool that is switched off is scenery that "
				+ "never moves, and nothing anywhere reports it")
		print("[route] %s places %d kinds needing a pool"
			% [GameMode.MODES[mode]["name"], placed.size()])

	# THE LIVE HALF. Everything above is vacuously true of a mode that places
	# nothing at all -- and if `_apply_lane` ever stopped dressing lanes, or the
	# gauntlet's step walked off the end, this file would go green over an empty
	# set. That is the rejection-oracle shape in a different coat, so the claim
	# that bites is a PRESENCE one: somebody's terrain really does place content
	# that needs a pool switched on.
	check(checked > 0,
		"at least one mode places content a pool has to be running for (%d) -- "
			% checked
		+ "without this the correspondence above is a wall of green over nothing")

# THE GENERATOR A MODE'S TERRAIN NAMES.
#
# EVERY TERRAIN IS LISTED, AND AN UNKNOWN ONE FAILS RATHER THAN FALLING BACK.
# This dispatch used to end in `_: return section()`, which meant a mode whose
# terrain nobody had added a case for was silently measured as the ORDINARY
# BRIDGE -- and the correspondence check above then reported the bridge's spikes
# and turrets under the new mode's name. Observed the moment RACE was added: three
# confident failures about content the race circuit does not place, naming a pool
# it has no reason to run.
#
# That is the wrong-object trap, arriving as a false ALARM instead of a false
# pass, which is the luckier half of it. A default case in a test that dispatches
# on a registry is a promise that the registry will never grow.
func _terrain_for(mode: int, seed_value: int):
	match GameMode.terrain(mode):
		GameMode.TERRAIN_TRACK:
			return SegmentGen.bus_track(WIDTH, seed_value, seed_value % 7)
		GameMode.TERRAIN_BLANK:
			return SegmentGen.blank_zone(WIDTH, seed_value, seed_value % 7)
		GameMode.TERRAIN_RACE:
			return SegmentGen.race_loop(WIDTH, seed_value, seed_value % 7)
		GameMode.TERRAIN_SECTIONS:
			return SegmentGen.section(WIDTH, seed_value, seed_value % 7)
		_:
			check(false,
				"a mode's terrain `%s` has no generator in this test -- add the "
					% GameMode.terrain(mode)
				+ "case rather than letting it be measured as the ordinary bridge, "
				+ "which reports that terrain's content under this mode's name")
			return null

# --- 3. Somewhere to put the bus ----------------------------------------------

func _a_bus_is_put_down_on_road() -> void:
	var built = BridgeGridScript.new()
	built.name = "SpawnRun"
	world.add_child(built)
	built.width = WIDTH
	built.build_run(97531, SegmentPool.SECTIONS_PER_ROUND + 1, [GameMode.TRACK])

	# The run's depth in rows, taken off the segments rather than assumed.
	var rows := 0
	for i in built.segment_count():
		var seg = built.segment_data(i)
		if seg != null:
			rows += seg.length

	var solid := 0
	var void_cells := 0
	var none := 0
	var hugging := 0
	var samples := 0
	var last: int = maxi(1, rows - SimConfig.BUS_SPAWN_FAR)
	for row in range(0, last):
		samples += 1
		var cell: Vector2i = BusBody.spawn_cell(built, Vector2i(WIDTH / 2, row))
		if cell.x < 0:
			none += 1
			continue
		if built.is_solid(cell):
			solid += 1
		else:
			void_cells += 1
		if cell.x <= 1 or cell.x >= WIDTH - 2:
			hugging += 1
	print("[route] spawn over %d rows: %d on road, %d in void, %d nowhere, %d on a rail"
		% [samples, solid, void_cells, none, hugging])

	check(samples > 40, "the sweep really covers a run (%d rows of track)" % samples)
	eq(void_cells, 0,
		"a bus is never put down over a hole (%d of %d) -- it would not error, it "
			% [void_cells, samples]
		+ "would fall, and the party would stand on a race track with no vehicle")
	eq(none, 0,
		"and there is always somewhere to put it (%d rows with no road within %d "
			% [none, SimConfig.BUS_SPAWN_FAR - SimConfig.BUS_SPAWN_NEAR]
		+ "ahead) -- every track row has lane in it, so this is the generator's "
		+ "claim as much as the search's")
	# AND IT IS NOT MERELY THE FIRST SOLID CELL IT MET. Nearest-to-centre is the
	# whole reason this is a search rather than a scan: the first solid cell in a
	# serpentine row is against whichever rail that lane starts at, so a left-to-
	# right walk would hug column 0 almost everywhere and park the bus on the rail
	# of a lane the party is not in.
	check(hugging * 3 < solid,
		"the bus is put down near the middle of the road rather than against a "
		+ "rail (%d of %d) -- a left-to-right scan would fail this" % [hugging, solid])
	built.queue_free()
