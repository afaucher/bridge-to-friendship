extends "res://scripts/test_support/test_case.gd"

# The accessory slot: horns, antlers, a moose rack, a tail, a shrimp tail, or nothing.
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

const CharacterStyle = preload("res://scripts/present/models/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const HatPool = preload("res://scripts/sim/items/hat_pool.gd")
const PlayerBody = preload("res://scripts/sim/actors/player/player_body.gd")
const TailFire = preload("res://scripts/present/vfx/tail_fire.gd")

func setup(main) -> void:
	_test_every_kind_builds(main)
	_test_nothing_collides(main)
	_test_spread_ceiling(main)
	_test_horns_point_outward(main)
	_test_antlers_branch()
	_test_the_moose_is_one_root(main)
	_test_every_limb_is_two_chained_segments(main)
	_test_the_tines_lift(main)
	_test_the_brow_is_in_front(main)
	_test_it_sits_low_and_goes_out(main)
	_test_the_moose_is_not_the_elk(main)
	_test_it_grows_from_the_surface(main)
	_test_switching_replaces(main)
	_test_none_is_nothing(main)
	_test_unknown_names_wear_nothing(main)
	_test_the_tail_is_quieter_than_the_nose()
	_test_the_shrimp_is_plated_and_fanned()
	_test_the_shrimp_tail_burns_at_one_tip(main)
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
	for kind in [CharacterStyle.ACCESSORY_HORNS, CharacterStyle.ACCESSORY_ANTLERS,
			CharacterStyle.ACCESSORY_TAIL, CharacterStyle.ACCESSORY_SHRIMP]:
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
	for kind in [CharacterStyle.ACCESSORY_HORNS, CharacterStyle.ACCESSORY_ANTLERS,
			CharacterStyle.ACCESSORY_MOOSE]:
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

# --- 6b. THE SHRIMP TAIL: PLATES AND A FAN ------------------------------------
#
# What separates it from the tail, as structure. Each claim is one the plain tail
# would FAIL, which is the point: two accessories that pass the same assertions
# are the same accessory in two sizes.
#
#   1. THE SHELL IS PLATES. Every join has a LIP -- the next plate starts
#      narrower than the one before it ends -- and no GAP: it starts inside the
#      plate before it. The tail asserts the opposite (matching radii), because a
#      tail is one stalk and this is armour.
#   2. THE BACK ARCHES: plates rise off the rump, then fall into the fan.
#   3. THE FAN IS PADDLES, NOT SPIKES: each blade is two chained cones that
#      swell from the root and come to a point -- a leaf.
#   4. THE FAN SPREADS AND LIES FLAT, which is the reading from a camera that
#      looks down at 45 degrees. Spread is measured against the shell's own
#      width, so "wide" means wider than the thing it hangs off.

const SHRIMP_PLATES := 6

func _test_the_shrimp_is_plated_and_fanned() -> void:
	var parts: Array = CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_SHRIMP)
	if not check(parts.size() > SHRIMP_PLATES, "the shrimp tail has a shell and a fan -- %d parts"
			% parts.size()):
		return
	var plates: Array = parts.slice(0, SHRIMP_PLATES)
	var blades: Array = parts.slice(SHRIMP_PLATES)

	# --- 1. plates: a lip at every join, and no gap ---
	var widest_plate: float = 0.0
	for i in range(SHRIMP_PLATES):
		widest_plate = maxf(widest_plate, maxf(float(plates[i]["radius"]), float(plates[i].get("tip", 0.0))))
	for i in range(SHRIMP_PLATES - 1):
		var a: Dictionary = plates[i]
		var b: Dictionary = plates[i + 1]
		check(float(b["radius"]) < float(a.get("tip", 0.0)) - 0.01,
			"plate %d starts narrower than plate %d ends, so the join is a lip -- %.3f against %.3f"
				% [i + 1, i, float(b["radius"]), float(a.get("tip", 0.0))])
		var start: Vector3 = _base_of(b)
		var a_base: Vector3 = _base_of(a)
		var a_end: Vector3 = _tip_of(a)
		# Inside plate a: between its two ends along its own axis, and close to it.
		var axis: Vector3 = (a["dir"] as Vector3).normalized()
		var along: float = (start - a_base).dot(axis)
		var off_axis: float = ((start - a_base) - axis * along).length()
		check(along > 0.0 and along < float(a["length"]) and off_axis < 0.01,
			"plate %d starts INSIDE plate %d, so there is no gap -- %.3f along a %.2f plate, %.3f off it"
				% [i + 1, i, along, float(a["length"]), off_axis])
		check(start.distance_to(a_end) < 0.06,
			"and only just inside -- %.3f from its end" % start.distance_to(a_end))

	# --- 2. the back arches ---
	var first: Vector3 = (plates[0]["dir"] as Vector3).normalized()
	var last: Vector3 = (plates[SHRIMP_PLATES - 1]["dir"] as Vector3).normalized()
	check(first.y > 0.3, "the shell rises off the rump -- %.3f" % first.y)
	check(last.y < -0.3, "and falls into the fan -- %.3f" % last.y)
	for i in range(1, SHRIMP_PLATES):
		var prev: Vector3 = (plates[i - 1]["dir"] as Vector3).normalized()
		var here: Vector3 = (plates[i]["dir"] as Vector3).normalized()
		check(here.y < prev.y, "plate %d bends further down than the one before -- %.3f after %.3f"
			% [i, here.y, prev.y])

	# --- 3. every blade is a leaf ---
	if not check(blades.size() >= 6 and blades.size() % 2 == 0,
			"the fan is blades of two segments each -- %d parts" % blades.size()):
		return
	var tips: Array = []
	for j in range(0, blades.size(), 2):
		var root: Dictionary = blades[j]
		var point: Dictionary = blades[j + 1]
		check(float(root.get("tip", 0.0)) > float(root["radius"]) * 1.5,
			"blade %d swells from its root -- %.3f to %.3f"
				% [j / 2, float(root["radius"]), float(root.get("tip", 0.0))])
		near(float(point["radius"]), float(root.get("tip", 0.0)), 0.001,
			"and its point starts as broad as the swell ends")
		check(float(point.get("tip", 0.0)) == 0.0, "and comes to a point")
		check(_tip_of(root).distance_to(_base_of(point)) < 0.01,
			"blade %d is one leaf, not two pieces" % [j / 2])
		tips.append(_tip_of(point))
		# --- 4a. flat: no blade stands up or hangs down ---
		var d: Vector3 = (point["dir"] as Vector3).normalized()
		check(absf(d.y) < 0.3, "blade %d lies flat enough to read from above -- %.3f" % [j / 2, d.y])

	# --- 4b. it spreads: tips span well beyond the shell, on both sides ---
	var left: float = 0.0
	var right: float = 0.0
	for t in tips:
		left = minf(left, (t as Vector3).x)
		right = maxf(right, (t as Vector3).x)
	check(right > widest_plate * 1.5 and -left > widest_plate * 1.5,
		"the fan spreads well outside the shell on both sides -- %.3f / %.3f against a shell %.3f wide"
			% [left, right, widest_plate])
	near(right, -left, 0.01, "and symmetrically")

	# --- and like the tail: long enough to see, clear of the deck ---
	var reach: float = 0.0
	for part in parts:
		reach = maxf(reach, _tip_of(part).z)
		var low: float = float(part["pos"].y) - maxf(float(part["radius"]), float(part.get("tip", 0.0)))
		check(low > -PlayerBody.HALF_HEIGHT + 0.15,
			"every part hangs clear of the deck -- %.3f against feet at %.3f" % [low, -PlayerBody.HALF_HEIGHT])
	check(reach - PlayerBody.RADIUS > 0.35,
		"long enough to see from the bridge camera -- %.3f behind the body" % (reach - PlayerBody.RADIUS))

# --- 6c. AND IT BURNS, AT ONE TIP, TO ONE SIDE -------------------------------
#
# A small fire at the point of the outer fan blade on one side: a glowing core,
# the flame, and a wisp of black smoke. Claims, each about the BUILT tree rather
# than the declared data:
#
#   1. EXACTLY ONE FIRE, and only on the shrimp tail.
#   2. AT A TIP, TO ONE SIDE: its position is the point of the blade reaching
#      furthest out on its side, so a reordered part list cannot move it onto the
#      shell, the telson or the inner blade and still pass.
#   3. THREE LAYERS, EACH REALLY DRAWN: a mesh, a colour ramp and a size curve
#      on every one. A wrong CPUParticles3D property name is a runtime error that
#      aborts the build silently, which is the swallow's bubbles twice over.
#   4. THE LAYERS ARE WHAT THEY ARE FOR: the core glows (additive) and the flame
#      does not, so it still reads on a pale deck; the flame shrinks as it rises
#      and the smoke GROWS; the smoke is dark, outlives the flame, starts above
#      it, and draws behind it.
#   5. SWITCHING PUTS IT OUT -- it belongs to the accessory, not the body.

func _fires_under(node: Node) -> Array:
	var found: Array = []
	for child in node.get_children():
		if child.name == "Fire":
			found.append(child)
		else:
			found.append_array(_fires_under(child))
	return found

func _emitters_under(node: Node) -> int:
	var n: int = 0
	for child in node.get_children():
		if child is CPUParticles3D:
			n += 1
		n += _emitters_under(child)
	return n

func _layer(fire: Node, label: String) -> CPUParticles3D:
	return fire.get_node_or_null(label) as CPUParticles3D

func _test_the_shrimp_tail_burns_at_one_tip(main) -> void:
	for kind in CharacterStyle.ACCESSORIES:
		var other: Node3D = _fresh(main)
		other.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var burning: bool = kind == CharacterStyle.ACCESSORY_SHRIMP
		eq(_fires_under(other).size(), 1 if burning else 0,
			"%s %s" % [kind, "burns once" if burning else "does not burn"])
		if not burning:
			eq(_emitters_under(other), 0, "and %s has no particles anywhere" % kind)
		other.queue_free()

	var body: Node3D = _fresh(main)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_SHRIMP)
	var root: Node3D = _accessory_root(body)
	var fires: Array = _fires_under(body)
	if not check(root != null and fires.size() == 1, "the shrimp tail has its fire to measure"):
		body.queue_free()
		return
	var fire: Node3D = fires[0]
	check(fire.get_parent() == root, "and it hangs off the accessory, so it turns with the aim")

	# --- 2. at the outermost blade point on its side ---
	var parts: Array = CharacterStyle.accessory_parts(CharacterStyle.ACCESSORY_SHRIMP)
	var side: float = signf(fire.position.x)
	check(side != 0.0, "the fire is to one side, not on the centreline -- x %.3f" % fire.position.x)
	var outermost: Vector3 = Vector3.ZERO
	for part in parts.slice(SHRIMP_PLATES):
		if float(part.get("tip", 0.0)) != 0.0:
			continue                 # a blade's root segment ends mid-blade, not at a tip
		var t: Vector3 = _tip_of(part)
		if signf(t.x) == side and absf(t.x) > absf(outermost.x):
			outermost = t
	check(fire.position.distance_to(outermost) < 0.005,
		"it burns at the point of the outermost blade on that side -- %s against %s"
			% [fire.position, outermost])

	# --- 3. three layers, each drawn ---
	var core: CPUParticles3D = _layer(fire, "Core")
	var flame: CPUParticles3D = _layer(fire, "Flame")
	var smoke: CPUParticles3D = _layer(fire, "Smoke")
	if not check(core != null and flame != null and smoke != null,
			"the fire is a core, a flame and smoke"):
		body.queue_free()
		return
	for layer in [core, flame, smoke]:
		var p: CPUParticles3D = layer
		check(p.emitting and p.amount > 0 and p.amount <= 32,
			"%s is small and burning -- %d particles" % [p.name, p.amount])
		check(p.mesh != null and p.color_ramp != null and p.scale_amount_curve != null,
			"%s is really drawn: a mesh, a colour ramp and a size curve" % p.name)
		check(p.gravity.y > 0.0, "%s rises -- gravity %.2f" % [p.name, p.gravity.y])

	# --- 4. each layer does its own job ---
	var core_mat := core.material_override as StandardMaterial3D
	var flame_mat := flame.material_override as StandardMaterial3D
	var smoke_mat := smoke.material_override as StandardMaterial3D
	check(core_mat.blend_mode == BaseMaterial3D.BLEND_MODE_ADD, "the core glows -- it is additive")
	check(flame_mat.blend_mode == BaseMaterial3D.BLEND_MODE_MIX,
		"and the flame is mixed, so it still reads on a pale deck")
	var f_curve: Curve = flame.scale_amount_curve
	var s_curve: Curve = smoke.scale_amount_curve
	check(f_curve.sample(1.0) < f_curve.sample(0.0),
		"the flame shrinks as it rises -- %.2f to %.2f" % [f_curve.sample(0.0), f_curve.sample(1.0)])
	check(s_curve.sample(1.0) > s_curve.sample(0.0) * 1.5,
		"and the smoke grows -- %.2f to %.2f" % [s_curve.sample(0.0), s_curve.sample(1.0)])
	var thickest: Color = Color(1, 1, 1, 0)
	for i in smoke.color_ramp.get_point_count():
		var c: Color = smoke.color_ramp.get_color(i)
		if c.a > thickest.a:
			thickest = c
	check(thickest.a > 0.3 and CharacterStyle.luminance(thickest) < 0.15,
		"the smoke is BLACK where it is thickest -- alpha %.2f, luminance %.3f"
			% [thickest.a, CharacterStyle.luminance(thickest)])
	check(smoke.lifetime > flame.lifetime, "and outlives the flame")
	check(smoke.position.y > 0.0, "and starts above it")
	check(smoke_mat.render_priority < flame_mat.render_priority,
		"and draws behind it, so it never dims the fire")

	# --- 5. switching puts it out ---
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_HORNS)
	eq(_fires_under(body).size() + _emitters_under(body), 0, "and switching accessory puts it out")
	body.queue_free()

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

# --- 7b. IT GROWS FROM THE SURFACE, NOT OUT OF THE MIDDLE OF THE HEAD ----------
#
# Reported from a render, and the numbers say how badly the first fan had it: the
# body is a cylinder of radius 0.4, the moose's wrist started at radius 0.29, and
# its far end -- where every finger begins -- was STILL inside. The whole palm
# grew out of the middle of the skull and only the tips escaped.
#
# NOTHING ABOVE COULD SEE IT. The spread ceiling measures how far OUT a part
# reaches, the fan tests measure the shape it makes, and a rack buried to the
# elbow satisfies both: it is exactly as wide and exactly as fanned as one that
# is not. "Where does it start" is a different question from "where does it end",
# and only the second was being asked.
#
# THE RULE HAS BOTH A FLOOR AND A CEILING, and the floor is the half people
# forget. A mount flush with the surface shows a seam the moment anything moves,
# and a mount OUTSIDE it floats -- so the parts that touch the body are meant to
# be slightly buried. What must not happen is a part that is buried and is not a
# mount.
const BODY_RADIUS := 0.4
const BODY_TOP := 0.9

# How far inside the body a point sits. Negative is outside.
func _burial(p: Vector3) -> float:
	if p.y >= BODY_TOP:
		return BODY_TOP - p.y
	return BODY_RADIUS - Vector2(p.x, p.z).length()

func _test_it_grows_from_the_surface(main) -> void:
	# MEASURED FOR EVERY ACCESSORY AND ASSERTED FOR THE MOOSE, and that split is
	# deliberate rather than lazy.
	#
	# Written as a rule for all four, it fails immediately -- and on content that
	# was signed off from play. The horns' base sits 0.246 m inside a body of
	# radius 0.4, which is very nearly the centre line, and the elk beam's is
	# 0.179 m in. Both are long cones mounted by their MIDPOINT, so half of each
	# is inside the head by construction and only the outer half is the horn you
	# see. That may be perfectly fine, or it may be the same fault the moose had;
	# it is not a question this change gets to answer on its own.
	#
	# So the numbers are printed for all of them -- they are in the gate output on
	# every run, which is where a decision can be made from -- and the assertion
	# binds the one accessory the rule was asked for.
	var report: Array = []
	for kind in CharacterStyle.ACCESSORIES:
		if kind == CharacterStyle.ACCESSORY_NONE:
			continue
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if not check(root != null, "%s built something to measure" % kind):
			continue

		var mounts: int = 0
		var deepest: float = -INF
		var deepest_free: float = -INF
		for child in root.get_children():
			var piece := child as MeshInstance3D
			if piece == null:
				continue
			var cone := piece.mesh as CylinderMesh
			if cone == null:
				continue
			var base: Vector3 = piece.transform * Vector3(0.0, -cone.height * 0.5, 0.0)
			var d: float = _burial(base)
			deepest = maxf(deepest, d)
			if d > -0.01:
				mounts += 1
			else:
				deepest_free = maxf(deepest_free, d)

		report.append("%s deepest %+.3f, %d anchored" % [kind, deepest, mounts])

		if kind == CharacterStyle.ACCESSORY_MOOSE:
			# NO PART STARTS DEEPER THAN ITS OWN SEAM. The rack's two mounts sit
			# 0.03 inside so there is no gap to see; 0.06 is that with margin, and
			# it is nowhere near the 0.11 the old wrist had or the 0.04 its fingers
			# had -- the whole palm grew out of the middle of the skull.
			check(deepest <= 0.06,
				"the moose starts at the head's SURFACE -- deepest base is %.3f m in"
					% deepest)
			# AND SOMETHING REALLY IS ANCHORED. Without this the line above is
			# satisfied by a rack floating a hand's width off the head, which is
			# the opposite mistake and looks just as wrong.
			check(mounts >= 2, "and is anchored rather than floating -- %d mounts" % mounts)
			# EVERY PART THAT IS NOT A MOUNT IS CLEAR OF THE BODY. This is the half
			# that actually failed: the old fingers were not mounts and were inside
			# the head anyway.
			check(deepest_free < 0.0,
				"and every part that is not the root clears the head outright -- "
				+ "deepest is %.3f" % deepest_free)
		body.queue_free()
	print("[accessory burial] %s" % ", ".join(report))

# --- 8. THE MOOSE: ONE ROOT, BIFURCATING ---------------------------------------
#
# What the rack IS, after six rebuilds. Every claim here is one a previous
# version would have failed, and the numbers come from
# design_ideas/antler_research.md rather than from taste.
#
# THIS FILE PREVIOUSLY ASSERTED THREE OTHER SHAPES -- a slab palm, a prism fan,
# and a starburst of cones -- and each set of assertions was perfectly true of
# the thing it described and said nothing about whether it read as an antler.
# The lesson is in CLAUDE.md's language: they measured that a shape EXISTED.
# What was missing was any claim about STRUCTURE, which is what these are.

const HEAD_W := 0.8
const SKULL_TOP := 0.9

func _moose_parts(main) -> Array:
	var body: Node3D = _fresh(main)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 1, CharacterStyle.ACCESSORY_MOOSE)
	var root: Node3D = _accessory_root(body)
	if root == null:
		return []
	var out: Array = []
	for child in root.get_children():
		var piece := child as MeshInstance3D
		if piece == null:
			continue
		var cone := piece.mesh as CylinderMesh
		if cone == null:
			continue
		out.append({
			"base": piece.transform * Vector3(0.0, -cone.height * 0.5, 0.0),
			"tip": piece.transform * Vector3(0.0, cone.height * 0.5, 0.0),
			"dir": piece.transform.basis.y.normalized(),
			"r0": cone.bottom_radius, "r1": cone.top_radius,
		})
	return out

# How far inside the body a point sits. Negative is outside.
func _sunk(p: Vector3) -> float:
	if p.y >= SKULL_TOP:
		return SKULL_TOP - p.y
	return 0.4 - Vector2(p.x, p.z).length()

func _test_the_moose_is_one_root(main) -> void:
	var parts: Array = _moose_parts(main)
	if not check(parts.size() > 0, "the moose built something to measure"):
		return

	# ONE PRIMITIVE. "Cylinders and cones only" is a decision about the whole art
	# language, and it was broken twice by reaching for a new mesh type rather
	# than by a bad number -- a BoxMesh slab and then a PrismMesh fan, both of
	# which read as a foreign object dropped into a cast of cones.
	for part in parts:
		check(part["r0"] > 0.0, "every part is a cone or a cylinder")

	# ONE ROOT PER SIDE. Goss: an antler forms by repeated bifurcation of a single
	# outgrowth, so exactly one part a side may touch the head and everything else
	# must start on another part. A rack with several roots is a bundle of horns.
	var anchored: Array = []
	for part in parts:
		if _sunk(part["base"]) > 0.0:
			anchored.append(part)
	eq(anchored.size(), 2, "exactly one root a side touches the head")

	# And every other part starts ON something. Measured against the parent's
	# axis SEGMENT, so a part floating past the end of its parent is caught.
	var floating: int = 0
	for part in parts:
		if _sunk(part["base"]) > 0.0:
			continue
		var nearest: float = INF
		for other in parts:
			if other == part:
				continue
			nearest = minf(nearest, _to_axis(part["base"], other))
		if nearest > 0.03:
			floating += 1
	eq(floating, 0, "and every other part grows out of one that came before it")

func _to_axis(at: Vector3, part: Dictionary) -> float:
	var a: Vector3 = part["base"]
	var span: Vector3 = part["tip"] - a
	var t: float = clampf((at - a).dot(span) / maxf(span.length_squared(), 0.0001), 0.0, 1.0)
	return (at - (a + span * t)).length() - part["r0"]

# --- 8b. EVERY LIMB IS TWO SEGMENTS, AND THEY CHAIN ---------------------------
#
# A limb built from one cone is a straight stick and nothing on an antler is
# straight. The chaining is what makes a pair read as ONE tapering thing: the
# first segment's TIP radius is the second's BASE radius, the same rule the elk
# beam and the tail already use. Without it a bent limb is two spikes meeting at
# an angle, which is what the elk looked like for three attempts.

func _test_every_limb_is_two_chained_segments(main) -> void:
	var parts: Array = _moose_parts(main)
	if parts.is_empty():
		return
	eq(parts.size() % 2, 0, "the part count is even -- two per limb")

	# A CHAIN PARTNER, NOT MERELY A SUCCESSOR. Several parts may start at the same
	# tip -- that is what a FORK is -- and a fork's children deliberately do NOT
	# inherit the parent's radius, because the pipe model splits it between them.
	# So the test looks for the ONE successor whose base radius MATCHES, which is
	# the second half of the same limb. The first version compared against every
	# successor and reported a 0.033 mismatch that was a fork doing its job.
	var chained: int = 0
	for part in parts:
		if part["r1"] <= 0.0001:
			continue        # a segment ending in a point starts no successor
		for other in parts:
			if other == part:
				continue
			if other["base"].distance_to(part["tip"]) < 0.01 					and absf(other["r0"] - part["r1"]) < 0.002:
				chained += 1
				break
	check(chained >= parts.size() / 2 - 2,
		"every limb's two segments share a radius at their join, so it reads as "
		+ "one tapering thing -- %d chains across %d parts" % [chained, parts.size()])

# --- 8c. THE TINES LIFT OUT OF THE PALM PLANE ---------------------------------
#
# First segment in the plane, second bent upward. This is the one claim that a
# purely planar rack passes and a moose does not: a point lying flat along the
# palm reads as a spike, and a real one curves up off it.

func _test_the_tines_lift(main) -> void:
	var parts: Array = _moose_parts(main)
	if parts.is_empty():
		return
	var lifted: int = 0
	var checked: int = 0
	for part in parts:
		if part["r1"] > 0.0001:
			continue        # only the OUTER segment of a limb ends in a point
		for other in parts:
			if other["tip"].distance_to(part["base"]) < 0.01:
				checked += 1
				if part["dir"].y > other["dir"].y + 0.05:
					lifted += 1
				break
	check(checked >= 8, "there are outer segments to measure -- %d" % checked)
	# The BEAM's own tip is an outer segment too and does not lift, so this is a
	# majority claim rather than a universal one.
	check(lifted >= checked - 4,
		"a tine's second segment bends UP out of the plane -- %d of %d lift"
			% [lifted, checked])

# --- 8d. THE BROW BRANCH IS IN FRONT ------------------------------------------
#
# The first fork is early and uneven: the smaller child is the BROW, and it
# projects FORWARD over the face. Built without this the rack is on backwards,
# and every extent assertion passes either way -- the same blindness the beak's
# row-major Basis had.

func _test_the_brow_is_in_front(main) -> void:
	var parts: Array = _moose_parts(main)
	if parts.is_empty():
		return
	var front: float = INF
	var back: float = -INF
	for part in parts:
		front = minf(front, minf(part["base"].z, part["tip"].z))
		back = maxf(back, maxf(part["base"].z, part["tip"].z))
	# Forward is -Z. The brow reaches forward of the head; the main branch sweeps
	# back behind it.
	check(front < -0.45,
		"the brow branch projects forward over the face -- reaches z %.2f" % front)
	check(back > 0.15, "and the main branch sweeps back behind it -- z %.2f" % back)

# --- 8e. IT SITS LOW AND GOES OUT ---------------------------------------------
#
# The cue the research ranks second and every version before this one had last.
# Root it high and angle it up and the result is a FALLOW DEER -- the other
# palmate cervid -- which reads as "deer", not "moose". That was predicted from
# the literature before it saw the model, and it was exactly what had been built:
# a beam leaving the head at 47 degrees upward.

func _test_it_sits_low_and_goes_out(main) -> void:
	var parts: Array = _moose_parts(main)
	if parts.is_empty():
		return
	var top: float = -INF
	var out: float = 0.0
	for part in parts:
		top = maxf(top, maxf(part["base"].y, part["tip"].y))
		out = maxf(out, maxf(absf(part["base"].x), absf(part["tip"].x)))
	var above: float = top - SKULL_TOP
	check(above < 0.40,
		"the rack stays below half a head-height above the skull -- %.2f" % above)
	check(out - 0.4 > 2.0 * maxf(above, 0.01),
		"and reaches out far further than up -- %.2f out against %.2f up"
			% [out - 0.4, above])

	# ROOTED AT EAR LEVEL, LATERAL. Not on the crown, which is where an elk's go.
	for part in parts:
		if _sunk(part["base"]) > 0.0:
			check(part["base"].y < SKULL_TOP,
				"and is rooted on the SIDE of the head, not the crown -- y %.2f"
					% part["base"].y)

# --- 8f. IT IS NOT THE ELK ----------------------------------------------------
#
# Two racks in one picker are only worth having if a player can tell them apart,
# and the risk went UP when the moose was rebuilt to use the elk's branching
# language. The research names front-view aspect as the separator: a moose is a
# wide horizontal bar, an elk is a lyre.

func _test_the_moose_is_not_the_elk(main) -> void:
	var shapes := {}
	for kind in [CharacterStyle.ACCESSORY_MOOSE, CharacterStyle.ACCESSORY_ANTLERS]:
		var body: Node3D = _fresh(main)
		body.apply_look(CharacterStyle.DEFAULT_BODY, 1, kind)
		var root: Node3D = _accessory_root(body)
		if root == null:
			continue
		var span := AABB()
		var first := true
		for child in root.get_children():
			var piece := child as MeshInstance3D
			if piece == null or piece.mesh == null:
				continue
			var box: AABB = piece.transform * piece.mesh.get_aabb()
			span = box if first else span.merge(box)
			first = false
		shapes[kind] = span
		body.queue_free()

	var moose: AABB = shapes.get(CharacterStyle.ACCESSORY_MOOSE, AABB())
	var elk: AABB = shapes.get(CharacterStyle.ACCESSORY_ANTLERS, AABB())
	var m_ratio: float = moose.size.x / maxf(moose.size.y, 0.001)
	var e_ratio: float = elk.size.x / maxf(elk.size.y, 0.001)
	check(m_ratio > 2.5, "the moose is a wide horizontal bar -- W:H %.2f" % m_ratio)
	check(e_ratio < 1.5, "and the elk is a lyre -- W:H %.2f" % e_ratio)
	check(moose.size.x > elk.size.x * 1.8,
		"and the moose is far the wider -- %.2f against %.2f" % [moose.size.x, elk.size.x])
	print("[racks] moose %.2f x %.2f (W:H %.2f)   elk %.2f x %.2f (W:H %.2f)"
		% [moose.size.x, moose.size.y, m_ratio, elk.size.x, elk.size.y, e_ratio])
