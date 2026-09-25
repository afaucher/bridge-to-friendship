extends "res://scripts/test_support/test_case.gd"

# EVERY MODE IS A SCRIPT THAT ANSWERS EVERY QUESTION, AND THE ANSWERS ARE USED.
#
# scripts/sim/modes/ holds one class per mode, each overriding only what it
# changes about the base game. What this pins:
#   1. EVERY REGISTERED MODE MAKES GROUND. Its `generate_section` returns a real
#      segment of the canvas width -- the grid calls nothing else.
#   2. THE SELECTOR CAN TELL THEM APART: every mode has its own colour.
#   3. THE RACE RANKS ON THE LAP AND THE BRIDGE DOES NOT. Asserted through
#      rank_entries with each mode's own ranking: a lap is the whole of a race's
#      board and nothing at all on the bridge's, where "hats decide" must hold
#      even if a stray lap time were on the entry.
#   4. THE LAP CLOCK AND THE LAP TRACKER COME WITH THE RACE and with nothing else.

const GameMode = preload("res://scripts/sim/modes/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/world/round_machine.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const LapTracker = preload("res://scripts/sim/systems/lap_tracker.gd")

func setup(_main) -> void:
	var colours: Dictionary = {}
	for mode in GameMode.ids():
		var label: String = GameMode.name_of(mode)
		var seg = GameMode.generate_section(mode, GridConfig.DEFAULT_WIDTH, 4242, 1)
		if check(seg != null, "%s makes ground" % label):
			eq(int(seg.width), GridConfig.DEFAULT_WIDTH, "%s makes it the canvas wide" % label)
			check(int(seg.length) > 0, "%s makes it some rows long" % label)
		var c: Color = GameMode.colour_of(mode)
		check(not colours.has(c), "%s has a colour of its own on the selector" % label)
		colours[c] = true
		eq(GameMode.MODES[mode]["name"], label, "the MODES table is built from the class")

	var racer := {"peer": 1, "lap": 1800, "hats": 0, "made_it": true}
	var hoarder := {"peer": 2, "lap": 0, "hats": 3, "made_it": true}
	var race: Array = RoundMachine.rank_entries([hoarder, racer], GameMode.ranking_of(GameMode.RACE))
	eq(int(race[0]["peer"]), 1, "in a race the lap wins over a hat stack")
	eq(RoundMachine.rank_key(race[0], GameMode.ranking_of(GameMode.RACE)), "lap",
		"and the board says so")
	var bridge: Array = RoundMachine.rank_entries([racer, hoarder], GameMode.ranking_of(GameMode.BASE))
	eq(int(bridge[0]["peer"]), 2, "on the bridge the hats win, whatever lap is on the entry")
	eq(RoundMachine.rank_key(bridge[0], GameMode.ranking_of(GameMode.BASE)), "hats",
		"and the board says hats")

	for mode in GameMode.ids():
		var race_only: bool = mode == GameMode.RACE
		eq(GameMode.hud_widgets_of(mode).has("lap_clock"), race_only,
			"%s %s a lap clock" % [GameMode.name_of(mode), "has" if race_only else "has no"])
		eq(GameMode.systems_of(mode).has(LapTracker), race_only,
			"%s %s the lap tracker" % [GameMode.name_of(mode), "brings" if race_only else "does not bring"])
	check(GameMode.all_systems().has(LapTracker), "and the world is told to build it")
	finish()
