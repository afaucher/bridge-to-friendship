extends "res://scripts/test_support/test_case.gd"

# THE BASELINE FOR THE 2026-08-14 PLAYTEST'S PREDICTION GLITCH.
#
# Reported as: "collisions are tripping up prediction -- players touching each
# other tends to cause glitches". The diagnosis, from `playtest_2026_08_14.md`:
#
#   Predicting your own body requires knowing where everyone else's body is, and
#   that is exactly the thing a client does not have accurately.
#
# A client predicts its own body and simulates nothing else. Remote players are
# snapped to wherever the last snapshot said. The player's own collision mask
# includes other players -- so the host resolves the local body against a CURRENT
# opponent while the client resolves the same step against a stale one. Two
# different answers, a reconcile, a visible yank.
#
# THIS TEST IS DELIBERATELY WRITTEN BEFORE THE FIX. It exists to produce a number
# that a later change can be judged against, and it is written now precisely so
# that nobody can tune it afterwards to flatter the result.
#
# WHAT IT MEASURES, and why it is two numbers and not one:
#
#   corrections        how OFTEN the prediction disagreed
#   mean / worst       how FAR it was out when it did
#
# Interpolating remote players is expected to trade a few big corrections for
# more small ones. That is a large improvement in feel and the COUNT ALONE would
# score it as a regression, so the magnitude has to be recorded beside it or the
# measurement will give the wrong answer about the very change it exists to judge.
#
# THE INSTRUMENT IS VALIDATED BEFORE IT IS BELIEVED: the run asserts that the two
# bodies genuinely came into contact. A pair of players who never touched would
# report a beautiful correction count and mean nothing at all -- which is the
# failure mode CLAUDE.md records under "validate an instrument against a case
# where it must report failure".

const PORT := 28785
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

# COAST TO COAST, which is the session that produced the report. 10 ticks is
# ~167 ms of one-way staleness on the client's authority.
const DELAY_TICKS := 10

# Two bodies of radius 0.4 are touching at 0.8 m centre to centre. A little over
# that counts as contact -- the solver keeps a small skin between them.
const CONTACT_DISTANCE := 1.0

const SETTLE_TICKS := 40
const RUN_TICKS := 320

# Long enough for a decent number of dashes; the interval is past SHOVE_DURATION
# (6 ticks) plus SHOVE_COOLDOWN (21) so every press lands.
const DASH_TICKS := 400
const DASH_INTERVAL := 40

var harness: Node = null
var client_peer: int = 0
var frame: int = 0
var contact_ticks: int = 0
var closest: float = 1e9
var worst_remote_lag: float = 0.0
var dashing: bool = false
var dashes_fired: int = 0
var walk_count: int = 0
var walk_metres: float = 0.0
var walk_worst: float = 0.0

func setup(_main) -> void:
	timeout_seconds = 45.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	client_peer = harness.client_mps[0].get_unique_id()
	harness.client_worlds[0].debug_inbound_delay_ticks = DELAY_TICKS

	# BOTH PLAYERS WALK INTO EACH OTHER AND KEEP PUSHING. Sustained contact, not a
	# glancing touch: the report is about players who are ON each other, and a
	# single frame of overlap would be a sample size of one.
	#
	# They spawn on a ring, so "toward the other" is along the axis between them --
	# taken as straight up-bridge and straight down-bridge, which is what a party
	# bunching up on a narrow deck actually does.
	# EACH STEERS BY WHAT ITS OWN MACHINE CAN SEE, which is both realistic and the
	# only thing either one could do. Fixed compass directions were tried first and
	# the two missed each other entirely -- spawn points are a RING, so "up-bridge"
	# and "down-bridge" are not the axis between two of them. The instrument guard
	# caught that on the first run, which is exactly what it is there for.
	harness.set_input_provider(1, func(for_tick: int) -> Array:
		if for_tick <= SETTLE_TICKS:
			return PlayerInput.make(for_tick, Vector2.ZERO, 0)
		return PlayerInput.make(for_tick,
			_toward(harness.host_world, 1, client_peer), 0))
	harness.set_input_provider(client_peer, func(for_tick: int) -> Array:
		if for_tick <= SETTLE_TICKS:
			return PlayerInput.make(for_tick, Vector2.ZERO, 0)
		var toward: Vector2 = _toward(harness.client_worlds[0], client_peer, 1)
		if not dashing:
			return PlayerInput.make(for_tick, toward, 0)
		# DASH ON A CADENCE, aimed at whoever is in front. SHOVE is edge-triggered
		# and has a cooldown, so holding it would fire once and then be refused --
		# the interval is comfortably past SHOVE_DURATION plus SHOVE_COOLDOWN so
		# every press is a real dash.
		var actions := 0
		if for_tick % DASH_INTERVAL == 0:
			actions = SimConfig.ACTION_SHOVE
			dashes_fired += 1
		return PlayerInput.make(for_tick, toward, actions))

func _physics_process(_delta: float) -> void:
	if not harness.is_ready:
		return
	frame += 1

	var client_world: Node3D = harness.client_worlds[0]
	var gap: float = _gap(client_world)
	if gap < closest:
		closest = gap
	if gap <= CONTACT_DISTANCE:
		contact_ticks += 1

	# INSTRUMENT VALIDATION, SAMPLED EVERY TICK. How far the client's view of the
	# REMOTE body is from the host's own copy. Measuring this once at the END gave
	# 0.000 m at every latency -- because by then both players are pressed together
	# and STATIONARY, and a stationary body looks identical in every view however
	# stale. Latency is only visible on something that is moving.
	var host_remote: Node = harness.host_world.players.get(1)
	var client_remote: Node = client_world.players.get(1)
	if host_remote != null and client_remote != null 			and is_instance_valid(host_remote) and is_instance_valid(client_remote):
		worst_remote_lag = maxf(worst_remote_lag,
			host_remote.position.distance_to(client_remote.position))

	if frame == RUN_TICKS:
		_report_walk(client_world)
		return
	if frame < RUN_TICKS + DASH_TICKS:
		return
	_report_dash(client_world)
	harness.shutdown()
	finish()

# --- Phase A: walking into each other -----------------------------------------

func _report_walk(client_world: Node3D) -> void:
	check(contact_ticks > 30,
		"the two players really were in sustained contact (%d ticks within %.1f m, "
		% [contact_ticks, CONTACT_DISTANCE]
		+ "closest %.2f m) -- without this the correction count measures nothing"
			% closest)
	eq(client_world.debug_inbound_delay_ticks, DELAY_TICKS,
		"and the latency injection stayed on for the whole run")
	# AND THE LATENCY ACTUALLY DID SOMETHING. Checked because it very nearly did
	# not: read once at the END of a run this is 0.000 m at every setting, because
	# by then both players are pressed together and stationary, and a still body
	# looks identical in every view however stale. Sampled per tick it scales as it
	# should -- 0.40 m at 4 ticks of delay, 2.65 m at 40.
	check(worst_remote_lag > 0.2,
		"and the client really was looking at a stale remote body (%.2f m worst)"
			% worst_remote_lag)

	_report("WALKING", int(client_world.corrections),
		float(client_world.correction_metres), float(client_world.correction_worst))
	print("[contact-prediction]   contact     = %d ticks, closest %.2f m"
		% [contact_ticks, closest])

	# Snapshot, so phase B reports its OWN cost rather than a running total.
	walk_count = int(client_world.corrections)
	walk_metres = float(client_world.correction_metres)
	walk_worst = float(client_world.correction_worst)
	dashing = true

# --- Phase B: dashing into somebody -------------------------------------------
#
# THE SCENARIO THE PHASE-A NUMBERS POINT AT. Sustained contact turned out to be
# cheap, and the reason was visible in the same data: two players pressed together
# are both STILL, and a still body is predicted perfectly by anybody. A dash is the
# opposite in every respect -- 56 m/s, six ticks long, client-PREDICTED, and aimed
# at a body the client may have metres out of date.

func _report_dash(client_world: Node3D) -> void:
	check(dashes_fired > 3,
		"the client actually dashed at somebody (%d dashes) -- a phase that never "
		% dashes_fired + "pressed the button would report a beautiful zero")

	_report("DASHING", int(client_world.corrections) - walk_count,
		float(client_world.correction_metres) - walk_metres,
		float(client_world.correction_worst))
	print("[contact-prediction]   dashes      = %d, worst before this phase %.4f m"
		% [dashes_fired, walk_worst])

	# NO BUDGET ASSERTED ON EITHER NUMBER, deliberately -- today's figures ARE the
	# thing under investigation, and pinning them would pin the bug in place. What
	# is asserted is that the reconciler is alive, because a silent zero would mean
	# the measurement broke rather than the netcode being perfect.
	check(int(client_world.corrections) > 0,
		"the reconciler is running at all (%d corrections overall)"
			% client_world.corrections)

func _report(label: String, count: int, metres: float, worst: float) -> void:
	var mean: float = metres / float(count) if count > 0 else 0.0
	print("[contact-prediction] %s at %d ticks of latency:" % [label, DELAY_TICKS])
	print("[contact-prediction]   corrections = %d" % count)
	print("[contact-prediction]   mean miss   = %.4f m" % mean)
	print("[contact-prediction]   worst miss  = %.4f m" % worst)
	print("[contact-prediction]   remote lag  = %.3f m worst" % worst_remote_lag)


# Distance between the local player and the nearest other body, as the CLIENT
# sees it. The client's own view is the one that matters: it is the machine whose
# prediction is being judged, and the one the player is looking at.
func _gap(client_world: Node3D) -> float:
	var mine: Node = client_world.players.get(client_peer)
	if mine == null or not is_instance_valid(mine):
		return 1e9
	var best: float = 1e9
	for key in client_world.players.keys():
		var peer: int = int(key)
		if peer == client_peer:
			continue
		var other: Node = client_world.players[peer]
		if other == null or not is_instance_valid(other):
			continue
		best = minf(best, mine.position.distance_to(other.position))
	return best

# A unit step from one player toward another, in the world-space (x, z) packing
# the input uses -- PlayerBody reads `move` straight into a wish vector.
func _toward(world: Node3D, from_peer: int, to_peer: int) -> Vector2:
	if world == null:
		return Vector2.ZERO
	var mine: Node = world.players.get(from_peer)
	var other: Node = world.players.get(to_peer)
	if mine == null or other == null 			or not is_instance_valid(mine) or not is_instance_valid(other):
		return Vector2.ZERO
	var to := Vector2(other.position.x - mine.position.x,
		other.position.z - mine.position.z)
	# KEEP PUSHING ONCE THEY ARE TOUCHING. Releasing at contact would give one
	# frame of overlap and then a walk away, and the report is about players who
	# are ON each other.
	if to.length() < 0.05:
		return Vector2.ZERO
	return to.normalized()
