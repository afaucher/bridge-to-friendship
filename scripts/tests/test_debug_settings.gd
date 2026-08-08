extends "res://scripts/test_support/test_case.gd"

# Guards the debug-knob registry itself. Knobs are read by name from all over
# the codebase, so a typo'd key returns a default and the caller quietly does
# the wrong thing -- these assertions are what turn that into a red gate.

func setup(_main) -> void:
	# Every registered option is well formed. A knob with a default outside its
	# own choices list is the failure mode that survives review.
	for key in DebugSettings.OPTIONS:
		var opt: Dictionary = DebugSettings.OPTIONS[key]
		check(opt.has("label"), "%s has a label" % key)
		check(opt.has("choices"), "%s has choices" % key)
		if not opt.has("choices"):
			continue
		var choices: Array = opt["choices"]
		check(choices.size() >= 2, "%s offers at least two choices" % key)
		var default_index := int(opt.get("default", 0))
		check(default_index >= 0 and default_index < choices.size(),
			"%s default index %d is within its choices" % [key, default_index])

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
