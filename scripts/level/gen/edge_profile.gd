extends RefCounted

# THE BRIDGE'S EDGES (M22): how far each side is set back, row by row, as
# waypoints joined by straight ramps, pinned at both ends. Section-only.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")

# --- The edge profile (M22) ---------------------------------------------------

# HOW FAR AN EDGE MAY MOVE IN ONE ROW.
#
# A cap, not a style choice. Deck thickness is derived from a cell's EIGHT
# neighbours (SegmentBuilder.cell_underside), so an edge that jumps several
# columns in a row leaves solid cells whose newly-exposed underside has nothing
# beneath it -- which is the tapered-shape trap that already cost this project a
# ramp with a knife edge over a DECK_THICKNESS-deep void. One column per row also
# happens to be the discipline the HEIGHT profile already keeps, so a bridge
# narrows at the rate it climbs and reads as one material.
const INSET_RATE := 1


# ROWS HELD AT FULL WIDTH AT EACH END. The entry and exit rows join the
# neighbouring segment, and the join contract (M17) plus the round boundary bands
# (M16) both want them solid across. Two rather than one so the taper has
# somewhere to finish rather than ending abruptly on the join itself.
const INSET_END_ROWS := 2


# HOW MANY ROWS ONE COLUMN OF WIDTH CHANGE TAKES.
#
# INSET_RATE is the correctness FLOOR -- never steeper than a column per row.
# This is the FEEL, and the two are different questions. Built at the floor, a
# three-column setback completes in three rows: six metres, which a player crosses
# in a second and reads as the bridge snapping rather than tapering. Spread over
# two to six rows per column the same setback takes 12 to 36 m, which is a shape
# you watch arrive.
#
# A RANGE, AND ROLLED PER EDGE. A fixed stride would make every transition in the
# game the same slope, which is the shape of the problem this milestone started
# with -- one number, applied everywhere, so nothing varies.
const INSET_STEP_ROWS_MIN := 2

const INSET_STEP_ROWS_MAX := 6


# The deepest either edge may ever be cut, as a pure function of the width.
#
# PURE ON PURPOSE. `safe` -- the columns a ramp or a lift may occupy -- needs this
# bound BEFORE any profile exists, which is what lets the profile be built last,
# with the lift rows it must pass through already known. Bounded so a section
# never closes to a thread: at a 21 canvas this is 6, so the narrowest deck is
# 21 - 2*6 = 9 cells and the widest is the full 21.
static func _edge_inset_bound(width: int) -> int:
	var base: int = mini(GridConfig.BASELINE_INSET, maxi(0, width / 2 - 2))
	return base + maxi(1, width / 7)


# One edge's inset, per row: how many columns of THIS side are cut away.
#
# WAYPOINTS AND RAMPS, not events-then-cap. The first version rolled flat setback
# BANDS and let a two-pass minimum cone discover the taper, which meant every
# transition came out at the steepest slope the rules allow -- the cone's whole
# job is to find the largest profile that fits, so it always tapers as late and
# as hard as it can. Correct, and it reads as the bridge snapping.
#
# So the shape is stated instead of derived: a handful of waypoints, each a row
# and an inset, joined by straight ramps. The gradient is then whatever the
# spacing gives, and the spacing is what `stride` controls.
#
# IT MOVES IN BOTH DIRECTIONS. A waypoint deeper than BASELINE_INSET is a pinch,
# shallower is the deck opening out past its usual width, and both are the same
# arithmetic. Before the canvas grew, only the first was expressible at all.
static func _edge_profile(width: int, length: int, salt: int) -> Array:
	var base: int = mini(GridConfig.BASELINE_INSET, maxi(0, width / 2 - 2))
	var deepest: int = _edge_inset_bound(width)
	var stride: int = INSET_STEP_ROWS_MIN \
		+ Hash.mix(salt + 811) % maxi(1, INSET_STEP_ROWS_MAX - INSET_STEP_ROWS_MIN + 1)

	# --- The waypoints, in row order ------------------------------------------
	#
	# Always opening and closing at the baseline: that is what makes every segment
	# boundary in the game the same familiar width, and it is what an authored
	# file (padded to the baseline) joins onto.
	var at: Array = [0]
	var to: Array = [base]

	# ONE OR TWO ROLLED EVENTS PER SIDE. Zero is a straight section at the
	# baseline, which is still wanted and arrives on its own when a roll lands
	# somewhere the ordering below discards.
	var marks: Array = []
	var events: int = 1 + Hash.mix(salt) % 2
	for e in events:
		marks.append(INSET_END_ROWS
			+ Hash.mix(salt + e * 7919) % maxi(1, length - 2 * INSET_END_ROWS))
	marks.sort()

	for row in marks:
		var r: int = clampi(int(row), INSET_END_ROWS, length - 1 - INSET_END_ROWS)
		# STRICTLY INCREASING, or the interpolation below walks backwards over rows
		# it has already written. Two events that rolled the same row is the
		# ordinary case, not an edge one.
		if r <= int(at[at.size() - 1]):
			continue
		at.append(r)
		to.append(Hash.mix(salt + r * 15485863) % (deepest + 1))
	at.append(length - 1)
	to.append(base)

	# --- The gradient is the constraint, so the WAYPOINTS give way -------------
	#
	# Each interior waypoint is pulled toward its neighbours until every leg is
	# walkable at one column per `stride` rows: forward so it is reachable from
	# the one before, backward so the profile can still get home to the baseline.
	# A section that cannot afford the setback it rolled gets a smaller one -- a
	# bridge that narrows less than intended is a shape, and one that narrows
	# faster than the gradient is the snap this whole rewrite exists to remove.
	for i in range(1, at.size() - 1):
		var back: int = (int(at[i]) - int(at[i - 1])) / stride
		to[i] = clampi(int(to[i]), int(to[i - 1]) - back, int(to[i - 1]) + back)
	for i in range(at.size() - 2, 0, -1):
		var fwd: int = (int(at[i + 1]) - int(at[i])) / stride
		to[i] = clampi(int(to[i]), int(to[i + 1]) - fwd, int(to[i + 1]) + fwd)

	# --- Joined by straight ramps ----------------------------------------------
	var out: Array = []
	out.resize(length)
	for i in range(at.size() - 1):
		var z0: int = int(at[i])
		var z1: int = int(at[i + 1])
		var v0: int = int(to[i])
		var v1: int = int(to[i + 1])
		var gap: int = maxi(1, z1 - z0)
		for z in range(z0, z1 + 1):
			out[z] = int(round(lerpf(float(v0), float(v1),
				float(z - z0) / float(gap))))

	# --- The ends, held flat ---------------------------------------------------
	for i in mini(INSET_END_ROWS, length):
		out[i] = base
		out[length - 1 - i] = base
	# Stride is a preference and the waypoints may not have left room for it, so
	# the ends get the same outward clamp they always did -- which is also what
	# repairs the two rows just forced flat.
	return _pin_ends(out, base)


# THE ENDS ARE A HARD CONSTRAINT AND THE CONE IS A SOFT ONE, so the cone cannot
# be the last word.
#
# `_cone` takes a MINIMUM, which means a widening event near either end reaches
# back and drags the pinned end open with it -- a target of 0 two rows in pulls
# row 0 down to 2 whatever it was pinned to. Forcing the end back afterwards then
# leaves a step at row 1, which is precisely the jump INSET_RATE exists to
# forbid. Measured before this existed: 19 rate breaks over 60 sections, and the
# diagnostic said `lift?false end?true` for every single one.
#
# So the ends are re-pinned and the rows next to them are dragged into line
# instead: forward from the pinned start (which makes the whole array Lipschitz),
# then pin the far end and walk backward (which repairs the far end, and only
# perturbs its own neighbourhood because the forward pass already made everything
# else consistent).
static func _pin_ends(profile: Array, base: int) -> Array:
	var out: Array = profile.duplicate()
	var n: int = out.size()
	if n < 2:
		return out
	for i in mini(INSET_END_ROWS, n):
		out[i] = base
	for z in range(1, n):
		out[z] = clampi(int(out[z]),
			int(out[z - 1]) - INSET_RATE, int(out[z - 1]) + INSET_RATE)
	for i in mini(INSET_END_ROWS, n):
		out[n - 1 - i] = base
	for z in range(n - 2, -1, -1):
		out[z] = clampi(int(out[z]),
			int(out[z + 1]) - INSET_RATE, int(out[z + 1]) + INSET_RATE)
	return out
