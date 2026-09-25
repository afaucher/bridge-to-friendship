extends "res://scripts/test_support/test_case.gd"

# A CLIENT BUILDS THE SAME GROUND AS THE HOST AFTER A MODE PICK.
#
# The selector rolls a fresh SEED for the round it picks (`_roll_seed_for_round`),
# so from that moment the run is a function of (seed, count, modes, seeds) -- and
# the host built its corridor from all four while a client was handed the seeds
# and then built from three. `_extend_run_to` stored them and did not pass them
# to `build_run`, and the late-join message did not send them at all. Every
# client stood on the run seed's terrain while the host simulated the rolled
# seed's: different holes, different walls, one bridge on each machine.
#
# Two ways in, and both are tested because they are two different lines:
#   A. LATE JOIN. The host picks before the client exists, so everything the
#      client learns comes from `host_add_peer`.
#   B. LIVE. The client is already here when the pick happens, so it learns the
#      rebuild from `_extend_run_to` on the way through `_extend_run`.
#
# THE COMPARISON IS THE WHOLE GRID, cell by cell -- kind, height and content --
# because a desync is "somewhere", and a sample of one row would pass a corridor
# that differed everywhere else.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const NetHarness = preload("res://scripts/test_support/net_harness.gd")

const PORT := 28790
const RUN_SEED := 777

var harness: Node = null
var phase: int = 0
var frame: int = 0
var picked_live: bool = false

func setup(_main) -> void:
	timeout_seconds = 60.0
	harness = NetHarness.new()
	add_child(harness)
	harness.assemble_run = true
	harness.run_seed = RUN_SEED
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	# PHASE A: pick BEFORE the client has connected. The handshake takes frames,
	# so the client world does not exist in the session yet -- whatever it builds
	# is built from what host_add_peer tells it.
	var host: Node = harness.host_world
	eq(int(host.round_machine.state), RoundMachine.State.LOBBY, "the host starts in a lobby")
	var before: Array = host.run_seeds.duplicate()
	host.selected_mode = GameMode.TRACK
	host._poll_mode_selection()
	check(host.run_seeds != before, "picking a mode rolls a seed for the round (%s -> %s)"
		% [str(before), str(host.run_seeds)])
	eq(host.mode_for_round(host.round_index()), GameMode.TRACK, "and the host's round is the pick")

func _physics_process(_delta: float) -> void:
	if harness == null or not harness.is_ready:
		return
	frame += 1
	var host: Node = harness.host_world
	var client: Node = harness.client_worlds[0]
	match phase:
		0:
			if client.grid == null or client.grid.segment_count() < host.grid.segment_count():
				return
			_compare(host, client, "late join")
			phase = 1
			frame = 0
		1:
			# PHASE B: the client is here now. Pick again, differently.
			if not picked_live:
				host.selected_mode = GameMode.RACE
				picked_live = true
				return
			if frame < 30:
				return
			eq(client.mode_for_round(client.round_index()), GameMode.RACE,
				"the client was told about the live pick")
			if client.grid.segment_count() < host.grid.segment_count():
				return
			_compare(host, client, "live pick")
			harness.shutdown()
			finish()

func _compare(host: Node, client: Node, label: String) -> void:
	eq(client.run_seeds, host.run_seeds, "%s: the client holds the host's round seeds" % label)
	eq(client.grid.segment_count(), host.grid.segment_count(),
		"%s: both built the same number of segments" % label)
	var rows: int = mini(host.grid.total_length(), client.grid.total_length())
	var diffs: int = 0
	var first: String = ""
	for z in rows:
		for x in host.grid.width:
			var c := Vector2i(x, z)
			if host.grid.kind_at(c) != client.grid.kind_at(c) \
					or host.grid.height_at(c) != client.grid.height_at(c) \
					or host.grid.content_at(c) != client.grid.content_at(c):
				diffs += 1
				if first == "":
					first = str(c)
	eq(diffs, 0, "%s: every cell of %d rows agrees (first difference at %s)" % [label, rows, first])
	check(rows > 0, "%s: there was ground to compare" % label)
