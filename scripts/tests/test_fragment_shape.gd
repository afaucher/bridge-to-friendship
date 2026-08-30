extends "res://scripts/test_support/test_case.gd"

# THE FRAGMENTER, ACROSS EVERY CHARACTER IN THE GAME, WITHOUT RUNNING THE GAME.
#
# The cheap tier of the death-animation gate: no world, no physics, no rendering,
# no frames. It reads each character's REAL SCENE, pulls its parts off the meshes
# the game actually draws, cuts them up and measures the result. A fifth
# character costs one line in KINDS below.
#
# WHAT IT IS WATCHING FOR is the property the whole feature rests on: the
# fragments TILE the body. If they do not, a corpse is a different shape from the
# thing that was standing there and the moment of death is a pop.
#
# THREE CLAIMS, AND THE THIRD IS THE ONE THAT BITES:
#
#   1. The parts sum to the whole. Cheap and weak on its own -- two cells that
#      overlap by exactly as much as a third is missing would pass it.
#   2. No two cells overlap. Guaranteed by construction (a binary subdivision
#      cannot produce an overlapping pair), and asserted anyway, because "by
#      construction" is an argument and this is a measurement.
#   3. EVERY POINT INSIDE THE BODY IS IN EXACTLY ONE CELL. The one that cannot be
#      satisfied by a wrong tiling that happens to balance: a gap and an overlap
#      both fail it, in the place where they are.
#
# A BOUNDING VOLUME COULD NOT DO ANY OF THIS. CLAUDE.md has the entry about the
# beak that pointed backwards through every extent assertion in its test -- an
# AABB cannot tell a prism from the box it was cut from. The union of a set of
# fragments has the same AABB whether they tile the body or sit in a heap, so
# every assertion here is about the INTERIOR.
#
# AND A SEPARATE PASS FOR THE DRAWN MESH, at the bottom. All of the above passed
# while the pieces were being drawn with ledges down the rusher's cone, and again
# while every one of them was a hollow shell: the cells were exact both times and
# the drawing was wrong.

const FragmentShape = preload("res://scripts/sim/fragment_shape.gd")
const Corpse = preload("res://scripts/sim/corpse.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# EVERY CHARACTER, READ FROM ITS OWN SCENE. Not a table of radii: the corpse gets
# its shape from the .tscn at runtime, so a test that restated the numbers would
# be checking a second copy of a fact against a third one.
#
# `single_lathe` says the body is ONE solid of revolution, which is what makes
# the exact-equality claim available -- see the spread assertion. A zombie is a
# torso and two arms; a turret is a tapered base, a ring and a box gun barrel.
const KINDS := [
	{"name": "rusher", "scene": "res://scenes/rusher.tscn", "single_lathe": true},
	{"name": "skirmisher", "scene": "res://scenes/skirmisher.tscn", "single_lathe": true},
	{"name": "zombie", "scene": "res://scenes/zombie.tscn", "single_lathe": false},
	{"name": "turret", "scene": "res://scenes/turret.tscn", "single_lathe": false},
]

# THE PLAYER IS NOT IN HERE, AND FINDING OUT WHY WAS WORTH THE DETOUR.
#
# It was, while the fragmenter took one mesh per body. Now that it takes every
# visible mesh, a player comes back as THREE parts -- the body, and the sidearm's
# grip and barrel -- and the sidearm is GEAR rather than body. Measured, that put
# the spread at 76.8: the grip is a thousandth of a cubic metre and is never
# worth splitting, so it sits there as a permanent floor under every real
# fragment.
#
# Nothing ships wrong, because Corpse.SCENES has no player in it and the player's
# death animation is deferred to the life limit. But it IS the open question that
# work has to answer first: a corpse needs a rule for telling a body from the
# things it is carrying. Visibility already excludes a stowed shield and will not
# exclude a drawn pistol. See design_ideas/death_fragments.md.

const PROBES := 3000

# AT THE SHIPPED COUNT, AND THEN DEEPER -- AND THE SECOND ONE IS NOT PADDING.
#
# The A/B that proved this test can fail also showed how narrowly it was passing:
# with the annulus split reverted to the naive midpoint, only the RUSHER's spread
# moved. At the shipped count a cylinder or a capsule never takes the radial axis
# at all -- its radial thickness is the shortest of the three sides and the
# greedy runs out of pieces before it becomes the longest -- so the other
# characters were asserting an equal size that no radial cut had contributed to.
const DEEP_COUNT := 64

func setup(_main) -> void:
	for kind in KINDS:
		_check_kind(kind, SimConfig.CORPSE_FRAGMENTS, false)
		_check_kind(kind, DEEP_COUNT, true)
	_check_annulus_split()
	_check_determinism()
	for kind in KINDS:
		_check_normals(kind)
	finish()

func _parts_of(kind: Dictionary) -> Array:
	var packed: PackedScene = load(str(kind["scene"]))
	if packed == null:
		return []
	var body: Node = packed.instantiate()
	var parts: Array = Corpse._parts_of(body)
	body.free()
	return parts

func _check_kind(kind: Dictionary, count: int, require_all_axes: bool) -> void:
	var name: String = "%s@%d" % [str(kind["name"]), count]
	var parts: Array = _parts_of(kind)
	if not check(parts.size() > 0, "%s: the scene yields at least one part" % name):
		return

	var pieces: Array = FragmentShape.fragment_body(parts, count)
	eq(pieces.size(), count, "%s: exactly the requested fragment count" % name)

	# 1. The parts sum to the whole -- every part of it.
	var body_volume: float = 0.0
	for part in parts:
		body_volume += part.volume()
	var total: float = 0.0
	var smallest: float = INF
	var largest: float = 0.0
	for piece in pieces:
		var v: float = FragmentShape.piece_volume(parts, piece)
		total += v
		smallest = minf(smallest, v)
		largest = maxf(largest, v)
	check(absf(total - body_volume) / body_volume < 1e-4,
		"%s: fragment volumes sum to the body -- body %.6f, fragments %.6f"
			% [name, body_volume, total])

	# 2 and 3, PER PART. Two pieces of DIFFERENT parts are allowed to overlap in
	# space -- a turret's ring sits in the column above its base -- so the tiling
	# claim is about each part's own volume, which is what was actually
	# subdivided.
	var overlaps: int = 0
	var uncovered: int = 0
	var doubled: int = 0
	var axes := {"y": false, "t": false, "p": false}
	for index in range(parts.size()):
		var mine: Array = []
		for piece in pieces:
			if piece.part == index:
				mine.append(piece)
		if mine.is_empty():
			continue
		overlaps += _overlaps_in(mine)
		var found: Array = _coverage_of(parts[index], mine)
		uncovered += int(found[0])
		doubled += int(found[1])
		if not parts[index].is_box():
			for piece in mine:
				if piece.y0 > parts[index].profile.y0 + 1e-6:
					axes["y"] = true
				if piece.t0 > 1e-6:
					axes["t"] = true
				if piece.p0 > 1e-6:
					axes["p"] = true

	eq(overlaps, 0, "%s: no two fragments of one part overlap" % name)
	eq(uncovered, 0, "%s: every interior point is inside some fragment" % name)
	eq(doubled, 0, "%s: no interior point is inside two fragments" % name)

	var spread: float = largest / smallest
	print("[FRAGMENT] %-16s parts=%d cells=%d volume=%.5f spread=%.3f axes=%s%s%s"
		% [name, parts.size(), pieces.size(), total, spread,
			"y" if axes["y"] else "-", "t" if axes["t"] else "-", "p" if axes["p"] else "-"])

	if require_all_axes and bool(kind["single_lathe"]):
		check(axes["y"] and axes["t"] and axes["p"],
			"%s: cut on all three axes -- without a radial cut the size claim is vacuous" % name)

	# 4. HOW EQUAL THE PIECES ARE, and which claim is available depends on the
	# body.
	#
	# ONE LATHE CUT TO A POWER OF TWO IS EXACT, and that is an arithmetic
	# impossibility rather than a tuned threshold: every cut halves a piece
	# exactly, so a split that were even slightly off on ANY of the three axes
	# could not produce it. A midpoint radial split shows up here as 3.0.
	#
	# A BODY OF SEVERAL PARTS CANNOT BE EXACT, and that is not a defect. The
	# greedy starts with one cell per part, and no number of halvings makes a
	# turret's base and its gun barrel agree. What greedy guarantees is the bound.
	if bool(kind["single_lathe"]):
		check(spread < 1.001,
			"%s: every fragment the same size -- largest/smallest %.4f" % [name, spread])
	else:
		# THE CLAIM IS ABOUT THE TOP END, and the bottom end is not a defect.
		#
		# A zombie's arm is a fortieth of its torso -- smaller than one fragment of
		# that torso ought to be -- so the greedy never splits it and it sits there
		# as a permanent floor. That is correct: you cannot make an arm bigger, and
		# a body whose smallest natural part is small has a small piece in it.
		#
		# What WOULD be a defect is a piece nobody got round to splitting: one
		# giant slab among the chips. So the assertion is that nothing is more than
		# twice the average, which is exactly the invariant greedy buys, and the
		# raw spread is printed beside it rather than asserted.
		var average: float = total / float(pieces.size())
		check(largest <= average * 2.05,
			"%s: no fragment is more than twice the average -- largest %.5f, average %.5f (raw spread %.2f)"
				% [name, largest, average, spread])

func _overlaps_in(mine: Array) -> int:
	var found: int = 0
	for i in range(mine.size()):
		for j in range(i + 1, mine.size()):
			var a = mine[i]
			var b = mine[j]
			if a is FragmentShape.BoxCell:
				if not (a.hi.x <= b.lo.x + 1e-6 or b.hi.x <= a.lo.x + 1e-6
						or a.hi.y <= b.lo.y + 1e-6 or b.hi.y <= a.lo.y + 1e-6
						or a.hi.z <= b.lo.z + 1e-6 or b.hi.z <= a.lo.z + 1e-6):
					found += 1
			elif not a.disjoint_from(b):
				found += 1
	return found

# [uncovered, doubled] over points sampled inside one part.
func _coverage_of(part, mine: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var uncovered: int = 0
	var doubled: int = 0
	var probed: int = 0
	while probed < PROBES:
		var hits: int = 0
		if part.is_box():
			var half: Vector3 = part.box * 0.5
			var at := Vector3(
				rng.randf_range(-half.x, half.x) * 0.999,
				rng.randf_range(-half.y, half.y) * 0.999,
				rng.randf_range(-half.z, half.z) * 0.999)
			probed += 1
			for piece in mine:
				if (at.x >= piece.lo.x and at.x < piece.hi.x
						and at.y >= piece.lo.y and at.y < piece.hi.y
						and at.z >= piece.lo.z and at.z < piece.hi.z):
					hits += 1
		else:
			var profile = part.profile
			var y: float = profile.y0 + rng.randf() * profile.height()
			if profile.radius_at(y) <= 1e-5:
				continue
			var p: float = rng.randf()
			var theta: float = rng.randf() * TAU
			# Nudged off the extremes: on the outer skin or the top face, "inside"
			# is a question about floating point rather than about the tiling.
			if p < 1e-4 or p > 1.0 - 1e-4:
				continue
			if y < profile.y0 + 1e-4 or y > profile.y1 - 1e-4:
				continue
			probed += 1
			for piece in mine:
				if piece.contains(y, theta, p):
					hits += 1
		if hits == 0:
			uncovered += 1
		elif hits > 1:
			doubled += 1
	return [uncovered, doubled]

# THE EQUAL-AREA ANNULUS SPLIT, ON ITS OWN AND THEN IN PLACE.
#
# Asserting the helper is not asserting the pass (CLAUDE.md), so this does both:
# the arithmetic directly, and then a cell the axis rule is guaranteed to cut
# RADIALLY -- thin in height, narrow in angle -- run through the real split. If
# the annulus split were the midpoint, that cell's two halves would come out at
# one-to-three while the first claim still passed.
func _check_annulus_split() -> void:
	var profile: FragmentShape.Profile = FragmentShape.profile_from_mesh(_cylinder(0.5, 2.0))
	if not check(profile != null, "annulus: built a test cylinder"):
		return

	near(FragmentShape.split_fraction(0.0, 1.0), sqrt(0.5), 1e-6,
		"annulus: a full disc halves at sqrt(1/2), not at 1/2")

	var cell := FragmentShape.Cell.new()
	cell.y0 = -0.01
	cell.y1 = 0.01
	cell.t0 = 0.0
	cell.t1 = 0.02
	cell.p0 = 0.0
	cell.p1 = 1.0
	var pair: Array = FragmentShape.split_cell(profile, cell)
	var a: float = FragmentShape.cell_volume(profile, pair[0])
	var b: float = FragmentShape.cell_volume(profile, pair[1])
	check(a > 0.0 and b > 0.0, "annulus: both halves have volume")
	check(absf(a - b) / maxf(a, b) < 1e-5,
		"annulus: a radial cut halves the volume -- inner %.9f, outer %.9f" % [a, b])

# SAME BODY, SAME COUNT, SAME PIECES -- on every machine and every run. A corpse
# is spawned independently on each client from nothing but a kind and a position,
# so if this were not true the same enemy would come apart differently for each
# player watching it. Run on the TURRET, which is the body with several parts and
# therefore the one where the greedy has a choice to make.
func _check_determinism() -> void:
	var parts: Array = _parts_of(KINDS[2])
	var a: Array = FragmentShape.fragment_body(parts, 24)
	var b: Array = FragmentShape.fragment_body(parts, 24)
	var differences: int = 0
	for i in range(a.size()):
		if a[i].part != b[i].part:
			differences += 1
			continue
		if a[i] is FragmentShape.BoxCell:
			if a[i].lo != b[i].lo or a[i].hi != b[i].hi:
				differences += 1
		elif (a[i].y0 != b[i].y0 or a[i].y1 != b[i].y1 or a[i].t0 != b[i].t0
				or a[i].t1 != b[i].t1 or a[i].p0 != b[i].p0 or a[i].p1 != b[i].p1):
			differences += 1
	eq(differences, 0, "determinism: two runs produce identical pieces")

func _cylinder(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	return mesh

# THE DRAWN MESH, WHICH IS A DIFFERENT QUESTION FROM THE CUT CELL.
#
# IT MATTERS FOR TWO REASONS AND ONLY ONE IS VISIBLE WHILE THE CORPSE IS INTACT.
# An inward normal is a face lit from behind AND a face back-face culling
# removes -- and while the pile is assembled every inward-facing surface is
# hidden inside the body anyway, so the whole class of fault is invisible until
# something scatters it and the insides come into view.
#
# THE DIVERGENCE THEOREM SETTLES CLOSURE AND DIRECTION IN ONE NUMBER. For a
# closed surface, (1/3) * sum of area * (centroid . normal) is the enclosed
# volume: it is only the volume if the surface is CLOSED (a missing face leaks),
# and only POSITIVE if the normals point outward. Computed from the STORED
# normals, so it measures the vectors the renderer actually consumes, and
# compared against a volume computed from the CELL, so it is not the mesh
# agreeing with itself.
func _check_normals(kind: Dictionary) -> void:
	var name: String = "%s normals" % str(kind["name"])
	var parts: Array = _parts_of(kind)
	if not check(parts.size() > 0, "%s: parts" % name):
		return
	var pieces: Array = FragmentShape.fragment_body(parts, SimConfig.CORPSE_FRAGMENTS)

	var empty: int = 0
	var inverted: int = 0
	var leaking: int = 0
	var wrong_winding: int = 0
	var worst: float = INF
	var best: float = 0.0

	for piece in pieces:
		var mesh: ArrayMesh = FragmentShape.piece_mesh(parts, piece)
		if mesh == null or mesh.get_surface_count() == 0:
			empty += 1
			continue
		var tris: Array = _triangles_of(mesh)
		if tris.is_empty():
			empty += 1
			continue

		var enclosed: float = 0.0
		for tri in tris:
			var a: Vector3 = tri[0]
			var b: Vector3 = tri[1]
			var c: Vector3 = tri[2]
			var n: Vector3 = tri[3]
			var cross: Vector3 = (b - a).cross(c - a)
			var area: float = cross.length() * 0.5
			if area <= 1e-12:
				continue
			enclosed += area * ((a + b + c) / 3.0).dot(n)
			# PARALLEL, not merely same-signed. Same-signed is tautological --
			# generate_normals() derives the normals FROM the winding, so the sign
			# cannot disagree. Parallel is a claim about FLAT SHADING, and it
			# would fail the day a smooth group stopped taking and corpses started
			# rendering as balloons.
			if absf(cross.normalized().dot(n) - _engine_winding_sign()) > 0.01:
				wrong_winding += 1
		enclosed /= 3.0

		var want: float = FragmentShape.piece_volume(parts, piece)
		if enclosed <= 0.0:
			inverted += 1
			continue
		var ratio: float = enclosed / want
		worst = minf(worst, ratio)
		best = maxf(best, ratio)
		# THE FLOOR IS PREDICTED PER PART, NOT PICKED. A lathe fragment is a
		# polygon inscribed in its circle, and a regular n-gon is exactly
		# (n / 2pi) * sin(2pi / n) of it -- 0.9936 at 32 segments and 0.9003 at
		# eight. A flat 0.95 was fine while every part was drawn at 32 and became
		# a false failure the day a turret's octagonal base was drawn at its own
		# eight: the mesh was exactly right and the threshold was not.
		#
		# The extra 5% below the prediction is the Y direction, where a capsule's
		# CAP is inscribed as well: measured, a cap fragment lands at 0.9533
		# against an angular prediction of 0.9936. It is wide enough for a chord
		# cutting a corner and nowhere near wide enough to hide a leak -- the real
		# hollow-shell bug measured 0.14. A box has nothing inscribed at all and
		# is expected to land on 1.0.
		var floor_ratio: float = 0.999
		if not parts[piece.part].is_box():
			var n: float = float(parts[piece.part].profile.angle_steps)
			floor_ratio = (n / TAU) * sin(TAU / n) * 0.95
		if ratio > 1.001 or ratio < floor_ratio:
			leaking += 1

	print("[NORMALS] %-12s pieces=%d empty=%d inverted=%d leaking=%d bad-winding=%d ratio %.4f..%.4f"
		% [str(kind["name"]), pieces.size(), empty, inverted, leaking, wrong_winding, worst, best])
	eq(empty, 0, "%s: every fragment produced a mesh" % name)
	eq(inverted, 0, "%s: every fragment's normals point out of it" % name)
	eq(leaking, 0, "%s: every fragment is a closed solid of its cell's volume" % name)
	eq(wrong_winding, 0, "%s: every face is flat shaded and wound the engine's way" % name)

	# AN ARITHMETIC PREDICTION FOR THE ONE SHAPE THAT HAS ONE. The rusher's
	# profile is a straight taper, so it does not curve in y and the ONLY thing
	# the tessellation inscribes is the circle -- and a regular n-gon is exactly
	# (n / 2pi) * sin(2pi / n) of its circle. At ANGLE_STEPS = 32 that is 0.99359.
	# A number nobody chose, which no merely-close mesh can satisfy.
	if str(kind["name"]) == "rusher":
		# Read off the PROFILE rather than the constant: a part is drawn at its own
		# source mesh's resolution now, so the prediction has to ask which one it
		# got rather than assume the default.
		var steps: int = parts[0].profile.angle_steps
		var n: float = float(steps)
		near(best, (n / TAU) * sin(TAU / n), 0.001,
			"%s: a straight taper's fragments enclose exactly the inscribed %d-gon fraction"
				% [name, steps])

# WHICH WAY ROUND GODOT WINDS A FRONT FACE, ASKED OF GODOT.
#
# The first version of this check assumed the right-hand rule and reported every
# fragment of every character wound inside-out -- while the rendered corpses were
# lit correctly, which is not something an inside-out mesh does. The test was
# wrong, and flipping its sign until it went green would have been tuning the
# instrument to the reading. So the convention is MEASURED, off a mesh the engine
# authored itself: a sphere, whose outward normal at a face is unambiguously its
# own centroid.
func _engine_winding_sign() -> float:
	if _winding_sign != 0.0:
		return _winding_sign
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.surface_get_arrays(0))
	var agree: int = 0
	var disagree: int = 0
	for tri in _triangles_of(mesh):
		var cross: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
		if cross.length_squared() < 1e-14:
			continue
		# The control has to be able to fail: on a unit sphere at the origin the
		# outward direction at a face IS its own centroid, so this also confirms
		# the sphere's stored normals point outward before anything is concluded.
		var out: Vector3 = ((tri[0] + tri[1] + tri[2]) / 3.0).normalized()
		if tri[3].dot(out) <= 0.0:
			continue
		if cross.normalized().dot(tri[3]) > 0.0:
			agree += 1
		else:
			disagree += 1
	check(agree == 0 or disagree == 0,
		"engine winding: a SphereMesh is wound consistently (%d agree, %d disagree)"
			% [agree, disagree])
	_winding_sign = 1.0 if agree > disagree else -1.0
	print("[NORMALS] engine winding sign %+.0f (%d agree, %d disagree on a SphereMesh)"
		% [_winding_sign, agree, disagree])
	return _winding_sign

var _winding_sign: float = 0.0

# Triangles as [a, b, c, averaged stored normal].
#
# ARRAY_INDEX IS NIL, NOT EMPTY, on an unindexed surface -- and assigning Nil to
# a typed PackedInt32Array RAISES, which aborts the calling function for the
# frame and leaves the test reporting PASS having asserted nothing. It did
# exactly that on the first run of this check: four silent aborts, no [NORMALS]
# line at all, and a green suite. The tell is a print that never appears.
func _triangles_of(mesh: ArrayMesh) -> Array:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms := PackedVector3Array()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		norms = arrays[Mesh.ARRAY_NORMAL]
	var index := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		index = arrays[Mesh.ARRAY_INDEX]
	var count: int = index.size() if index.size() > 0 else verts.size()
	var out: Array = []
	for t in range(0, count - 2, 3):
		var i0: int = index[t] if index.size() > 0 else t
		var i1: int = index[t + 1] if index.size() > 0 else t + 1
		var i2: int = index[t + 2] if index.size() > 0 else t + 2
		var n := Vector3.ZERO
		if norms.size() > i2:
			n = (norms[i0] + norms[i1] + norms[i2]).normalized()
		out.append([verts[i0], verts[i1], verts[i2], n])
	return out
