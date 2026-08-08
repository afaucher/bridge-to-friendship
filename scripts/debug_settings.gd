extends Node

# Autoload singleton: DebugSettings
# ----------------------------------
# Global debug knobs, deliberately the SIMPLEST possible thing. Game code reads
# these directly (e.g. DebugSettings.get_choice("net_log")) rather than routing a
# selection through a host/client packet -- so flipping a knob on the local
# machine changes local behaviour immediately. That breaks the networking
# abstraction on purpose: this is a dev surface, not authoritative game state. If
# a knob ever has to be CORRECT across a real multiplayer session, promote it out
# of here into replicated state; until then, ease of adding a toggle wins.
#
# TO ADD A KNOB: append one entry to OPTIONS. Any code anywhere can then read it
# with get_choice("your_key"), and a debug menu can build itself from the
# registry without further wiring.
#
# Every knob is also settable from the environment (BTF_<KEY_UPPERCASE>=<index>)
# so a headless test or a sim run can flip one without a UI -- see _ready().

signal changed(key: String, value: int)

const OPTIONS := {
	"net_log": {
		"label": "Network log",
		"choices": ["off", "on"],
		"default": 0,
		"help": "Per-event print for peer connect/disconnect, spawn, and state sync.",
	},
	"steam": {
		"label": "Steam backend",
		"choices": ["auto", "off"],
		"default": 0,
		"help": "'off' skips Steam init entirely -- the default for headless runs, which have no Steam client.",
	},
}

var _values: Dictionary = {}

func _ready() -> void:
	for key in OPTIONS:
		_values[key] = int(OPTIONS[key]["default"])
	_apply_env_overrides()

# BTF_NET_LOG=1 etc. Accepts either the index or the choice name, because
# remembering that "on" is 1 is exactly the kind of thing that goes wrong at
# 2am. An unknown key or value is reported and ignored rather than silently
# dropped -- a typo'd override that quietly does nothing is worse than none.
func _apply_env_overrides() -> void:
	for key in OPTIONS:
		# Explicitly typed, not inferred: `key` comes from iterating a Dictionary
		# so it is a Variant, and `:=` on an expression built from one is a
		# parse error ("cannot infer the type"), not a runtime problem.
		var env_name: String = "BTF_" + str(key).to_upper()
		if not OS.has_environment(env_name):
			continue
		var raw := OS.get_environment(env_name).strip_edges()
		var choices: Array = OPTIONS[key]["choices"]
		var idx := choices.find(raw)
		if idx == -1 and raw.is_valid_int():
			idx = int(raw)
		if idx < 0 or idx >= choices.size():
			printerr("[DebugSettings] ", env_name, "=", raw, " is not a valid choice for '", key, "' (", choices, ")")
			continue
		_values[key] = idx
		print("[DebugSettings] ", key, " = ", choices[idx], " (from ", env_name, ")")

func get_choice(key: String) -> int:
	if not _values.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return 0
	return int(_values[key])

func get_choice_name(key: String) -> String:
	if not OPTIONS.has(key):
		return ""
	return str(OPTIONS[key]["choices"][get_choice(key)])

func is_on(key: String) -> bool:
	return get_choice(key) == 1

func set_choice(key: String, value: int) -> void:
	if not OPTIONS.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return
	var choices: Array = OPTIONS[key]["choices"]
	if value < 0 or value >= choices.size():
		printerr("[DebugSettings] value ", value, " out of range for '", key, "'")
		return
	if _values.get(key, -1) == value:
		return
	_values[key] = value
	changed.emit(key, value)
