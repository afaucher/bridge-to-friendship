extends RefCounted

# GENERATED SEGMENTS. M17 layers 1 and the lobby.
#
# Produces a `SegmentData` in memory rather than a file, so everything
# downstream -- the validator, the builder, the dressing pass, the run assembler
# -- cannot tell the difference between a generated segment and an authored one.
# That is the whole architecture: this file only has to fill in cell records.
#
# THE LOBBY CAME FIRST ON PURPOSE (phase 4). It is trivially parametric -- a
# solid rectangle, a rack, some hats, a band at each end -- and it is the one
# piece of content where being wrong is CHEAP: a lobby has no hazards, so a
# generation bug costs a strange-looking room rather than a run nobody can
# finish. It proves generate, validate, assemble and play end to end before any
# of that meets terrain full of holes and shooters. Getting the first generator
# wrong on hostile terrain means debugging the generator and the level design at
# the same time.
#
# EVERYTHING HERE IS A PURE FUNCTION OF ITS SEED. The bridge is a pure function
# of (seed, count) and must stay one, because a joining client is told two
# numbers and builds the identical world. The mixer is local; the global RNG is
# never touched.
#
# THIS FILE IS NOW THE FRONT DOOR, NOT THE GENERATOR. It was six generators in
# 3,000 lines -- the bridge, the maze, the lobby, the blank zone, the bus route
# and the race circuit, with water, edges, patches, mines and the bus post mixed
# through them and helpers private to one used by another. Each is now its own
# file under scripts/grid/gen/, and this re-exports what callers outside the
# generators have always asked for, under the names they have always used.
#
# NEW CODE SHOULD PRELOAD THE GENERATOR IT MEANS. A mode's ground belongs to the
# mode (scripts/sim/modes/), and each mode calls its own module directly.

const GenUtil = preload("res://scripts/grid/gen/gen_util.gd")
const LobbyGen = preload("res://scripts/grid/gen/lobby_gen.gd")
const BlankZoneGen = preload("res://scripts/grid/gen/blank_zone_gen.gd")
const BusTrackGen = preload("res://scripts/grid/gen/bus_track_gen.gd")
const SectionGen = preload("res://scripts/grid/gen/section_gen.gd")
const WaterFeatures = preload("res://scripts/grid/gen/water_features.gd")
const MazeGen = preload("res://scripts/grid/gen/maze_gen.gd")
const EdgeProfile = preload("res://scripts/grid/gen/edge_profile.gd")
const RaceCircuitGen = preload("res://scripts/grid/gen/race_circuit_gen.gd")
const ModeProps = preload("res://scripts/grid/gen/mode_props.gd")

# --- The generators -----------------------------------------------------------

static func section(width: int, run_seed: int, index: int, attempts: int = 24):
	return SectionGen.section(width, run_seed, index, attempts)

static func lobby(width: int, run_seed: int, index: int):
	return LobbyGen.lobby(width, run_seed, index)

static func blank_zone(width: int, run_seed: int, index: int):
	return BlankZoneGen.blank_zone(width, run_seed, index)

static func bus_track(width: int, run_seed: int, index: int):
	return BusTrackGen.bus_track(width, run_seed, index)

static func race_loop(width: int, run_seed: int, index: int, slice: int = 0,
		slices: int = 1):
	return RaceCircuitGen.race_loop(width, run_seed, index, slice, slices)

static func track_speed_limit(turn_rows: int) -> float:
	return BusTrackGen.track_speed_limit(turn_rows)

# --- Pieces the tests drive directly -------------------------------------------

static func _place_channel(seg, salt: int) -> void:
	WaterFeatures._place_channel(seg, salt)

static func _maze_deepest(open_cells: Dictionary, cols: int, rows: int,
		from: Vector2i) -> Vector2i:
	return MazeGen._maze_deepest(open_cells, cols, rows, from)

static func _maze_between(a: Vector2i, b: Vector2i) -> Vector2i:
	return MazeGen._maze_between(a, b)

# --- Their numbers, under the old names ------------------------------------------

const LOBBY_MIN_WIDTH = GenUtil.LOBBY_MIN_WIDTH
const GATE_DEPTH = GenUtil.GATE_DEPTH
const SPLIT_RISE_MAX = SectionGen.SPLIT_RISE_MAX
const INSET_RATE = EdgeProfile.INSET_RATE
const INSET_STEP_ROWS_MAX = EdgeProfile.INSET_STEP_ROWS_MAX
const MAZE_MAX_ROWS = MazeGen.MAZE_MAX_ROWS
const TRACK_TURN_MIN = BusTrackGen.TRACK_TURN_MIN
const TRACK_TURN_MAX = BusTrackGen.TRACK_TURN_MAX
const TRACK_LANE_MIN = BusTrackGen.TRACK_LANE_MIN
const TRACK_LANE_MAX = BusTrackGen.TRACK_LANE_MAX
const TRACK_BAY_MIN = BusTrackGen.TRACK_BAY_MIN
const TRACK_BAY_MAX = BusTrackGen.TRACK_BAY_MAX
const RACE_LANE_MIN = RaceCircuitGen.RACE_LANE_MIN
const RACE_LANE_PINCH = RaceCircuitGen.RACE_LANE_PINCH
const RACE_LANE_MAX = RaceCircuitGen.RACE_LANE_MAX
const RACE_PINCH_ROWS = RaceCircuitGen.RACE_PINCH_ROWS
const RACE_INFIELD_MIN = RaceCircuitGen.RACE_INFIELD_MIN
const RACE_OUTER_SWING = RaceCircuitGen.RACE_OUTER_SWING
const RACE_CHECKPOINTS = RaceCircuitGen.RACE_CHECKPOINTS
const CIRCUIT_CHICANE = RaceCircuitGen.CIRCUIT_CHICANE
const CIRCUIT_HAIRPIN = RaceCircuitGen.CIRCUIT_HAIRPIN
const CIRCUIT_BOTTLENECK = RaceCircuitGen.CIRCUIT_BOTTLENECK
const CIRCUIT_KINDS = RaceCircuitGen.CIRCUIT_KINDS
const BUS_POST_ROW = ModeProps.BUS_POST_ROW
