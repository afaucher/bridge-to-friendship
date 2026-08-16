extends RefCounted

# Checks a parsed segment for the mistakes a text format makes easy and a
# playtest makes expensive.
#
# THE ASCENDER RULES ARE THE POINT. A layer with no way up is a dead run, and a
# layer only a cooperating pair can pass strands a lone player permanently --
# which drop-in makes a real case, not a hypothetical, since the party can be one
# person at any moment. See design_ideas/bridge_grid.md.
#
# Both rules fall out of running the same reachability flood TWICE with different
# movement budgets: once with what one player can do unaided, once with what a
# shove or a rope adds. Exit unreachable under BOTH means there is no way up at
# all; reachable under assisted but not solo means a lone player is stranded.
# Expressing it this way means the validator asks exactly the question the design
# asks, rather than enumerating ascender types and hoping the list stays complete.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# What a player can climb unaided: a single height unit is a step up. Anything
# more needs an ascender, a ramp shallow enough to walk, or help.
const SOLO_RISE := 1

# What a shove up a steep ramp or a rope from above is worth. Not a physics
# result -- a design statement about how much cooperation buys.
const ASSISTED_RISE := 4

# LADDERS AND BOUNCERS ARE AUTHORABLE AND NOT YET CLIMBABLE.
#
# `GridConfig.ASCENDER_CONTENTS` has listed both since M2 and the flood has
# counted them as a way up ever since -- but no climb mechanic exists.
# playtest_bridge's own header says so: "the glyph validates and the loader
# collects it, but there is no climb mechanic, so today it is a 2 m wall".
#
# Which means the validator would certify a segment whose only route is a ladder,
# and the party would walk up to it and stop. Turned off here rather than left as
# a comment somebody has to remember, and it is ONE LINE to flip on the day M17
# phase 6 builds the climb.
const LADDERS_CLIMBABLE := false

static func validate(seg) -> Array:
	var problems: Array[String] = []
	if not seg.is_valid():
		return seg.errors.duplicate()

	var solo := _flood(seg, SOLO_RISE)
	var assisted := _flood(seg, ASSISTED_RISE)

	if not _exit_reached(seg, assisted):
		problems.append(
			"the exit row (z = %d) cannot be reached from the entry row even with help: there is no way up"
				% (seg.length - 1))
	elif not _exit_reached(seg, solo):
		problems.append(
			"the exit row can only be reached with help -- a solo player is stranded. Add a ladder, a bouncer, or a shallower ramp.")

	_check_orphans(seg, assisted, problems)
	_check_content_placement(seg, problems)
	_check_gates(seg, problems)
	return problems

# A ROUND BOUNDARY MUST BE UNCROSSABLE EXCEPT BY CROSSING IT (M16).
#
# Every rule downstream -- the barrier, "is everyone over", who lived through the
# round -- assumes a player cannot get past the strip without standing on it. A
# row with one cell of ordinary deck in it is a row players walk around, and
# every one of those rules then fails somewhere far from the cause: the barrier
# opens with somebody still behind it, or a player who crossed is scored as
# having been left behind.
#
# So it is refused at AUTHORING TIME, where the message can name the row. This is
# the cheapest place in the entire milestone to catch it, and the only place
# where the fix is obvious to the person who caused it.
static func _check_gates(seg, problems: Array) -> void:
	for z in seg.length:
		var marked := 0
		for x in seg.width:
			if seg.content_at(x, z) == GridConfig.Content.GATE:
				marked += 1
		if marked == 0:
			continue
		if marked < seg.width:
			problems.append(
				("the round boundary at z = %d covers %d of %d cells -- a strip with a "
					% [z, marked, seg.width])
				+ "gap is a strip players walk around, and every rule about crossing it "
				+ "then fails somewhere else")
		# A gate cell on a ramp is a boundary on a slope: the strip is a LINE the
		# party stands on together, and a sloped one has them at four heights.
		for x in seg.width:
			if seg.content_at(x, z) != GridConfig.Content.GATE:
				continue
			if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				problems.append(
					"the round boundary at (%d, %d) sits on a ramp -- a boundary is somewhere the party STANDS"
						% [x, z])
				break

# Flood from every solid cell in the entry row, stepping only where a player with
# the given rise budget could go. Returns the set of reachable cells.
static func _flood(seg, max_rise: int) -> Dictionary:
	return _flood_from(seg, solid_columns(seg, 0), max_rise)

# The same flood from a CHOSEN set of entry columns, which is what a run needs: a
# party arriving from the previous segment does not get to start from the whole
# entry row, only from the cells that were solid on both sides of the join.
static func _flood_from(seg, entry_columns: Array, max_rise: int) -> Dictionary:
	var seen := {}
	var queue: Array = []
	for col in entry_columns:
		var x: int = int(col)
		if x >= 0 and x < seg.width and seg.is_solid(x, 0):
			var c := Vector2i(x, 0)
			seen[c] = true
			queue.append(c)

	while queue.size() > 0:
		var cell: Vector2i = queue.pop_front()
		for dir in 4:
			var step: Vector2i = GridConfig.DIR_CELLS[dir]
			var next := Vector2i(cell.x + step.x, cell.y + step.y)
			if seen.has(next) or not seg.in_bounds(next.x, next.y):
				continue
			if not seg.is_solid(next.x, next.y) or seg.has_wall(cell.x, cell.y, dir):
				continue
			if not _can_step(seg, cell, next, max_rise):
				continue
			seen[next] = true
			queue.append(next)
	return seen

# THERE IS NO STEP-UP IN THIS GAME, and the flood believed there was.
#
# Measured 2026-08-16 with a body walking full stick into a ONE UNIT deck step
# for two and a half seconds: it stopped at y 1.45 against a step top of y 1.76
# and never got up. `move_and_slide` does not mantle and nothing here implements
# it, so ANY vertical rise between two deck cells is a wall, whatever the rise
# budget says.
#
# The budget was therefore modelling a movement the player does not have, and any
# segment whose only route crossed a bare one-unit step VALIDATED AND WAS
# IMPASSABLE. That is the worst failure a rejection oracle can have: it does not
# report a problem, it certifies a broken thing.
#
# So a rise is allowed only where something exists to climb:
#   A RAMP, and then the budget is a SLOPE limit -- one unit per cell is 27
#   degrees and walkable, two is 45 and needs a shove, which is exactly what
#   SOLO_RISE and ASSISTED_RISE have always meant on a ramp.
#   AN ASCENDER, once one is actually implemented. See below.
static func _can_step(seg, from: Vector2i, to: Vector2i, max_rise: int) -> bool:
	var rise: int = seg.height_at(to.x, to.y) - seg.height_at(from.x, from.y)
	if rise <= 0:
		return true   # falling or level is always allowed
	if LADDERS_CLIMBABLE and seg.content_at(to.x, to.y) in GridConfig.ASCENDER_CONTENTS:
		return true
	# A BARE STEP UP IS A WALL. No mantle, no step-up, no exceptions.
	if seg.kind_at(to.x, to.y) != GridConfig.Kind.RAMP:
		return false
	return rise <= max_rise

static func _exit_reached(seg, seen: Dictionary) -> bool:
	for x in seg.width:
		if seg.is_solid(x, seg.length - 1) and seen.has(Vector2i(x, seg.length - 1)):
			return true
	return false

# --- The join contract (M17 phase 0) ------------------------------------------

# Which columns of `row` are solid.
static func solid_columns(seg, row: int) -> Array:
	var out: Array = []
	for x in seg.width:
		if seg.is_solid(x, row):
			out.append(x)
	return out

# Which columns of the EXIT row a party can stand on, having entered on
# `entry_columns`. This is the whole contract in one function: it is what a
# segment hands to the next one.
static func reachable_exit_columns(seg, entry_columns: Array, max_rise: int) -> Array:
	var seen: Dictionary = _flood_from(seg, entry_columns, max_rise)
	var last: int = seg.length - 1
	var out: Array = []
	for x in seg.width:
		if seg.is_solid(x, last) and seen.has(Vector2i(x, last)):
			out.append(x)
	return out

# WALK A WHOLE RUN, CARRYING THE SET OF CELLS THE PARTY CAN OCCUPY.
#
# `SegmentValidator.validate` checks a segment ALONE, and until 2026-08-16 that
# was the only check there was -- so nothing anywhere asked whether a run's
# segments CONNECT. Segment A can exit solid only on the left while B enters
# solid only on the right, and the party stops at a seam no authoring pass looked
# at. It worked by luck: the pool segments are near-solid across their full width
# at both ends. Thin paths and variable width are both requests to spend that
# luck, and M16 turned one join per round into six.
#
# WHY A RUN PASS AND NOT A PER-SEGMENT PROPERTY. The plan hoped this could be
# induction: prove something per segment, check overlaps, done. It cannot, and
# the reason is the feature that made dual path cheap. A segment that splits into
# lanes cannot promise "from ANY entry cell you reach EVERY exit cell" -- entering
# left means exiting left -- so what a segment offers depends on where you came
# in. Carrying the set forward is the exact answer and costs one flood per
# segment, which is what validating them individually already costs.
static func validate_run(segments: Array, max_rise: int) -> Array:
	var problems: Array[String] = []
	if segments.is_empty():
		return problems

	var occupiable: Array = solid_columns(segments[0], 0)
	if occupiable.is_empty():
		problems.append("segment 0 ('%s') has no solid cell to start on"
			% segments[0].name)
		return problems

	for i in segments.size():
		var seg = segments[i]
		# THE JOIN. Where the party could be, intersected with where this segment
		# can be entered.
		var entered: Array = []
		for col in occupiable:
			if int(col) < seg.width and seg.is_solid(int(col), 0):
				entered.append(int(col))
		if entered.is_empty():
			problems.append(
				("no way into segment %d ('%s'): the party can be at columns %s and its "
					% [i, seg.name, str(occupiable)])
				+ "entry row is solid at %s" % str(solid_columns(seg, 0)))
			return problems

		occupiable = reachable_exit_columns(seg, entered, max_rise)
		if occupiable.is_empty():
			problems.append(
				("segment %d ('%s') cannot be crossed: entered at columns %s, and no cell "
					% [i, seg.name, str(entered)])
				+ "of its exit row is reachable from there")
			return problems
	return problems

# Solid cells nothing can ever touch. Usually a mistake; occasionally decoration,
# in which case the author should have drawn a hole.
static func _check_orphans(seg, assisted: Dictionary, problems: Array) -> void:
	var orphans := 0
	for z in seg.length:
		for x in seg.width:
			if seg.is_solid(x, z) and not assisted.has(Vector2i(x, z)):
				orphans += 1
	if orphans > 0:
		problems.append("%d solid cells are unreachable even with help (marooned deck)" % orphans)

static func _check_content_placement(seg, problems: Array) -> void:
	var spawns := 0
	for z in seg.length:
		for x in seg.width:
			var content: int = seg.content_at(x, z)
			if content == GridConfig.Content.NONE:
				continue
			if content == GridConfig.Content.SPAWN:
				spawns += 1
			if not seg.is_solid(x, z):
				problems.append("content at (%d, %d) sits on a hole" % [x, z])
			if content == GridConfig.Content.PILLAR and seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				# A stone on a slope has nowhere legible to be pushed to, and the
				# one-cell push rule stops meaning anything.
				problems.append("a pillar at (%d, %d) sits on a ramp" % [x, z])
			if content == GridConfig.Content.HAT and seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				# A hat is a rigid body that lands and settles. On a slope it
				# simply rolls off, so an authored one there is a hat placed
				# somewhere else -- and where it ends up depends on the slope
				# rather than on the author.
				problems.append("a hat at (%d, %d) sits on a ramp and would roll off" % [x, z])
			if content == GridConfig.Content.PICKUP and seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				# Identical to the hat rule, and worth stating separately rather
				# than folding the two together: a special is a rigid body that
				# lands and settles, so on a slope it slides off and the author has
				# placed it wherever the slope decided. It matters more here --
				# there is one weapon, not a scattering of hats.
				problems.append("a special at (%d, %d) sits on a ramp and would slide off" % [x, z])
			if content == GridConfig.Content.MOUND and seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				# A rusher rises straight up out of the deck over a fixed second.
				# On a slope that animation emerges through the hillside, and the
				# telegraph -- the entire fairness argument for this hazard -- is
				# played somewhere the player cannot see it.
				problems.append("a mound at (%d, %d) sits on a ramp" % [x, z])
	if spawns > 0 and spawns < 4:
		problems.append("only %d spawn cells: a full party of 4 needs 4 (or none, to use the default ring)" % spawns)
