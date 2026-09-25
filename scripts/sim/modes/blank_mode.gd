extends "res://scripts/sim/modes/base_mode.gd"

# A ZONE WITH NOTHING IN IT. The second mode, and deliberately not a gameplay
# variant: what it exercises is that A MODE GENERATES ITS OWN GROUND, which is
# the seam the bus and the shooter both need and the one thing no amount of
# tuning base would have built.
#
# THE TERRAIN IS EMPTY AND SO ARE THE POOLS, and those are two different
# statements. `no_dress` keeps the dressing pass off the ground; these keep the
# WORLD's own spawners off it. A blank zone with rushers walking about would be
# flat terrain with the usual threats on it, which would read as the mode having
# failed to take effect rather than as a bug.

func display_name() -> String:
	return "Void"

func blurb() -> String:
	return "The empty map. Nothing here but you and the bus."

func colour() -> Color:
	return Color(0.86, 0.84, 0.52)

func terrain() -> String:
	return TERRAIN_BLANK

func generate_section(width: int, slot_seed: int, slot: int):
	return SegmentGen.blank_zone(width, slot_seed, slot)

func pools() -> Dictionary:
	return {
		# Nothing that threatens, and nothing that is placed INTO terrain.
		"rushers": OFF, "gunners": OFF, "zombies": OFF, "swallows": OFF, "plinko": OFF,
		"deployables": OFF, "stones": OFF, "spikes": OFF, "mutable": OFF,
		"mounds": OFF, "graves": OFF, "merchants": OFF,
		# ...and everything that belongs to the PLAYERS rather than to the level
		# keeps running. A zone you cannot be rescued in, or that eats your hats,
		# would be a punishment rather than an empty room.
		"hats": RUNS, "specials": RUNS, "elevators": RUNS, "hearts": RUNS,
		"bullets": RUNS, "leash": RUNS, "checkpoint": RUNS, "drone": RUNS,
		"rescue": RUNS,
		# THE ONE THING IN IT. An empty room is not a minigame; the bus is what the
		# emptiness is FOR.
		"bus": RUNS,
	}
