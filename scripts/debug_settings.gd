extends Node

# Autoload singleton: DebugSettings
# ----------------------------------
# The registry of debug knobs, and the values behind them. See
# implementation_plans/m14_debug_console.md.
#
# TO ADD A KNOB: append ONE entry to OPTIONS. Nothing else. The menu builds itself
# by walking this dictionary, the replication sends whatever is in it, and the
# environment override works for free. There is deliberately no per-knob UI code
# anywhere in the project, because a debug surface that costs a UI change per
# setting is a debug surface nobody adds settings to.
#
# THIS FILE HOLDS THE VALUES. IT DOES NOT REPLICATE THEM. An RPC on an autoload
# travels over the DEFAULT peerless MultiplayerAPI, and the net harness roots each
# world at its own SceneMultiplayer -- so an autoload RPC is one no test can ever
# reach (m9_hud.md hit exactly this with player names). GameWorld owns the
# request/broadcast pair and writes the results in here, the same shape
# player_names already uses.
#
# Every knob is also settable from the environment as BTF_<KEY_UPPERCASE>, so a
# headless test or a sim run can flip one with no UI at all.

signal changed(key: String, value: Variant)

# The kinds a knob can be. `choice` is the original and stays the default when an
# entry does not say, so every knob written before this milestone still works
# untouched.
const KIND_CHOICE := "choice"
const KIND_BOOL := "bool"
const KIND_FLOAT := "float"
const KIND_INT := "int"

# A NUMERIC KNOB'S `default` MUST EQUAL THE CONSTANT IT SHADOWS. tuned() returns
# whatever is in here, so a default that has drifted from sim_config.gd silently
# changes the game the moment the console is opened and closed again.
# `test_debug_settings` asserts every one of these against its constant, which is
# the only thing that keeps the two honest.
const OPTIONS := {
	# --- Diagnostics ---------------------------------------------------------
	"show_hitboxes": {
		"section": "Diagnostics",
		"kind": KIND_BOOL,
		"view_only": true,
		"label": "Show hitboxes",
		"default": 0,
		"help": "Draw every collision shape as a wireframe. The first thing to reach for when something catches on geometry it looks clear of.",
	},
	"net_log": {
		"section": "Diagnostics",
		"label": "Network log",
		"choices": ["off", "on"],
		"default": 0,
		"help": "Per-event print for peer connect/disconnect, spawn, and state sync.",
	},
	"steam": {
		"section": "Diagnostics",
		"label": "Steam backend",
		"choices": ["auto", "off"],
		"default": 0,
		"help": "'off' skips Steam init entirely -- the default for headless runs, which have no Steam client.",
	},

	# --- Hazards -------------------------------------------------------------
	"plinko_hit_radius": {
		"section": "Hazards",
		"kind": KIND_FLOAT,
		"label": "Plinko hit radius",
		"default": 1.1, "min": 0.4, "max": 3.0, "step": 0.05,
		"mirrors": "PLINKO_HIT_RADIUS",
		"help": "Slop ON TOP of real contact (ball 0.6 + body 0.4 = 1.0 m). At 1.1 the test fires at 1.5 m. Was effectively 2.0 m until the half-height unit error was fixed on 2026-08-14.",
	},

	"rusher_speed_pct": {
		"section": "Hazards",
		"kind": KIND_FLOAT,
		"label": "Rusher speed",
		"default": 100.0, "min": 25.0, "max": 100.0, "step": 25.0,
		"help": "Percentage of RUSHER_SPEED. Stepped at 25 so it is the four settings asked for -- 100, 75, 50, 25 -- rather than a slider nobody can report a number from. A PERCENTAGE and not a speed, because what a playtest is answering is 'is it too fast', which is a question about the shipped value.",
	},

	"turret_arc_deg": {
		"section": "Hazards",
		"kind": KIND_FLOAT,
		"label": "Turret firing arc",
		"default": 360.0, "min": 45.0, "max": 360.0, "step": 15.0,
		"mirrors": "TURRET_ARC_DEG",
		"help": "How wide a cone a turret can swing its gun through, centred on the direction it was bolted at. 360 is a gun that tracks you anywhere, which is what shipped before turrets became their own type. Narrow it and flanking becomes an answer the geometry supplies for free -- somewhere under 90 it stops being a hazard and becomes a door. This is a slider precisely because the right value is a thing to FIND in a playtest.",
	},

	# --- Weapons -------------------------------------------------------------
	"mg_spread_deg": {
		"section": "Weapons",
		"kind": KIND_FLOAT,
		"label": "MG spread (horizontal)",
		"default": 10.0, "min": 0.0, "max": 30.0, "step": 0.5,
		"mirrors": "MG_SPREAD_DEG",
		"help": "Half-angle of the cone across the bridge. Vertical is a separate, much tighter number.",
	},
	"mg_fire_interval": {
		"section": "Weapons",
		"kind": KIND_FLOAT,
		"label": "MG fire interval",
		"default": 0.4, "min": 0.05, "max": 2.0, "step": 0.05,
		"mirrors": "MG_FIRE_INTERVAL",
		"help": "Seconds between rounds. Already moved twice in playtest, which is why it is here.",
	},
}

var _values: Dictionary = {}

func _ready() -> void:
	for key in OPTIONS:
		_values[key] = OPTIONS[key]["default"]
	_apply_env_overrides()

# --- Reading ------------------------------------------------------------------

# THE READ SITE FOR A SHADOWED CONSTANT.
#
#   was:  SimConfig.MG_SPREAD_DEG
#   now:  DebugSettings.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
#
# The fallback is what an unregistered key returns, so a read site whose knob is
# later deleted keeps working on the constant rather than on zero. sim_config.gd
# stays `const` throughout and remains the place tuning lives -- this shadows a
# handful of values on request, and turning it into a bag of variables would lose
# the property that makes the file greppable.
func tuned(key: String, fallback: float) -> float:
	if not _values.has(key):
		return fallback
	return float(_values[key])

func get_choice(key: String) -> int:
	if not _values.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return 0
	return int(_values[key])

func get_choice_name(key: String) -> String:
	if not OPTIONS.has(key):
		return ""
	if kind_of(key) != KIND_CHOICE:
		return str(_values.get(key, ""))
	return str(OPTIONS[key]["choices"][get_choice(key)])

func is_on(key: String) -> bool:
	return get_choice(key) == 1

static func kind_of(key: String) -> String:
	if not OPTIONS.has(key):
		return KIND_CHOICE
	return str(OPTIONS[key].get("kind", KIND_CHOICE))

# A VIEW KNOB CHANGES WHAT IS DRAWN AND NOTHING THE SIMULATION READS.
#
# The distinction earns its keep in GameWorld.push_setting: a client may apply one
# of these the instant it is clicked, because there is no way for it to make two
# bodies in one host tick run under different rules. A simulation knob has to wait
# for the host to apply it on a tick boundary, and test_debug_replication is the
# assertion that says so -- it caught the version of this that skipped the
# distinction, on the first run.
static func is_view_only(key: String) -> bool:
	return bool(OPTIONS.get(key, {}).get("view_only", false))

static func section_of(key: String) -> String:
	return str(OPTIONS.get(key, {}).get("section", "Other"))

# Every key, grouped by section and stable in order. The menu walks this; nothing
# else decides what is shown.
static func sections() -> Dictionary:
	var out: Dictionary = {}
	for key in OPTIONS:
		var s: String = section_of(str(key))
		if not out.has(s):
			out[s] = []
		out[s].append(str(key))
	return out

# --- Writing ------------------------------------------------------------------

# ONE SETTER FOR EVERY KIND, because the menu and the replication both have to
# work on a knob they know nothing about.
#
# OUT OF RANGE IS TREATED DIFFERENTLY BY KIND, on purpose:
#
#   choice/bool  REFUSED. Index 99 into a two-item list is a caller bug, and the
#                original rule here is that a silently clamped knob reports a
#                value nobody asked for. That decision stands.
#   float/int    CLAMPED. These arrive from a SLIDER and from the NETWORK, where
#                the edge of the range is exactly what "as far as it goes" means,
#                and a request that silently did nothing would look like a
#                dropped packet.
func set_value(key: String, value: Variant) -> void:
	if not OPTIONS.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return
	var clean: Variant = _coerce(key, value)
	if clean == null:
		printerr("[DebugSettings] value ", value, " out of range for '", key, "'")
		return
	if _values.get(key, null) == clean:
		return
	_values[key] = clean
	changed.emit(key, clean)

func get_value(key: String) -> Variant:
	return _values.get(key, OPTIONS.get(key, {}).get("default", 0))

# Kept for every existing call site.
func set_choice(key: String, value: int) -> void:
	set_value(key, value)

# Returns the value to store, or null when it is not acceptable at all.
func _coerce(key: String, value: Variant) -> Variant:
	var entry: Dictionary = OPTIONS[key]
	match kind_of(key):
		KIND_FLOAT:
			return clampf(float(value), float(entry.get("min", -INF)), float(entry.get("max", INF)))
		KIND_INT:
			# Plain literals: GDScript refuses `-1 << 30` outright ("only positive
			# operands are supported"), and a parse error in an AUTOLOAD makes the
			# singleton Nil, so every DebugSettings call in the project fails with
			# a message that names the caller instead of this line.
			return clampi(int(value), int(entry.get("min", -1000000000)), int(entry.get("max", 1000000000)))
		KIND_BOOL:
			var b := int(value)
			return b if b == 0 or b == 1 else null
		_:
			var choices: Array = entry["choices"]
			var i := int(value)
			return i if i >= 0 and i < choices.size() else null

# --- The whole config, for replication ----------------------------------------

# A plain Dictionary of key -> value. GameWorld pushes this to clients wholesale:
# it is a handful of entries changed by hand, so working out what changed costs
# more than sending all of it -- the same argument player_names already makes.
func snapshot() -> Dictionary:
	return _values.duplicate()

func apply_snapshot(values: Dictionary) -> void:
	for key in values:
		set_value(str(key), values[key])

# --- Environment overrides ----------------------------------------------------

# BTF_NET_LOG=1, BTF_MG_SPREAD_DEG=4.5. Accepts a choice NAME as well as an index,
# because remembering that "on" is 1 is exactly the kind of thing that goes wrong
# at 2am. An unknown key or value is reported and ignored rather than silently
# dropped -- a typo'd override that quietly does nothing is worse than none.
func _apply_env_overrides() -> void:
	for key in OPTIONS:
		# Explicitly typed, not inferred: `key` comes from iterating a Dictionary
		# so it is a Variant, and `:=` on an expression built from one is a parse
		# error ("cannot infer the type"), not a runtime problem.
		var name: String = str(key)
		var env_name: String = "BTF_" + name.to_upper()
		if not OS.has_environment(env_name):
			continue
		var raw := OS.get_environment(env_name).strip_edges()
		var parsed: Variant = _parse_env(name, raw)
		if parsed == null:
			printerr("[DebugSettings] ", env_name, "=", raw, " is not valid for '", name, "'")
			continue
		set_value(name, parsed)
		print("[DebugSettings] ", name, " = ", get_choice_name(name), " (from ", env_name, ")")

func _parse_env(key: String, raw: String) -> Variant:
	match kind_of(key):
		KIND_FLOAT:
			return float(raw) if raw.is_valid_float() else null
		KIND_INT:
			return int(raw) if raw.is_valid_int() else null
		KIND_BOOL:
			if raw in ["on", "true", "yes"]:
				return 1
			if raw in ["off", "false", "no"]:
				return 0
			return int(raw) if raw.is_valid_int() else null
		_:
			var choices: Array = OPTIONS[key]["choices"]
			var idx: int = choices.find(raw)
			if idx == -1 and raw.is_valid_int():
				idx = int(raw)
			return idx if idx >= 0 and idx < choices.size() else null
