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

const BASE := 0
const BLANK := 1
const TRACK := 2
const RACE := 3

# WHICH GENERATOR FILLS A MODE'S SECTIONS. Declared, like everything else here --
# BridgeGrid reads it and calls the matching function, so a mode never reaches
# into the generator and the generator never asks what mode it is.
#
# This is the seam the bus and the shooter actually need. Neither is `section()`
# with knobs on: a bus wants a route and a shooter wants a corridor, and both are
# "this mode makes its own ground".
const TERRAIN_SECTIONS := "sections"      # the ordinary generated bridge
const TERRAIN_BLANK := "blank"            # flat, empty, undressed
const TERRAIN_TRACK := "track"            # the serpentine bus route
const TERRAIN_RACE := "race"              # a closed circuit with an infield

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
	"drone", "rescue", "bus",
]

# The three answers a mode may give about a pool. RUNS_DIFFERENTLY is not
# implemented by anything yet and exists so that the day a mode needs it, it is a
# value in a table rather than a fourth concept invented under pressure.
const RUNS := "runs"
const OFF := "off"
const DIFFERENT := "differently"

# THE REGISTRY. One entry per mode; base is the only one in phase 1 and that is
# deliberate -- the seam is what is being built, not a second game.
#
# `pools` is spelled out rather than defaulted. A default would make an unanswered
# pool look answered, which is the exact silence this table exists to prevent, and
# `missing_pools()` would then have nothing to find.
const MODES := {
	BASE: {
		"name": "Bridge With Friends",
		"blurb": "The normal mode. Cross together, keep your hats.",
		# NOTHING OVERRIDDEN, and that is a real entry rather than an omission:
		# base composing an empty dictionary over the defaults is the same code
		# path every other mode will take, so the composition is exercised daily.
		"overrides": {},
		"terrain": TERRAIN_SECTIONS,
		"pools": {
			"rushers": RUNS, "gunners": RUNS, "zombies": RUNS, "plinko": RUNS,
			"hats": RUNS, "specials": RUNS, "deployables": RUNS, "stones": RUNS,
			"elevators": RUNS, "spikes": RUNS, "mutable": RUNS, "mounds": RUNS,
			"graves": RUNS, "merchants": RUNS, "hearts": RUNS, "bullets": RUNS,
			"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
			# NO BUS ON THE ORDINARY BRIDGE. It is the blank zone's whole content,
			# and a vehicle on a bridge full of pillars and holes is a different
			# feature with a different set of problems.
			"bus": OFF,
		},
	},

	# A ZONE WITH NOTHING IN IT. The second mode, and deliberately not a gameplay
	# variant: what it exercises is that A MODE GENERATES ITS OWN GROUND, which is
	# the seam the bus and the shooter both need and the one thing no amount of
	# tuning base would have built.
	#
	# EVERY POOL IT SWITCHES OFF IS A ROW IN THE SUBSYSTEM x MODE GRID, which is
	# the obligation that could not be paid with one mode: a table with one row is
	# a table where every entry agrees with every other by construction.
	#
	# THE TERRAIN IS EMPTY AND SO ARE THE POOLS, and those are two different
	# statements. `no_dress` keeps the dressing pass off the ground; these keep the
	# WORLD's own spawners off it. A blank zone with rushers walking about would be
	# flat terrain with the usual threats on it, which is not a blank zone -- and
	# it would read as the mode having failed to take effect rather than as a bug.
	BLANK: {
		"name": "Void",
		"blurb": "The empty map. Nothing here but you and the bus.",
		"overrides": {},
		"terrain": TERRAIN_BLANK,
		"pools": {
			# Nothing that threatens, and nothing that is placed INTO terrain.
			"rushers": OFF, "gunners": OFF, "zombies": OFF, "plinko": OFF,
			"deployables": OFF, "stones": OFF, "spikes": OFF, "mutable": OFF,
			"mounds": OFF, "graves": OFF, "merchants": OFF,
			# ...and everything that belongs to the PLAYERS rather than to the
			# level keeps running. A zone you cannot be rescued in, or that eats
			# your hats, would be a punishment rather than an empty room.
			"hats": RUNS, "specials": RUNS, "elevators": RUNS, "hearts": RUNS,
			"bullets": RUNS, "leash": RUNS, "checkpoint": RUNS, "drone": RUNS,
			"rescue": RUNS,
			# THE ONE THING IN IT. An empty room is not a minigame; the bus is
			# what the emptiness is FOR.
			"bus": RUNS,
		},
	},

	# THE BUS ROUTE. A serpentine carved out of the same canvas the blank zone
	# leaves whole: full-width lanes joined at alternating ends, so the driving is
	# lateral and the corners are where the rows advance. See SegmentGen.bus_track.
	#
	# EVERY POOL THIS RUNS IS ONE ITS TERRAIN PLACES CONTENT FOR, and that is not a
	# coincidence -- it is the subsystem x mode grid finally doing its job. A
	# gauntlet lane writes SKIRMISHER glyphs and a strip lane writes TIMED ones, so
	# `gunners` and `mutable` MUST run here or the track would be drawn full of
	# things that never move. That is the silence this table exists to prevent,
	# arriving from the direction nobody watches: not a pool running where it
	# should not, but content placed for a pool that is switched off.
	#
	# `test_game_mode` now checks that correspondence for every mode rather than
	# leaving it to whoever adds the next lane flavour.
	TRACK: {
		"name": "Bus Survival",
		"blurb": "Get the bus to the other side. Zombies on the verges.",
		"overrides": {},
		"terrain": TERRAIN_TRACK,
		"pools": {
			# What the track itself places.
			"bus": RUNS, "gunners": RUNS, "mutable": RUNS,
			# AND THE ZOMBIES, WHICH ARE THE ONLY THING ON THIS TRACK THAT CAN
			# TOUCH YOU. Every other threat here shoots: a skirmisher's round
			# launches a rider at 8.25 m/s, below BUS_EJECT_SPEED, so gunfire
			# chips and nothing could throw anybody out of a bus. A zombie hits
			# at 11.28, which is over the line -- so the rule that a body-check
			# takes your seat finally has something to do it, and defending the
			# bus becomes the passengers' job while the driver keeps going.
			#
			# `graves` rides with them because a zombie is not spawned, it is
			# RAISED: the terrain places a grave and the pool wakes the pack. One
			# without the other is a headstone nobody comes out of.
			"zombies": RUNS, "graves": RUNS,
			# Nothing else the bridge would have put there. A rusher on a race
			# track is a bridge hazard that wandered into the wrong game.
			# AND THE DEPLOYABLES POOL, because the track scatters armed MINES and
			# a mine is a deployable. Switched off, they would be placed, drawn,
			# and never tick -- scenery in the shape of a hazard, which is the
			# exact silence this table exists to prevent.
			"deployables": RUNS,
			"rushers": OFF, "plinko": OFF,
			"stones": OFF, "spikes": OFF, "mounds": OFF,
			"merchants": OFF, "elevators": OFF,
			# And everything that belongs to the party.
			"hats": RUNS, "specials": RUNS, "hearts": RUNS, "bullets": RUNS,
			"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
		},
	},

	# THE RACE CIRCUIT. A closed ring with a hole in the middle -- see
	# implementation_plans/m26_race_track.md and SegmentGen.race_loop.
	#
	# WHAT IS HERE AND WHAT IS NOT. This is the mode existing and being drivable:
	# you can pick it, it builds circuits, and the bus and the mines work on them.
	# The LAPS are not here. Crossing a gate does nothing yet, nothing is timed,
	# and nothing is on screen -- the gates are generated and recorded and no
	# subsystem reads them.
	#
	# AND THE RUN STILL ADVANCES, which is the honest shape of what phase 2 left
	# undone. A circuit cannot stream: it is bounded and comes back on itself, and
	# the right answer is one arena the run does not move through. What this
	# builds instead is a CHAIN of circuits joined at their caps -- drivable, and
	# each one lappable, but the party can also just keep going forwards, which is
	# the bridge's win condition wearing a racetrack. Fixing that means teaching
	# `_extend_run`, the leash and the round machine that a run can be closed, and
	# that is its own phase rather than something to bolt on here.
	RACE: {
		"name": "Race Track",
		"blurb": "Best lap time wins. Cross the white line to start.",
		"overrides": {},
		"terrain": TERRAIN_RACE,
		"pools": {
			# The vehicle, and the mines the circuit scatters. Both are placed by
			# the terrain, so both must run or the track is drawn full of things
			# that never move.
			"bus": RUNS, "deployables": RUNS,
			# NOTHING THAT SHOOTS OR CHASES. A circuit is about the line and the
			# corner; the hazards are the hole in the middle and the mines. The
			# zombies that make the bus route a fight would make this one a fight
			# with a lap timer attached, which is a different game.
			"gunners": OFF, "rushers": OFF, "zombies": OFF, "plinko": OFF,
			"mutable": OFF, "stones": OFF, "spikes": OFF, "mounds": OFF,
			"graves": OFF, "merchants": OFF, "elevators": OFF,
			# And everything that belongs to the party.
			"hats": RUNS, "specials": RUNS, "hearts": RUNS, "bullets": RUNS,
			"leash": RUNS, "checkpoint": RUNS, "drone": RUNS, "rescue": RUNS,
		},
	},

}

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
	return str(MODES.get(mode, {}).get("blurb", ""))

static func exists(mode: int) -> bool:
	return MODES.has(mode)

static func name_of(mode: int) -> String:
	if not MODES.has(mode):
		return "?"
	return str(MODES[mode]["name"])

static func ids() -> Array:
	return MODES.keys()

# WHAT THIS MODE SAYS ABOUT A POOL. An unknown mode or an unnamed pool answers
# RUNS -- the base behaviour -- because a half-declared mode must not be able to
# switch a subsystem off by accident. `missing_pools()` is what makes the omission
# visible; this is what keeps the game playable while somebody fixes it.
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
