extends "res://scripts/sim/modes/base_mode.gd"

const RaceCircuitGen = preload("res://scripts/grid/gen/race_circuit_gen.gd")

# THE RACE CIRCUIT. A closed ring with a hole in the middle -- see
# implementation_plans/m26_race_track.md and SegmentGen.race_loop.
#
# THE ONE MODE WITH RULES OF ITS OWN, and all of them are here: a circuit for
# ground, the LapTracker for the laps, the lap clock on the HUD, and a board that
# ranks on the best lap. None of the world, the round machine or the HUD asks
# "is this the race" -- each asks the mode.

const LapTracker = preload("res://scripts/sim/systems/lap_tracker.gd")

func display_name() -> String:
	return "Race Track"

func blurb() -> String:
	return "Best lap time wins. Cross the white line to start."

func colour() -> Color:
	return Color(0.85, 0.85, 0.88)    # start-line white

func terrain() -> String:
	return TERRAIN_RACE

# ONE CIRCUIT PER ROUND, HANDED OUT A SLICE PER SLOT. The round is the seed, so
# all five slots compute the same circuit and each takes its own piece of it --
# which is what makes them one track rather than five.
func generate_section(width: int, slot_seed: int, slot: int):
	return RaceCircuitGen.race_loop(width, slot_seed,
		SegmentPool.round_of_slot(slot),
		(slot % (SegmentPool.SECTIONS_PER_ROUND + 1)) - 1,
		SegmentPool.SECTIONS_PER_ROUND)

func pools() -> Dictionary:
	return {
		# The vehicle, and the mines the circuit scatters. Both are placed by the
		# terrain, so both must run or the track is drawn full of things that
		# never move.
		"bus": RUNS, "deployables": RUNS,
		# NOTHING THAT SHOOTS OR CHASES. A circuit is about the line and the
		# corner; the hazards are the hole in the middle and the mines.
		"gunners": OFF, "rushers": OFF, "zombies": OFF, "swallows": OFF, "plinko": OFF,
		"mutable": OFF, "stones": OFF, "spikes": OFF, "mounds": OFF,
		"graves": OFF, "merchants": OFF, "elevators": OFF,
		# And everything that belongs to the party.
		"hats": RUNS, "specials": RUNS, "hearts": RUNS, "bullets": RUNS,
		"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
	}

func systems() -> Array:
	return [LapTracker]

# LAP TIME FIRST. In a race the hats did not decide anything; the lap did. A tie
# on laps (nobody finished one, or two identical) falls through to the bridge's
# own order.
func ranking() -> Array:
	return ["lap"] + super()

func hud_widgets() -> Array:
	return ["lap_clock"]
