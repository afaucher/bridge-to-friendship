extends "res://scripts/test_support/test_case.gd"

# A CLIENT KNOWS ITS OWN LAP.
#
# Laps are decided on the host, and until LapTracker they were never sent: a
# client's HUD read `lap_elapsed_of` and `best_lap_of` from dictionaries only the
# host ever wrote, so a racer on a client drove with no lap clock and no best,
# and the gate they should drive at next was never lit for them. The race was a
# mode that worked only for whoever hosted it.
#
# The claims, each on the CLIENT's own world:
#   1. A LAP STARTED ON THE HOST IS RUNNING ON THE CLIENT -- the clock counts.
#   2. THE NEXT GATE IS THE ONE THE HOST EXPECTS.
#   3. A BEST LAP REACHES IT.
#   4. A NEW ROUND CLEARS IT, as it clears the host's.

const NetHarness = preload("res://scripts/test_support/net_harness.gd")

const PORT := 28792
const DEADLINE := 600

var harness: Node = null
var phase := 0
var frame := 0

func setup(_main) -> void:
	timeout_seconds = 40.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()

func _physics_process(_delta: float) -> void:
	if harness == null or not harness.is_ready:
		return
	frame += 1
	var host: Node = harness.host_world
	var client: Node = harness.client_worlds[0]
	var peer: int = client.local_peer
	if not check(host.laps != null and client.laps != null, "both worlds have a lap tracker"):
		_end()
		return
	match phase:
		0:
			# The start line: begins a lap.
			host.laps.touch(peer, 0)
			phase = 1
			frame = 0
		1:
			if client.lap_elapsed_of(peer) <= 0 and frame < DEADLINE:
				return
			check(client.lap_elapsed_of(peer) > 0,
				"a lap the host started is running on the client (%d ticks)"
					% client.lap_elapsed_of(peer))
			eq(client._lap_next.get(peer, -1), host._lap_next.get(peer, -2),
				"and the client expects the same gate next as the host")
			host.laps.best[peer] = 1234
			host.laps._announce(peer)
			phase = 2
			frame = 0
		2:
			if client.best_lap_of(peer) != 1234 and frame < DEADLINE:
				return
			eq(client.best_lap_of(peer), 1234, "a best lap reaches the client")
			host.clear_round_stats()
			phase = 3
			frame = 0
		3:
			if (client.best_lap_of(peer) != 0 or client.lap_elapsed_of(peer) != 0) \
					and frame < DEADLINE:
				return
			eq(client.best_lap_of(peer), 0, "a new round clears the client's best too")
			eq(client.lap_elapsed_of(peer), 0, "and its running lap")
			_end()

func _end() -> void:
	harness.shutdown()
	finish()
