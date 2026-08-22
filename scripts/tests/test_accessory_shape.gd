extends "res://scripts/test_support/test_case.gd"

# THE SHAPE INSTRUMENT: every ratio that describes an accessory, printed on every
# gate run, so two versions can be compared as NUMBERS instead of by remembering
# what the last render looked like.
#
# IT ASSERTS ALMOST NOTHING ON PURPOSE. Its job is to make a shape legible, and a
# threshold guessed today is a threshold that argues with the next redesign --
# this file has already watched three sets of assertions in test_accessory.gd
# become true statements about shapes nobody wanted. What belongs here is the
# measurement; what belongs there is the claim.
#
# It earned its place by catching what six rounds of looking at renders did not:
# that the moose had a MEDIAN BRANCH ANGLE OF 16 DEGREES against the elk's 61,
# which is the difference between a stack of parallel tubes and an antler. That
# number was invisible in every screenshot and obvious the moment it was printed.
#
# It measures the BUILT meshes, not the data -- the same rule the beak taught,
# that a declared position and a rendered one can disagree by a whole rotation.
# Parentage is INFERRED geometrically (a part's parent is whichever other part's
# axis its base sits nearest), because the data does not record it; if the
# inference finds nothing, the structure is not branching at all.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")

const HEAD_W := 0.8         # the body cylinder's diameter -- the reference
const HEAD_H := 1.8

func setup(main) -> void:
	timeout_seconds = 60.0
	for kind in CharacterStyle.ACCESSORIES:
		if kind == CharacterStyle.ACCESSORY_NONE:
			continue
		_report(main, kind)
	finish()

func _report(main, kind: String) -> void:
	var body: Node3D = PlayerScene.instantiate()
	main.add_child(body)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
	var root: Node3D = body.get_node_or_null("Facing/Accessory") as Node3D
	if root == null:
		body.queue_free()
		return

	var pieces: Array = []
	for child in root.get_children():
		var piece := child as MeshInstance3D
		var cone := piece.mesh as CylinderMesh if piece != null else null
		if cone == null:
			continue
		pieces.append({
			"base": piece.transform * Vector3(0.0, -cone.height * 0.5, 0.0),
			"tip": piece.transform * Vector3(0.0, cone.height * 0.5, 0.0),
			"dir": piece.transform.basis.y.normalized(),
			"r0": cone.bottom_radius, "r1": cone.top_radius, "len": cone.height,
		})

	# --- overall box ---------------------------------------------------------
	var span := AABB()
	var first := true
	for child in root.get_children():
		var piece := child as MeshInstance3D
		if piece == null or piece.mesh == null:
			continue
		var box: AABB = piece.transform * piece.mesh.get_aabb()
		span = box if first else span.merge(box)
		first = false

	print("")
	print("=== %s === %d parts" % [kind.to_upper(), pieces.size()])
	print("  box      W %.2f  H %.2f  D %.2f" % [span.size.x, span.size.y, span.size.z])
	print("  vs head  W %.2fx  H %.2fx  D %.2fx   (head is %.2f wide, %.2f tall)"
		% [span.size.x / HEAD_W, span.size.y / HEAD_W, span.size.z / HEAD_W,
			HEAD_W, HEAD_H])
	print("  W:H %.2f   W:D %.2f   H:D %.2f"
		% [span.size.x / maxf(span.size.y, 0.001), span.size.x / maxf(span.size.z, 0.001),
			span.size.y / maxf(span.size.z, 0.001)])

	# --- per segment: how slender, and how thick against the head ------------
	var stubbiest: float = 0.0
	var thinnest: float = INF
	var thickest: float = 0.0
	for p in pieces:
		stubbiest = maxf(stubbiest, p["r0"] / p["len"])
		thinnest = minf(thinnest, p["r0"] * 2.0)
		thickest = maxf(thickest, p["r0"] * 2.0)
	print("  segments thickness/length worst %.3f   thickness %.3f..%.3f (%.2f..%.2f x head)"
		% [stubbiest, thinnest, thickest, thinnest / HEAD_W, thickest / HEAD_W])

	# --- branching: parent inferred as the part whose AXIS passes nearest ----
	#
	# The data does not record parentage, so it is recovered geometrically: a
	# part's parent is whichever OTHER part's axis its base sits closest to. That
	# is exactly the property "a tine starts at a joint of the beam" asserts, so
	# if the inference finds nothing the structure is not branching at all.
	var angles: Array = []
	var tapers: Array = []
	var orphans: int = 0
	for i in pieces.size():
		var me: Dictionary = pieces[i]
		var best: int = -1
		var best_d: float = INF
		for j in pieces.size():
			if i == j:
				continue
			var d: float = _axis_distance(me["base"], pieces[j])
			if d < best_d:
				best_d = d
				best = j
		if best < 0 or best_d > 0.10:
			orphans += 1
			continue
		var parent: Dictionary = pieces[best]
		angles.append(rad_to_deg(parent["dir"].angle_to(me["dir"])))
		tapers.append(me["r0"] / maxf(parent["r0"], 0.001))

	if angles.is_empty():
		print("  branching: NONE -- no part starts on another part's axis")
	else:
		angles.sort()
		tapers.sort()
		print("  branching: %d joined, %d free-standing" % [angles.size(), orphans])
		print("    branch angle  min %.0f  median %.0f  max %.0f degrees"
			% [angles[0], angles[angles.size() / 2], angles[angles.size() - 1]])
		print("    taper (child radius / parent radius)  min %.2f  median %.2f  max %.2f"
			% [tapers[0], tapers[tapers.size() / 2], tapers[tapers.size() - 1]])
	body.queue_free()

# Distance from a point to a part's axis SEGMENT (not the infinite line).
func _axis_distance(at: Vector3, part: Dictionary) -> float:
	var a: Vector3 = part["base"]
	var b: Vector3 = part["tip"]
	var span: Vector3 = b - a
	var t: float = clampf((at - a).dot(span) / maxf(span.length_squared(), 0.0001), 0.0, 1.0)
	return (at - (a + span * t)).length() - part["r0"]
