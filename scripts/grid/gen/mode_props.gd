extends RefCounted

# THINGS A MODE'S GROUND CARRIES THAT THE BRIDGE DOES NOT: the bus post and the
# scattered mines. Shared by the blank zone, the bus route and the race circuit.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GenUtil = preload("res://scripts/grid/gen/gen_util.gd")

# HOW NARROW A ROAD IS AT A PINCH. Nothing lethal is placed on one: at this width
# a mine is not something you steer around, it is a road block. The race circuit
# pinches its lanes to exactly this (RaceCircuitGen.RACE_LANE_PINCH).
const PINCH_WIDTH := 2


# HOW MINES ARE SCATTERED, and the two numbers are about spacing rather than
# density. A stride down the rows so they never bunch, and a clear band at each
# end so nothing lethal sits on a seam.
const MINE_ROW_STRIDE := 7

const MINE_END_CLEAR := 3


# A BUS POST JUST INSIDE THE ENTRANCE.
#
# AT THE BEGINNING, NOT THE MIDDLE, and the first version got that backwards
# for a reason worth keeping. Halfway minimises the worst case: it is the
# furthest you can ever be from a post, so a bus lost at either end costs the
# same half-level walk. That is the right optimisation for RECOVERY and the
# wrong one for the common case, because nothing hands out a bus automatically
# any more -- so the first thing that happens in every bus level is arriving
# without one. Reported from play as having to walk a way to find it, which is
# exactly what optimising the rare case does to the frequent one.
#
# THE TRADE IS REAL AND IT IS ACCEPTED. A bus lost at the far end of a
# serpentine is now a walk back down the whole level rather than half of it. On
# a CIRCUIT it costs nothing at all -- the entrance is on the lap, so you pass
# the post every time round -- and the circuit is the mode this matters most in.
#
# A COUPLE OF ROWS IN, never on the seam itself. An entry row is where a party
# arrives with no warning, and a post standing on it is something you walk into
# before you have seen it.
const BUS_POST_ROW := 2


static func _place_bus_post(seg) -> void:
	for dz in seg.length:
		var z: int = BUS_POST_ROW + dz
		if z >= seg.length - 1:
			break
		for dx in seg.width:
			for side in [1, -1]:
				var x: int = seg.width / 2 + dx * side
				if x < 0 or x >= seg.width:
					continue
				if not seg.is_solid(x, z):
					continue
				if seg.content_at(x, z) != GridConfig.Content.NONE:
					continue
				seg.contents[z][x] = GridConfig.Content.BUS_POST
				return


# ARMED MINES ON THE ROAD, scattered rather than placed.
#
# ONE STRIDE DOWN THE ROWS AND A ROLLED COLUMN. Spacing is the whole design: a
# mine every seven rows is something you steer around, and a cluster is a wall.
# The column is rolled per row so they do not line up into a lane nobody drives
# in -- which is what a fixed column would be after the second lap.
#
# CLEAR OF BOTH ENDS, because the authoring rules say nothing lethal goes on an
# entry or exit row: a party meets those with no warning, and on a circuit the
# entry row is also where a lap starts. And clear of the GATES, because a mine on
# a checkpoint is a lap you are punished for completing.
static func _scatter_mines(seg, salt: int, gates: Array) -> void:
	var blocked := {}
	for entry in gates:
		blocked[entry[0]] = true
	var z: int = MINE_END_CLEAR + GenUtil._band_roll(salt, 91, 6151, 0, MINE_ROW_STRIDE - 1)
	while z < seg.length - MINE_END_CLEAR:
		var x: int = GenUtil._band_roll(salt, z, 3557, 0, seg.width - 1)
		# WALK TO THE NEAREST ROAD rather than skipping the row. On a circuit the
		# rolled column lands in the hole about half the time, and skipping would
		# put every mine on whichever side the roll happened to favour.
		var placed := false
		for step in seg.width:
			for dir in [1, -1]:
				var cx: int = x + step * dir
				if cx < 0 or cx >= seg.width:
					continue
				var cell := Vector2i(cx, z)
				if not seg.is_solid(cx, z) or blocked.has(cell):
					continue
				if seg.content_at(cx, z) != GridConfig.Content.NONE:
					continue
				# NEVER IN A PINCH. A mine on a four-metre squeeze is not a hazard
				# you steer around, it is a road block -- the bus is 1.1 m wide and
				# a blast radius is four. Hazards go where there is a line past
				# them; the pinch is already the difficulty there.
				if _run_width_at(seg, cx, z) <= PINCH_WIDTH:
					continue
				seg.mine_cells.append(cell)
				placed = true
				break
			if placed:
				break
		z += MINE_ROW_STRIDE


# How wide the piece of road under (x, z) is, across the row. Used to keep mines
# out of pinches, and it asks the geometry rather than the profile that made it.
static func _run_width_at(seg, x: int, z: int) -> int:
	if not seg.is_solid(x, z):
		return 0
	var lo: int = x
	while lo > 0 and seg.is_solid(lo - 1, z):
		lo -= 1
	var hi: int = x
	while hi < seg.width - 1 and seg.is_solid(hi + 1, z):
		hi += 1
	return hi - lo + 1
