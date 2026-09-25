extends RefCounted

# WHAT KIND OF ROUND THIS IS. M25 phase 1: the seam, with nothing new to look at.
#
# THE BASE GAME IS MODE ZERO, NOT THE ABSENCE OF A MODE, and that is the whole
# reason this file exists before there is a second mode to put in it. If "base"
# were the absence, every subsystem would grow an implicit `if no mode, do the old
# thing` and modes would become exceptions to a normal nobody wrote down. Exceptions
# to an unwritten normal is how a system acquires four incompatible special cases
# and no way to test any of them.
#
# Because base is a mode, the mode machinery is exercised by the thing that runs
# every day -- every playtest and every gate run. That is the only version that
# stays working, and it is why phase 1 is a mode that must look like nothing
# happened. **If anything on screen changed, phase 1 failed.**
#
# A MODE DECLARES; IT MUST NOT WRITE. `overrides` is read by the world and composed
# over the ordinary values -- nothing here is assigned into SimConfig or into
# DebugSettings, and leaving a mode is DROPPING a declaration rather than
# remembering to undo one. There is nothing to leak.
#
# This project already has that hazard at test scale and keeps tripping on it:
# `test_gunners` must restore `turret_arc_deg`, and `mg_spread_deg` had to be put
# back in two separate files on 2026-08-22. Those get caught because the gate runs
# tests back to back and somebody reads the diff. A mode that leaked would do it
# DURING PLAY, on one machine, with nobody watching.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const BaseMode = preload("res://scripts/sim/modes/base_mode.gd")

const BASE := 0
const BLANK := 1
const TRACK := 2
const RACE := 3

# WHICH GENERATOR FILLS A MODE'S SECTIONS, by name. The generator itself is each
# mode's `generate_section`; these names remain for anything that asks which KIND
# of ground a mode makes.
const TERRAIN_SECTIONS = BaseMode.TERRAIN_SECTIONS
const TERRAIN_BLANK = BaseMode.TERRAIN_BLANK
const TERRAIN_TRACK = BaseMode.TERRAIN_TRACK
const TERRAIN_RACE = BaseMode.TERRAIN_RACE

# EVERY POOL THAT TICKS, NAMED. A mode owes each of these an answer, and the point
# of the list is that the answers are explicit rather than implied by whatever
# happens to be wired up.
#
# THE FAILURE MODE THIS PREVENTS IS SILENCE, not an error. In a spaceship shooter,
# what does the rescue drone do? What does a hat do? The dangerous answer is not
# "it crashes" -- it is that it QUIETLY RUNS: hats posing onto ships, a drone
# flying out to rescue a spaceship, a merchant standing in a starfield waiting to
# be dashed into.
#
# So the test that matters is what happens when somebody adds pool twenty-one: it
# must fail loudly for every existing mode rather than silently joining them all.
# `missing_pools()` is that check and `test_game_mode` runs it over every mode.
const POOLS := [
	"rushers", "gunners", "zombies", "plinko", "hats", "specials",
	"deployables", "stones", "elevators", "spikes", "mutable", "mounds",
	"graves", "merchants", "hearts", "bullets", "leash", "checkpoint",
	"drone", "rescue", "bus", "swallows",
]

# The three answers a mode may give about a pool. See BaseMode.
const RUNS = BaseMode.RUNS
const OFF = BaseMode.OFF
const DIFFERENT = BaseMode.DIFFERENT

# THE REGISTRY: one script per mode in scripts/sim/modes/, each overriding only
# what it changes about the base game. What each mode IS -- its name, its pools,
# its generator, its scoring, its HUD -- lives in its own file; this is the list
# of them and the questions everything else asks.
const MODE_SCRIPTS := {
	BASE: preload("res://scripts/sim/modes/base_mode.gd"),
	BLANK: preload("res://scripts/sim/modes/blank_mode.gd"),
	TRACK: preload("res://scripts/sim/modes/track_mode.gd"),
	RACE: preload("res://scripts/sim/modes/race_mode.gd"),
}

# One instance of each, built once.
static var _defs: Dictionary = {}

# THE OLD TABLE'S SHAPE, for readers that walk it (`MODES[mode]["name"]`). Built
# from the classes, so it cannot disagree with them.
static var MODES: Dictionary = _build_table()

static func _build_table() -> Dictionary:
	var out: Dictionary = {}
	for mode in MODE_SCRIPTS:
		var d = def(mode)
		out[mode] = {
			"name": d.display_name(), "blurb": d.blurb(), "overrides": d.overrides(),
			"terrain": d.terrain(), "pools": d.pools(),
		}
	return out

# THE MODE ITSELF. An unregistered id is the base game, for the reason `policy`
# answers RUNS: a half-written mode must not be able to produce a corridor nobody
# can cross or switch a subsystem off by accident.
static func def(mode: int):
	if not MODE_SCRIPTS.has(mode):
		mode = BASE
	if not _defs.has(mode):
		var d = MODE_SCRIPTS[mode].new()
		d.id = mode
		_defs[mode] = d
	return _defs[mode]

# WHAT CONTENT A MODE'S TERRAIN PLACES, and which pool has to be running for it to
# mean anything. Read by the test that checks the two agree -- see the note on
# TRACK above.
const CONTENT_POOLS := {
	GridConfig.Content.SKIRMISHER: "gunners",
	GridConfig.Content.TURRET: "gunners",
	GridConfig.Content.SHOOTER: "plinko",
	GridConfig.Content.TIMED: "mutable",
	GridConfig.Content.CRUMBLE: "mutable",
	GridConfig.Content.MOUND: "rushers",
	GridConfig.Content.GRAVE: "zombies",
	GridConfig.Content.SPIKES: "spikes",
	GridConfig.Content.MERCHANT: "merchants",
	GridConfig.Content.ELEVATOR: "elevators",
}

# THE ONE-LINE DESCRIPTION, for the lobby. Empty rather than a placeholder for a
# mode that has not written one: the HUD hides the line, and "TODO" on screen is
# worse than nothing.
#
# THE NAMES CAME FROM THE ASK and two of them describe a rule that is not built
# yet. "Bus Survival" says get the bus across or everybody loses, and there is no
# lose condition on it -- the round ends the ordinary way. Written as the ask
# worded it rather than softened, because the blurb is where the intended design
# lives and a player reading it will report the gap, which is the fastest way for
# it to get built.
static func blurb_of(mode: int) -> String:
	return def(mode).blurb() if exists(mode) else ""

static func exists(mode: int) -> bool:
	return MODE_SCRIPTS.has(mode)

static func name_of(mode: int) -> String:
	return def(mode).display_name() if exists(mode) else "?"

static func ids() -> Array:
	return MODE_SCRIPTS.keys()

static func policy(mode: int, pool: String) -> String:
	if not MODES.has(mode):
		return RUNS
	return str(MODES[mode]["pools"].get(pool, RUNS))

static func runs(mode: int, pool: String) -> bool:
	return policy(mode, pool) != OFF

# THE POOLS THIS MODE FORGOT TO MENTION, and the pools it mentions that do not
# exist. Both directions, because a check that walks one side of a correspondence
# passes on every fault living on the other -- the lesson the release zip taught
# on 2026-08-21, where an archive check asked "is every file present" and could
# not see the two extra copies of the game inside it.
static func missing_pools(mode: int) -> Array:
	if not MODES.has(mode):
		return POOLS.duplicate()
	var declared: Dictionary = MODES[mode]["pools"]
	var out: Array = []
	for pool in POOLS:
		if not declared.has(pool):
			out.append(pool)
	for key in declared:
		if not POOLS.has(key):
			out.append("unknown:%s" % str(key))
	return out

# WHAT THIS MODE CHANGES, as data. Read by GameWorld.tuned(); never written
# anywhere. See the header for why that distinction is the point of the file.
static func overrides(mode: int) -> Dictionary:
	if not MODES.has(mode):
		return {}
	return MODES[mode]["overrides"]

static func has_override(mode: int, key: String) -> bool:
	return overrides(mode).has(key)

# WHICH TERRAIN THIS MODE'S SECTIONS ARE MADE OF. An unregistered mode builds the
# ordinary bridge, for the same reason `policy` answers RUNS: a half-written mode
# must not be able to produce a corridor nobody can cross.
static func terrain(mode: int) -> String:
	if not MODES.has(mode):
		return TERRAIN_SECTIONS
	return str(MODES[mode].get("terrain", TERRAIN_SECTIONS))

# --- What each mode brings -----------------------------------------------------

# Its colour on the selector. A mode nobody registered is the neutral grey.
static func colour_of(mode: int) -> Color:
	return def(mode).colour() if exists(mode) else Color(0.55, 0.55, 0.58)

# ONE SLOT OF A MODE'S GROUND. BridgeGrid calls this and nothing else, so a mode
# never reaches into the grid and the grid never asks which mode it is.
static func generate_section(mode: int, width: int, slot_seed: int, slot: int):
	return def(mode).generate_section(width, slot_seed, slot)

# The world systems one mode brings.
static func systems_of(mode: int) -> Array:
	return def(mode).systems()

# EVERY SYSTEM ANY MODE BRINGS, once each. The world builds all of them at start,
# so a mode chosen mid-run finds its system already standing -- and each system
# decides for itself whether it has anything to do.
static func all_systems() -> Array:
	var out: Array = []
	for mode in MODE_SCRIPTS:
		for script in systems_of(mode):
			if not out.has(script):
				out.append(script)
	return out

# What decides this mode's round, in order. See RoundMachine.rank_entries.
static func ranking_of(mode: int) -> Array:
	return def(mode).ranking()

# The HUD widgets this mode adds.
static func hud_widgets_of(mode: int) -> Array:
	return def(mode).hud_widgets()
