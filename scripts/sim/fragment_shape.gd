extends RefCounted

# CUTTING A BODY INTO PIECES THAT LOOK LIKE THE BODY.
#
# The death animation replaces an enemy with the fragments of itself: a pile that
# is, on the frame it appears, INDISTINGUISHABLE from the thing that was standing
# there, and which comes apart when something disturbs it. See
# design_ideas/death_fragments.md.
#
# THE PIECES TILE THE ORIGINAL EXACTLY, and that is the whole design rather than a
# nice property. If the union of the fragments were merely APPROXIMATELY the body
# then the moment of death would be a visible pop -- a silhouette changing shape
# on the one frame the player is looking straight at it -- which is the thing this
# feature exists to remove. Everything below is arranged to make the tiling exact
# and to make it CHECKABLE (see test_fragment_shape.gd).
#
# --- ONE SHAPE MODEL FOR EVERY CHARACTER -------------------------------------
#
# A rusher is a tapered cylinder, a zombie and a skirmisher are capsules, a player
# is a cylinder. Written as four cases that would be four sets of bugs; written as
# ONE case they are a SOLID OF REVOLUTION -- a profile r(y) spun about the Y axis
# -- and this file never learns that rushers exist. Adding a fifth character costs
# nothing here as long as its body is a lathe.
#
# AND THE PROFILE IS READ OFF THE MESH THE GAME ACTUALLY DRAWS (profile_from_mesh),
# never restated as constants. CLAUDE.md has an entry about the ladder whose face
# was computed twice, in two places, from two subtly different arithmetics -- they
# agreed on every case anybody had until a tie showed up. A corpse whose radius is
# a copy of the scene's radius is that bug waiting for the day somebody widens a
# zombie. There is one record of how big an enemy is, and it is the .tscn.
#
# --- A FRAGMENT IS A CELL IN LATHE SPACE -------------------------------------
#
# Not a chunk of triangles: a box in (y, theta, rho), where rho is a FRACTION of
# the local radius r(y) rather than a distance. That last part is what lets the
# same cell description work on a taper -- a cell at p 0.5..1.0 is the outer half
# of the body at every height, so the pieces of a cone taper with the cone instead
# of being cut by a cylinder that does not fit it.
#
# Cells come from recursive binary subdivision, so they are disjoint and cover the
# whole solid BY CONSTRUCTION. The test asserts it anyway, because "by
# construction" is an argument and a point sample is a measurement.
#
# --- WHICH AXIS TO CUT, AND WHERE --------------------------------------------
#
# WHICH: the one with the largest PHYSICAL extent -- height, arc length, or radial
# thickness, all in metres, measured at the cell's middle. That single rule is
# what produces pieces that resemble the whole. Always cutting the longest side
# drives every cell toward the same proportions at the same time as it drives them
# toward the same size; cutting a fixed axis order instead gives long splinters,
# and cutting randomly gives a mess.
#
# WHERE: at EQUAL VOLUME, which is not the midpoint on two of the three axes.
#
#   angle   the midpoint. Volume is linear in theta, so here the naive answer is
#           also the right one.
#   radius  sqrt((p0^2 + p1^2) / 2), the equal-AREA annulus split. This is the one
#           place the obvious answer is visibly wrong: halving a disc at p = 0.5
#           gives an inner core of a QUARTER the volume and an outer ring of three
#           quarters. A death animation made of pieces that differ four-fold does
#           not read as a body coming apart, it reads as a body losing a crumb.
#   height  wherever the integral of r^2 dy is halved. On a cylinder that is the
#           midpoint; on a rusher's taper it is well below it, and on a capsule's
#           end cap it is well inside it.
#
# --- HOW MANY, AND WHY GREEDY --------------------------------------------------
#
# Splitting until every piece is under a target size gives a count nobody chose
# and a spread up to 2x. Repeatedly splitting the LARGEST piece until there are
# exactly N gives the count that was asked for and the tightest spread available,
# which is what "until all the pieces wind up the same size" actually means. N is
# small enough (tens) that finding the largest by walking the list is free.
#
# NO RANDOMNESS ANYWHERE IN HERE. Two machines handed the same mesh and the same
# count cut it identically, so the only thing a corpse has to be told over the
# wire is where it is -- and a test can assert an exact tiling rather than a
# distribution. The scatter is where the randomness lives, and it is seeded.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# How finely the profile is sampled. The table IS the shape as far as everything
# downstream is concerned -- volumes, splits and the drawn mesh all read it -- so
# the tiling is exact against the table whatever this number is, and this number
# only decides how close the table is to the ideal capsule or cone. At 256 a
# 0.45 m capsule cap is within about a tenth of a percent by volume, which is
# three orders of magnitude finer than anything anyone can see.
const SAMPLES := 256

# HOW MANY ANGULAR STEPS THE WHOLE BODY IS DRAWN ON -- a GLOBAL grid, not a
# per-fragment target edge length, and that is the entire point.
#
# A POLYGON INSCRIBED IN A CIRCLE SITS INSIDE IT, BY AN AMOUNT THAT DEPENDS ON
# HOW MANY SIDES IT HAS. The first version chose each cell's segment count from
# its own arc length in metres, so a wide cell and a narrow one over the same
# span used different counts, inset their chords by different amounts, and did
# not meet: the intact rusher came out with horizontal LEDGES stepping down its
# cone, and the pile stopped being the body it replaced. Nothing about the tiling
# was wrong -- the cells were exact, and every assertion in test_fragment_shape
# passed, because the fault was in how the exact cells were DRAWN.
#
# Every angular split is a midpoint of [0, TAU], so every cell boundary is a
# multiple of TAU / 2^k. At 32 -- itself a power of two -- every cell's samples
# land on the same global grid as its neighbours' and the seams close exactly.
# KEEP IT A POWER OF TWO for that reason.
const ANGLE_STEPS := 32

# Vertical tessellation, as a target edge length in metres. This one CAN be
# per-cell in a way the angular one cannot: cells stacked in y share their
# boundary exactly and both evaluate the profile there, and two cells in the SAME
# y band get the same count from the same arithmetic.
#
# 0.08 rather than 0.16 because of the capsule CAPS, the only place the profile
# curves in y. At 0.16 a cap fragment enclosed 86% of the volume of the cell it
# was cut from -- not a fault, just a chord cutting a corner, but a visible facet
# on the one part of a zombie that is round.
const MESH_RISE := 0.08

# Below this a cell is not worth drawing -- a capsule's pole cell can come out as
# a sliver with no volume in it, and a RigidBody3D with a degenerate shape is a
# solver problem rather than a piece of debris.
const MIN_CELL_VOLUME := 1.0e-6


# r(y) for one body, sampled. Built by profile_from_mesh; nothing else should
# construct one, because the point of this class is that there is a single path
# from "what the game draws" to "what the corpse is made of".
class Profile extends RefCounted:
	var y0: float = 0.0
	var y1: float = 0.0
	var radii := PackedFloat32Array()
	# Cumulative integral of r^2 dy from y0. Everything about volume comes from
	# here, so a cell's volume and the whole body's volume can never be computed
	# by two different methods that drift apart.
	var _cum := PackedFloat32Array()

	func _init(low: float, high: float, samples: PackedFloat32Array) -> void:
		y0 = low
		y1 = high
		radii = samples
		var n: int = radii.size() - 1
		var step: float = (y1 - y0) / float(n)
		_cum.resize(n + 1)
		_cum[0] = 0.0
		for i in range(n):
			var a: float = radii[i] * radii[i]
			var b: float = radii[i + 1] * radii[i + 1]
			_cum[i + 1] = _cum[i] + 0.5 * (a + b) * step

	func height() -> float:
		return y1 - y0

	func radius_at(y: float) -> float:
		var n: int = radii.size() - 1
		var t: float = clampf((y - y0) / (y1 - y0), 0.0, 1.0) * float(n)
		var i: int = clampi(int(t), 0, n - 1)
		return lerpf(radii[i], radii[i + 1], t - float(i))

	func max_radius() -> float:
		var best: float = 0.0
		for r in radii:
			best = maxf(best, r)
		return best

	# The volume of the FULL solid of revolution between two heights: pi * the
	# integral of r^2 dy. A cell takes its share of this.
	func volume_between(a: float, b: float) -> float:
		return PI * (_cum_at(b) - _cum_at(a))

	func volume() -> float:
		return volume_between(y0, y1)

	func _cum_at(y: float) -> float:
		var n: int = _cum.size() - 1
		var t: float = clampf((y - y0) / (y1 - y0), 0.0, 1.0) * float(n)
		var i: int = clampi(int(t), 0, n - 1)
		return lerpf(_cum[i], _cum[i + 1], t - float(i))

	# The height that divides [a, b] into two equal volumes. Bisection rather than
	# a closed form because the closed form is different for every profile shape
	# and this one is correct for all of them, including the piecewise table a
	# capsule turns into. 32 halvings of a 2 m body land within a nanometre.
	func split_y(a: float, b: float) -> float:
		var target: float = 0.5 * (_cum_at(a) + _cum_at(b))
		var lo: float = a
		var hi: float = b
		for _i in range(32):
			var mid: float = 0.5 * (lo + hi)
			if _cum_at(mid) < target:
				lo = mid
			else:
				hi = mid
		return 0.5 * (lo + hi)


# One fragment, as a box in (y, theta, rho-fraction). `volume` is cached because
# the greedy loop reads it once per cell per split.
class Cell extends RefCounted:
	var y0: float = 0.0
	var y1: float = 0.0
	var t0: float = 0.0
	var t1: float = TAU
	var p0: float = 0.0
	var p1: float = 1.0
	var volume: float = 0.0

	func copy() -> Cell:
		var c := Cell.new()
		c.y0 = y0
		c.y1 = y1
		c.t0 = t0
		c.t1 = t1
		c.p0 = p0
		c.p1 = p1
		c.volume = volume
		return c

	# Do these two cells overlap in space? They must not -- a BSP cannot produce
	# an overlapping pair, and the test asks anyway. TWO BOXES ARE DISJOINT AS
	# SOON AS THEY ARE DISJOINT ON ONE AXIS, which is why this reads as an `or`.
	func disjoint_from(other: Cell) -> bool:
		return (y1 <= other.y0 + 1e-6 or other.y1 <= y0 + 1e-6
			or t1 <= other.t0 + 1e-6 or other.t1 <= t0 + 1e-6
			or p1 <= other.p0 + 1e-6 or other.p1 <= p0 + 1e-6)

	func contains(y: float, theta: float, p: float) -> bool:
		return (y >= y0 and y < y1
			and theta >= t0 and theta < t1
			and p >= p0 and p < p1)


# --- Reading a body ----------------------------------------------------------

# The one door in. Returns null for anything that is not a solid of revolution,
# which is the honest answer for a box: the caller shows no corpse rather than
# showing a wrong one.
static func profile_from_mesh(mesh: Mesh) -> Profile:
	if mesh is CylinderMesh:
		var cyl := mesh as CylinderMesh
		return _lathe(cyl.height, func(t: float) -> float:
			return lerpf(cyl.bottom_radius, cyl.top_radius, t))
	if mesh is CapsuleMesh:
		var cap := mesh as CapsuleMesh
		var radius: float = cap.radius
		# Godot's CapsuleMesh height INCLUDES both hemispherical caps, so the
		# straight midsection runs from -mid to +mid.
		var mid: float = maxf(0.0, cap.height * 0.5 - radius)
		var half: float = cap.height * 0.5
		return _lathe(cap.height, func(t: float) -> float:
			var y: float = lerpf(-half, half, t)
			var over: float = absf(y) - mid
			if over <= 0.0:
				return radius
			return sqrt(maxf(0.0, radius * radius - over * over)))
	return null

# Sample a radius function over a mesh-local height centred on the origin, which
# is where Godot puts both a CylinderMesh and a CapsuleMesh.
static func _lathe(height: float, radius_of: Callable) -> Profile:
	var samples := PackedFloat32Array()
	samples.resize(SAMPLES + 1)
	for i in range(SAMPLES + 1):
		samples[i] = float(radius_of.call(float(i) / float(SAMPLES)))
	return Profile.new(-height * 0.5, height * 0.5, samples)


# --- Cutting -----------------------------------------------------------------

# Split `profile` into exactly `count` cells. Deterministic: same profile, same
# count, same cells, on every machine and every run.
static func fragment(profile: Profile, count: int) -> Array:
	var whole := Cell.new()
	whole.y0 = profile.y0
	whole.y1 = profile.y1
	whole.volume = profile.volume()
	var cells: Array = [whole]
	if count <= 1:
		return cells

	while cells.size() < count:
		# The largest cell, by volume. A linear scan because `count` is tens and a
		# heap would be more code than the thing it speeds up.
		#
		# TIES ARE BROKEN BY POSITION IN THE LIST, deterministically -- and once
		# the subdivision has evened out there are a great many ties, so a test
		# must not assume WHICH equal cell got cut. It may only assume they are
		# equal, which is the property this loop is for.
		var best: int = 0
		for i in range(1, cells.size()):
			if cells[i].volume > cells[best].volume:
				best = i
		var pair: Array = split_cell(profile, cells[best])
		cells[best] = pair[0]
		cells.append(pair[1])

	return cells

# Cut one cell in two along whichever of its three sides is physically longest,
# at the place that halves the volume. See the header for why each of the three
# split points is what it is.
static func split_cell(profile: Profile, cell: Cell) -> Array:
	var y_mid: float = 0.5 * (cell.y0 + cell.y1)
	var r_mid: float = profile.radius_at(y_mid)
	var p_mid: float = 0.5 * (cell.p0 + cell.p1)

	var rise: float = cell.y1 - cell.y0
	# Arc length at the cell's MIDDLE radius, not its outer edge: the outer edge
	# would over-report a thin skin cell and cut it into slivers.
	var arc: float = (cell.t1 - cell.t0) * r_mid * p_mid
	var thickness: float = (cell.p1 - cell.p0) * r_mid

	var low: Cell = cell.copy()
	var high: Cell = cell.copy()

	if rise >= arc and rise >= thickness:
		var cut: float = profile.split_y(cell.y0, cell.y1)
		low.y1 = cut
		high.y0 = cut
	elif arc >= thickness:
		var cut: float = 0.5 * (cell.t0 + cell.t1)
		low.t1 = cut
		high.t0 = cut
	else:
		var cut: float = split_fraction(cell.p0, cell.p1)
		low.p1 = cut
		high.p0 = cut

	low.volume = cell_volume(profile, low)
	high.volume = cell_volume(profile, high)
	return [low, high]

# THE EQUAL-AREA ANNULUS SPLIT: the radius that divides the ring between p0 and
# p1 into two equal areas, and therefore two equal volumes. NOT (p0 + p1) / 2 --
# halving a full disc at 0.5 gives an inner core of a quarter the volume against
# an outer ring of three quarters, and pieces that differ four-fold do not read
# as a body coming apart.
#
# Its own function because the test asserts it directly AND asserts it in place:
# a helper that is correct and not called is the shape of bug CLAUDE.md records
# against the stride fix next door.
static func split_fraction(p0: float, p1: float) -> float:
	return sqrt(0.5 * (p0 * p0 + p1 * p1))

# A cell's share of the solid: its angular fraction, times its annular fraction,
# times the full volume of the lathe over its height band. Reads the same
# cumulative table the whole body's volume comes from, so the parts cannot fail
# to sum to the whole for arithmetic reasons -- only for tiling reasons, which is
# what the test is actually watching for.
static func cell_volume(profile: Profile, cell: Cell) -> float:
	var angular: float = (cell.t1 - cell.t0) / TAU
	var annular: float = cell.p1 * cell.p1 - cell.p0 * cell.p0
	return angular * annular * profile.volume_between(cell.y0, cell.y1)

# Where to put a fragment's ORIGIN. The equal-volume height and the equal-area
# radius, which is near enough the centre of mass for debris to spin plausibly.
#
# IT DOES NOT HAVE TO BE EXACT FOR THE ASSEMBLED PILE TO BE EXACT: cell_mesh is
# built around this same point and the body is placed at it, so whatever this
# returns, mesh plus placement puts every vertex back where it belongs. Only the
# tumbling looks slightly different if this is off.
static func cell_centre(profile: Profile, cell: Cell) -> Vector3:
	var y: float = profile.split_y(cell.y0, cell.y1)
	var theta: float = 0.5 * (cell.t0 + cell.t1)
	var p: float = sqrt(0.5 * (cell.p0 * cell.p0 + cell.p1 * cell.p1))
	var r: float = profile.radius_at(y) * p
	return Vector3(r * cos(theta), y, r * sin(theta))


# --- Drawing -----------------------------------------------------------------

# A point on the lathe, in the profile's own space.
static func point_at(profile: Profile, y: float, theta: float, p: float) -> Vector3:
	var r: float = profile.radius_at(y) * p
	return Vector3(r * cos(theta), y, r * sin(theta))

# The mesh for one cell, with its vertices expressed RELATIVE TO `origin` so the
# result can be hung on a body placed there.
#
# Six surfaces, three of which are usually degenerate and skipped: the outer
# skin, the inner skin (absent when the cell reaches the axis), the two radial
# end caps, and the top and bottom (absent at a capsule's poles, where the
# profile radius is zero). Zero-area triangles are dropped rather than emitted,
# because a degenerate triangle is a normal nobody can compute.
static func cell_mesh(profile: Profile, cell: Cell, origin: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# FLAT SHADING, chosen rather than inherited: these are chips off a solid and
	# a smoothed chip reads as a balloon.
	st.set_smooth_group(-1)

	# Rounded onto the global grid rather than derived from this cell's own size --
	# see ANGLE_STEPS. A cell narrower than one step still gets one segment.
	var na: int = maxi(1, int(round((cell.t1 - cell.t0) / (TAU / float(ANGLE_STEPS)))))
	var ny: int = maxi(1, int(ceil((cell.y1 - cell.y0) / MESH_RISE)))

	for i in range(na):
		var ta: float = lerpf(cell.t0, cell.t1, float(i) / float(na))
		var tb: float = lerpf(cell.t0, cell.t1, float(i + 1) / float(na))
		for j in range(ny):
			var ya: float = lerpf(cell.y0, cell.y1, float(j) / float(ny))
			var yb: float = lerpf(cell.y0, cell.y1, float(j + 1) / float(ny))
			# Outer skin, wound so its face points away from the axis.
			_quad(st, origin,
				point_at(profile, ya, ta, cell.p1), point_at(profile, ya, tb, cell.p1),
				point_at(profile, yb, tb, cell.p1), point_at(profile, yb, ta, cell.p1))
			# Inner skin, wound the other way -- it faces the axis.
			if cell.p0 > 0.0:
				_quad(st, origin,
					point_at(profile, ya, tb, cell.p0), point_at(profile, ya, ta, cell.p0),
					point_at(profile, yb, ta, cell.p0), point_at(profile, yb, tb, cell.p0))
		# Bottom and top.
		_quad(st, origin,
			point_at(profile, cell.y0, ta, cell.p0), point_at(profile, cell.y0, tb, cell.p0),
			point_at(profile, cell.y0, tb, cell.p1), point_at(profile, cell.y0, ta, cell.p1))
		_quad(st, origin,
			point_at(profile, cell.y1, tb, cell.p0), point_at(profile, cell.y1, ta, cell.p0),
			point_at(profile, cell.y1, ta, cell.p1), point_at(profile, cell.y1, tb, cell.p1))

	for j in range(ny):
		var ya: float = lerpf(cell.y0, cell.y1, float(j) / float(ny))
		var yb: float = lerpf(cell.y1, cell.y0, 1.0 - float(j + 1) / float(ny))
		# THE TWO RADIAL END FACES, only present when this is not a full ring --
		# and the two that were WOUND INSIDE OUT until 2026-08-29.
		#
		# Godot's front face is the CLOCKWISE one, so the outward normal is the
		# NEGATION of the right-hand-rule cross product -- measured off a
		# SphereMesh rather than remembered. These two were the only faces of the
		# six wound the other way, so they were back-face culled and every
		# fragment rendered as a hollow shell you could see straight through.
		# Measured: the mesh enclosed 14% of the volume of the cell it was cut
		# from. It was invisible while a corpse was intact -- an inward-facing
		# surface is hidden inside the assembled body anyway -- and only showed
		# once something scattered the pile and the insides came into view.
		if cell.t1 - cell.t0 < TAU - 1e-5:
			_quad(st, origin,
				point_at(profile, ya, cell.t0, cell.p1), point_at(profile, yb, cell.t0, cell.p1),
				point_at(profile, yb, cell.t0, cell.p0), point_at(profile, ya, cell.t0, cell.p0))
			_quad(st, origin,
				point_at(profile, yb, cell.t1, cell.p1), point_at(profile, ya, cell.t1, cell.p1),
				point_at(profile, ya, cell.t1, cell.p0), point_at(profile, yb, cell.t1, cell.p0))

	st.generate_normals()
	return st.commit()

static func _quad(st: SurfaceTool, origin: Vector3, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3) -> void:
	_tri(st, origin, a, b, c)
	_tri(st, origin, a, c, d)

static func _tri(st: SurfaceTool, origin: Vector3, a: Vector3, b: Vector3, c: Vector3) -> void:
	# A collapsed corner -- the axis, or a capsule's pole -- makes a triangle with
	# no area and no normal. Drop it.
	if (b - a).cross(c - a).length_squared() < 1e-12:
		return
	st.add_vertex(a - origin)
	st.add_vertex(b - origin)
	st.add_vertex(c - origin)
