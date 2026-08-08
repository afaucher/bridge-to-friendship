extends "res://scripts/test_support/test_case.gd"

# MVP criterion B1: after a scripted sequence of inputs, two peers report
# identical world state.
#
# This is the test M1 exists to pass. A real host and a real client, each with
# their own GameWorld, in one process over a real socket — the host simulating
# both players, the client predicting only its own.
#
# WHY IT SETTLES BEFORE COMPARING: the client's view of a REMOTE player is
# whatever the last snapshot said, so while anyone is moving the two worlds are
# legitimately a few ticks apart and comparing then measures transit time rather
# than agreement. Holding zero input until everything is at rest removes the lag
# from the comparison without weakening it: if the two simulations disagreed
# about what the inputs did, they would come to rest in different places.

const PORT := 28779
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")

# Both players walk a scripted L-shape, jump, then stop. Different routes on
# purpose: identical inputs could agree by symmetry rather than by the
# simulation actually working.
const HOST_SCRIPT := [
	[60, Vector2(0.0, -1.0), 0],           # forward 1s
	[30, Vector2(1.0, 0.0), 0],            # right 0.5s
	[1, Vector2(1.0, 0.0), SimConfig.ACTION_JUMP],
	[90, Vector2(1.0, 0.0), 0],
]
const CLIENT_SCRIPT := [
	[45, Vector2(-1.0, 0.0), 0],           # left 0.75s
	[1, Vector2(-1.0, 0.0), SimConfig.ACTION_JUMP],
	[75, Vector2(0.0, 1.0), 0],            # back 1.25s
	[60, Vector2(0.0, 0.0), 0],
]
const SETTLE_TICKS := 120

var harness: Node = null
var client_peer: int = 0
var frame: int = 0
var scripted_ticks: int = 0

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
	check(client_peer > 1, "the client has a peer id above the host's")

	# Both worlds must agree on the roster before anything moves.
	eq(harness.host_world.players.size(), 2, "the host knows both players")
	eq(harness.client_worlds[0].players.size(), 2, "the client knows both players")

	scripted_ticks = _script_length(HOST_SCRIPT) + SETTLE_TICKS
	harness.set_input_provider(1, _make_provider(HOST_SCRIPT))
	harness.set_input_provider(client_peer, _make_provider(CLIENT_SCRIPT))

func _script_length(script: Array) -> int:
	var total := 0
	for entry in script:
		total += int(entry[0])
	return total

# Turns a [duration, move, actions] script into the input_provider callable the
# GameWorld pulls from. Deliberately the SAME hook a keyboard feeds, so the test
# cannot exercise a movement path the game does not use.
func _make_provider(script: Array) -> Callable:
	return func(for_tick: int) -> Array:
		var remaining: int = for_tick
		for entry in script:
			var duration: int = int(entry[0])
			if remaining <= duration:
				return PlayerInput.make(for_tick, entry[1], int(entry[2]))
			remaining -= duration
		return PlayerInput.empty(for_tick)

func _physics_process(_delta: float) -> void:
	if not harness.is_ready:
		return
	frame += 1
	if frame < scripted_ticks:
		return

	var host_world: Node3D = harness.host_world
	var client_world: Node3D = harness.client_worlds[0]

	# Every player, on every peer, in the same place.
	for peer in [1, client_peer]:
		var host_pos: Vector3 = host_world.player_position(peer)
		var client_pos: Vector3 = client_world.player_position(peer)
		var drift: float = host_pos.distance_to(client_pos)
		# 5 cm. Tight enough that a real disagreement about what the inputs did
		# cannot hide under it -- the scripted moves cover ~9 m — and loose
		# enough not to depend on float-exact agreement between two
		# independently-stepping simulations.
		check(drift < 0.05,
			"peer %d agrees on player %d position (host %v vs client %v, drift %.4f m)"
				% [client_peer, peer, host_pos, client_pos, drift])
		eq(client_world.player_state(peer), host_world.player_state(peer),
			"peers agree on player %d state" % peer)

	# Both players ended somewhere their inputs actually took them. Without this,
	# two simulations that both did nothing would agree perfectly.
	check(host_world.player_position(1).distance_to(host_world.spawn_point(0)) > 3.0,
		"the host player actually moved")
	check(host_world.player_position(client_peer).distance_to(host_world.spawn_point(1)) > 3.0,
		"the client player actually moved")

	harness.shutdown()
	finish()
