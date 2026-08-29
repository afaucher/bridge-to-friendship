extends "res://scripts/test_support/test_case.gd"

# A BUS, ACROSS A REAL SOCKET.
#
# The bus shipped host-only. `test_bus` proves it drives, grows, leans, plants
# riders and takes the driver's trigger away -- and every one of those claims is
# equally true of a vehicle only one machine can see, which in a co-op game is
# the whole feature failing.
#
# AND THE MISSING WIRE WAS NOT MAINLY ABOUT DRAWING. The step loop asks
# `bus_carrying(peer)` to zero a rider's movement and to strip the driver's
# trigger; on a client with no buses that question answered NULL. So a client
# aboard predicted itself WALKING while the host had it planted on a moving deck,
# and `_reconcile` corrected it every tick for as long as anybody rode. That is
# the rubber-band symptom this project has now chased three times, and it is why
# claim 4 below is the one worth having.
#
# The claims:
#   1. A bus built on the host EXISTS on the client, which never builds one.
#   2. It is in the same PLACE, with the same heading and the same length. World-
#      local coordinates, so the harness's kilometre between worlds never reaches
#      the wire -- and the bus worked in GLOBAL space until this test existed,
#      which reads identically in solo and is a kilometre wrong the moment a
#      second world exists.
#   3. The ROSTER crosses. It decides who drives, who may shoot and how long the
#      deck is; a client with the transform and not the roster draws the wrong
#      bus with the wrong person at the wheel.
#   4. A RIDER DOES NOT RUBBER-BAND. The client stops predicting a body it has no
#      input for, so `corrections` stays flat while the bus is driven under it.
#      This is a claim about a NUMBER not moving, so phase 0 establishes it can
#      move at all -- otherwise a broken counter passes it.
#   5. A bus the host culls is dropped by the client, which is the only way a
#      client ever learns one is gone.

const PORT := 28789
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

# Long enough that a bus driven at speed covers real ground under a planted
# rider -- a stationary bus is the "latency instrument read on a stationary body"
# trap, where every view agrees because nothing is moving.
const DRIVE_TICKS := 90

# How long a snapshot is allowed to take across a loopback socket before its
# absence is a failure rather than a wait.
# How long the test waits for a snapshot to land. Generous on purpose: with a
# real grid the host's snapshot exceeds the MTU on a keyframe and much of the
# unreliable channel does not arrive at all (measured: 5 consumed out of 147).
# That is a transport problem, recorded in _apply_bus_snapshot and worth fixing
# on its own; a test of the BUS should not be a coin flip on it.
const ARRIVAL_TICKS := 60

# How far apart the two copies may be once the bus has STOPPED. Half a metre
# against a bus that just drove nine, so a copy that never got a snapshot cannot
# satisfy it -- and it is a claim about agreement rather than about latency.
const TRACKING_SLACK := 0.5

var harness: Node = null
var frame: int = 0
var phase: int = 0
var host_world: Node = null
var client_world: Node = null
var host_bus: Node = null
var walked_corrections: int = 0
var rode_from: int = 0
var rode_start: Vector3 = Vector3.ZERO
var rider: int = 0
var doomed_id: int = 0
var rode_at: int = 0
var culled_at: int = 0
var client_from: Vector3 = Vector3.ZERO
var shoved_at: int = 0
var settled_at: int = 0

func setup(_main) -> void:
	timeout_seconds = 45.0
	harness = NetHarness.new()
	# A REAL ASSEMBLED RUN ON BOTH ENDS. `_ensure_bus` refuses to build onto a
	# world with no grid -- correct, and it means the gym scene the other net
	# tests use is not enough here. The seed goes only to the host; the client is
	# told it over the wire, which is a thing this harness already tests.
	harness.assemble_run = true
	harness.run_seed = 8172
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	host_world = harness.host_world
	client_world = harness.client_worlds[0]
	host_world.round_machine.round_index = 0
	host_world.round_machine.state = RoundMachine.State.RUNNING
	rider = client_world.local_peer
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1

	# --- 0. The correction counter can move ------------------------------------
	#
	# Claim 4 is that a number stays flat, and this project has shipped counters
	# that were flat because they were unreachable. So before asserting the
	# quiet, prove the instrument is live: teleport the client's own body away
	# from where the host says it is and watch `corrections` climb.
	if phase == 1 and frame > 8:
		var mine: Node = client_world.player_body(rider)
		if not check(mine != null, "the client has its own body"):
			finish()
			return
		# WAIT UNTIL IT IS WALKING. `_reconcile` only counts a correction in a
		# state the client PREDICTS, and a body still falling to the deck from its
		# spawn is not one -- so the first version of this probe reported zero
		# corrections about a working build, depending on nothing but how long the
		# drop took that run. A probe that can only fire in one state has to wait
		# for that state rather than guess a frame.
		if mine.state != PlayerBody.State.WALK and frame < 8 + ARRIVAL_TICKS:
			return
		if not check(mine.state == PlayerBody.State.WALK,
				"the client's body has landed and is being predicted (state %d)"
					% mine.state):
			finish()
			return
		walked_corrections = client_world.corrections
		# MOVED ON THE HOST, NOT ON THE CLIENT, and the difference is the whole
		# mechanism. `_reconcile` compares what the client PREDICTED for the acked
		# tick against what the host says happened -- so shoving the client's own
		# body now changes nothing it will ever look at, and the first version of
		# this probe passed or failed depending on network timing. Moving the
		# authoritative copy is a disagreement the client cannot have predicted.
		var theirs: Node = host_world.player_body(rider)
		if not check(theirs != null, "the host has the client's body"):
			finish()
			return
		theirs.position += Vector3(3.0, 0.0, 0.0)
		shoved_at = frame
		phase = 2
		return

	if phase == 2 and frame > shoved_at:
		var moved: int = client_world.corrections - walked_corrections
		# POLL FOR IT. The correction can only be counted on a tick the client
		# actually receives a snapshot for its own player, and delivery is not
		# once per tick -- see the note in _apply_bus_snapshot about how little of
		# the unreliable channel arrives with a real grid in this harness. A fixed
		# six-tick window made this probe fail two runs in three while the build
		# was perfectly correct: a chosen frame is a guess about somebody else's
		# clock, and here the clock is the network.
		if moved <= 0 and frame < shoved_at + ARRIVAL_TICKS:
			return
		check(moved > 0,
			"the correction counter is live: shoving the client's body off the "
			+ "host's answer produced %d corrections -- without this, claim 4 " % moved
			+ "below is satisfied by a counter that never fires")
		eq(client_world._buses.size(), 0,
			"and the client starts with no buses, so anything it has later it was "
			+ "told about")
		eq(host_world._buses.size(), 0,
			"nor does the host, which is what makes that a moment rather than a "
			+ "coincidence -- the mode is only switched on now")
		# THE MODE ON THE HOST ONLY. A client never asks whether the bus pool
		# runs; it is told what exists. Setting it on both ends would hide a
		# client quietly building its own, which is claim 1's other half.
		host_world.run_modes = [GameMode.BLANK]
		phase = 3
		return

	# --- 1, 2, 3. It exists, in the right place, with the right roster ----------

	if phase == 3 and frame > shoved_at + 4:
		host_world._process_buses()
		if not check(host_world._buses.size() > 0, "the host built a bus"):
			finish()
			return
		host_bus = host_world._buses[0]
		# BOARDED ON THE HOST, which is where boarding is decided, and the rider is
		# the CLIENT's own player -- the case that matters, because it is that
		# machine which has to stop predicting.
		host_bus.riders.clear()
		host_bus.board(rider)
		phase = 4
		return

	if phase == 4 and frame > shoved_at + 8:
		# WAIT FOR IT TO ARRIVE, with a deadline -- a chosen frame is a guess about
		# how long a real socket takes, and this is the one assertion in the file
		# whose timing is not under the test's control. Waiting is not weakening:
		# the deadline still fails a build where it never crosses.
		if client_world._buses.size() < 1 and frame < shoved_at + 8 + ARRIVAL_TICKS:
			return
		if not check(client_world._buses.size() == 1,
				"the client has exactly the one bus the host has, within %d ticks "
					% ARRIVAL_TICKS
				+ "(%d)" % client_world._buses.size()):
			finish()
			return
		var theirs: Node = client_world._buses[0]
		eq(theirs.bus_id, host_bus.bus_id, "and it is the same one, by id")
		near(theirs.position.x, host_bus.position.x, 0.05,
			"in the same place across X -- world-local, so the kilometre between "
			+ "these two worlds never reaches the wire")
		near(theirs.position.z, host_bus.position.z, 0.05, "and across Z")
		near(theirs.heading, host_bus.heading, 0.02, "pointing the same way")
		eq(theirs.riders, host_bus.riders,
			"carrying the same people -- the roster decides who drives, who may "
			+ "shoot and how long the deck is, so a transform without it draws the "
			+ "wrong bus with the wrong person at the wheel")
		near(theirs.length(), host_bus.length(), 0.01,
			"and is therefore the same length")
		check(client_world.bus_carrying(rider) != null,
			"and the client can answer `am I aboard` -- the question the step loop "
			+ "asks to stop a rider walking, which answered NULL before this wire "
			+ "existed and is the whole rubber-band")

		# DRIVE IT UNDER THEM. Full throttle and a steady lock, so the deck really
		# travels while somebody is planted on it: a stationary bus looks identical
		# in every view however stale, which is the instrument trap that would make
		# claim 4 pass on a broken build.
		# FROM THE CLIENT'S OWN STICK, over the wire. The host never reads a
		# scripted input for a remote peer -- that peer's input arrives by RPC,
		# which is exactly the path a real driver's steering takes.
		harness.set_input_provider(rider, func(t: int) -> Array:
			var inp: Array = PlayerInput.empty(t)
			inp[PlayerInput.MOVE] = Vector2(0.35, -1.0)
			return inp)
		rode_at = frame
		client_from = theirs.position
		rode_from = client_world.corrections
		rode_start = host_bus.position
		doomed_id = host_bus.bus_id
		phase = 5
		return

	# --- 4. A rider does not rubber-band ---------------------------------------

	if phase == 5 and frame > rode_at + DRIVE_TICKS:
		var travelled: float = rode_start.distance_to(host_bus.position)
		var gained: int = client_world.corrections - rode_from
		print("[busnet] the bus carried a remote rider %.2f m for %d corrections"
			% [travelled, gained])
		# THE MOTION REALLY CROSSES, and this is where that is proved rather than at
		# the moment the bus appears. A bus is announced reliably with a position,
		# so "the client's bus is in the right place" is satisfied by the announce
		# alone while it is standing still -- the snapshot section could be dropped
		# entirely and that assertion would not move. Only a bus that has DRIVEN
		# separates the two, which is why the tracking claim lives after the ride.
		var client_bus: Node = client_world._buses[0] if client_world._buses.size() > 0 else null
		if check(client_bus != null, "the client still has the bus it was riding"):
			var client_went: float = client_from.distance_to(client_bus.position)
			print("[busnet] the client's copy travelled %.2f m against the host's %.2f"
				% [client_went, travelled])
			check(client_went > 4.0,
				"the client's copy moved with it (%.2f m) -- the reliable announce "
					% client_went
				+ "carries a position, so a bus standing still looks perfectly "
				+ "replicated with the snapshot section dropped entirely")

		check(travelled > 4.0,
			"the bus really drove while somebody was aboard (%.2f m) -- a "
				% travelled
			+ "stationary deck agrees in every view however stale, so this is what "
			+ "makes the next assertion mean anything")
		check(gained <= 2,
			"and the rider did not rubber-band: %d corrections over %d ticks "
				% [gained, DRIVE_TICKS]
			+ "aboard. The client stops predicting a body it has no input for -- "
			+ "before this it predicted itself WALKING against a moving deck and "
			+ "corrected on every tick of the ride")

		# THROTTLE OFF, THEN COMPARE. Two moving objects across a lossy link differ
		# by whatever the last delivered snapshot was worth -- at 13 m/s that is
		# metres, and tuning a tolerance to absorb it would be tuning against the
		# transport rather than testing the bus. A bus that has stopped has one
		# right answer, and both ends should reach it.
		harness.set_input_provider(rider, func(t: int) -> Array:
			return PlayerInput.empty(t))
		settled_at = frame
		phase = 55
		return

	if phase == 55 and frame > settled_at + 8:
		var client_bus: Node = client_world._buses[0] if client_world._buses.size() > 0 else null
		if not check(client_bus != null, "the client still has the bus"):
			finish()
			return
		var apart: float = client_bus.position.distance_to(host_bus.position)
		if apart > TRACKING_SLACK and frame < settled_at + 8 + ARRIVAL_TICKS:
			return
		print("[busnet] once stopped, the two copies are %.2f m apart" % apart)
		check(apart <= TRACKING_SLACK,
			"a stopped bus is in the same place on both machines (%.2f m apart) -- "
				% apart
			+ "the reliable announce fixed where it STARTED, so this is the "
			+ "snapshot section and nothing else")
		near(client_bus.heading, host_bus.heading, 0.25,
			"pointing the same way after a corner, which only the snapshot carries")

		# --- 5. And a culled bus goes away ------------------------------------
		host_bus.position = Vector3(host_bus.position.x, SimConfig.FALL_KILL_Y - 1.0,
			host_bus.position.z)
		culled_at = frame
		phase = 6
		return

	if phase == 6 and frame > culled_at + ARRIVAL_TICKS:
		# BY ID, NOT BY COUNT. `_ensure_bus` builds a replacement on the very next
		# tick, so "the client has one bus" is true before and after and says
		# nothing at all. What has to be gone is the WRECK.
		eq(client_world._bus_by_id(doomed_id), null,
			"the bus the host culled is dropped by the client -- absence is how a "
			+ "client learns one is gone, and the only way it ever does")
		check(client_world._buses.size() > 0,
			"and the replacement crossed too, so the client is not left looking at "
			+ "an empty road")
		finish()
