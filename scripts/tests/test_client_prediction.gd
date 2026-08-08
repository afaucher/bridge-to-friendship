extends "res://scripts/test_support/test_case.gd"

# MVP criterion B2: a client's own movement is predicted locally and reconciles
# without a visible snap under 120 ms of latency.
#
# Localhost has no round trip worth the name, so the client's inbound snapshots
# are held for 8 ticks (~133 ms at 60 Hz, comfortably past the 120 ms bar). That
# delays the authority the client is correcting against, which is exactly the
# condition prediction exists to survive.
#
# WHAT "WITHOUT A VISIBLE SNAP" MEANS HERE, and why it is measured this way:
# a correction is only visible if it MOVES the player. So the test records the
# client's own position every tick and asserts that no single tick displaces it
# further than a tick of ordinary walking could. A reconciliation that quietly
# agrees with the prediction moves nothing; one that fights it shows up as a
# position jump, which is precisely what a player would see.

const PORT := 28780
const DELAY_TICKS := 8
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")

# One tick of walking, plus generous headroom for acceleration and the physics
# solver. A genuine mispredict correction over 133 ms of divergence would be
# many times this.
const MAX_TICK_DISPLACEMENT := SimConfig.WALK_SPEED * SimConfig.TICK_DELTA * 2.5

const RUN_TICKS := 240

var harness: Node = null
var client_peer: int = 0
var frame: int = 0
var last_position: Vector3 = Vector3.ZERO
var have_last: bool = false
var worst_jump: float = 0.0
var worst_jump_tick: int = -1
var samples: int = 0

func setup(_main) -> void:
	timeout_seconds = 30.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	client_peer = harness.client_mps[0].get_unique_id()
	harness.client_worlds[0].debug_inbound_delay_ticks = DELAY_TICKS

	# Keep moving the whole time. A stationary player predicts perfectly and
	# proves nothing -- prediction only has to work while the player is doing
	# something the host has not confirmed yet.
	harness.set_input_provider(client_peer, func(for_tick: int) -> Array:
		var phase: int = (for_tick / 40) % 4
		var move := Vector2.ZERO
		match phase:
			0: move = Vector2(0.0, -1.0)
			1: move = Vector2(1.0, 0.0)
			2: move = Vector2(0.0, 1.0)
			3: move = Vector2(-1.0, 0.0)
		return PlayerInput.make(for_tick, move, 0))

func _physics_process(_delta: float) -> void:
	if not harness.is_ready:
		return
	frame += 1

	var client_world: Node3D = harness.client_worlds[0]
	var position: Vector3 = client_world.player_position(client_peer)

	# Ignore the first few ticks: the very first snapshot legitimately hard-sets
	# the body, because the client has no prediction history to compare against.
	if have_last and frame > DELAY_TICKS + 4:
		var jump: float = position.distance_to(last_position)
		samples += 1
		if jump > worst_jump:
			worst_jump = jump
			worst_jump_tick = frame
	last_position = position
	have_last = true

	if frame < RUN_TICKS:
		return

	check(samples > 150, "the run collected enough samples (%d)" % samples)
	check(worst_jump <= MAX_TICK_DISPLACEMENT,
		"no visible correction snap: worst single-tick displacement %.4f m at tick %d (budget %.4f m)"
			% [worst_jump, worst_jump_tick, MAX_TICK_DISPLACEMENT])

	# The client really did move under its own prediction rather than being
	# dragged around by authority, and it really was reconciling against a
	# delayed host.
	check(client_world.player_position(client_peer).distance_to(client_world.spawn_point(1)) > 1.0,
		"the client player moved under prediction")
	eq(client_world.debug_inbound_delay_ticks, DELAY_TICKS,
		"the latency injection stayed on for the whole run")

	print("[prediction] corrections=%d over %d ticks, worst tick displacement %.4f m"
		% [client_world.corrections, frame, worst_jump])

	harness.shutdown()
	finish()
