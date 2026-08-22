extends "res://scripts/test_support/test_case.gd"

# The facing marker's SHAPE, measured where the player actually sees it.
#
# player.tscn is explicit that the nose is not decoration: the shove commits to
# one of four compass axes chosen at the instant of the press, so a player has to
# know which axis they are on BEFORE they commit, and a featureless cylinder
# cannot tell them. That makes every change to this mesh a change to a control.
#
# THE MEASURED PROPERTY IS PROTRUSION PAST THE BODY, NOT SIZE. The camera frames
# 60 m of bridge from above, where the body is a CIRCLE of radius 0.4 -- so the
# only part of the marker that says anything is the part outside that circle.
# A nose can be made bigger, look better in a close-up, and read as nothing.
# See design_ideas/character_customization.md.
#
# It has a FLOOR as well as a ceiling, and the floor is the half that catches the
# real bug. The ceiling is only about honesty toward the collider (contract rule
# 3); the floor is the whole feature working.
#
# AND IT MEASURES THE TRANSFORMED MESH RATHER THAN THE MESH. The beak's apex is
# +Y in its own space and the node turns it -90 degrees about X to aim it
# forward, which is nine hand-written numbers in a .tscn -- the Godot Basis trap
# CLAUDE.md has already paid for twice, once on a bullet tail and once on a
# muzzle offset. A test that read `mesh.size` would pass with the marker pointing
# at the sky. Writing this caught exactly that class of error on its first run,
# though in the test's own arithmetic rather than in the scene.
#
# AN AABB CANNOT TELL A BEAK FROM A BOX -- the bounding volume of a prism is the
# box it was cut from, so every extent assertion below passes just as well
# against the wedge this replaced. The taper is therefore asserted from the
# VERTICES, and that is the only claim here that is about the new shape rather
# than about the budget it had to stay inside.

const PlayerScene = preload("res://scenes/player.tscn")

# From player.tscn's CylinderShape3D. The silhouette the marker has to break.
const BODY_RADIUS := 0.4

# The budget, from the design doc's catalogue. The wedge this replaced protruded
# 0.35, which is the one value with a proven read -- so it sits between these by
# construction rather than by luck.
const PROTRUSION_MIN := 0.28
const PROTRUSION_MAX := 0.40

# How near an extreme a vertex has to be to count as sitting on it.
const BAND := 0.02

func setup(_main) -> void:
	var player: Node3D = PlayerScene.instantiate()
	add_child(player)

	var nose := player.get_node_or_null("Facing/Nose") as MeshInstance3D
	if not check(nose != null, "player.tscn still has a Facing/Nose"):
		finish()
		return
	if not check(nose.mesh != null, "the nose has a mesh"):
		finish()
		return

	# In the FACING pivot's space, which is the space the yaw is written in --
	# _point_nose writes Facing.rotation.y and nothing else, so -Z here is
	# forward for every yaw the player can hold.
	var box: AABB = nose.transform * nose.mesh.get_aabb()

	# Forward is -Z, so the FRONT of the marker is the AABB's MINIMUM z and its
	# back is the maximum. Both are reported as positive distances forward of the
	# body's centre, which is the only form in which they are comparable to
	# BODY_RADIUS.
	var tip: float = -box.position.z
	var rear: float = -(box.position.z + box.size.z)

	_test_points_forward(tip, rear)
	_test_protrusion(tip)
	_test_asymmetric(tip, rear)
	_test_keeps_its_height(box)
	_test_tapers(nose)
	finish()

# --- 1. It points forward at all ----------------------------------------------
#
# The claim the Basis numbers can silently break. A marker rotated into +Y is
# still 0.5 m long, still triangular, and points at the sky.

func _test_points_forward(tip: float, rear: float) -> void:
	check(tip > rear, "the nose extends toward -Z, which is forward")
	near(tip, 0.75, 0.001, "the tip sits at z = -0.75, where the old wedge's face was")

# --- 2. The budget, floor and ceiling -----------------------------------------

func _test_protrusion(tip: float) -> void:
	var protrusion: float = tip - BODY_RADIUS
	check(protrusion >= PROTRUSION_MIN,
		"the nose clears the body by at least %.2f m, or it says nothing from the camera -- got %.3f"
			% [PROTRUSION_MIN, protrusion])
	check(protrusion <= PROTRUSION_MAX,
		"and by no more than %.2f m, so it overhangs no further than the shape it replaced -- got %.3f"
			% [PROTRUSION_MAX, protrusion])

# --- 3. It is a marker and not a hat ------------------------------------------
#
# A shape symmetric about the body's centre indicates no direction whatever it is
# made of. Cheap, and the one property no nose may ever lose.

func _test_asymmetric(tip: float, rear: float) -> void:
	check(rear > 0.0, "the nose lies in front of the body's centre rather than straddling it")
	check(tip > rear, "and reaches further forward than back, so it is asymmetric about -Z")

# --- 4. The side view keeps its mass ------------------------------------------
#
# The reason this is a PRISM and not a cone. A cone tapers in both axes: pointier
# from above and thinner from the side, so it wins the arrow and loses the
# visibility, and nothing in the top-down assertions above can see that. Assert
# the height the old wedge had.

func _test_keeps_its_height(box: AABB) -> void:
	near(box.size.y, 0.3, 0.001, "the nose is still 0.3 m tall in side view")
	near(box.size.x, 0.3, 0.001, "and still 0.3 m across at its base")

# --- 5. It is actually a beak -------------------------------------------------
#
# THE ONLY ASSERTION HERE THAT THE OLD WEDGE WOULD FAIL. Everything above is
# about the box the shape has to live inside, and a box passes all of it. What
# makes this a beak is that its width goes to nothing at the front while keeping
# full width at the back -- which is what turns the plan view from a square tab
# into an arrow.

func _test_tapers(nose: MeshInstance3D) -> void:
	var arrays: Array = nose.mesh.surface_get_arrays(0)
	var raw: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if not check(raw.size() > 0, "the nose mesh has vertices to measure"):
		return

	var verts: Array[Vector3] = []
	var min_z: float = INF
	var max_z: float = -INF
	for v in raw:
		var p: Vector3 = nose.transform * v
		verts.append(p)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)

	var front: float = _x_spread(verts, min_z)
	var back: float = _x_spread(verts, max_z)

	near(back, 0.3, 0.01, "the beak is full width where it meets the body")
	check(front < back * 0.25,
		"and narrows to a point at the tip -- front spread %.3f against %.3f at the base (a box would tie)"
			% [front, back])

# How wide the mesh is across X among the vertices sitting at a given z.
func _x_spread(verts: Array[Vector3], at_z: float) -> float:
	var lo: float = INF
	var hi: float = -INF
	for p in verts:
		if absf(p.z - at_z) <= BAND:
			lo = minf(lo, p.x)
			hi = maxf(hi, p.x)
	return 0.0 if lo == INF else hi - lo
