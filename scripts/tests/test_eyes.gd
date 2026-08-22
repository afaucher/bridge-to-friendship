extends "res://scripts/test_support/test_case.gd"

# Everybody gets eyes, nobody picks them, and some faces do not match.
#
# THE CLAIM THAT MATTERS IS DETERMINISM, exactly as it is for hats. A face rolled
# with randf() at spawn would be:
#
#   * different every launch, so the thing this whole feature exists for -- "that
#     one's me" -- would stop being true overnight;
#   * different on every MACHINE, so the wonky eye your friend is laughing at
#     would not be the one you can see;
#   * and untestable, because a draw from the entropy-seeded global RNG has no
#     correct answer to assert.
#
# So the seed is rolled once and saved, and everything about a face is a pure
# function of it. This file pins that, the asymmetry RATE, and the fact that the
# meshes actually get built -- because a perfect knob generator nothing renders
# is the "mechanically perfect and invisible" failure CLAUDE.md records from the
# three guns that shipped as a floating barrel.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")

func setup(_main) -> void:
	_test_deterministic()
	_test_everybody_has_two()
	_test_asymmetry_rate()
	_test_symmetric_faces_really_match()
	_test_asymmetric_faces_really_do_not()
	_test_the_meshes_exist(_main)
	finish()

# --- 1. Same seed, same face --------------------------------------------------

func _test_deterministic() -> void:
	for id in [0, 1, 7, 42, 1000, 65535, 999983]:
		var a: Dictionary = CharacterStyle.eye_knobs(id)
		var b: Dictionary = CharacterStyle.eye_knobs(id)
		check(a["left"] == b["left"] and a["right"] == b["right"],
			"seed %d gives the same face every time" % id)

	# And it does not depend on the global RNG, which is entropy-seeded per launch
	# -- so re-seeding must not move a single number. This is the difference
	# between "reproducible" and "reproducible today".
	var before: Dictionary = CharacterStyle.eye_knobs(4242)
	seed(98765)
	randf()
	randi()
	var after: Dictionary = CharacterStyle.eye_knobs(4242)
	check(before["left"] == after["left"] and before["right"] == after["right"],
		"and does not touch the global RNG")

# --- 2. Nobody is faceless ----------------------------------------------------
#
# INCLUDING SEED ZERO, which is what a peer with no announcement yet reports. It
# has to be a real face rather than a gap, or a joining player is briefly blank.

func _test_everybody_has_two() -> void:
	for id in [0, 1, 2, 3, 77, 12345, 888888]:
		var knobs: Dictionary = CharacterStyle.eye_knobs(id)
		for side in ["left", "right"]:
			var eye: Dictionary = knobs[side]
			check(float(eye["size"]) > 0.0, "seed %d has a %s eye with real size" % [id, side])
			check(float(eye["y"]) > 0.0, "and it is above the body's centre (%s)" % side)
		# Left is +X and right is -X. A face whose eyes are on the same side is
		# not asymmetry, it is a bug, and no amount of asymmetry may cause it.
		check(float(knobs["left"]["x"]) > 0.0 and float(knobs["right"]["x"]) < 0.0,
			"seed %d has one eye either side of the centreline" % id)

# --- 3. The chance is a chance ------------------------------------------------
#
# A MINORITY, and both halves of that matter: at 0% the feature does not exist,
# and at 100% asymmetry stops being a characteristic and becomes the model. The
# window is wide because this is a rate over a sample, not a constant -- but it
# is narrow enough to catch a predicate stuck at true or false, which is the
# realistic failure.

func _test_asymmetry_rate() -> void:
	var odd: int = 0
	var total: int = 3000
	for i in total:
		if CharacterStyle.is_asymmetric(i * 7919 + 13):
			odd += 1
	var rate: float = float(odd) / float(total)
	check(absf(rate - CharacterStyle.ASYMMETRY_CHANCE) < 0.06,
		"about %.0f%% of faces are asymmetric -- measured %.1f%% over %d seeds"
			% [CharacterStyle.ASYMMETRY_CHANCE * 100.0, rate * 100.0, total])
	# Stated separately so a stuck predicate names itself rather than hiding
	# inside a tolerance.
	check(odd > 0, "some faces are asymmetric")
	check(odd < total, "and some are not")

# --- 4 and 5. The flag agrees with the geometry -------------------------------
#
# THE TWO HALVES ARE SEPARATE TESTS ON PURPOSE. `is_asymmetric` returning true
# while both eyes match is a face that claims to be odd and is not; and eyes that
# differ on a face flagged symmetric is worse, because it means the flag a test
# trusts is not the thing being drawn. Assert the RELATIONSHIP, not the flag.

func _test_symmetric_faces_really_match() -> void:
	var checked: int = 0
	for i in 400:
		var id: int = i * 104729 + 5
		if CharacterStyle.is_asymmetric(id):
			continue
		checked += 1
		var knobs: Dictionary = CharacterStyle.eye_knobs(id)
		var l: Dictionary = knobs["left"]
		var r: Dictionary = knobs["right"]
		if not check(is_equal_approx(float(l["size"]), float(r["size"])),
				"a symmetric face has two eyes the same size (seed %d)" % id):
			return
		if not check(is_equal_approx(float(l["y"]), float(r["y"])),
				"and at the same height (seed %d)" % id):
			return
		if not check(is_equal_approx(float(l["x"]), -float(r["x"])),
				"and mirrored about the centreline (seed %d)" % id):
			return
	check(checked > 50, "and the sweep actually found symmetric faces to check -- %d" % checked)

func _test_asymmetric_faces_really_do_not() -> void:
	var checked: int = 0
	for i in 400:
		var id: int = i * 104729 + 5
		if not CharacterStyle.is_asymmetric(id):
			continue
		checked += 1
		var knobs: Dictionary = CharacterStyle.eye_knobs(id)
		var l: Dictionary = knobs["left"]
		var r: Dictionary = knobs["right"]
		var differs: bool = not is_equal_approx(float(l["size"]), float(r["size"])) \
			or not is_equal_approx(float(l["y"]), float(r["y"]))
		if not check(differs,
				"a face flagged asymmetric has eyes that actually differ (seed %d)" % id):
			return
	check(checked > 50, "and the sweep found asymmetric faces to check -- %d" % checked)

# --- 6. Something is actually drawn -------------------------------------------
#
# The knobs above could all be perfect and the player still have no face. A
# weapon that is mechanically perfect and invisible passes a mechanics suite --
# CLAUDE.md, on three guns that shipped as a floating barrel.

func _test_the_meshes_exist(main) -> void:
	var body: Node3D = PlayerScene.instantiate()
	main.add_child(body)
	body.apply_look(CharacterStyle.DEFAULT_BODY, 20260820)

	for node_name in ["EyeLeft", "EyeRight"]:
		var eye := body.get_node_or_null("Facing/" + node_name) as MeshInstance3D
		if not check(eye != null, "%s was built" % node_name):
			continue
		check(eye.mesh != null, "%s has a mesh" % node_name)
		check(eye.material_override != null, "%s has its own material" % node_name)
		var pupil := eye.get_node_or_null("Pupil") as MeshInstance3D
		check(pupil != null and pupil.mesh != null, "%s has a pupil" % node_name)
		# IN FRONT OF THE BODY. The cylinder's surface is at -0.4 at the
		# centreline, and an eye behind that is inside the head.
		check(eye.position.z < 0.0, "%s is on the front of the face" % node_name)

	# UNDER `Facing`, not under the root -- so they turn with the aim like the
	# nose does. A face that stayed pointing north while the body turned would be
	# worse than no face.
	var left := body.get_node_or_null("Facing/EyeLeft")
	check(left != null and left.get_parent().name == "Facing",
		"the eyes hang off the Facing pivot, so they turn with the player")

	# And re-applying does not stack up a second pair.
	body.apply_look(CharacterStyle.DEFAULT_BODY, 20260820)
	var pairs: int = 0
	for child in body.get_node("Facing").get_children():
		if str(child.name).begins_with("Eye"):
			pairs += 1
	eq(pairs, 2, "applying a look twice leaves exactly two eyes")

	body.queue_free()
