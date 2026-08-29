extends "res://scripts/test_support/test_case.gd"

# THE BLANK ZONE: A MODE THAT GENERATES ITS OWN GROUND.
#
# The second mode, and deliberately not a gameplay variant. What the bus and the
# shooter will both need is not a different rule about hazards -- it is that a mode
# MAKES ITS OWN TERRAIN. A bus wants a route and a shooter wants a corridor, and
# neither is `section()` with knobs on. So the cheapest honest second mode is the
# smallest instance of that seam, producing the simplest thing a generator can
# produce.
#
# IT IS ALSO WHAT MAKES THE SUBSYSTEM x MODE GRID REAL. With one mode that table
# had one row, and every entry agreed with every other by construction. A second
# row that switches eleven pools OFF is the first time the grid can be wrong.
#
# EVERY CLAIM HERE IS A PRESENCE CLAIM -- no hazards, no set pieces, one height --
# and that is on purpose. `SegmentGen.section()` validates and rerolls, so a
# generator bug does not produce broken output, it produces NO output, and every
# correctness assertion then passes over an empty set. This project lost a day to
# exactly that shape on split plateaus, and the tell was a presence counter.
#
# The claims:
#   1. THE ZONE EXISTS AT ALL, which is the assertion a rejection oracle can make
#      unreachable and therefore the one worth making first.
#   2. IT IS FLAT AND EMPTY: one height, no content, no hazards.
#   3. IT IS CROSSABLE, and by the ordinary validator -- a blank zone is still
#      walked by a walking player, so this mode does NOT need the per-mode
#      traversal model that the bus will.
#   4. IT JOINS THE BRIDGE. Same width conventions as a lobby, and a solid column
#      on both sides of the seam, or the run is a dead end nobody printed.
#   5. THE POOLS IT SWITCHES OFF DO NOT RUN, asked through the world rather than
#      the table -- a declaration nothing reads is a comment.
#   6. AND BASE IS UNCHANGED, because a second mode that quietly altered the first
#      would be the leak this whole design exists to prevent.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")

const WIDTH := 21
const SEEDS := 40

# POOLS THAT BELONG TO A MODE RATHER THAN TO THE GAME. Base is expected NOT to
# run these, and every entry is a decision somebody has to come here and make --
# which is the point of listing them rather than loosening the assertion.
#
# `bus` is the blank zone's own content and has never existed on the bridge, so
# base declaring it OFF is not base being changed. The claim below is still that
# adding a mode did not quietly switch off something the ordinary game HAS.
const MODE_ONLY := ["bus"]

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 60.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "BlankWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if done or world.tick < 2:
		return
	done = true
	set_physics_process(false)

	_it_exists_and_is_blank()
	_the_run_uses_the_mode_it_was_given()
	_it_is_crossable()
	_it_joins_the_bridge()
	_the_pools_it_turns_off_do_not_run()
	_base_is_unchanged()
	finish()

# --- 1, 2. It exists, and there is nothing in it -----------------------------

func _it_exists_and_is_blank() -> void:
	var made: int = 0
	var contents: int = 0
	var heights: Dictionary = {}
	var kinds: Dictionary = {}
	for seed_value in SEEDS:
		var seg = SegmentGen.blank_zone(WIDTH, seed_value * 7919, seed_value)
		if seg == null:
			continue
		made += 1
		for z in seg.length:
			for x in seg.width:
				if seg.is_solid(x, z):
					heights[seg.height_at(x, z)] = true
					kinds[seg.kind_at(x, z)] = true
					if seg.content_at(x, z) != GridConfig.Content.NONE:
						contents += 1
	print("[blank] %d of %d seeds produced a zone; %d contents, heights %s"
		% [made, SEEDS, contents, str(heights.keys())])

	# THE PRESENCE CLAIM FIRST. A generator that validates and rerolls turns a bug
	# into an ABSENCE, and every assertion below would then be a wall of green over
	# nothing at all.
	eq(made, SEEDS,
		"every seed produces a zone (%d of %d) -- this is the assertion a rejection "
			% [made, SEEDS]
		+ "oracle can quietly make unreachable, so it is the one made first")

	eq(contents, 0,
		"and there is nothing in any of them (%d contents) -- no hazards, no "
			% contents + "pickups, no set pieces. That is what blank means")
	eq(heights.size(), 1,
		"at exactly one height (%s) -- flat is the whole of this mode's terrain "
			% str(heights.keys()) + "rule, and two heights would be a slope nobody asked for")
	check(kinds.has(GridConfig.Kind.DECK) and kinds.size() == 1,
		"and every standable cell is plain DECK (%s) -- no ramps, no water, "
			% str(kinds.keys()) + "nothing that behaves")

	# UNDRESSED, and that is a SECOND statement from "the generator made it empty".
	# The dressing pass is a separate stage that scatters hazards over generated
	# ground; without this flag a blank zone would be flat terrain with the usual
	# threats on it, which would read as the mode having failed to take effect.
	var one = SegmentGen.blank_zone(WIDTH, 12345, 3)
	check(one.no_dress,
		"the zone refuses the dressing pass -- being generated empty and being "
		+ "left empty are two different things, and only the second is visible")
	check(one.tags.has("blank"), "and it is tagged as what it is")

# --- 2b. AND THE WORLD BUILDS IT WHEN THE MODE SAYS SO -------------------------
#
# THE ASSERTION THE FIRST DRAFT DID NOT HAVE, found by A/B: with
# `GameMode.terrain()` hardwired to return the ordinary bridge, this file still
# PASSED. Everything above calls `SegmentGen.blank_zone()` by hand, so it tested
# the generator and never the caller -- and the caller is the entire seam this
# mode exists to build. A test that hand-builds its own input has not tested the
# caller, and the caller is usually where the bug is.
func _the_run_uses_the_mode_it_was_given() -> void:
	var cycle: int = SegmentPool.SECTIONS_PER_ROUND + 1
	var built = BridgeGridScript.new()
	built.name = "BlankRun"
	world.add_child(built)
	built.width = WIDTH
	# ROUND 0 BASE, ROUND 1 BLANK -- both in one run, so the claim is that the
	# builder switches rather than that it can be configured. A run that was blank
	# throughout would pass with the mode ignored and a constant swapped.
	built.build_run(4242, cycle * 2, [GameMode.BASE, GameMode.BLANK])

	var base_blank := 0
	var blank_blank := 0
	var base_slots := 0
	var blank_slots := 0
	for i in built.segment_count():
		if SegmentPool.is_lobby_slot(i):
			continue          # a lobby is always base and never asks
		var seg = built.segment_data(i)
		if seg == null:
			continue
		var is_blank: bool = seg.tags.has("blank")
		if SegmentPool.round_of_slot(i) == 0:
			base_slots += 1
			base_blank += 1 if is_blank else 0
		else:
			blank_slots += 1
			blank_blank += 1 if is_blank else 0
	print("[blank] round 0: %d/%d blank; round 1: %d/%d blank"
		% [base_blank, base_slots, blank_blank, blank_slots])

	check(base_slots > 0 and blank_slots > 0,
		"the run really covers two rounds (%d + %d sections)"
			% [base_slots, blank_slots])
	eq(blank_blank, blank_slots,
		"every section of the round chosen as BLANK is a blank zone (%d of %d) -- "
			% [blank_blank, blank_slots]
		+ "this is the seam: the world reads the mode's terrain declaration and "
		+ "calls the generator it names")
	eq(base_blank, 0,
		"and none of the base round's sections are (%d of %d), so the builder is "
			% [base_blank, base_slots]
		+ "SWITCHING rather than having been configured once")
	built.queue_free()

# --- 3. And it can be walked --------------------------------------------------

func _it_is_crossable() -> void:
	# BY THE ORDINARY VALIDATOR, which is the interesting half. The plan warns that
	# a mode with a different BODY needs its own answer to "can this be crossed" --
	# a ship corridor validated by "can a player walk this?" is nonsense. A blank
	# zone is walked by a walking player, so it does NOT need that yet, and saying
	# so here is what stops the next reader assuming it does.
	for seed_value in SEEDS:
		var seg = SegmentGen.blank_zone(WIDTH, seed_value * 104729, seed_value)
		var problems: Array = SegmentValidator.validate(seg)
		if not eq(problems.size(), 0,
				"seed %d validates for a walking player (%s)"
					% [seed_value, str(problems)]):
			return

# --- 4. It joins ---------------------------------------------------------------

func _it_joins_the_bridge() -> void:
	# THE JOIN CONTRACT, which BridgeGrid enforces by REFUSING to load a segment --
	# so a zone that failed it would not appear, and the run would silently be
	# shorter than the plan. That is the absence failure again, one layer up.
	var zone = SegmentGen.blank_zone(WIDTH, 999, 1)
	var lobby = SegmentGen.lobby(WIDTH, 999, 0)
	eq(zone.width, lobby.width,
		"a zone shares the CANVAS with the lobby (%d cells) -- BridgeGrid refuses "
			% zone.width + "to join two segments of different canvas widths at all")

	# ...AND THE CANVAS IS NOT THE DECK, which is the distinction the first version
	# of this assertion missed entirely. Both segments fill the same 21-cell canvas
	# whatever they cut out of it, so `zone.width == lobby.width` was true before
	# and after the zone was opened out and could not tell the two apart. CLAUDE.md
	# has this one twice over: `width` meant four things at once until the day they
	# came apart, and the uses that read it without thinking were the wrong ones.
	var zone_deck: int = _widest_row(zone)
	var lobby_deck: int = _widest_row(lobby)
	print("[blank] deck: zone %d cells (%.0f m), lobby %d cells (%.0f m)"
		% [zone_deck, zone_deck * GridConfig.CELL_SIZE,
			lobby_deck, lobby_deck * GridConfig.CELL_SIZE])
	eq(zone_deck, zone.width,
		"and the zone uses ALL of it (%d of %d cells) -- an empty space that is "
			% [zone_deck, zone.width]
		+ "exactly as wide as the bridge is a stretch with the furniture removed; "
		+ "what makes it read as a PLACE is that it opens out")
	check(zone_deck > lobby_deck,
		"which is wider than the lobby it follows (%.0f m against %.0f m)"
			% [zone_deck * GridConfig.CELL_SIZE, lobby_deck * GridConfig.CELL_SIZE])

	# AND IT IS STILL FLAT, so those extra cells are deck continuing outward rather
	# than a lip to trip over at the join.
	var heights: Dictionary = {}
	for z in zone.length:
		for x in zone.width:
			if zone.is_solid(x, z):
				heights[zone.height_at(x, z)] = true
	eq(heights.size(), 1, "at one height across the whole of it")
	var overlap := 0
	for x in mini(lobby.width, zone.width):
		if lobby.is_solid(x, lobby.length - 1) and zone.is_solid(x, 0):
			overlap += 1
	check(overlap > 0,
		"and at least one column is solid on both sides of the seam (%d) -- "
			% overlap + "without it BridgeGrid refuses the segment and the run "
		+ "quietly comes up short")

# The widest solid span in a segment, in cells. The DECK, which is not the canvas.
func _widest_row(seg) -> int:
	var best := 0
	for z in seg.length:
		var n := 0
		for x in seg.width:
			if seg.is_solid(x, z):
				n += 1
		best = maxi(best, n)
	return best

# --- 5. The pools it turns off ------------------------------------------------

func _the_pools_it_turns_off_do_not_run() -> void:
	# ASKED THROUGH THE WORLD, not the table. `GameMode.runs()` returning false is
	# a declaration; `world.mode_runs()` being consulted at the top of a tick is the
	# behaviour. A declaration nothing reads is a comment.
	world.run_modes = [GameMode.BLANK]
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	eq(world.current_mode(), GameMode.BLANK, "the world is in the blank mode")

	var off: Array = []
	for pool in GameMode.POOLS:
		if not GameMode.runs(GameMode.BLANK, pool):
			off.append(pool)
			check(not world.mode_runs(pool),
				"the world agrees that '%s' does not run here" % pool)
	print("[blank] %d of %d pools are off in a blank zone" % [off.size(), GameMode.POOLS.size()])

	# AND A GATED POOL REALLY STOPS, measured rather than asked. Everything above
	# reads the same table the declaration lives in -- `world.mode_runs()` is a
	# wrapper over `GameMode.runs()` -- so all of it would pass with the gates
	# unwired, which is CLAUDE.md's "asserting the helper is not asserting the
	# pass". This is the pass: a live rusher, ticked, in each mode.
	var at: Vector3 = world.player_body(1).global_position + Vector3(0.0, 0.6, -6.0)
	var rusher: Node = world._spawn_rusher(at)
	if check(rusher != null and is_instance_valid(rusher), "a rusher exists to watch"):
		world.round_machine.state = RoundMachine.State.RUNNING
		world.run_modes = [GameMode.BLANK]
		var start: Vector3 = rusher.global_position
		for _i in 30:
			world._process_rushers()
		var moved_blank: float = start.distance_to(rusher.global_position)

		# THE CONTROL, and it has to be able to succeed: if the rusher would not
		# have moved in base either, "it did not move" says nothing at all. Same
		# lesson as the hat that could not be shot because the control was never
		# lifted clear of the deck.
		world.run_modes = [GameMode.BASE]
		start = rusher.global_position
		for _i in 30:
			world._process_rushers()
		var moved_base: float = start.distance_to(rusher.global_position)

		print("[blank] a rusher moved %.3f m in a blank zone, %.3f m in base"
			% [moved_blank, moved_base])
		check(moved_base > 0.05,
			"the control moves in base (%.3f m) -- without that, 'it did not move' "
				% moved_base + "is a claim about a rusher that was never going to")
		near(moved_blank, 0.0, 0.001,
			"and the same rusher does not move in a blank zone (%.3f m): the pool "
				% moved_blank
			+ "is gated at the top of its tick, not merely declared off in a table")
		world.run_modes = [GameMode.BLANK]
	check(off.size() >= 8,
		"and it really does switch a lot off (%d of %d) -- a second row that "
			% [off.size(), GameMode.POOLS.size()]
		+ "agreed with the first everywhere could not make the grid wrong, which "
		+ "is the only reason the grid needed a second row")

	# ...AND THE ONES THAT BELONG TO THE PLAYERS KEEP RUNNING. A zone you cannot be
	# rescued in would be a punishment rather than an empty room.
	for pool in ["rescue", "drone", "checkpoint", "hats", "specials"]:
		check(world.mode_runs(pool),
			"'%s' still runs -- it belongs to the players, not to the level" % pool)

	# THE LOBBY IS STILL BASE even inside a blank round, which is the escape hatch:
	# a mode that turned out to be broken must never be able to strand the party
	# somewhere they cannot choose again.
	world.round_machine.state = RoundMachine.State.LOBBY
	eq(world.current_mode(), GameMode.BASE, "and its lobby is base")
	for pool in GameMode.POOLS:
		if MODE_ONLY.has(pool):
			continue
		check(world.mode_runs(pool), "so '%s' runs again in the lobby" % pool)

# --- 6. Base is untouched -----------------------------------------------------

func _base_is_unchanged() -> void:
	# A SECOND MODE THAT ALTERED THE FIRST WOULD BE THE LEAK THIS DESIGN EXISTS TO
	# PREVENT -- and it would be invisible, because base is what everything else in
	# the gate is measured on.
	world.run_modes = [GameMode.BASE]
	world.round_machine.state = RoundMachine.State.RUNNING
	for pool in GameMode.POOLS:
		if MODE_ONLY.has(pool):
			continue
		check(world.mode_runs(pool),
			"base still runs '%s' with a second mode in the registry" % pool)
	eq(GameMode.terrain(GameMode.BASE), GameMode.TERRAIN_SECTIONS,
		"and base still builds the ordinary bridge")
	eq(GameMode.overrides(GameMode.BASE), {}, "and overrides nothing")
	world.round_machine.state = RoundMachine.State.LOBBY
