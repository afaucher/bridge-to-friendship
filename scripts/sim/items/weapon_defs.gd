extends RefCounted

# EVERY SPECIAL, ONE ROW EACH. What it is called on the HUD, how much of it you
# get, which mesh it shows and in what colour, how the one button drives it, how
# often it fires, what it fires, and what it costs to carry.
#
# THIS WAS FIVE PLACES. `SpecialBody.kind_name()` held the names,
# `SHAPE_NODES` the meshes, `_kind_colour()` the colours, a line in
# `apply_kind_look` the barrels, `SpecialPool._base_ammo()` the magazines -- and
# the BEHAVIOUR was nine `_step_*` functions in GameWorld, six of them the same
# eight lines with different constants. Adding a weapon meant finding all of
# them, and the one that was missed was invisible: three guns shipped as a
# floating barrel because two of the five tables disagreed about a mesh
# (CLAUDE.md, "a lookup table whose values repeat").
#
# A NEW WEAPON IS A ROW HERE, a mesh in special.tscn, and -- only if it does
# something no row here does -- a `fire` verb in WeaponSystem.
#
# DECLARES, DOES NOT DO. Nothing in this file touches the world; WeaponSystem
# reads a row and acts on it. Preloads only SimConfig, so special_body.gd can
# take its Kind enum from here without closing a class cycle.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

enum Kind { MACHINE_GUN, GRENADE, MINE, SHIELD, ROCKET, LEGS, SHOTGUN, RIFLE, HEAVY }

# ONE BUTTON, FOUR MEANINGS. Which one a special is, is the whole difference
# between them -- the slot, the pickup, the drop and the HUD box are shared.
enum Trigger {
	HOLD,       # fires while DOWN, on its interval: every gun, and the mine
	RELEASE,    # charges while down, throws when it comes UP: the grenade
	PRESS,      # one use per press: the shield, which is up while held
	PASSIVE,    # the body spends it (legs); the button is read by PlayerBody
}

# What a HOLD weapon's shot is. `spread` is [horizontal, vertical] degrees; SPREAD_KNOB
# means the machine gun's own cone, read from the `mg_spread_deg` knob each shot;
# NO_SPREAD fires exactly down the aim with no roll at all (the rocket).
const SPREAD_KNOB := [-1.0, -1.0]
const NO_SPREAD := []

const DEFS := {
	Kind.MACHINE_GUN: {
		"name": "MG", "ammo": SimConfig.MG_AMMO,
		"shape": "Body", "barrel": true, "colour": Color(0.95, 0.6, 0.15),
		"trigger": Trigger.HOLD, "interval": SimConfig.MG_FIRE_INTERVAL,
		"interval_knob": "mg_fire_interval",
		"fire": "rounds", "rounds": 1, "spread": SPREAD_KNOB, "damage": SimConfig.MG_DAMAGE,
	},
	Kind.GRENADE: {
		"name": "NADE", "ammo": SimConfig.GRENADE_AMMO,
		# The same hazard yellow it throws.
		"shape": "Nade", "barrel": false, "colour": Color(0.95, 0.75, 0.15),
		"trigger": Trigger.RELEASE, "fire": "grenade",
	},
	Kind.MINE: {
		"name": "MINE", "ammo": SimConfig.MINE_AMMO,
		"shape": "Mine", "barrel": false, "colour": Color(0.85, 0.22, 0.15),
		"trigger": Trigger.HOLD, "interval": SimConfig.MINE_PLACE_INTERVAL, "fire": "mine",
	},
	Kind.SHIELD: {
		"name": "SHLD", "ammo": SimConfig.SHIELD_AMMO,
		"shape": "Shield", "barrel": false, "colour": Color(0.25, 0.52, 0.88),
		"trigger": Trigger.PRESS, "fire": "",
	},
	Kind.ROCKET: {
		"name": "RKT", "ammo": SimConfig.ROCKET_AMMO,
		# Olive, the only military thing here.
		"shape": "Rocket", "barrel": false, "colour": Color(0.55, 0.62, 0.30),
		# HELD DOWN, like the machine gun, and firing on the same timer -- a rocket
		# is a gun, not a thrown thing. The cadence does all the work of making it
		# feel different: two shots take three seconds, so holding is not a strategy.
		"trigger": Trigger.HOLD, "interval": SimConfig.ROCKET_FIRE_INTERVAL,
		"fire": "rounds", "rounds": 1, "spread": NO_SPREAD, "rocket": true,
		"damage": SimConfig.MG_DAMAGE,
	},
	Kind.LEGS: {
		"name": "LEGS", "ammo": SimConfig.LEGS_AMMO,
		# Spring green, and the only mobility one.
		"shape": "Legs", "barrel": false, "colour": Color(0.35, 0.85, 0.70),
		"trigger": Trigger.PASSIVE, "fire": "",
	},
	Kind.SHOTGUN: {
		"name": "SHOT", "ammo": SimConfig.SHOTGUN_AMMO,
		# A hotter, redder orange than the MG.
		"shape": "Body", "barrel": true, "colour": Color(0.80, 0.35, 0.10),
		# A FISTFUL AT ONCE. The pellets leave on one pull and the SHOT is what
		# costs ammunition, not the pellet -- which is what makes the magazine eight
		# rather than fifty-six, and each pull a decision the player can count.
		"trigger": Trigger.HOLD, "interval": SimConfig.SHOTGUN_FIRE_INTERVAL,
		"fire": "rounds", "rounds": SimConfig.SHOTGUN_PELLETS,
		"spread": [SimConfig.SHOTGUN_SPREAD_DEG, SimConfig.SHOTGUN_SPREAD_VERTICAL_DEG],
		"damage": SimConfig.SHOTGUN_DAMAGE,
	},
	Kind.RIFLE: {
		"name": "RIFLE", "ammo": SimConfig.RIFLE_AMMO,
		# Pale blue: the only PRECISE warm thing.
		"shape": "Body", "barrel": true, "colour": Color(0.55, 0.80, 0.95),
		# ONE ROUND, ALMOST EXACTLY WHERE YOU POINTED, SLOWLY. The cone is not zero:
		# a perfectly deterministic line makes two players in the same place fire
		# the same round forever, and a hair of scatter keeps a burst from being
		# one bullet.
		"trigger": Trigger.HOLD, "interval": SimConfig.RIFLE_FIRE_INTERVAL,
		"fire": "rounds", "rounds": 1,
		"spread": [SimConfig.RIFLE_SPREAD_DEG, SimConfig.RIFLE_SPREAD_VERTICAL_DEG],
		"damage": SimConfig.RIFLE_DAMAGE,
	},
	Kind.HEAVY: {
		"name": "HEAVY", "ammo": SimConfig.HEAVY_AMMO,
		# Gunmetal, the only HEAVY-looking one.
		"shape": "Body", "barrel": true, "colour": Color(0.45, 0.42, 0.40),
		# THE MACHINE GUN WITH THE BRAKES OFF: faster, wider, sixty rounds deep. Not
		# a new mechanism -- a different position on the same three dials, and the
		# interesting part is the price it charges to carry.
		"trigger": Trigger.HOLD, "interval": SimConfig.HEAVY_FIRE_INTERVAL,
		"fire": "rounds", "rounds": 1,
		"spread": [SimConfig.HEAVY_SPREAD_DEG, SimConfig.HEAVY_SPREAD_VERTICAL_DEG],
		"damage": SimConfig.HEAVY_DAMAGE, "carry_speed": SimConfig.HEAVY_CARRY_SPEED,
	},
}

static func has(kind: int) -> bool:
	return DEFS.has(kind)

static func def(kind: int) -> Dictionary:
	return DEFS.get(kind, {})

static func name_of(kind: int) -> String:
	return str(def(kind).get("name", "?"))

static func base_ammo(kind: int) -> int:
	return int(def(kind).get("ammo", 0))

static func shape_of(kind: int) -> String:
	return str(def(kind).get("shape", ""))

static func has_barrel(kind: int) -> bool:
	return bool(def(kind).get("barrel", false))

# The machine gun, unchanged, for anything this table does not know.
static func colour_of(kind: int) -> Color:
	return def(kind).get("colour", Color(0.95, 0.6, 0.15))

static func trigger_of(kind: int) -> int:
	return int(def(kind).get("trigger", Trigger.HOLD))

# How long between uses. A row with an `interval_knob` is tunable from the console.
static func interval_of(kind: int) -> float:
	var row: Dictionary = def(kind)
	var fixed: float = float(row.get("interval", 0.0))
	var knob: String = str(row.get("interval_knob", ""))
	return DebugSettings.tuned(knob, fixed) if knob != "" else fixed

# How fast you walk while holding it, as a fraction of normal.
static func carry_speed_of(kind: int) -> float:
	return float(def(kind).get("carry_speed", 1.0))

# Every distinct mesh any kind shows. DEDUPLICATED ON THE VALUE -- see
# SpecialBody.apply_kind_look for why walking the keys was a bug.
static func shape_nodes() -> Array:
	var out: Array = []
	for kind in DEFS:
		var node: String = shape_of(kind)
		if node != "" and not out.has(node):
			out.append(node)
	return out
