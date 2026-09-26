extends "res://scripts/test_support/test_case.gd"

# SIMULATING A COAST-TO-COAST LINK ON TWO MACHINES SITTING ON ONE DESK.
#
# A LAN is sub-millisecond, so every prediction and reconciliation path in this
# game runs in its easiest possible case -- and the report the telemetry was built
# for ("networking gets worse over time") came from a session across the country.
# The knobs make the short link behave like the long one.
#
# THE CLAIMS, and the first one is the one this project keeps needing:
#
#   1. IT IS INERT AT ITS DEFAULTS. A dev knob that costs something when it is off
#      is a knob that cannot ship, and the gate is a hundred worlds that must not
#      pay for it.
#   2. THE NUMBER MEANS MILLISECONDS AND ARRIVES AS TICKS, asserted as arithmetic
#      against TICK_DELTA rather than against a literal -- a packet can only be
#      consumed on a tick boundary, so that conversion is the whole contract.
#   3. BOTH LEGS. The label says "one way" and promises the round trip is twice it,
#      which is only true if a client's INPUT is delayed reaching the host as well
#      as the host's state coming back. Measured on the host's own view of how far
#      behind the client's input is, because that is the leg nobody would notice
#      was missing: with only the snapshot delayed the host still reacts on the
#      frame you press, and the game feels wrong in a way no number shows.
#   4. LOSS IS COUNTED AT THE LINE THAT DROPS THE PACKET, and the session survives
#      it. That is the design claim -- decisions go reliably, motion rides the
#      snapshot -- so a quarter of the snapshots going missing must cost nothing
#      but smoothness.
#   5. ONE SWITCH DOES ALL THREE, which is the control somebody will actually use.

const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const PlayerInput = preload("res://scripts/sim/actors/player/player_input.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# Its own port. The gate runs tests as parallel processes on one machine, so two
# tests sharing one is a race that fails whichever loses. See CLAUDE.md.
const PORT := 28793

const LATENCY_MS := 50.0
const LOSS_PCT := 25.0

var harness = null
var client_peer: int = 0
var phase: int = 0
var frame: int = 0
var noted: Dictionary = {}

func setup(_main) -> void:
	timeout_seconds = 60.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	client_peer = harness.client_mps[0].get_unique_id()
	# WALKING THE WHOLE TIME. A stationary client sends input that is identical
	# every tick, and "the host is behind" is unmeasurable on a player who is not
	# doing anything -- the same reason a latency instrument read on a still body
	# reports zero.
	harness.set_input_provider(client_peer, func(for_tick: int) -> Array:
		return PlayerInput.make(for_tick, Vector2(0.0, -1.0), 0))

func _teardown_knobs() -> void:
	# RESTORED BY NAME, because these are globals for the whole process and the
	# gate runs this file beside others in it. `test_gunners` learned this the hard
	# way with the machine-gun spread.
	DebugSettings.set_value("net_sim_preset", 0)
	DebugSettings.set_value("net_sim_latency_ms", 0.0)
	DebugSettings.set_value("net_sim_jitter_ms", 0.0)
	DebugSettings.set_value("net_sim_loss_pct", 0.0)

func _host() -> Node3D:
	return harness.host_world

func _client() -> Node3D:
	return harness.client_worlds[0]

func _physics_process(_delta: float) -> void:
	if harness == null or not harness.is_ready:
		return
	frame += 1
	# Unconditional heartbeat: five phases over a socket, each waiting on a
	# different condition, is the shape that presents as a timeout with no clue
	# which one never resolved.
	if frame % 120 == 0:
		print("[netlink] phase %d frame %d delayed %d dropped %d"
			% [phase, frame, _host().net_sim_delayed, _client().net_sim_dropped])
	match phase:
		0: _inert_by_default()
		1: _milliseconds_become_ticks()
		2: _both_legs_are_delayed()
		3: _loss_is_counted_and_survivable()
		4: _one_switch_does_all_three()

# --- 1. Inert by default --------------------------------------------------------

func _inert_by_default() -> void:
	# A FEW TICKS OF REAL TRAFFIC FIRST, so "nothing was queued" is a statement
	# about packets that really arrived rather than about a quiet session.
	if frame < 30:
		return
	check(_host().net_sim_delayed == 0 and _client().net_sim_delayed == 0,
		"nothing is queued at the defaults (host %d, client %d) -- a dev knob that "
			% [_host().net_sim_delayed, _client().net_sim_delayed]
		+ "costs something while it is off is a knob that cannot ship")
	check(_host().net_sim_dropped == 0 and _client().net_sim_dropped == 0,
		"and nothing is dropped (host %d, client %d)"
			% [_host().net_sim_dropped, _client().net_sim_dropped])
	eq(_host()._sim_link_ticks(), 0, "and the link adds no ticks at all")
	# AND THE TRAFFIC WAS REAL, which is what stops the three claims above being
	# true of a session where nothing happened.
	check(_host().players.has(client_peer),
		"the session is actually running -- the client's player exists on the host")
	phase = 1
	frame = 0

# --- 2. Milliseconds become ticks ------------------------------------------------

func _milliseconds_become_ticks() -> void:
	DebugSettings.set_value("net_sim_latency_ms", LATENCY_MS)
	# ARITHMETIC, NOT A LITERAL. 50 ms at a 60 Hz tick is three ticks, and writing
	# `3` here would be a test of today's physics rate rather than of the
	# conversion -- `test_sim_determinism` exists because that rate is allowed to
	# change.
	var wanted: int = int(round(LATENCY_MS / 1000.0 / SimConfig.TICK_DELTA))
	var got: int = _host()._sim_link_ticks()
	print("[netlink] %.0f ms -> %d ticks (wanted %d, tick is %.4f s)"
		% [LATENCY_MS, got, wanted, SimConfig.TICK_DELTA])
	eq(got, wanted,
		"the knob's milliseconds arrive as the right number of ticks (%d of %d) -- "
			% [got, wanted]
		+ "a packet can only be consumed on a tick boundary, so this conversion is "
		+ "the whole contract the label makes")
	check(got > 0,
		"and it is more than nothing (%d) -- a conversion that rounds a real "
			% got
		+ "latency to zero would leave every claim below it green over a link that "
		+ "was never made worse")
	noted["want_ticks"] = wanted
	phase = 2
	frame = 0

# --- 3. Both legs ---------------------------------------------------------------

func _both_legs_are_delayed() -> void:
	# Let the delay work through: the client has to send, the host has to hold and
	# release, and the answer has to come back.
	if frame < 90:
		return
	var host_delayed: int = _host().net_sim_delayed
	var client_delayed: int = _client().net_sim_delayed

	# THE INPUT LEG, ON THE HOST. This is the half that would be silently missing:
	# delaying only the client's inbound snapshot gives half a round trip and a
	# host that reacts on the frame you press.
	check(host_delayed > 0,
		"the host really holds the client's INPUT (%d batches) -- without this leg "
			% host_delayed
		+ "the knob is half a round trip, and the host answers on the frame you "
		+ "pressed while you see it 100 ms later")
	# THE SNAPSHOT LEG, ON THE CLIENT.
	check(client_delayed > 0,
		"and the client really holds the host's SNAPSHOTS (%d)" % client_delayed)

	# AND IT IS ACTUALLY LATE, which is a different claim from "it was queued". A
	# queue that released everything immediately would satisfy both counters above.
	#
	# MEASURED AS THE GAP between the tick the client is on and the newest input
	# the host has applied from it. Both machines agree about the tick number (the
	# 2026-08-18 clock fix is what makes that true), so this subtraction means
	# something.
	var behind: int = _client().tick - int(_host()._last_input_tick.get(client_peer, 0))
	var want: int = int(noted["want_ticks"])
	print("[netlink] host is %d ticks behind the client's input (one way wants %d)"
		% [behind, want])
	check(behind >= want,
		"the host's view of the client's input really is at least the one-way "
		+ "latency behind (%d ticks against %d) -- being queued is not being late"
			% [behind, want])
	phase = 3
	frame = 0

# --- 4. Loss --------------------------------------------------------------------

func _loss_is_counted_and_survivable() -> void:
	if frame == 1:
		DebugSettings.set_value("net_sim_latency_ms", 0.0)
		DebugSettings.set_value("net_sim_loss_pct", LOSS_PCT)
		noted["before_dropped"] = _client().net_sim_dropped
		noted["at"] = _client().player_position(client_peer)
		return
	if frame < 120:
		return
	var dropped: int = _client().net_sim_dropped - int(noted["before_dropped"])
	print("[netlink] at %.0f%% loss the client threw away %d arriving packets"
		% [LOSS_PCT, dropped])
	check(dropped > 0,
		"packets are really thrown away (%d), counted at the line that throws "
			% dropped
		+ "them -- a knob that is written, mirrored into a menu and never consulted "
		+ "is a shape this project keeps finding")

	# AND THE SESSION SURVIVES IT, which is the design claim rather than a property
	# of this knob: decisions go reliably and motion rides the snapshot, so losing a
	# quarter of the snapshots costs smoothness and nothing else. If this ever
	# fails, something has started to depend on an unreliable packet for its
	# EXISTENCE.
	check(_host().players.has(client_peer) and _client().players.has(client_peer),
		"both machines still have the player after a lossy stretch")
	var moved: float = _client().player_position(client_peer).distance_to(noted["at"])
	check(moved > 0.5,
		"and the client is still walking under prediction (%.2f m) -- a client that "
			% moved
		+ "froze would satisfy every other claim here")
	phase = 4
	frame = 0

# --- 5. One switch does all three -----------------------------------------------
#
# THE CONTROL SOMEBODY WILL ACTUALLY USE. Three sliders on each of two machines is
# a thing that does not get set before the session it was needed for, so the preset
# is the coarse control -- and set on the HOST it reaches everybody, by the same
# broadcast every other knob uses.
#
# THE CLAIM IS THE PRECEDENCE, WITH THE SLIDERS AT ZERO. A preset that merely wrote
# the three numbers would be a second copy of the same fact, so there is one read
# path and the preset WINS while it is on. Asserted with the numbers explicitly
# zeroed, which is the case where a broken precedence reads as a link that does
# nothing -- and the arithmetic comes from the preset table rather than a literal,
# so retuning `coast` cannot silently make this a test of nothing.
func _one_switch_does_all_three() -> void:
	if frame == 1:
		_teardown_knobs()
		DebugSettings.set_value("net_sim_preset", 1)     # "coast"
		noted["preset_delayed"] = _host().net_sim_delayed
		return
	if frame < 60:
		return
	eq(DebugSettings.get_choice_name("net_sim_preset"), "coast",
		"the preset is the one being measured")
	var wanted: int = int(round(float(SimConfig.NET_SIM_PRESETS["coast"]["latency_ms"])
		/ 1000.0 / SimConfig.TICK_DELTA))
	var held: int = _host().net_sim_delayed - int(noted["preset_delayed"])
	print("[netlink] preset 'coast' with every slider at zero: %d batches held, "
		% held + "one way wants %d ticks" % wanted)
	check(wanted > 0,
		"the preset is worth something in ticks (%d) -- a preset that rounds to "
			% wanted
		+ "nothing would leave the claim below green over a link that never changed")
	check(held > 0,
		"one switch delays traffic with all three numbers at zero (%d batches "
			% held
		+ "held) -- the preset has to WIN over the sliders, or the control somebody "
		+ "will actually use is the one that does nothing")
	# AND BOTH MACHINES, WHICH IS THE WHOLE POINT OF PUTTING IT ON THE HOST. The
	# client's own queue has to move too, or one person plays on a long link and
	# everybody else plays on a LAN.
	check(_client().net_sim_delayed > 0,
		"and the client's own queue is holding too (%d) -- each machine delays what "
			% _client().net_sim_delayed
		+ "arrives at it, which is what makes one number a round trip")
	_teardown_knobs()
	harness.shutdown()
	finish()
