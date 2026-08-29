extends "res://scripts/test_support/test_case.gd"

# THE FRAGMENTER, ACROSS EVERY CHARACTER IN THE GAME, WITHOUT RUNNING THE GAME.
#
# This is the cheap tier of the death-animation gate: no world, no physics, no
# rendering, no frames. It reads each character's REAL SCENE, pulls the profile
# off the mesh the game actually draws, cuts it up and measures the result. A
# fifth character costs one line in KINDS below.
#
# WHAT IT IS WATCHING FOR is the one property the whole feature rests on: the
# fragments TILE the body. If they do not, a corpse is a different shape from the
# thing that was standing there and the moment of death is a pop.
#
# THREE CLAIMS, AND THE THIRD IS THE ONE THAT BITES:
#
#   1. The parts sum to the whole. Cheap and weak on its own -- two cells that
#      overlap by exactly as much as a third cell is missing would pass it.
#   2. No two cells overlap. Guaranteed by construction (a binary subdivision
#      cannot produce an overlapping pair), and asserted anyway, because "by
#      construction" is an argument and this is a measurement.
#   3. EVERY POINT INSIDE THE BODY IS IN EXACTLY ONE CELL. This is the one that
#      cannot be satisfied by a wrong tiling that happens to balance: a gap and an
#      overlap both fail it, in the place where they are.
#
# A BOUNDING VOLUME COULD NOT DO ANY OF THIS. CLAUDE.md has the entry about the
# beak that pointed backwards through every extent assertion in its test -- an
# AABB cannot tell a prism from the box it was cut from. The union of a set of
# fragments has the same AABB whether they tile the body or sit in a heap, so the
# assertions here are all about the INTERIOR.

const FragmentShape = preload("res://scripts/sim/fragment_shape.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# EVERY CHARACTER, READ FROM ITS OWN SCENE. Not a table of radii: the corpse gets
# its shape from the .tscn at runtime, so a test that restated the numbers would
# be checking a second copy of a fact against a third one. The player is in here
# even though the player's death animation is deferred -- the fragmenter does not
# know what a player is, and a cylinder is worth covering for the day it lands.
const KINDS := [
	{"name": "player", "scene": "res://scenes/player.tscn"},
	{"name": "rusher", "scene": "res://scenes/rusher.tscn"},
	{"name": "skirmisher", "scene": "res://scenes/skirmisher.tscn"},
	{"name": "zombie", "scene": "res://scenes/zombie.tscn"},
]

# How many interior points to test for single-coverage, per character. Cheap
# enough to be generous: this is the assertion doing the real work.
const PROBES := 4000

# AT THE SHIPPED COUNT, AND THEN DEEPER -- AND THE SECOND ONE IS NOT PADDING.
#
# The A/B that proved this test can fail also showed how narrowly it was passing:
# with the annulus split reverted to the naive midpoint, only the RUSHER's spread
# moved. At sixteen pieces a cylinder or a capsule never takes the radial axis at
# all -- its radial thickness is the shortest of the three sides and the greedy
# has run out of pieces before it becomes the longest -- so three of the four
# characters were asserting an equal size that no radial cut had contributed to.
# That is a wall of green over an untaken branch, and only the tapered body was
# holding the line.
#
# DEEP_COUNT is chosen to be past the depth at which every profile has cut on all
# three axes, and the test asserts that it really has (see `axes` below) rather
# than assuming it. Both counts are powers of two, so both must come out exactly
# even.
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

# `require_all_axes` is only asked at the deep count: at the shipped one it would
# be a false claim about a correct fragmenter.
func _check_kind(kind: Dictionary, count: int, require_all_axes: bool) -> void:
	var name: String = "%s@%d" % [str(kind["name"]), count]
	var packed: PackedScene = load(str(kind["scene"]))
	if not check(packed != null, "%s: scene loads" % name):
		return
	var body: Node = packed.instantiate()
	var mesh_node := body.get_node_or_null("Mesh") as MeshInstance3D
	if not check(mesh_node != null and mesh_node.mesh != null, "%s: has a Mesh" % name):
		body.free()
		return

	var mesh: Mesh = mesh_node.mesh
	var profile: FragmentShape.Profile = FragmentShape.profile_from_mesh(mesh)
	if not check(profile != null, "%s: mesh is a solid of revolution" % name):
		body.free()
		return

	# THE SAMPLED PROFILE AGAINST THE CLOSED FORM. The table is what everything
	# downstream integrates, so this is the one place the approximation is
	# measured against the real shape rather than against itself.
	var exact: float = _exact_volume(mesh)
	var sampled: float = profile.volume()
	check(absf(sampled - exact) / exact < 0.005,
		"%s: sampled volume within 0.5%% of the closed form -- exact %.5f, sampled %.5f"
			% [name, exact, sampled])

	var cells: Array = FragmentShape.fragment(profile, count)
	eq(cells.size(), count, "%s: exactly the requested fragment count" % name)

	# 1. The parts sum to the whole.
	var total: float = 0.0
	var smallest: float = INF
	var largest: float = 0.0
	for cell in cells:
		var v: float = FragmentShape.cell_volume(profile, cell)
		total += v
		smallest = minf(smallest, v)
		largest = maxf(largest, v)
	check(absf(total - sampled) / sampled < 1e-4,
		"%s: fragment volumes sum to the body -- body %.6f, fragments %.6f"
			% [name, sampled, total])

	# 2. No two cells overlap.
	var overlaps: int = 0
	for i in range(cells.size()):
		for j in range(i + 1, cells.size()):
			if not cells[i].disjoint_from(cells[j]):
				overlaps += 1
	eq(overlaps, 0, "%s: no two fragments overlap" % name)

	# 3. EXACTLY ONE CELL PER INTERIOR POINT. The claim a balanced-but-wrong
	# tiling cannot satisfy.
	var uncovered: int = 0
	var doubled: int = 0
	var probed: int = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var span: float = profile.height()
	while probed < PROBES:
		# Rejection-sampled into the solid: pick a point in the bounding cylinder
		# and keep it only if it is inside the profile. A capsule's caps mean this
		# rejects a fair amount, which is fine and is why there is a probe budget
		# rather than a fixed loop count.
		var y: float = profile.y0 + rng.randf() * span
		var r_here: float = profile.radius_at(y)
		if r_here <= 1e-5:
			continue
		var p: float = rng.randf()
		var theta: float = rng.randf() * TAU
		# Nudged off the extremes so a probe never lands exactly on the outer skin
		# or the top face, where the half-open cell convention makes "inside" a
		# question about floating point rather than about the tiling.
		if p < 1e-4 or p > 1.0 - 1e-4:
			continue
		if y < profile.y0 + 1e-4 or y > profile.y1 - 1e-4:
			continue
		probed += 1
		var hits: int = 0
		for cell in cells:
			if cell.contains(y, theta, p):
				hits += 1
		if hits == 0:
			uncovered += 1
		elif hits > 1:
			doubled += 1
	eq(uncovered, 0, "%s: every interior point is inside some fragment" % name)
	eq(doubled, 0, "%s: no interior point is inside two fragments" % name)

	# 4. THEY END UP THE SAME SIZE, which is the point of splitting the largest
	# cell rather than splitting to a target. Printed as well as asserted: the
	# number is the thing to look at when tuning the count.
	var spread: float = largest / smallest

	# WHICH AXES WERE ACTUALLY CUT, read off the finished cells rather than
	# recorded during the split: a cell whose p0 has left zero was made by a
	# radial cut, and likewise for the other two. This is what stops the size
	# claim above from being green over an axis the greedy never reached.
	var axes := {"y": false, "t": false, "p": false}
	for cell in cells:
		if cell.y0 > profile.y0 + 1e-6:
			axes["y"] = true
		if cell.t0 > 1e-6:
			axes["t"] = true
		if cell.p0 > 1e-6:
			axes["p"] = true
	print("[FRAGMENT] %-14s cells=%d volume=%.5f spread=%.3f axes=%s%s%s"
		% [name, cells.size(), total, spread,
			"y" if axes["y"] else "-", "t" if axes["t"] else "-", "p" if axes["p"] else "-"])
	if require_all_axes:
		check(axes["y"] and axes["t"] and axes["p"],
			"%s: the subdivision cut on all three axes -- without a radial cut the size claim below is vacuous" % name)
	# AN ARITHMETIC IMPOSSIBILITY RATHER THAN A TUNED THRESHOLD. Every cut halves
	# a piece exactly, so at a power-of-two count every fragment is exactly the
	# same size -- and a split that were even slightly off on ANY of the three
	# axes could not produce this. A midpoint radial split shows up here as 3.0.
	# See the note on CORPSE_FRAGMENTS: this is why that number is 16.
	check(spread < 1.001,
		"%s: every fragment the same size -- largest/smallest %.4f" % [name, spread])

	body.free()

# THE EQUAL-AREA ANNULUS SPLIT, ON ITS OWN AND THEN IN PLACE.
#
# Asserting the helper is not asserting the pass (CLAUDE.md), so this does both:
# the arithmetic directly, and then a cell that the axis rule is guaranteed to cut
# RADIALLY -- thin in height, narrow in angle -- run through the real _split. If
# the annulus split were the midpoint, the two halves of that cell would come out
# at one-to-three and the second claim would fail while the first still passed.
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

# SAME PROFILE, SAME COUNT, SAME CELLS -- on every machine and every run. The
# corpse is spawned independently on each client from nothing but a kind and a
# position, so if this were not true the same enemy would come apart differently
# for each player watching it.
func _check_determinism() -> void:
	var profile: FragmentShape.Profile = FragmentShape.profile_from_mesh(_cylinder(0.4, 1.8))
	var a: Array = FragmentShape.fragment(profile, 24)
	var b: Array = FragmentShape.fragment(profile, 24)
	var differences: int = 0
	for i in range(a.size()):
		if (a[i].y0 != b[i].y0 or a[i].y1 != b[i].y1 or a[i].t0 != b[i].t0
				or a[i].t1 != b[i].t1 or a[i].p0 != b[i].p0 or a[i].p1 != b[i].p1):
			differences += 1
	eq(differences, 0, "determinism: two runs produce identical cells")

func _cylinder(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	return mesh

func _exact_volume(mesh: Mesh) -> float:
	if mesh is CylinderMesh:
		var c := mesh as CylinderMesh
		var r: float = c.top_radius
		var b: float = c.bottom_radius
		# A frustum. Reduces to pi r^2 h when the two radii agree.
		return PI * c.height * (r * r + r * b + b * b) / 3.0
	var cap := mesh as CapsuleMesh
	var mid: float = maxf(0.0, cap.height - 2.0 * cap.radius)
	return (PI * cap.radius * cap.radius * mid
		+ 4.0 / 3.0 * PI * cap.radius * cap.radius * cap.radius)

# THE DRAWN MESH, WHICH IS A DIFFERENT QUESTION FROM THE CUT CELL.
#
# Everything above is about the SUBDIVISION -- that the cells tile the body. All
# of it passed while the fragments were being drawn with ledges down the rusher's
# cone, because the cells were exact and the drawing was wrong. This is the other
# half: given a correct cell, is the mesh built for it a closed solid whose
# normals point OUT of it.
#
# IT MATTERS FOR TWO SEPARATE REASONS, AND ONLY ONE OF THEM IS VISIBLE WHILE THE
# CORPSE IS INTACT. An inward normal is a face lit from behind AND a face
# back-face culling removes -- and while the pile is assembled every inward-facing
# surface is hidden inside the body anyway, so the whole class of fault is
# invisible until something scatters it and the insides come into view.
#
# THE DIVERGENCE THEOREM SETTLES CLOSURE AND DIRECTION IN ONE NUMBER. For a
# closed surface, (1/3) * sum of area * (centroid . normal) is the enclosed
# volume: it is only the volume if the surface is CLOSED (a missing face leaks),
# and it is only POSITIVE if the normals point outward. Computed from the STORED
# normals rather than from the winding, so it measures the vectors the renderer
# actually consumes, and compared against a volume computed from the CELL rather
# than from the mesh -- so it is not the mesh agreeing with itself.
#
# The mesh is a polygon inscribed in the profile, so its volume is legitimately a
# little UNDER the analytic cell's. The tolerance is one-sided for that reason.
func _check_normals(kind: Dictionary) -> void:
	var name: String = "%s normals" % str(kind["name"])
	var packed: PackedScene = load(str(kind["scene"]))
	var body: Node = packed.instantiate()
	var mesh_node := body.get_node_or_null("Mesh") as MeshInstance3D
	var profile: FragmentShape.Profile = FragmentShape.profile_from_mesh(mesh_node.mesh)
	body.free()
	if not check(profile != null, "%s: profile" % name):
		return

	var cells: Array = FragmentShape.fragment(profile, SimConfig.CORPSE_FRAGMENTS)
	var empty: int = 0
	var inverted: int = 0
	var leaking: int = 0
	var wrong_winding: int = 0
	var worst: float = INF
	var best: float = 0.0

	for cell in cells:
		var centre: Vector3 = FragmentShape.cell_centre(profile, cell)
		var mesh: ArrayMesh = FragmentShape.cell_mesh(profile, cell, centre)
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
			var n: Vector3 = tri[3]          # the STORED normal, averaged over the face
			var cross: Vector3 = (b - a).cross(c - a)
			var area: float = cross.length() * 0.5
			if area <= 1e-12:
				continue
			enclosed += area * ((a + b + c) / 3.0).dot(n)
			# And the winding against the stored normal, in the engine's own
			# convention rather than in one this file assumed -- see
			# _engine_winding_sign().
			# PARALLEL, not merely same-signed. Same-signed is tautological --
			# generate_normals() derives the normals FROM the winding, so the sign
			# can never disagree and that assertion was dead. Requiring them
			# PARALLEL asserts something real: that the surface is FLAT shaded.
			# Had the smooth group not taken, the normals would be averaged across
			# neighbouring faces, every dot would fall short of one, and a corpse
			# would render as a balloon rather than as chips off a solid.
			if absf(cross.normalized().dot(n) - _engine_winding_sign()) > 0.01:
				wrong_winding += 1
		enclosed /= 3.0

		var want: float = FragmentShape.cell_volume(profile, cell)
		if enclosed <= 0.0:
			inverted += 1
			continue
		var ratio: float = enclosed / want
		worst = minf(worst, ratio)
		best = maxf(best, ratio)
		# Bigger than its own cell means the surface is not the one that was cut;
		# a long way under means a face is missing and the solid leaks.
		if ratio > 1.001 or ratio < 0.95:
			leaking += 1

	print("[NORMALS] %-12s cells=%d empty=%d inverted=%d leaking=%d bad-winding=%d volume ratio %.4f..%.4f"
		% [str(kind["name"]), cells.size(), empty, inverted, leaking, wrong_winding, worst, best])
	eq(empty, 0, "%s: every fragment produced a mesh" % name)
	eq(inverted, 0, "%s: every fragment's normals point out of it" % name)
	eq(leaking, 0, "%s: every fragment is a closed solid of its cell's volume" % name)
	eq(wrong_winding, 0, "%s: every face is flat shaded and wound the engine's way" % name)

	# AN ARITHMETIC PREDICTION FOR THE ONE SHAPE THAT HAS ONE. A cylinder's
	# profile does not curve, so the ONLY thing the tessellation inscribes is the
	# circle -- and the area of a regular n-gon inscribed in its circle is exactly
	# (n / 2pi) * sin(2pi / n). At ANGLE_STEPS = 32 that is 0.99358, and the mesh
	# has to hit it. This is worth far more than the band above: it is a number
	# nobody chose, it cannot be satisfied by a mesh that is merely close, and it
	# would move if either the angular grid or the closure changed.
	if str(kind["name"]) == "player":
		var n: float = float(FragmentShape.ANGLE_STEPS)
		var predicted: float = (n / TAU) * sin(TAU / n)
		near(worst, predicted, 0.001,
			"%s: a cylinder's fragments enclose exactly the inscribed %d-gon fraction"
				% [name, FragmentShape.ANGLE_STEPS])

# WHICH WAY ROUND GODOT WINDS A FRONT FACE, ASKED OF GODOT.
#
# The first version of this test assumed the right-hand rule and reported every
# fragment of every character wound inside-out -- while the rendered corpses were
# lit correctly and not culled, which is not something an inside-out mesh does.
# The test was wrong, and flipping its sign until it went green would have been
# tuning the instrument to the reading.
#
# So the convention is MEASURED, off a mesh the engine authored itself: a sphere,
# whose outward normal at any vertex is unambiguously its own position. Whatever
# sign relates its winding to its normals is the sign this project's meshes have
# to match, on this engine build, without anybody having to remember which way
# Godot goes.
func _engine_winding_sign() -> float:
	if _winding_sign != 0.0:
		return _winding_sign
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	var arrays: Array = sphere.surface_get_arrays(0)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var agree: int = 0
	var disagree: int = 0
	for tri in _triangles_of(mesh):
		var cross: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
		if cross.length_squared() < 1e-14:
			continue
		# On a unit sphere at the origin the outward direction at a face is its
		# own centroid, so this checks the STORED normals are outward too -- the
		# control has to be able to fail, and a sphere whose normals pointed in
		# would make the whole measurement meaningless.
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

# Triangles as [a, b, c, averaged stored normal]. SurfaceTool may or may not have
# produced an index array, so walk whichever it gave.
#
# ARRAY_INDEX IS NIL, NOT EMPTY, when a surface is unindexed -- and assigning Nil
# to a typed PackedInt32Array RAISES, which aborts the calling function for the
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
