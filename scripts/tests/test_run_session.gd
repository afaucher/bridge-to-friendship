extends "res://scripts/test_support/test_case.gd"

# MVP criteria D2, D3, D4 -- the session half of M8.
#
# The claim everything here rests on: **the bridge is a pure function of (seed,
# segment count)**. That is what makes drop-in affordable. A player joining a run
# in progress is told two numbers, builds the identical bridge locally, and needs
# only a diff of what has moved since. If this ever stops being true, joining
# means shipping a world down the wire and D2's five-second budget is gone.
#
# D1 (two players on separate machines over a Steam lobby) is not here and cannot
# be: the gate has no Steam client. ENet proves the replication; Steam is the
# transport swap, and that is exactly why NetworkManager has two.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PORT := 28781
const RUN_SEED := 4242

var harness: Node = null
var client_peer: int = 0
var frame: int = 0
var joined_at_tick: int = -1

func setup(main) -> void:
	timeout_seconds = 40.0
	_test_plan_is_deterministic()
	_test_segments_stack()
	_test_checkpoint_and_wipe(main)
	_test_solo_hang_is_not_a_wipe(main)

	# Drop-in: a host that has already been running, and a client that arrives
	# later and has to end up with the same bridge.
	harness = NetHarness.new()
	add_child(harness)
	harness.assemble_run = true
	harness.run_seed = RUN_SEED
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

# --- The bridge is a pure function of the seed --------------------------------

func _test_plan_is_deterministic() -> void:
	var a: Array = SegmentPool.plan(RUN_SEED, 6)
	var b: Array = SegmentPool.plan(RUN_SEED, 6)
	eq(a, b, "the same seed always plans the same run")
	eq(a.size(), 6, "and plans as many segments as asked for")

	var other: Array = SegmentPool.plan(RUN_SEED + 1, 6)
	check(a != other, "a different seed plans a different run")

	# Extending a run must not rewrite it: a client told "you now have 6" has
	# already built the first 3, and they must still be the same three.
	var shorter: Array = SegmentPool.plan(RUN_SEED, 3)
	eq(shorter, a.slice(0, 3), "extending a run leaves the segments already built alone")

	# Every run opens on the same ground, so nobody is dropped straight into the
	# hardest thing in the pool.
	eq(SegmentPool.plan(1, 1)[0], SegmentPool.plan(999, 1)[0], "every run starts the same way")

# --- Segments stack into a continuous climb -----------------------------------

func _test_segments_stack():
	var world := _solo_world(null)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)

	check(world.grid.segment_count() >= 2, "a run loads several segments")

	# The join is what stacking is for: the last row of one segment and the first
	# row of the next must be at the same height, or the bridge has a step in it
	# that no ascender covers.
	var boundary: int = world.grid.first_row_of_segment(1)
	var below: int = world.grid.height_at(Vector2i(GridConfig.DEFAULT_WIDTH / 2, boundary - 1))
	var above: int = world.grid.height_at(Vector2i(GridConfig.DEFAULT_WIDTH / 2, boundary))
	eq(above, below, "segments join at a matching deck height (%d -> %d)" % [below, above])

	# And the run genuinely climbs, rather than every segment restarting at zero.
	var last_row: int = world.grid.total_length() - 1
	check(world.grid.height_at(Vector2i(GridConfig.DEFAULT_WIDTH / 2, last_row)) > 0,
		"the run gains height across segments")
	world.stop()
	world.queue_free()

# --- Checkpoints and the wipe -------------------------------------------------

func _test_checkpoint_and_wipe(main) -> void:
	var world := _solo_world(main)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	var a: Node = world.player_body(1)
	var b: Node = world.player_body(2)

	# Walk the party well up the bridge.
	#
	# CHECKPOINTS ARE GONE (M16). They banked a segment index every N segments and
	# a wipe restarted there; with rounds the answer to "where does the party
	# restart" is always THE LOBBY THEY CAME FROM, which is authored and obvious
	# rather than derived from arithmetic on a segment index. The claim this phase
	# makes is unchanged in spirit -- a wipe does not drop you at the bottom of
	# the bridge -- and is now asserted against the lobby.
	var deep_row: int = world.grid.first_row_of_segment(2) + 2
	a.position = world.grid.cell_surface_world(Vector2i(7, deep_row)) + Vector3(0.0, 1.0, 0.0)
	b.position = a.position + Vector3(2.0, 0.0, 0.0)
	world._process_run()

	# EVERYONE DOWN IS NOT YET A WIPE. A downed player still has a bleed-out and a
	# drone; the run has not lost ground until nobody can come back on their own.
	# This used to fire here, which meant a hanging player's rescue window closed
	# the instant they were the last one up -- see _check_wipe.
	a.begin_downed()
	b.begin_downed()
	world._process_run()
	eq(world.wipes, 0, "everyone DOWN is not yet a wipe -- they still have a countdown")

	# A HANGING player is the case that broke: catching a lip must never be the
	# thing that ends the run.
	a.revive()
	b.revive()
	a._begin_hang(world.grid.cell_surface_world(Vector2i(7, deep_row)), GridConfig.DIR_NORTH)
	b._begin_hang(world.grid.cell_surface_world(Vector2i(9, deep_row)), GridConfig.DIR_NORTH)
	world._process_run()
	eq(world.wipes, 0, "and a party hanging off a lip is not a wipe either")

	# Past rescue: waiting on the drone, nobody able to reach them. NOW it is one.
	world._begin_drone_return(1)
	world._begin_drone_return(2)
	world._process_run()

	eq(world.wipes, 1, "everyone waiting on the drone at once IS a wipe")
	eq(a.state, PlayerBody.State.WALK, "which puts the party back on their feet")
	eq(a.health, SimConfig.MAX_HEALTH, "at full health")
	var restored: Vector2i = world.grid.cell_of_world(a.position)
	var lobby_row: int = maxi(world.round_machine.rear_row + 1, 1)
	check(absi(restored.y - lobby_row) <= 3,
		"IN THE LOBBY (row %d, lobby %d) -- not wherever they fell" % [restored.y, lobby_row])
	check(a.position.distance_to(b.position) > 0.5, "and not stacked on each other")

	world.stop()
	world.queue_free()

# --- A lone player's hang is not a wipe ---------------------------------------
#
# The reported bug at its sharpest. Solo, "everyone is out" is just you, so
# catching a lip restarted the run on the tick you grabbed it -- and a lone player
# could never reach the hang timer or the drone at all.
#
# There is deliberately NO special case for a party of one. The rule "a wipe is
# when everyone is past rescue" produces the right answer here on its own, and a
# rule with a player-count exception in it is one nobody can predict from the
# outside.
func _test_solo_hang_is_not_a_wipe(parent) -> void:
	var world := _solo_world(parent)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	var a: Node = world.player_body(1)

	a._begin_hang(world.grid.cell_surface_world(Vector2i(7, 4)), GridConfig.DIR_NORTH)
	var hung_at: Vector3 = a.position

	# Long enough that an instant wipe could not be missed by sampling once.
	for _i in 30:
		world._process_run()

	eq(world.wipes, 0, "a lone player hanging off a lip does not wipe the run")
	eq(a.state, PlayerBody.State.LEDGE_HANG, "they are left hanging, with their timer running")
	near(a.position.distance_to(hung_at), 0.0, 0.01,
		"and are still where they caught -- not teleported back to a checkpoint")

	world.stop()
	world.queue_free()

func _solo_world(parent) -> Node3D:
	var world := Node3D.new()
	world.name = "RunWorld%d" % randi()
	world.set_script(GameWorldScript)
	if parent != null:
		parent.add_child(world)
	else:
		add_child(world)
	return world

# --- Drop-in ------------------------------------------------------------------

func _on_ready() -> void:
	client_peer = harness.client_mps[0].get_unique_id()
	joined_at_tick = harness.host_world.tick

func _physics_process(_delta: float) -> void:
	if harness == null or not harness.is_ready:
		return
	frame += 1
	if frame != 120:
		return

	var host_world: Node3D = harness.host_world
	var client_world: Node3D = harness.client_worlds[0]

	# THE WHOLE POINT: the client was told a seed and a count, and built the same
	# bridge. Never sent one.
	eq(client_world.grid.run_seed, host_world.grid.run_seed, "the joiner is told which run this is")
	eq(client_world.grid.segment_count(), host_world.grid.segment_count(),
		"and builds the same number of segments")
	eq(client_world.grid.total_length(), host_world.grid.total_length(),
		"so the bridges are the same length")

	# Spot-check the geometry itself rather than trusting the counts.
	for row in [1, 12, host_world.grid.total_length() - 2]:
		var cell := Vector2i(7, int(row))
		eq(client_world.grid.height_at(cell), host_world.grid.height_at(cell),
			"deck height agrees at row %d" % row)
		eq(client_world.grid.is_solid(cell), host_world.grid.is_solid(cell),
			"and so does what is solid at row %d" % row)

	# And the live world arrived too.
	eq(client_world.players.size(), host_world.players.size(), "the joiner sees every player")
	check(frame < 300, "all of it inside D2's budget")

	harness.shutdown()
	finish()
