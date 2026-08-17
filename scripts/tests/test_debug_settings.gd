extends "res://scripts/test_support/test_case.gd"

# Guards the debug-knob registry itself. Knobs are read by name from all over
# the codebase, so a typo'd key returns a default and the caller quietly does
# the wrong thing -- these assertions are what turn that into a red gate.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SpecialPool = preload("res://scripts/sim/special_pool.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")

func setup(_main) -> void:
	# Every registered option is well formed, whatever KIND it is. A knob with a
	# default outside its own range is the failure mode that survives review.
	for key in DebugSettings.OPTIONS:
		var opt: Dictionary = DebugSettings.OPTIONS[key]
		var kind: String = DebugSettings.kind_of(str(key))
		check(opt.has("label"), "%s has a label" % key)
		check(opt.has("section"), "%s is filed under a section for the menu" % key)
		match kind:
			DebugSettings.KIND_FLOAT, DebugSettings.KIND_INT:
				check(opt.has("min") and opt.has("max"), "%s has a range" % key)
				var d := float(opt.get("default", 0.0))
				check(d >= float(opt["min"]) and d <= float(opt["max"]),
					"%s default %.3f is inside its own range" % [key, d])
			DebugSettings.KIND_BOOL:
				check(int(opt.get("default", 0)) in [0, 1], "%s defaults to 0 or 1" % key)
			_:
				check(opt.has("choices"), "%s has choices" % key)
				if not opt.has("choices"):
					continue
				var choices: Array = opt["choices"]
				check(choices.size() >= 2, "%s offers at least two choices" % key)
				var default_index := int(opt.get("default", 0))
				check(default_index >= 0 and default_index < choices.size(),
					"%s default index %d is within its choices" % [key, default_index])

	_test_no_drift()
	_test_numeric_knobs()
	_test_ammo_multiplier()

	# Reading and writing round-trips, and out-of-range writes are refused
	# rather than clamped -- a silently clamped knob reports a value the caller
	# never asked for.
	eq(DebugSettings.get_choice("net_log"), 0, "net_log defaults to off")
	eq(DebugSettings.is_on("net_log"), false, "is_on agrees with the default")

	var seen: Array = []
	DebugSettings.changed.connect(func(key: String, value: int) -> void:
		seen.append([key, value]))

	DebugSettings.set_choice("net_log", 1)
	eq(DebugSettings.get_choice("net_log"), 1, "net_log reads back after set")
	eq(DebugSettings.get_choice_name("net_log"), "on", "the choice name follows the index")
	eq(seen.size(), 1, "changing a knob emits exactly one signal")

	DebugSettings.set_choice("net_log", 1)
	eq(seen.size(), 1, "setting a knob to its current value emits nothing")

	DebugSettings.set_choice("net_log", 99)
	eq(DebugSettings.get_choice("net_log"), 1, "an out-of-range write is refused")

	DebugSettings.set_choice("net_log", 0)

	# The headless default. If this ever flips, every test run starts trying to
	# reach a Steam client that is not there.
	eq(DebugSettings.get_choice_name("steam"), "auto", "steam knob defaults to auto")

	finish()

# THE AMMO MULTIPLIER, MEASURED AT THE LINE THAT GRANTS AMMO.
#
# Asserted through SpecialPool rather than by re-doing the arithmetic here: a test
# that multiplies the constant by the knob and compares it against the same
# expression proves only that multiplication works. What is under test is that the
# knob is READ where ammo is handed out, and every weapon goes through _full_ammo.
func _test_ammo_multiplier() -> void:
	var was: float = DebugSettings.tuned("ammo_multiplier", 1.0)
	var kinds: Array = [
		[SpecialBody.Kind.MACHINE_GUN, SimConfig.MG_AMMO],
		[SpecialBody.Kind.GRENADE, SimConfig.GRENADE_AMMO],
		[SpecialBody.Kind.MINE, SimConfig.MINE_AMMO],
		[SpecialBody.Kind.SHIELD, SimConfig.SHIELD_AMMO],
		[SpecialBody.Kind.ROCKET, SimConfig.ROCKET_AMMO],
		[SpecialBody.Kind.LEGS, SimConfig.LEGS_AMMO],
	]

	# THE DEFAULT CHANGES NOTHING. Every other assertion in this project about a
	# weapon's ammo compares against the bare constant, so a multiplier that was
	# not exactly 1.0 at rest would turn a debug knob into a balance change.
	DebugSettings.set_value("ammo_multiplier", 1.0)
	for entry in kinds:
		eq(SpecialPool._full_ammo(int(entry[0])), int(entry[1]),
			"at 1.0 a %s arrives with its constant, untouched" % str(entry[0]))

	DebugSettings.set_value("ammo_multiplier", 4.0)
	for entry in kinds:
		check(SpecialPool._full_ammo(int(entry[0])) > int(entry[1]),
			"at 4.0 every weapon gets MORE (%s: %d from %d) -- one knob has to reach "
				% [str(entry[0]), SpecialPool._full_ammo(int(entry[0])), int(entry[1])]
			+ "all six, and the way this fails is a weapon added later that does not "
			+ "go through _full_ammo")

	DebugSettings.set_value("ammo_multiplier", 0.5)
	for entry in kinds:
		var low: int = SpecialPool._full_ammo(int(entry[0]))
		check(low < int(entry[1]), "at 0.5 every weapon gets less (%s: %d)"
			% [str(entry[0]), low])
		check(low >= 1, "and never nothing (%s: %d)" % [str(entry[0]), low])

	# THE FLOOR, EXERCISED DIRECTLY, because no shipped weapon can reach it: the
	# smallest magazine in the game is the rocket's two, and 2 x 0.5 rounds to one
	# exactly. So the guard never fires today and would fire the moment somebody
	# ships a single-use special -- which is precisely the kind of branch that is
	# wrong on the day it is needed. A special is DESTROYED the tick its ammo hits
	# zero, so without this the pickup would vanish as the player touched it.
	eq(SpecialPool._scaled(1), 1,
		"a one-use special still arrives with one at half ammo, rather than being "
		+ "rounded out of existence")

	# THE RANGE IS THE RANGE. Out of bounds CLAMPS for a float knob (it arrives
	# from a slider and from the network, where the edge is what "as far as it
	# goes" means), so this is checking the bounds are the ones asked for.
	DebugSettings.set_value("ammo_multiplier", 99.0)
	eq(DebugSettings.tuned("ammo_multiplier", 1.0), 4.0, "it clamps at 4x")
	DebugSettings.set_value("ammo_multiplier", 0.01)
	eq(DebugSettings.tuned("ammo_multiplier", 1.0), 0.5, "and at 0.5x")

	DebugSettings.set_value("ammo_multiplier", was)

# A KNOB THAT SHADOWS A CONSTANT MUST DEFAULT TO THAT CONSTANT.
#
# tuned() returns whatever is in the registry, so a default that has drifted from
# sim_config.gd silently changes the game the moment somebody opens the console
# and closes it again -- and it would change it to a number nobody chose, which is
# the worst kind of wrong. Nothing else keeps these two files honest.
func _test_no_drift() -> void:
	# By NAME, out of the script's own constant map, read through a plain Script
	# reference. Both SimConfig.get(name) and SimConfig.get_script_constant_map()
	# are parse errors -- "cannot call a non-static function on the class
	# directly" -- and hard-coding the constants here would defeat the entire
	# point of the check.
	var script: Script = load("res://scripts/sim/sim_config.gd")
	var consts: Dictionary = script.get_script_constant_map()
	for key in DebugSettings.OPTIONS:
		var opt: Dictionary = DebugSettings.OPTIONS[key]
		if not opt.has("mirrors"):
			continue
		var name: String = str(opt["mirrors"])
		check(consts.has(name), "%s names a real SimConfig constant (%s)" % [key, name])
		if not consts.has(name):
			continue
		var constant: Variant = consts[name]
		near(float(opt["default"]), float(constant), 0.0001,
			"%s defaults to SimConfig.%s (%s vs %s)" % [key, name, opt["default"], constant])

func _test_numeric_knobs() -> void:
	# A float knob round-trips, and tuned() reads it.
	var was: float = DebugSettings.tuned("mg_spread_deg", -1.0)
	DebugSettings.set_value("mg_spread_deg", 4.5)
	near(DebugSettings.tuned("mg_spread_deg", -1.0), 4.5, 0.001,
		"a float knob reads back through tuned()")

	# CLAMPED, not refused -- unlike a choice. This value arrives from a slider
	# and from the network, where the edge of the range is what "as far as it
	# goes" means.
	DebugSettings.set_value("mg_spread_deg", 999.0)
	near(DebugSettings.tuned("mg_spread_deg", -1.0),
		float(DebugSettings.OPTIONS["mg_spread_deg"]["max"]), 0.001,
		"a float past its maximum is clamped to it")
	DebugSettings.set_value("mg_spread_deg", was)

	# AN UNKNOWN KEY FALLS BACK TO THE CONSTANT rather than to zero. A read site
	# whose knob is deleted later keeps working on the value in sim_config.gd.
	near(DebugSettings.tuned("no_such_knob", 7.25), 7.25, 0.0001,
		"tuned() on an unregistered key returns the constant it was given")

	# The whole config round-trips, which is what the replication sends.
	var snap: Dictionary = DebugSettings.snapshot()
	check(snap.has("mg_spread_deg") and snap.has("net_log"),
		"the snapshot carries every kind of knob")
	DebugSettings.apply_snapshot(snap)
	near(DebugSettings.tuned("mg_spread_deg", -1.0), was, 0.001,
		"and applying it back is a no-op")
