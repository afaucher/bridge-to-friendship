extends RefCounted

# THE BASE GAME, AND THE DEFAULT FOR EVERY QUESTION A MODE IS ASKED.
#
# THE BASE GAME IS MODE ZERO, NOT THE ABSENCE OF A MODE (see game_mode.gd): every
# other mode extends this and overrides only what it changes, so "what does the
# race do about X" has an answer that is either written in race_mode.gd or is the
# base game's, and never "whatever the world happens to do when nobody says".
#
# A MODE DECLARES; IT MUST NOT WRITE. Every method here returns a value that the
# world, the grid, the round machine or the HUD composes -- nothing here assigns
# into SimConfig, DebugSettings or the world. Leaving a mode is dropping a
# declaration rather than remembering to undo one.
#
# ADDING A MODE IS A SCRIPT HERE AND A LINE IN game_mode.gd's registry. Its
# terrain, its rules, its scoring and its HUD all live in the one file.

const SectionGen = preload("res://scripts/level/gen/section_gen.gd")
const SegmentPool = preload("res://scripts/level/segment_pool.gd")

# The three answers a mode may give about a pool. DIFFERENT is not implemented by
# anything yet and exists so that the day a mode needs it, it is a value in a
# table rather than a fourth concept invented under pressure.
const RUNS := "runs"
const OFF := "off"
const DIFFERENT := "differently"

# WHICH GENERATOR FILLS A MODE'S SECTIONS, by name -- kept for the tests and tools
# that ask which kind of ground a mode makes. The generator itself is
# `generate_section`.
const TERRAIN_SECTIONS := "sections"      # the ordinary generated bridge
const TERRAIN_BLANK := "blank"            # flat, empty, undressed
const TERRAIN_TRACK := "track"            # the serpentine bus route
const TERRAIN_RACE := "race"              # a closed circuit with an infield

# The id game_mode.gd registered this mode under.
var id: int = 0

func display_name() -> String:
	return "Bridge With Friends"

# THE ONE-LINE DESCRIPTION, for the lobby. Empty rather than a placeholder for a
# mode that has not written one: the HUD hides the line, and "TODO" on screen is
# worse than nothing.
func blurb() -> String:
	return "The normal mode. Cross together, keep your hats."

# ITS COLOUR ON THE SELECTOR. Deliberately not from the hat palette: a hat is loot
# and the selector is furniture, and a player must never read it as something to
# collect.
func colour() -> Color:
	return Color(0.42, 0.62, 0.86)

# WHAT THIS MODE CHANGES, as data. Read by GameWorld.tuned(); never written.
func overrides() -> Dictionary:
	return {}

func terrain() -> String:
	return TERRAIN_SECTIONS

# ONE SLOT OF THIS MODE'S GROUND. `slot_seed` is the round's own seed (the
# selector rolls one) and `slot` the slot's index in the run. The lobby between
# rounds is never asked: it is always base.
func generate_section(width: int, slot_seed: int, slot: int):
	return SectionGen.section(width, slot_seed, slot)

# EVERY POOL THAT TICKS, ANSWERED. Spelled out rather than defaulted -- a default
# would make an unanswered pool look answered, which is the silence
# `GameMode.missing_pools()` exists to find.
func pools() -> Dictionary:
	return {
		"rushers": RUNS, "gunners": RUNS, "zombies": RUNS, "swallows": RUNS, "plinko": RUNS,
		"hats": RUNS, "specials": RUNS, "deployables": RUNS, "stones": RUNS,
		"elevators": RUNS, "spikes": RUNS, "mutable": RUNS, "mounds": RUNS,
		"graves": RUNS, "merchants": RUNS, "hearts": RUNS, "bullets": RUNS,
		"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
		# NO BUS ON THE ORDINARY BRIDGE. It is the blank zone's whole content,
		# and a vehicle on a bridge full of pillars and holes is a different
		# feature with a different set of problems.
		"bus": OFF,
	}

# WORLD SYSTEMS ONLY THIS MODE NEEDS, as scripts (see scripts/sim/systems/).
# The world builds one of each across every registered mode.
func systems() -> Array:
	return []

# WHAT DECIDES THE ROUND, IN ORDER. Keys of RoundMachine's comparator: the board
# is sorted by the first key that separates two players, and numbered by the same
# list, so a mode that ranks on something new adds a key there and names it here.
#
# THE BRIDGE IS SCORED ON HATS: how many you kept, then how tall the tower is,
# then whether you made it.
func ranking() -> Array:
	return ["hats", "hat_height", "made_it"]

# HUD WIDGETS THIS MODE ADDS, by id (see scripts/ui/hud_widgets.gd). The panels
# every mode shares -- you, your friends, the round line -- are not widgets.
func hud_widgets() -> Array:
	return []
