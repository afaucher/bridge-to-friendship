extends "res://scripts/test_support/test_case.gd"

# The bug this test was written for, and the reason M9 touches the simulation at
# all: `rescue_progress` was host-only.
#
# It is declared on the body and incremented by GameWorld._tick_haul/_tick_revive,
# which run on the host and nowhere else -- and it was NOT in capture_state(), so
# it never reached a snapshot. The "a teammate is pulling you up" bar therefore
# existed on exactly one machine in the session. On every client it would sit
# empty and silent, with no error anywhere, during the tensest moment the game
# has. An empty bar looks exactly like a rescue that is not happening.
#
# WHY IT ASSERTS ZERO FIRST. Written the obvious way -- down a player, wait, check
# the bar moved -- this test passes against a field that is always full, against
# one the client computes locally, and against a stubbed constant. So it pins the
# TRANSITION: zero while nobody is helping, above zero once someone is, measured
# on the CLIENT. That is CLAUDE.md's rule about validating an instrument against a
# case where it must report failure, applied to the instrument this milestone is.

const PORT := 28782
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const HudModel = preload("res://scripts/ui/hud/hud_model.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerBody = preload("res://scripts/sim/actors/player/player_body.gd")

# Far enough that REVIVE_RADIUS (2.5 m) cannot reach, close enough to stay on the
# gym floor.
const HELPER_PARKED := Vector3(18.0, 0.9, 0.0)

var harness: Node = null
var client_peer: int = 0
var phase: int = 0
var phase_frame: int = 0
var zero_while_alone: bool = true
# The frame the client first saw itself DOWNED, or -1. The quiet window is
# measured from THERE, not from when the host downed it: under a loaded parallel
# gate the snapshot carrying the state can take longer than any chosen frame.
var seen_down_at: int = -1

# POLLED, NOT SAMPLED. Both waits used to be a single chosen frame (20 and 30),
# which CLAUDE.md names as a coin flip on the unreliable snapshot, and the first
# of them lost the flip in a six-way parallel gate on 2026-09-25 ("expected 5,
# got 0") while passing solo every time.
const DOWN_DEADLINE := 240
const QUIET_WINDOW := 25
# The revive completes at REVIVE_SECONDS (90 ticks), which would put the bar back
# to NO_BAR and read as the failure this hunts -- so the deadline stays inside it.
const HELP_DEADLINE := 80
# THE CLIENT IS ALWAYS BEHIND, so agreement is asked of the host's RECENT past,
# not of its present. Comparing two moving values across a lossy link measures
# the link: in a loaded gate on 2026-09-25 the client read 0.078 while the host
# read 0.333, 23 ticks of honest lag. The claim that matters -- the client shows
# the SAME quantity on the same scale -- is that its value is one the host really
# had within the last LAG_WINDOW ticks. A wrong scale (the haul's seconds, the
# bleed-out's) matches nothing in that history.
const LAG_WINDOW := 40
const AGREE := 0.03
var host_history: Array = []

func setup(_main) -> void:
	timeout_seconds = 40.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	client_peer = harness.client_mps[0].get_unique_id()
	eq(harness.client_worlds[0].local_peer, client_peer, "the client knows which player is its own")

# The client's own view of itself -- which is the thing that was broken.
func _client_own() -> Dictionary:
	return HudModel.build(harness.client_worlds[0], client_peer)["own"]

func _physics_process(_delta: float) -> void:
	if not harness.is_ready:
		return
	phase_frame += 1
	match phase:
		0: _phase_down_the_client()
		1: _phase_nobody_helping()
		2: _phase_helper_arrives()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 1. Put the client's player down, with the host's player well clear -------

func _phase_down_the_client() -> void:
	if phase_frame < 10:
		return
	var host_world: Node3D = harness.host_world

	# Names ride the world's own multiplayer, so this is the only rig that can
	# exercise them. Checked for PRESENCE, not for content: what a peer announces
	# depends on whether the box has a Steam client, and both worlds here share
	# one process and therefore one persona.
	check(host_world.player_names.has(client_peer),
		"the client's name announcement reached the host")
	check(harness.client_worlds[0].player_names.has(1),
		"and the host's roster came back to the client")

	# The host owns every body, so this is done there and has to ARRIVE.
	host_world.player_body(1).position = HELPER_PARKED
	host_world.player_body(client_peer).begin_downed()
	_advance(1)

# --- 2. Nobody helping: the bar must read zero, on the client ------------------

func _phase_nobody_helping() -> void:
	var own: Dictionary = _client_own()
	if seen_down_at < 0:
		if int(own.get("state", -1)) != PlayerBody.State.DOWNED and phase_frame < DOWN_DEADLINE:
			return
		eq(int(own["state"]), PlayerBody.State.DOWNED, "the client sees itself go down")
		eq(str(own["state_label"]), "DOWN", "and reports it")
		check(bool(own["needs_help"]), "and knows it needs help")
		seen_down_at = phase_frame
	if float(own["rescue"]) > 0.001:
		zero_while_alone = false
	if phase_frame >= seen_down_at + QUIET_WINDOW:
		check(zero_while_alone,
			"with nobody in range the client's rescue bar stays EMPTY -- if this fails the bar is not measuring anything")
		var host_body: Node = harness.host_world.player_body(client_peer)
		near(float(host_body.rescue_progress), 0.0, 0.001, "and the host agrees nobody is helping")
		# Walk the helper over.
		harness.host_world.player_body(1).position = \
			harness.host_world.player_body(client_peer).position + Vector3(1.2, 0.0, 0.0)
		_advance(2)

# --- 3. Helper alongside: it must move, on the client --------------------------

func _phase_helper_arrives() -> void:
	# REVIVE_SECONDS is 1.5s = 90 ticks, so sample well inside that: a revive that
	# COMPLETES would put the player back in WALK and the bar back to NO_BAR,
	# which would read as the same failure this test is hunting.
	# Recorded from the FIRST tick of the phase, so the history covers every value
	# a lagging client could still be showing.
	var host_body: Node = harness.host_world.player_body(client_peer)
	var expected: float = clampf(host_body.rescue_progress / SimConfig.REVIVE_SECONDS, 0.0, 1.0)
	host_history.append(expected)
	if phase_frame < 30:
		return

	var own: Dictionary = _client_own()

	var client_fraction: float = float(own["rescue"])
	var matched: bool = false
	for k in range(maxi(0, host_history.size() - LAG_WINDOW), host_history.size()):
		if absf(client_fraction - float(host_history[k])) < AGREE:
			matched = true
			break
	if (client_fraction <= 0.05 or not matched) and phase_frame < HELP_DEADLINE:
		return

	check(host_body.rescue_progress > 0.0,
		"the host is running the revive (%.3f s)" % host_body.rescue_progress)
	check(client_fraction > 0.05,
		"and the CLIENT can see it -- rescue bar at %.2f, not stuck empty" % client_fraction)
	check(client_fraction <= 1.0, "without overflowing its bar")
	# The two ends agree about how far along it is, not merely that it is nonzero.
	check(matched,
		"and shows a value the host really had in the last %d ticks -- client %.3f, host now %.3f"
			% [LAG_WINDOW, client_fraction, expected])

	harness.shutdown()
	finish()
