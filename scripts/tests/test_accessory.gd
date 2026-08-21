extends "res://scripts/test_support/test_case.gd"

# The accessory slot: horns, antlers, a tail, or nothing.
#
# THIS FEATURE'S WHOLE CLAIM IS THAT IT CHANGES NOTHING BUT THE PICTURE, so most
# of this file is about what an accessory must NOT do. Two rules carry it, and
# both are ones a "does it appear?" test passes while they are broken:
#
#   1. NO COLLIDER. art_direction.md's contract rule 3 allows decorative overhang
#      exactly where nothing collides. A tail that catches a dash is a cosmetic
#      that changed a fight, and a horn you can stand on is the "hat you can
#      stand on is a ladder" note from player.tscn.
#   2. NO EFFECT ON THE HAT TOWER. A hat's slot is a hit column -- a round travels
#      flat at the height of the muzzle that fired it, so anything that moves the
#      tower moves what a shooter meets first. That is a gameplay effect bought
#      with a cosmetic, which is the line this whole feature sits on the far side
#      of.
#
# And one about the picture itself: the SPREAD CEILING. It is the mirror of the
# nose's protrusion floor -- the nose must break the body's top-down circle to
# say anything, and an accessory must not break it so badly that a player stops
# reading as a player.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const HatPool = preload("res://scripts/sim/hat_pool.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

func setup(main) -> void:
	_test_every_kind_builds(main)
	_test_nothing_collides(main)
	_test_spread_ceiling(main)
	_test_horns_point_outward(main)
	_test_antlers_branch()
	_test_switching_replaces(main)
	_test_none_is_nothing(main)
	_test_unknown_names_wear_nothing(main)
	_test_the_tail_is_quieter_than_the_nose()
	_test_hat_tower_unmoved(main)
	finish()

func _fresh(main) -> Node3D:
	var body: Node3D = PlayerScene.instantiate()
	main.add_child(body)
	return body

func _accessory_root(body: Node3D) -> Node3D:
	return body.get_node_or_null("Facing/Accessory") as Node3D

# --- 1. Each one is actually drawn --------------------------------------------
#
# A weapon that is mechanically perfect and invisible passes a mechanics suite --
# CLAUDE.md, on three guns that shipped as a floating barrel. Same trap here.

func _test_every_kind_builds(main) -> void:
	for kind in [CharacterStyle.ACCESSORY_HORNS, CharacterStyle.ACCESSORY_ANTLERS, CharacterStyle.ACCESSORY_TAIL]:
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if not check(root != null, "%s builds an accessory node" % kind):
			continue
		var meshes: int = 0
		for child in root.get_children():
			if child is MeshInstance3D and child.mesh != null:
				meshes += 1
		check(meshes == CharacterStyle.accessory_parts(kind).size(),
			"%s draws every part it declares -- %d of %d"
				% [kind, meshes, CharacterStyle.accessory_parts(kind).size()])
		body.queue_free()

# --- 2. NOTHING COLLIDES -------------------------------------------------------
#
# Asserted over the whole subtree rather than at the root, because the failure
# would be one part with a shape on it and not the parent.

func _test_nothing_collides(main) -> void:
	for kind in CharacterStyle.ACCESSORIES:
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if root == null:
			body.queue_free()
			continue
		check(_collider_count(root) == 0,
			"%s is mesh and nothing else -- found %d colliders" % [kind, _collider_count(root)])
		body.queue_free()

func _collider_count(node: Node) -> int:
	var found: int = 0
	if node is CollisionShape3D or node is CollisionObject3D:
		found += 1
	for child in node.get_children():
		found += _collider_count(child)
	return found

# --- 3. The spread ceiling -----------------------------------------------------
#
# MEASURED FROM THE BUILT MESHES, not from the numbers that were fed in. That is
# the lesson the beak taught in this same feature: the declared position and the
# rendered position disagreed by a whole rotation, and every assertion about the
# inputs passed. So this transforms each part's own AABB and reads the extremes.

func _test_spread_ceiling(main) -> void:
	for kind in CharacterStyle.ACCESSORIES:
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if root == null:
			body.queue_free()
			continue
		var widest: float = 0.0
		for child in root.get_children():
			var piece := child as MeshInstance3D
			if piece == null or piece.mesh == null:
				continue
			var box: AABB = piece.transform * piece.mesh.get_aabb()
			widest = maxf(widest, maxf(absf(box.position.x), absf(box.position.x + box.size.x)))
		check(widest <= CharacterStyle.ACCESSORY_SPREAD_MAX,
			"%s stays inside the spread ceiling -- %.3f against %.2f"
				% [kind, widest, CharacterStyle.ACCESSORY_SPREAD_MAX])
		body.queue_free()

# --- 3b. THEY SPLAY OUTWARD ---------------------------------------------------
#
# THIS ASSERTION EXISTS BECAUSE ITS FIRST VERSION WAS WORTHLESS, and the A/B is
# the only thing that showed it.
#
# It originally checked that the widest point exceeded 0.3, and passed with the
# horn tilt REVERSED -- because a horn attached at x = 0.26 with a radius of
# 0.075 already reaches 0.335 before it is tilted at all. The number was
# satisfied by the mounting point, so the test agreed with whatever direction the
# horns leaned.
#
# The claim is about DIRECTION, so it has to be measured as one: each piece's tip
# against its own base. A cone's tip is at +length/2 along its own Y, so pushing
# that through the built node's transform gives where the point actually ended
# up -- the beak's lesson, that a rotation is only ever verified by measuring
# what came out of it.
func _test_horns_point_outward(main) -> void:
	for kind in [CharacterStyle.ACCESSORY_HORNS, CharacterStyle.ACCESSORY_ANTLERS]:
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if not check(root != null, "%s built something to measure" % kind):
			continue
		var checked: int = 0
		var outermost: float = 0.0
		var attach: float = 999.0
		for child in root.get_children():
			var piece := child as MeshInstance3D
			if piece == null or piece.mesh == null:
				continue
			var cone := piece.mesh as CylinderMesh
			if cone == null:
				continue
			var tip: Vector3 = piece.transform * Vector3(0.0, cone.height * 0.5, 0.0)
			var base: Vector3 = piece.transform * Vector3(0.0, -cone.height * 0.5, 0.0)
			checked += 1
			outermost = maxf(outermost, absf(tip.x))
			attach = minf(attach, absf(base.x))
			# EVERY piece stays on its own side of the head. A rack that crossed
			# the centreline would put the left antler on the right, and a
			# magnitude test alone cannot see that.
			if not check(signf(tip.x) == signf(base.x) or is_zero_approx(tip.x),
					"%s: a piece stays on its own side -- tip x %.3f, base x %.3f"
						% [kind, tip.x, base.x]):
				break
		check(checked > 0, "%s had pieces to measure" % kind)

		# THE OUTWARD CLAIM IS ABOUT THE WHOLE STRUCTURE, NOT EACH PIECE, and that
		# is a correction. It used to be asserted per-part, which was right for
		# horns and wrong for a real rack: an elk beam FLATTENS as it sweeps back,
		# so its last segments barely move outward at all, and the G5 tine is a
		# short spike that mostly goes up. Demanding every piece lean outward
		# would have forbidden the anatomy.
		check(outermost > attach + 0.15,
			"%s reaches well outside where it is attached -- %.3f against %.3f"
				% [kind, outermost, attach])
		body.queue_free()

# --- 3c. THE ANTLERS ACTUALLY BRANCH -----------------------------------------
#
# THE ASSERTION FOR THE FAULT THAT WAS REPORTED, and nothing before it could have
# caught it. The rack was "cones whose tip intersects the middle of the next",
# which is two separate problems:
#
#   * the BEAM was a couple of independent cones that happened to overlap, rather
#     than one tapering stalk;
#   * the TINES were placed at eyeballed points that crossed the beam mid-span,
#     so they pierced it instead of growing out of it.
#
# Both are geometry, so both are measurable. The beam must chain -- every
# segment's end is the next one's start, at the same thickness -- and every tine
# must have its BASE somewhere ON that chain.

const ANTLER_BEAM_PARTS := 4
const ANTLER_PARTS_PER_SIDE := 9

func _test_antlers_branch() -> void:
	var parts: Array = CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_ANTLERS)
	if not check(parts.size() == ANTLER_PARTS_PER_SIDE * 2,
			"a rack is %d parts a side -- got %d total" % [ANTLER_PARTS_PER_SIDE, parts.size()]):
		return

	# One side is enough: the other is the same numbers with x negated, which
	# _test_horns_point_outward already covers by sweeping every piece.
	var side: Array = parts.slice(0, ANTLER_PARTS_PER_SIDE)

	# --- the beam is a chain ---
	var joints: Array[Vector3] = [_base_of(side[0])]
	for i in ANTLER_BEAM_PARTS:
		joints.append(_tip_of(side[i]))
	for i in range(ANTLER_BEAM_PARTS - 1):
		var a: Dictionary = side[i]
		var b: Dictionary = side[i + 1]
		if not check(_tip_of(a).distance_to(_base_of(b)) < 0.01,
				"beam segment %d ends where %d starts -- %s against %s"
					% [i, i + 1, _tip_of(a), _base_of(b)]):
			return
		near(float(b["radius"]), float(a.get("tip", 0.0)), 0.001,
			"and is the same thickness at the join, so the beam tapers rather than steps")

	# --- every tine grows OUT of the beam rather than through it ---
	#
	# Measured as the distance from the tine's base to the beam polyline. Inside
	# the beam's own thickness means it emerges from the stalk; further out means
	# it is a floating spike, and crossing it mid-span is what "intersects the
	# middle of the next" looked like.
	for i in range(ANTLER_BEAM_PARTS, ANTLER_PARTS_PER_SIDE):
		var tine: Dictionary = side[i]
		var base: Vector3 = _base_of(tine)
		var nearest: float = 999.0
		for j in range(joints.size() - 1):
			var closest: Vector3 = Geometry3D.get_closest_point_to_segment(base, joints[j], joints[j + 1])
			nearest = minf(nearest, base.distance_to(closest))
		if not check(nearest < 0.02,
				"tine %d is attached to the beam -- its base sits %.3f away from it" % [i, nearest]):
			return

	# --- and the shape is elk rather than a bush ---
	#
	# The two proportions that make a rack identifiable, from Boone and Crockett's
	# field-judging description. Without them this is a branching structure that
	# could be any deer.
	var brow: Dictionary = side[ANTLER_BEAM_PARTS]
	check((brow["dir"] as Vector3).z < -0.5,
		"the brow tine points FORWARD over the face -- the one part that goes the other way")
	var royal: Dictionary = side[ANTLER_BEAM_PARTS + 3]
	check((royal["dir"] as Vector3).normalized().y > 0.8,
		"the royal tine goes up off the top of the beam")
	for i in range(ANTLER_BEAM_PARTS + 1, ANTLER_PARTS_PER_SIDE):
		if i == ANTLER_BEAM_PARTS + 3:
			continue
		check(float(royal["length"]) >= float(side[i]["length"]),
			"and is the longest point on the rack -- %.2f against %.2f at part %d"
				% [float(royal["length"]), float(side[i]["length"]), i])

	# The beam still sweeps BACK, which is the thing the flat version had none of.
	check(_tip_of(side[ANTLER_BEAM_PARTS - 1]).z > 0.6,
		"and the beam sweeps back over the shoulders -- %.3f" % _tip_of(side[ANTLER_BEAM_PARTS - 1]).z)

func _base_of(part: Dictionary) -> Vector3:
	return (part["pos"] as Vector3) - (part["dir"] as Vector3).normalized() * (float(part["length"]) * 0.5)

func _tip_of(part: Dictionary) -> Vector3:
	return (part["pos"] as Vector3) + (part["dir"] as Vector3).normalized() * (float(part["length"]) * 0.5)

# --- 4. One at a time ----------------------------------------------------------
#
# Accessories are exclusive, so switching has to REMOVE what was there. Growing
# the node list in place is how a player ends up wearing antlers and horns, and
# the only test that catches it is one that switches.

func _test_switching_replaces(main) -> void:
	var body: Node3D = _fresh(main)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_ANTLERS)
	var after_antlers: int = _accessory_root(body).get_child_count()
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_HORNS)
	var after_horns: int = _accessory_root(body).get_child_count()
	eq(after_antlers, CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_ANTLERS).size(),
		"antlers build their own parts")
	eq(after_horns, CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_HORNS).size(),
		"and switching to horns leaves ONLY horns -- not both")
	body.queue_free()

func _test_none_is_nothing(main) -> void:
	var body: Node3D = _fresh(main)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_HORNS)
	check(_accessory_root(body) != null, "horns are there to be taken off")
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_NONE)
	check(_accessory_root(body) == null, "and choosing none removes them entirely")
	body.queue_free()

# --- 5. A name off the wire cannot be anything --------------------------------
#
# The kind is stored and replicated as a NAME so reordering the list cannot remap
# saved characters. The price is that a file or a packet can name something this
# build has never heard of, and wearing nothing is the right answer to that.

func _test_unknown_names_wear_nothing(main) -> void:
	var body: Node3D = _fresh(main)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, "wings")
	check(_accessory_root(body) == null, "an unknown accessory name wears nothing rather than raising")
	check(not CharacterStyle.is_accessory("wings"), "and is not accepted as a kind")
	check(CharacterStyle.is_accessory(CharacterStyle.ACCESSORY_TAIL), "while a real one is")
	body.queue_free()

# --- 6. The tail does not out-shout the nose ----------------------------------
#
# It trails on the aim axis, which makes it a REAR-POINTING facing cue -- a small
# bonus and a small risk, since a player with two markers reads the louder one.
#
# THIS RULE WAS ORIGINALLY ABOUT LENGTH AND IT WAS THE WRONG QUESTION. It said
# the tail must reach less far back than the nose reaches forward (0.35), which
# sounds sober and is a rule no tail worth having can satisfy -- played, the
# 0.26-reach tail that passed it was reported as "probably 5x too short and
# thin".
#
# What actually keeps the marker the marker is CONTRAST, not size. The nose sits
# a full 0.35 from the body in luminance and an accessory only 0.18, so however
# long the tail gets, the eye still goes to the beak. That is the relationship
# worth pinning, and unlike the length rule it is one the design can grow into.

func _test_the_tail_is_quieter_than_the_nose() -> void:
	var parts: Array = CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_TAIL)
	if not check(parts.size() >= 4, "the tail is segmented -- %d parts" % parts.size()):
		return

	# --- it curves UP ---
	#
	# The claim the segments exist to make. The first segment leaves the rump
	# heading DOWN and the last one is heading UP, and every step in between turns
	# further up than the one before it -- a monotonic sweep rather than a kink.
	var first: Vector3 = (parts[0]["dir"] as Vector3).normalized()
	var last: Vector3 = (parts[parts.size() - 1]["dir"] as Vector3).normalized()
	check(first.y < 0.0, "the tail leaves the body heading down -- %.3f" % first.y)
	check(last.y > 0.6, "and finishes heading up -- %.3f" % last.y)
	for i in range(1, parts.size()):
		var prev: Vector3 = (parts[i - 1]["dir"] as Vector3).normalized()
		var here: Vector3 = (parts[i]["dir"] as Vector3).normalized()
		if not check(here.y > prev.y,
				"segment %d turns further up than the one before it -- %.3f after %.3f"
					% [i, here.y, prev.y]):
			return

	# --- the segments actually join ---
	#
	# The positions are a chain worked out by hand, so this is the assertion that
	# catches an arithmetic slip: each segment's END must be the next one's START,
	# and its tip radius must be the next one's base. Either mismatch shows up in
	# game as a tail with gaps or steps in it, which reads as broken rather than
	# as a shape somebody chose.
	for i in range(parts.size() - 1):
		var a: Dictionary = parts[i]
		var b: Dictionary = parts[i + 1]
		var a_end: Vector3 = (a["pos"] as Vector3) + (a["dir"] as Vector3).normalized() * (float(a["length"]) * 0.5)
		var b_start: Vector3 = (b["pos"] as Vector3) - (b["dir"] as Vector3).normalized() * (float(b["length"]) * 0.5)
		if not check(a_end.distance_to(b_start) < 0.01,
				"segment %d ends where %d starts -- %s against %s" % [i, i + 1, a_end, b_start]):
			return
		near(float(b["radius"]), float(a.get("tip", 0.0)), 0.001,
			"and is the same thickness at the join, so it tapers rather than steps")

	# --- it reads from the game camera ---
	var tip: Vector3 = (parts[parts.size() - 1]["pos"] as Vector3) \
		+ last * (float(parts[parts.size() - 1]["length"]) * 0.5)
	check(tip.z - PlayerBody.RADIUS > 0.35,
		"the tail is long enough to see from the bridge camera -- %.3f behind the body"
			% (tip.z - PlayerBody.RADIUS))

	# --- and never drags through the deck ---
	#
	# The body origin is HALF_HEIGHT above the feet, so anything below
	# -HALF_HEIGHT is underground. Checked at every segment rather than at the
	# tip, because the tail now curves: its LOWEST point is in the middle.
	for part in parts:
		var low: float = float(part["pos"].y) - float(part["radius"])
		if not check(low > -PlayerBody.HALF_HEIGHT + 0.15,
				"every segment hangs clear of the deck -- %.3f against feet at %.3f"
					% [low, -PlayerBody.HALF_HEIGHT]):
			return

	# --- and it wears the marker's colour ---
	#
	# Decided from play: the accessory and the nose share one colour so they read
	# as the character's trim. This replaces an earlier rule that the nose had to
	# out-contrast the accessory, which was protecting against a confusion that
	# does not happen -- opposite ends of the body, completely different shapes.
	for i in 12:
		var body := Color.from_hsv(float(i) / 12.0, 0.7, 0.55)
		if not check(CharacterStyle.accessory_colour(body) == CharacterStyle.nose_colour(body),
				"the accessory wears the nose's colour"):
			return

# --- 7. THE HAT TOWER IS UNTOUCHED --------------------------------------------
#
# The claim that keeps this a cosmetic. Asserted by posing a real stack on a real
# body with and without antlers -- the widest, tallest accessory -- and comparing
# where the hats end up.
#
# It is structurally true today, because pose_stack mounts at
# PlayerBody.HALF_HEIGHT, a constant. That is exactly why it is worth asserting:
# the day somebody makes the mount derived, this is what notices.

func _test_hat_tower_unmoved(main) -> void:
	# A RefCounted, not a Node -- it holds hats but is not itself in the tree, and
	# it is told where to parent them.
	var pool: HatPool = HatPool.new()
	pool.attach(main)
	var body: Node3D = _fresh(main)
	body.position = Vector3.ZERO
	body.peer_id = 1

	# A real three-hat stack, worn the way the game wears them.
	for i in 3:
		var hat: Node = pool.spawn_loose(Vector3(0.0, 5.0, 0.0), 100 + i)
		hat.wear(1, i)

	var bare: Array = _stack_heights(pool, body, CharacterStyle.ACCESSORY_NONE)
	var horned: Array = _stack_heights(pool, body, CharacterStyle.ACCESSORY_ANTLERS)
	if not check(bare.size() == 3 and horned.size() == 3,
			"both runs posed three hats -- got %d and %d" % [bare.size(), horned.size()]):
		return

	for i in bare.size():
		near(horned[i], bare[i], 0.0001,
			"hat %d sits at the same height with antlers on as without" % i)

	# AND THE COMPARISON HAS TO BE ABLE TO FAIL. Three identical numbers prove
	# nothing if the tower never had any height to it -- the hats must actually be
	# stacked, or "unchanged" is a claim about a stack that was never posed.
	check(bare[1] > bare[0] and bare[2] > bare[1],
		"and the hats really are stacked, so an equal comparison means something -- %.3f, %.3f, %.3f"
			% [bare[0], bare[1], bare[2]])

func _stack_heights(pool: HatPool, body: Node3D, kind: String) -> Array:
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
	pool.pose_stack(1, body, PlayerBody.HALF_HEIGHT, 0.0)
	var out: Array = []
	for hat in pool.worn_by(1):
		out.append(hat.global_position.y)
	return out
