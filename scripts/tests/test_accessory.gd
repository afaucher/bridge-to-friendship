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
		for child in root.get_children():
			var piece := child as MeshInstance3D
			if piece == null or piece.mesh == null:
				continue
			var cone := piece.mesh as CylinderMesh
			if cone == null:
				continue
			var tip: Vector3 = piece.transform * Vector3(0.0, cone.height * 0.5, 0.0)
			var base: Vector3 = piece.position
			checked += 1
			if not check(absf(tip.x) > absf(base.x) + 0.02,
					"%s: a piece leans OUTWARD from where it is attached -- tip x %.3f against base x %.3f"
						% [kind, tip.x, base.x]):
				break
			# Same side of the head it started on. A tilt big enough to cross the
			# centreline would satisfy the magnitude test above while putting the
			# left horn on the right.
			if not check(signf(tip.x) == signf(base.x),
					"%s: and stays on its own side -- tip x %.3f, base x %.3f"
						% [kind, tip.x, base.x]):
				break
		check(checked > 0, "%s had pieces to measure" % kind)
		body.queue_free()

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
# It trails on the aim axis, which makes it a REAR-POINTING facing cue. That is a
# small bonus and a small risk: if it reached further back than the nose reaches
# forward, a player would have two markers and the louder one would be the one
# that means nothing.

func _test_the_tail_is_quieter_than_the_nose() -> void:
	var parts: Array = CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_TAIL)
	if not check(parts.size() == 1, "the tail is one piece"):
		return
	var part: Dictionary = parts[0]
	# Its tip, along the cone's own axis after the tilt.
	var tilt: float = deg_to_rad(float(part["rot"].x))
	var half: float = float(part["length"]) * 0.5
	var tip_z: float = float(part["pos"].z) + half * sin(tilt)
	var reach: float = tip_z - PlayerBody.RADIUS
	check(reach > 0.0, "the tail is visible behind the body at all -- %.3f" % reach)
	check(reach < 0.35,
		"and reaches less far back than the nose reaches forward (0.35) -- %.3f" % reach)

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
