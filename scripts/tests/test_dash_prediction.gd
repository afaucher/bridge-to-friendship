extends "res://scripts/test_support/test_case.gd"

# M13 item 2. A dash starts the moment you press it, not a round trip later.
#
# THE CLAIM A PLAYER WOULD MAKE: a dash goes in ONE straight line, once.
#
# MEASURED FIRST, because the obvious description of this bug is wrong. It is
# tempting to say an unpredicted dash "does nothing for a round trip" -- it does
# not. The press lands inside a WALK tick, which the client has always predicted,
# so the first tick of travel happens locally either way. What actually went wrong
# was uglier, sampled at 8 ticks of one-way delay:
#
#   tick   +0     +1     +2 .. +8         +10
#   with   0.93   1.87   smooth to 7.47   done
#   без    0.93   0.93   catches up       0.93  <-- teleported back, dashes AGAIN
#
# So the client stalled for a tick, ran the rest of the dash, and then RUBBER-
# BANDED to the start and dashed a second time when authority arrived. A player
# sees the dash happen twice from two different places.
#
# The assertions below are therefore about the SHAPE of the travel -- monotonic,
# no stall -- rather than about "did it move", which is true of both.
#
# WHY THIS IS SAFE, which is the half the old rule got right and this test also
# pins: what the dash HITS is still authority's to decide. The client runs the
# line; it does not push stones or launch teammates.
#
# The delay here is deliberately large -- eight ticks each way is worse than a
# real coast-to-coast link -- because the whole point is behaviour when authority
# is far away.

const PORT := 28784
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

const DELAY_TICKS := 8

# Far enough past the 6-tick dash to catch the rewind that used to follow it.
const SAMPLES := 16

var harness: Node = null
var client_peer: int = 0
var frame: int = 0
# NEVER, until the test says so. It was 40, which fired a stray dash before the
# one being measured and left SHOVE_COOLDOWN running -- so the real press was
# refused and the test reported "the client is not dashing", which is true and
# has nothing to do with prediction.
var fire_on: int = -1
var recorded: Dictionary = {}

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
	# Still, then one tick of dash. Edge-triggered, exactly as a key press is --
	# a held bit would re-fire it on every replayed tick, which is the trap
	# player_input.gd documents.
	harness.set_input_provider(client_peer, func(for_tick: int) -> Array:
		var actions: int = SimConfig.ACTION_SHOVE if for_tick == fire_on else 0
		return PlayerInput.make(for_tick, Vector2.ZERO, actions, 0.0))

func _physics_process(_delta: float) -> void:
	if not harness.is_ready:
		return
	frame += 1
	var client_world: Node3D = harness.client_worlds[0]
	var body: Node = client_world.player_body(client_peer)
	if body == null:
		return

	# SETTLED FIRST, and this is not politeness. A body spawns 1.2 m above the deck
	# and takes about twenty ticks to fall; an earlier version measured from frame
	# 20 and "it moved" was true because it was still DROPPING.
	if frame == 60:
		recorded["before"] = body.position
		recorded["samples"] = []
		fire_on = client_world.tick + 1
		return

	# Every tick of the dash and well past the point authority arrives.
	# FROM +0, NOT +1. The stall is between the entry tick and the one after it, so
	# a window starting at +1 cannot see it -- the stall assertion below was dead
	# code until this was fixed.
	if frame >= 61 and frame < 61 + SAMPLES:
		var flat: float = Vector2(body.position.x - recorded["before"].x,
			body.position.z - recorded["before"].z).length()
		(recorded["samples"] as Array).append(flat)
		return

	if frame == 61 + SAMPLES:
		var samples: Array = recorded["samples"]

		# 1. IT GOES ONE WAY. An unpredicted dash finishes, then gets rewound to the
		# start by the first authoritative frame and replayed -- which reads as the
		# body teleporting backwards and dashing twice.
		var worst_backslide: float = 0.0
		for i in range(1, samples.size()):
			worst_backslide = maxf(worst_backslide, float(samples[i - 1]) - float(samples[i]))
		check(worst_backslide < 0.5,
			"the dash never goes backwards (worst reversal %.2f m over %d ticks)"
				% [worst_backslide, samples.size()])

		# 2. AND IT DOES NOT STALL. Without prediction the client enters SHOVE on
		# the predicted WALK tick, then freezes because nothing steps it, until
		# authority says where it went.
		var stalls: int = 0
		for i in range(1, mini(samples.size(), 7)):
			if absf(float(samples[i]) - float(samples[i - 1])) < 0.1:
				stalls += 1
		eq(stalls, 0, "and does not stall mid-dash (%d frozen ticks in the first six)" % stalls)

		# 3. It goes a dash's worth. SHOVE_SPEED for SHOVE_DURATION is 5.6 m.
		var furthest: float = 0.0
		for v in samples:
			furthest = maxf(furthest, float(v))
		check(furthest > 5.0, "and carries a dash's distance (%.2f m)" % furthest)

		# 4. THE HALF THE OLD RULE GOT RIGHT: authority still decides. The two
		# machines agree about where it ended.
		var host_pos: Vector3 = harness.host_world.player_position(client_peer)
		var client_pos: Vector3 = client_world.player_position(client_peer)
		check(client_pos.distance_to(host_pos) < 1.0,
			"and both machines agree where it ended (%.2f m apart)"
				% client_pos.distance_to(host_pos))
		finish()
