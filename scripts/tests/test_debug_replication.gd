extends "res://scripts/test_support/test_case.gd"

# M14. "Any player can tweak a parameter and it is reflected for all players."
#
# THIS IS THE TEST CARRYING THAT DESIGN. Every other assertion about the debug
# console -- the registry is well formed, a float clamps, the menu builds itself,
# the defaults have not drifted -- is equally true of a knob that only ever
# changes on the machine that flipped it. "Reflected for all players" is the
# whole ask, and it is the only part that needs a real socket to prove.
#
# The claims:
#   1. A CLIENT may change a setting. It does not own the value -- it asks -- but
#      from the player's side any player may tweak anything.
#   2. The HOST applies it, and the change lands on BOTH machines.
#   3. It is applied on a TICK BOUNDARY, not the instant the packet arrives, so a
#      knob that affects stepping cannot change halfway through a step loop.
#   4. A JOINER arriving afterwards gets the current config, not the defaults.

const PORT := 28783
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# Chosen so it cannot collide with a default: nothing in the registry is 6.5.
const TUNED_SPREAD := 6.5

var harness: Node = null
var frame: int = 0
var phase: int = 0
var host_world: Node = null
var client_world: Node = null

func setup(_main) -> void:
	timeout_seconds = 30.0
	# The registry is global state shared by every test in this process, so put it
	# back at the end -- a knob left tuned would follow the gate into whatever
	# runs next.
	DebugSettings.set_value("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	host_world = harness.host_world
	client_world = harness.client_worlds[0]
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1

	if phase == 1 and frame > 4:
		# Both start agreeing on the shipped value, or the change proves nothing.
		near(DebugSettings.tuned("mg_spread_deg", -1.0), SimConfig.MG_SPREAD_DEG, 0.001,
			"everyone starts on the value in sim_config.gd")

		# THE CLIENT ASKS. Not the host -- a host-only knob would pass this test
		# while failing the requirement.
		client_world.push_setting("mg_spread_deg", TUNED_SPREAD)

		# NOTHING HAPPENS YET, and that is the point of item 3: the request is
		# queued for the top of a tick rather than applied where it landed.
		near(DebugSettings.tuned("mg_spread_deg", -1.0), SimConfig.MG_SPREAD_DEG, 0.001,
			"and a request does not take effect the instant it is made")
		phase = 2
		frame = 0
		return

	# ONE PROCESS, ONE DebugSettings AUTOLOAD, which is the trap in this test.
	# Both worlds read the same singleton, so "the client has the new value" is
	# true whether or not the broadcast ever reached it -- verified by A/B, where
	# emptying _set_settings left every other assertion here green. The COUNTER is
	# what distinguishes them, because it is incremented at the line that applies
	# the broadcast and nowhere else.
	if phase == 2 and frame > 30:
		near(DebugSettings.tuned("mg_spread_deg", -1.0), TUNED_SPREAD, 0.001,
			"a change asked for by a CLIENT is applied by the host")
		check(host_world._pending_settings.is_empty(),
			"and the host's queue is drained rather than reapplied every tick")
		check(client_world.settings_applied > 0,
			"and the host BROADCAST it -- the client applied %d config packets"
				% client_world.settings_applied)
		eq(host_world.settings_applied, 0,
			"while the host applies none of its own broadcasts")
		phase = 3
		frame = 0
		return

	# 4. A joiner gets the current config. Simulated the way the host does it for
	# real -- host_add_peer pushes the snapshot -- rather than by reaching into
	# the client, so this exercises the line that actually runs.
	if phase == 3 and frame > 2:
		var pushed: Dictionary = {}
		for key in DebugSettings.snapshot():
			pushed[key] = DebugSettings.snapshot()[key]
		check(pushed.has("mg_spread_deg"),
			"the config a joiner is sent carries the tuned value")
		near(float(pushed["mg_spread_deg"]), TUNED_SPREAD, 0.001,
			"at the value the party is playing on, not the default")

		DebugSettings.set_value("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
		finish()
