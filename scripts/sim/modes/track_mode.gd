extends "res://scripts/sim/modes/base_mode.gd"

# THE BUS ROUTE. A serpentine carved out of the same canvas the blank zone leaves
# whole: full-width lanes joined at alternating ends, so the driving is lateral
# and the corners are where the rows advance. See SegmentGen.bus_track.
#
# EVERY POOL THIS RUNS IS ONE ITS TERRAIN PLACES CONTENT FOR, and that is the
# subsystem x mode grid doing its job. A gauntlet lane writes SKIRMISHER glyphs
# and a strip lane writes TIMED ones, so `gunners` and `mutable` MUST run here or
# the track would be drawn full of things that never move -- content placed for
# a pool that is switched off. `test_game_mode` checks that correspondence.
#
# THE NAME CAME FROM THE ASK and describes a rule that is not built yet: there is
# no lose condition on the bus, the round ends the ordinary way. Written as asked
# rather than softened, because a player reading it will report the gap.

func display_name() -> String:
	return "Bus Survival"

func blurb() -> String:
	return "Get the bus to the other side. Zombies on the verges."

func colour() -> Color:
	return Color(0.82, 0.68, 0.22)   # the bus's own deck yellow

func terrain() -> String:
	return TERRAIN_TRACK

func generate_section(width: int, slot_seed: int, slot: int):
	return SegmentGen.bus_track(width, slot_seed, slot)

func pools() -> Dictionary:
	return {
		# What the track itself places.
		"bus": RUNS, "gunners": RUNS, "mutable": RUNS,
		# AND THE ZOMBIES, WHICH ARE THE ONLY THING ON THIS TRACK THAT CAN TOUCH
		# YOU. A skirmisher's round launches a rider below BUS_EJECT_SPEED, so
		# gunfire chips and nothing else could throw anybody out of a bus; a zombie
		# hits over the line. `graves` rides with them because a zombie is RAISED:
		# one without the other is a headstone nobody comes out of.
		"zombies": RUNS, "swallows": RUNS, "graves": RUNS,
		# AND THE DEPLOYABLES, because the track scatters armed MINES and a mine is
		# a deployable. Switched off, they would be scenery in the shape of a hazard.
		"deployables": RUNS,
		# Nothing else the bridge would have put there.
		"rushers": OFF, "plinko": OFF,
		"stones": OFF, "spikes": OFF, "mounds": OFF,
		"merchants": OFF, "elevators": OFF,
		# And everything that belongs to the party.
		"hats": RUNS, "specials": RUNS, "hearts": RUNS, "bullets": RUNS,
		"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
	}
