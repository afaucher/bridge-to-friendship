extends RefCounted

# THE MAZE: the one section KIND that is not the profile loop -- a braided
# corridor lattice end to end, with its dead ends trapped. Called by
# SectionGen.section one time in five.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GenUtil = preload("res://scripts/grid/gen/gen_util.gd")

# --- The maze section ---------------------------------------------------------

# THE LATTICE. Corridors sit on EVEN columns and EVEN rows; everything between
# them starts as wall and gets carved. So the maze's own coordinates (i, j) map
# to grid cells (2i, 2 + 2j), and the cell halfway between two neighbours is the
# wall that separates them -- carving a link is writing one cell.
#
# EVEN COLUMNS, WHICH PUTS THE OUTER LANES AGAINST THE BRIDGE'S OWN EDGE (changed
# 2026-08-17). It was odd columns, spending x = 0 and x = width-1 on explicit WALL
# blocks -- and the deck already railings itself there: `has_wall` parapets any
# SOLID cell in the outermost column. The boundary was being paid for twice.
#
# THE TWO WERE THE SAME HEIGHT WHEN THAT CHANGED, and are not any more:
# WALL_HEIGHT went to 1.0 on 2026-08-20 so the bridge reads as a structure rather
# than a trench, while a maze wall is still MAZE_WALL_HEIGHT (2 units). The
# argument survives the difference because it never rested on them matching --
# there is no jump and no step-up in this game, so a 1 m railing is exactly as
# impassable as a 2 m one, and the outer lane is bounded either way. What DID
# change is how it looks: the maze's outer lane now has a low rail beside it and
# the interior has tall walls, which is either "the maze is built ON a bridge"
# or "the outside wall is missing" depending on the eye. Worth a look next time
# a maze comes up in play.
#
# Worth a lane, and worth more than a lane. At width 15 it is eight corridors
# instead of seven, and the maze stops being a sealed box: the outer lanes have
# the real deck edge beside them and the drop past it, which is what every other
# section looks like from a 45-degree camera.
#
# THE LANE IS WALKABLE, AND THAT WAS MEASURED BEFORE THIS CHANGED -- see
# test_edge_lane. A parapet is a 0.3 m slab inset at the cell edge, and this repo
# has three separate notes about flat-bottomed bodies catching on exactly that
# kind of boundary, every one of which presented as "sometimes you just stop". A
# body walks the outer lane its full length and stays dead on its centre line.
const MAZE_MIN_ROWS := 7

const MAZE_MAX_ROWS := 10


# TWO UNITS, AND THE NUMBER IS A SIGHTLINE RATHER THAN A CLIMB. There is no
# step-up in this game, so ANY height blocks and one unit would block just as
# well. At the camera's 45 degrees a wall of height h hides exactly h metres of
# ground behind it and a cell is 2 m, so two units hides the FLOOR of the cell
# beyond and one unit would hide half of it and read as a kerb. A player is
# 1.8 m, so heads still clear it: you lose track of what is on the ground, never
# of where your friends are. Three would start swallowing people.
const MAZE_WALL_HEIGHT := 2


# HOW HARD TO BRAID, as a fraction of the cell count added back as extra links.
#
# A PERFECT MAZE IS THE WRONG SHAPE HERE. The camera is fixed top-down, so the
# whole maze is on screen and nobody is discovering anything -- a single-solution
# maze read from above is not a puzzle, it is a queue, and four players walk it in
# single file. Loops are what make it a co-op section: two routes that both arrive
# means splitting up is a real choice rather than a mistake.
#
# The authored run_maze.seg was carved by dead-end removal alone and came out at
# five loops across seventy cells, which is close to single-file. This adds loops
# DIRECTLY instead of hoping the dead ends supply them.
const MAZE_BRAID := 6      # one extra link per this many cells


# A few dead ends survive to hold the rewards. From above you can SEE the hat, so
# a detour is a decision about time -- which is the only way a dead end earns its
# place in a maze you can see all of.
const MAZE_DEAD_ENDS := 4


# FLOOR TRAPS. A maze with nothing in it is a walking puzzle, and this one is
# read from above -- so the route is never the problem, and the only thing that
# can make choosing it cost anything is what is standing on it.
#
# TIMED FLOORS ARE THE MAZE-FRIENDLY HAZARD. They are periodically solid, so one
# can never make a route impossible -- only slower -- which matters because the
# reachability flood CANNOT SEE CONTENT. A hazard that could seal a corridor would
# be a maze that validates and cannot be crossed, which is the shape CLAUDE.md
# keeps recording. The phase is per-cell (cell.x * 7 + cell.y * 13), so two of
# them side by side open at different moments rather than becoming one wide gap.
#
# SPIKES ARE THE SAME KIND OF THING, and the first version of this file said
# otherwise at length. It claimed a spike could SEAL a corridor -- that it hurts
# the cell it is drawn in, that a maze corridor is one cell wide, and so a spike
# on a cut vertex is a wall with a health bar -- and it refused any placement that
# disconnected the maze.
#
# SPIKES RUN ON A CLOCK. SPIKE_PERIOD is 2 s and they are out for 34% of it, of
# which the leading and trailing quarters are the RAMP -- a deliberate telegraph
# -- so the cell actually hurts for 0.48 s in every 2.0 and is harmless 76% of the
# time. And when it does hit it charges SPIKE_DAMAGE, one of five health. It does
# not block; it takes a toll from somebody who walked through without reading it.
# Corrected on the day it was written, from "the spikes absolutely run on a timer,
# you can walk through them can't you?" -- which is what the constants say and
# what piece_spike_gallery's own header has said all along: a rhythm to read
# rather than a wall.
#
# So a spike on the only route is not a blocked maze, it is a timing gate, which
# is a perfectly good thing for a maze to have. The connectivity check has gone
# and the placements it was suppressing are back.
const MAZE_TIMED := 3

const MAZE_SPIKES := 3


# A WIDE LANE. One row or one column of the lattice, laid out two cells across
# instead of one, so the maze has somewhere in it that is not single file.
#
# THE PROBLEM IT ANSWERS is that a one-cell corridor is a place where nothing can
# happen. Two players cannot pass, a dash is a commitment with no room to correct,
# and a party of four is a queue for the whole section -- which is the same
# complaint the braid answers for ROUTES ("a single-route maze is not a puzzle, it
# is a queue") arriving one level down, about the corridor rather than the map.
#
# IT IS A LAYOUT DECISION AND NOT A CARVE. The lattice is built, braided and
# pruned exactly as it always was; the only thing that changes is how far apart
# the finished cells are placed. So the maze's topology -- every route, every
# loop, every dead end and every reward -- is bit-identical to the maze the same
# seed would have produced without it, and none of the reasoning above about
# braids or dead ends has to be re-checked. What a wall crosses the lane, it
# crosses two cells wide.
#
# HALF OF THEM, because a maze is already one section in five. A rarity inside a
# rarity is a feature nobody sees: at one in five it would be one section in
# twenty-five and most parties would never meet one.
const MAZE_WIDE_PERCENT := 50


# THE LANE IS PAID FOR OUT OF THE LATTICE, not added to the section. A wide lane
# costs one grid column or one grid row; taking it from the lattice keeps a maze
# the same size on the bridge whichever way the roll went, and the alternative --
# growing the section by a row -- makes the length of a section depend on a dice
# roll nobody can see, which the round machine and every walk-budget number are
# denominated in.

static func _maze_attempt(width: int, run_seed: int, index: int, attempt: int):
	var salt: int = Hash.mix(run_seed + index * 15485863 + attempt * 97 + 0x5EED)
	var cols: int = (width + 1) / 2
	# Below three columns it is a corridor with kinks in it, not a maze.
	if cols < 3:
		return null
	var rows: int = MAZE_MIN_ROWS + salt % (MAZE_MAX_ROWS - MAZE_MIN_ROWS + 1)

	# THE WIDE LANE, ROLLED BEFORE ANYTHING IS BUILT, because it is paid for out of
	# the lattice and the lattice is the first thing decided.
	#
	# THE AXIS IT ROLLS MAY NOT BE AFFORDABLE, so it takes the other one rather
	# than dropping the lane. A horizontal lane spends a lattice ROW and rows have
	# a floor (MAZE_MIN_ROWS, below which a maze is a corridor with kinks in it);
	# a vertical lane spends a COLUMN and needs three left to still be a maze. At
	# the current tuning a 7-row maze is a quarter of them, so without the swap a
	# quarter of the horizontal rolls would silently become no lane at all.
	#
	# IT BIASES THE AXIS AND THAT IS THE PRICE: measured over 250 sections, 12
	# lanes ran along the maze and 8 across it, because the swap only ever runs one
	# way. The alternative was rolling `rows` from a range that can always afford a
	# row, which buys an even split by making every maze with a lane across it
	# shorter than one with a lane along it -- a correlation between the axis and
	# the length of the section, which is a worse thing to have than a 60/40.
	var wide: bool = Hash.mix(salt + 0x717D) % 100 < MAZE_WIDE_PERCENT
	var wide_across: bool = Hash.mix(salt + 0x717E) % 2 == 0
	if wide:
		var can_across: bool = rows - 1 >= MAZE_MIN_ROWS
		var can_along: bool = cols - 1 >= 3
		if wide_across and not can_across:
			wide_across = false
		elif not wide_across and not can_along:
			wide_across = true
		# And if the axis it swapped TO cannot afford one either, there is no lane.
		# Unreachable at the 21 canvas, where a column is always affordable; it is
		# here so a narrower bridge degrades into an ordinary maze rather than into
		# a lattice with two columns in it.
		wide = can_across if wide_across else can_along
	if wide:
		if wide_across:
			rows -= 1
		else:
			cols -= 1

	# Entry deck, a wall row with the door, the lattice, the far wall row, then two
	# rows of deck to arrive on. Derived rather than picked so the two ends cannot
	# disagree with the lattice between them.
	#
	# TWO LENGTHS, AND THEY ARE DIFFERENT QUESTIONS. `compact` is the coordinate
	# frame the carve works in -- every cell, link and door below is a compact
	# coordinate -- and `length` is what the section really measures once a wide
	# lane has pushed everything past it over by one. Keeping them apart is the
	# whole reason the carve needed no changes at all: it never learns there is
	# such a thing as a wide lane.
	var compact: int = rows * 2 + 4
	var length: int = compact + (1 if wide and wide_across else 0)

	# WHICH LANE, IN COMPACT COORDINATES. -1 for "no wide lane on this axis", which
	# is what every mapping below tests.
	var wide_x: int = -1
	var wide_z: int = -1
	if wide:
		if wide_across:
			wide_z = 2 + 2 * (Hash.mix(salt + 0x717F) % rows)
		else:
			wide_x = 2 * (Hash.mix(salt + 0x7180) % cols)

	# THE COLUMN THE LATTICE DOES NOT USE, offered to either side. A lattice of
	# `cols` columns spans 2*cols-1 cells and a wide one spans 2*cols, so at the
	# 21 canvas a wide maze has exactly one column spare -- and always parking it
	# on the same side would make every wide maze lean the same way. Rolled ONLY
	# when there is a wide lane, so a maze without one lays out exactly where it
	# always did.
	var used: int = 2 * cols - 1 + (1 if wide_x >= 0 else 0)
	var x0: int = 0
	if wide_x >= 0 and width - used > 0:
		x0 = Hash.mix(salt + 0x7181) % (width - used + 1)
	var lay: Dictionary = {"wide_x": wide_x, "wide_z": wide_z, "x0": x0}

	var seg = GenUtil._blank("section_%d_maze" % index, width, length)
	var maze_tags: Array[String] = ["foot", "generated", "maze"]
	if wide:
		# TAGGED SO THE INTENT CAN BE CHECKED AGAINST THE ARTIFACT. Nothing in the
		# game reads it; test_segment_gen does, and a claim that the geometry
		# matches what the generator meant needs both halves to be readable.
		maze_tags.append("wide_across" if wide_across else "wide_along")
	seg.tags = maze_tags
	seg.no_dress = true

	# EVERYTHING IS WALL UNTIL SOMETHING CARVES IT. Building the solid and cutting
	# passages out of it is the only order that cannot leave a stray open cell: the
	# opposite -- start open, add walls -- has to be right everywhere at once.
	for z in range(1, length - 2):
		for x in width:
			seg.kinds[z][x] = GridConfig.Kind.WALL
			seg.heights[z][x] = MAZE_WALL_HEIGHT

	var open_cells: Dictionary = {}
	for j in rows:
		for i in cols:
			open_cells[Vector2i(2 * i, 2 + 2 * j)] = true

	# DEPTH-FIRST CARVE. A spanning tree over the lattice, so every cell is
	# reachable from every other before a single loop is added -- which is what
	# makes the braid below free to be as aggressive as it likes without any risk
	# of cutting the maze in two.
	var visited: Dictionary = {Vector2i(0, 0): true}
	var stack: Array = [Vector2i(0, 0)]
	var step: int = 0
	while not stack.is_empty():
		var cell: Vector2i = stack[stack.size() - 1]
		var options: Array = []
		for d in 4:
			var n: Vector2i = cell + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows:
				continue
			if not visited.has(n):
				options.append(n)
		if options.is_empty():
			stack.pop_back()
			continue
		step += 1
		var pick: Vector2i = options[Hash.mix(salt + step * 2749) % options.size()]
		open_cells[_maze_between(cell, pick)] = true
		visited[pick] = true
		stack.append(pick)

	# BRAID. Extra links between neighbours that are not yet linked, taken at
	# scattered positions rather than by walking the lattice in order -- an
	# in-order pass concentrates every loop in the first rows it visits.
	var extra: int = (cols * rows) / MAZE_BRAID
	for k in extra:
		var i: int = Hash.mix(salt + k * 7523) % cols
		var j: int = Hash.mix(salt + k * 8161) % rows
		var here := Vector2i(i, j)
		var dirs: Array = []
		for d in 4:
			var n: Vector2i = here + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows:
				continue
			if not open_cells.has(_maze_between(here, n)):
				dirs.append(n)
		if dirs.is_empty():
			continue
		open_cells[_maze_between(here, dirs[Hash.mix(salt + k * 6421) % dirs.size()])] = true

	# THEN OPEN THE DEAD ENDS THAT ARE LEFT, past the few kept for rewards. A dead
	# end with nothing in it is a wrong turn the player can see is a wrong turn,
	# which is a walk they take for no reason.
	var dead: Array = []
	for j in rows:
		for i in cols:
			if _maze_degree(open_cells, Vector2i(i, j)) == 1:
				dead.append(Vector2i(i, j))
	for n in dead.size():
		if n < MAZE_DEAD_ENDS:
			continue
		var here: Vector2i = dead[n]
		# Re-checked: opening one dead end can raise a neighbour's degree, so the
		# list goes stale as it is walked.
		if _maze_degree(open_cells, here) != 1:
			continue
		var shut: Array = []
		for d in 4:
			var nb: Vector2i = here + GridConfig.DIR_CELLS[d]
			if nb.x < 0 or nb.x >= cols or nb.y < 0 or nb.y >= rows:
				continue
			if not open_cells.has(_maze_between(here, nb)):
				shut.append(nb)
		if not shut.is_empty():
			open_cells[_maze_between(here, shut[Hash.mix(salt + n * 4133) % shut.size()])] = true

	# ONE DOOR EACH END. A full-width mouth would let the party fan out before the
	# maze had asked them anything; a single opening makes the entrance a PLACE,
	# and puts everybody in the same corridor for the first moment.
	var in_door: int = 2 * (Hash.mix(salt + 1811) % cols)
	var out_door: int = 2 * (Hash.mix(salt + 3181) % cols)
	# IN THE COMPACT FRAME, like every other cell here -- `_maze_at` puts the exit
	# door back on `length - 3` once a wide row has moved it.
	var doors: Dictionary = {
		Vector2i(in_door, 1): true,
		Vector2i(out_door, compact - 3): true,
	}
	for door in doors:
		open_cells[door] = true

	# LAY THE LATTICE OUT. Up to here every coordinate has been compact; this is
	# the only place that knows a wide lane exists.
	#
	# A DOOR IS NEVER WIDENED, even when the wide lane runs through it. "One door
	# each end" is a design decision with its own reasoning -- a single opening
	# makes the entrance a PLACE and puts the whole party in one corridor for the
	# first moment -- and it is worth more than the two cells it costs. Walking a
	# one-cell door into a two-cell lane reads correctly; it is the mouth of the
	# avenue.
	for cell in open_cells:
		var here: Array = [_maze_at(cell, lay)] if doors.has(cell) \
			else _maze_cells(cell, lay)
		for at in here:
			seg.kinds[at.y][at.x] = GridConfig.Kind.DECK
			seg.heights[at.y][at.x] = 0

	# THE REWARDS, in whichever dead ends survived.
	#
	# A HAT FIRST, AND AT LEAST ONE ALWAYS. Hats are the score, so the hat is what
	# makes a maze worth entering rather than a delay between the sections that
	# have something in them -- every other section pays in hats and this one has
	# no hazard to drop them. The heart comes second because it is the reward that
	# only matters on a bad run, and a maze with nothing but hearts in it is a maze
	# a healthy party walks straight through.
	var kept: Array = []
	for j in rows:
		for i in cols:
			if _maze_degree(open_cells, Vector2i(i, j)) == 1:
				kept.append(Vector2i(i, j))
	for n in mini(kept.size(), MAZE_DEAD_ENDS):
		var at: Vector2i = _maze_at(_maze_lattice(kept[n]), lay)
		seg.contents[at.y][at.x] = \
			GridConfig.Content.HEART if n == 1 else GridConfig.Content.HAT

	_maze_traps(seg, open_cells, cols, rows, salt,
		Vector2i((in_door) / 2, 0), Vector2i((out_door) / 2, rows - 1), kept, lay)

	# AND IF THE BRAID LEFT NO DEAD END AT ALL, the hat goes at the DEEPEST point
	# instead -- the cell furthest from the entrance by actual walking distance
	# through the maze, not by straight line.
	#
	# IT DOES NOT FIRE AT THE CURRENT TUNING, and that is written down rather than
	# assumed: A/B'd 2026-08-16 by deleting this branch, and 250 sections stayed
	# green -- no maze at MAZE_BRAID = 6 came out with zero dead ends. So it is
	# insurance against the dial moving, not a path the sweep exercises, and
	# `_maze_deepest` is unit-tested directly in test_segment_gen for that reason.
	# An untested branch that only runs after somebody retunes a constant is the
	# branch most likely to be wrong on the day it matters.
	if kept.is_empty():
		var deep: Vector2i = _maze_deepest(open_cells, cols, rows,
			Vector2i((in_door - 1) / 2, 0))
		var deep_at: Vector2i = _maze_at(_maze_lattice(deep), lay)
		seg.contents[deep_at.y][deep_at.x] = GridConfig.Content.HAT
	# A MAZE JOINS THE RUN LIKE ANY OTHER SECTION. Its lattice keeps the full
	# canvas -- a maze is a different kind of place and its outer columns are WALL
	# rather than edge -- but the rows it is entered and left by are the baseline,
	# so the mouth is the same width as the bridge that leads to it.
	GenUtil._baseline_end_rows(seg)
	return seg


# The lattice cell furthest from `from` by walking distance. A breadth-first walk
# over the carved links, which is the only measure that means anything in a maze:
# the cell across the wall from the entrance may be a two-minute detour away.
static func _maze_deepest(open_cells: Dictionary, cols: int, rows: int,
		from: Vector2i) -> Vector2i:
	var seen: Dictionary = {from: true}
	var queue: Array = [from]
	var last: Vector2i = from
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		last = cell
		for d in 4:
			var n: Vector2i = cell + GridConfig.DIR_CELLS[d]
			if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows or seen.has(n):
				continue
			if not open_cells.has(_maze_between(cell, n)):
				continue
			seen[n] = true
			queue.append(n)
	return last


# Traps, on corridor cells only, spaced apart and never on a door cell or a
# reward. `entry` and `exit` are lattice coordinates.
static func _maze_traps(seg, open_cells: Dictionary, cols: int, rows: int,
		salt: int, entry: Vector2i, exit_cell: Vector2i, rewards: Array,
		lay: Dictionary) -> void:
	var taken: Dictionary = {entry: true, exit_cell: true}
	for r in rewards:
		taken[r] = true

	# NOT ON TOP OF EACH OTHER, and not next to each other either. Spikes beside a
	# timed floor is a hazard aimed at somebody standing still waiting for the
	# floor to come back -- the same complaint that got hazards banned from beside
	# a lift, arriving by a different route.
	var placed: Array = []
	var wanted: Array = []
	for _t in MAZE_TIMED:
		wanted.append(GridConfig.Content.TIMED)
	for _v in MAZE_SPIKES:
		wanted.append(GridConfig.Content.SPIKES)

	for n in wanted.size():
		var kind: int = int(wanted[n])
		for attempt in 24:
			var i: int = Hash.mix(salt + n * 3701 + attempt * 149) % cols
			var j: int = Hash.mix(salt + n * 6229 + attempt * 271) % rows
			var here := Vector2i(i, j)
			if taken.has(here):
				continue
			var near := false
			for other in placed:
				if absi(int(other.x) - i) + absi(int(other.y) - j) <= 1:
					near = true
					break
			if near:
				continue
			# ON THE FIRST OF THE PAIR when the cell is in a wide lane, which
			# leaves the other half clear. That is the wide lane paying for itself:
			# a spike in a one-cell corridor is a toll you cannot refuse, and the
			# same spike in a two-cell one is a thing to walk around.
			var at: Vector2i = _maze_at(_maze_lattice(here), lay)
			seg.contents[at.y][at.x] = kind
			taken[here] = true
			placed.append(here)
			break


# --- Laying the lattice out ---------------------------------------------------
#
# Three functions, and they are the ONLY code that knows a lane can be two cells
# wide. Everything above them works in the compact frame where a lattice cell
# (i, j) is the grid cell (2i, 2 + 2j) and the cell between two neighbours is the
# wall that separates them.

# A lattice cell in the compact frame.
static func _maze_lattice(cell: Vector2i) -> Vector2i:
	return Vector2i(2 * cell.x, 2 + 2 * cell.y)


# Compact -> laid out. Everything past a wide lane moves over by one, and the
# whole lattice moves over by the spare column the wide one did not take.
static func _maze_at(cell: Vector2i, lay: Dictionary) -> Vector2i:
	var x: int = int(cell.x) + int(lay["x0"])
	if int(lay["wide_x"]) >= 0 and int(cell.x) > int(lay["wide_x"]):
		x += 1
	var z: int = int(cell.y)
	if int(lay["wide_z"]) >= 0 and int(cell.y) > int(lay["wide_z"]):
		z += 1
	return Vector2i(x, z)


# The one or two cells a compact cell becomes. TWO for anything in the wide lane
# -- its cells AND the links between them, which is what makes the lane a lane
# rather than a row of wider rooms.
#
# Only one axis is ever wide, so this returns at most two cells; a maze wide both
# ways would need the diagonal as well, and the roll above does not produce one.
static func _maze_cells(cell: Vector2i, lay: Dictionary) -> Array:
	var at: Vector2i = _maze_at(cell, lay)
	var out: Array = [at]
	if int(lay["wide_x"]) >= 0 and int(cell.x) == int(lay["wide_x"]):
		out.append(at + Vector2i(1, 0))
	elif int(lay["wide_z"]) >= 0 and int(cell.y) == int(lay["wide_z"]):
		out.append(at + Vector2i(0, 1))
	return out


# The grid cell between two lattice neighbours -- the wall that separates them,
# and the single cell that carving a link writes.
static func _maze_between(a: Vector2i, b: Vector2i) -> Vector2i:
	return Vector2i(a.x + b.x, 2 + a.y + b.y)


# How many of a lattice cell's four walls have been carved.
static func _maze_degree(open_cells: Dictionary, cell: Vector2i) -> int:
	var n: int = 0
	for d in 4:
		if open_cells.has(_maze_between(cell, cell + GridConfig.DIR_CELLS[d])):
			n += 1
	return n
