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
	var seen := {}
	var queue: Array = []
	for x in seg.width:
		if seg.is_solid(x, 0):
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

static func _can_step(seg, from: Vector2i, to: Vector2i, max_rise: int) -> bool:
	var rise: int = seg.height_at(to.x, to.y) - seg.height_at(from.x, from.y)
	if rise <= 0:
		return true   # falling or level is always allowed
	# A ladder or a bouncer gets you up regardless of how far.
	if seg.content_at(to.x, to.y) in GridConfig.ASCENDER_CONTENTS:
		return true
	return rise <= max_rise

static func _exit_reached(seg, seen: Dictionary) -> bool:
	for x in seg.width:
		if seg.is_solid(x, seg.length - 1) and seen.has(Vector2i(x, seg.length - 1)):
			return true
	return false

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
