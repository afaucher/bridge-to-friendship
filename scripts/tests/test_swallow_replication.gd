extends "res://scripts/test_support/test_case.gd"

# THE BUBBLE SWALLOW EXISTS ON EVERY MACHINE, AND GOES AWAY PROPERLY.
#
# Four claims, each of them a bug that shipped with M28:
#
#   1. A CLIENT HAS THE SWALLOW. There was no snapshot section and no RPC, so a
#      client never had one -- never saw it, and (worse) never felt its pull, so a
#      predicted client standing in one diverged from the host on every tick.
#      Asserted as the pull a client's own world computes, which is what its
#      prediction actually consumes, not merely a count.
#   2. IT DIES ON THE CLIENT TOO, and what it held spills there.
#   3. A WIPE TAKES IT, and counts what it held as lost. Every other thing the
#      level put there goes on a wipe; the swallow kept the party's hats across
#      the restart.
#   4. A MODE THAT SWITCHES SWALLOWS OFF counts the bank as lost too. It freed
#      them with no accounting, so hats left the game with nobody's `hats_lost`
#      going up.
#   5. A HIT TAKES ITS OWN STRENGTH, and a body arriving takes none. It read
#      `hit.damage`, a field `Hit` does not have, so everything did exactly 1.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const SwallowBody = preload("res://scripts/sim/swallow_body.gd")

const PORT := 28791
const A := 41

var harness: Node = null
var host_swallow = null
var phase := 0
var frame := 0
var worst_client_pull := 0.0

func setup(main) -> void:
	timeout_seconds = 60.0
	_a_hit_takes_its_own_strength()
	_a_wipe_takes_it(main)
	_a_mode_that_turns_it_off_counts_the_bank(main)

	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return

# --- 5. Damage ----------------------------------------------------------------

func _hit(kind: int, amount: int):
	var h = Hit.new()
	h.kind = kind
	h.amount = amount
	return h

func _a_hit_takes_its_own_strength() -> void:
	var s = SwallowBody.new()
	add_child(s)
	s.set_surfaced(true)
	var full: int = int(s.health)
	s.receive_hit(_hit(Hit.Kind.BULLET, 3))
	eq(int(s.health), full - 3, "a rifle-strength round takes three, not one")
	var after_round: int = int(s.health)
	check(not s.receive_hit(_hit(Hit.Kind.IMPACT, 5)), "a body arriving is refused")
	eq(int(s.health), after_round, "and takes nothing")
	s.receive_hit(_hit(Hit.Kind.EXPLOSIVE, 2))
	eq(int(s.health), after_round - 2, "a blast takes its own strength")
	s.queue_free()

# --- 3. The wipe --------------------------------------------------------------

func _solo(main, label: String) -> Node3D:
	var world := Node3D.new()
	world.name = label
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, A, false)
	world._spawn_player(A, 0)
	return world

func _a_wipe_takes_it(main) -> void:
	var world := _solo(main, "WipeWorld")
	var s = world._spawn_swallow(world.player_position(A) + Vector3(30.0, 0.0, 0.0))
	s.swallow_hat(0, A)
	eq(world.swallow_count(), 1, "wipe: a swallow is standing, holding a hat")
	world._restart_at_checkpoint()
	eq(world.swallow_count(), 0, "a wipe takes the swallow with the rest of the level")
	eq(int(world.stats_of(A).get("hats_lost", 0)), 1,
		"and the hat inside it is counted as lost")
	world.stop()
	world.queue_free()

# --- 4. A mode switches it off ------------------------------------------------

func _a_mode_that_turns_it_off_counts_the_bank(main) -> void:
	var world := _solo(main, "ModeOffWorld")
	var s = world._spawn_swallow(world.player_position(A) + Vector3(30.0, 0.0, 0.0))
	s.swallow_hat(0, A)
	world.run_modes = [GameMode.RACE]
	world.round_machine.state = RoundMachine.State.RUNNING
	check(not world.mode_runs("swallows"), "the race does not run swallows")
	world._process_swallows()
	eq(world.swallow_count(), 0, "so the swallow is cleared")
	eq(int(world.stats_of(A).get("hats_lost", 0)), 1,
		"and what it held is counted as lost, the way the corridor cut counts it")
	world.stop()
	world.queue_free()

# --- 1 and 2. Across the wire -------------------------------------------------

func _physics_process(_delta: float) -> void:
	if harness == null or not harness.is_ready:
		return
	frame += 1
	var host: Node = harness.host_world
	var client: Node = harness.client_worlds[0]
	var client_peer: int = client.local_peer
	match phase:
		0:
			# Beside the CLIENT's player, so it is the client's own prediction that
			# has to feel it -- inside the reach, outside the core.
			var at: Vector3 = host.player_position(client_peer) \
				+ Vector3(SimConfig.SWALLOW_CORE + 1.0, 0.0, 0.0)
			host_swallow = host._spawn_swallow(at)
			host_swallow.swallow_hat(0, 1)
			phase = 1
			frame = 0
		1:
			if client.swallow_count() == 0 or frame < 30:
				if frame > 240:
					eq(client.swallow_count(), 1, "the client was told the swallow exists")
					_end()
				return
			eq(client.swallow_count(), 1, "the client has the swallow")
			var theirs = client._swallows[0]
			check(bool(theirs.surfaced) == bool(host_swallow.surfaced),
				"and agrees whether it is up (host %s, client %s)"
				% [host_swallow.surfaced, theirs.surfaced])
			eq(int(theirs.bank_size()), int(host_swallow.bank_size()),
				"and what it is holding")
			# GLOBAL positions: the pull is a global-space query, and the client's
			# world sits a kilometre over from the host's (see NetHarness).
			var pull: Vector3 = client.swallow_pull_at(client.players[client_peer].global_position)
			var want: Vector3 = host.swallow_pull_at(host.players[client_peer].global_position)
			check(want.length() > 0.0, "the host pulls the client's player (%.2f)" % want.length())
			near(pull.length(), want.length(), 0.5,
				"and so does the client's OWN world, which is what its prediction replays")
			host_swallow.receive_hit(_hit(Hit.Kind.BULLET, 99))
			phase = 2
			frame = 0
		2:
			if client.swallow_count() > 0 and frame < 240:
				return
			eq(host.swallow_count(), 0, "a killed swallow is gone on the host")
			eq(client.swallow_count(), 0, "and on the client")
			_end()

func _end() -> void:
	harness.shutdown()
	finish()
