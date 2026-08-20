extends "res://scripts/test_support/test_case.gd"

# Generated hat shapes: base/top/rim width, height, curl and a palette colour,
# all derived from style_id.
#
# THE CLAIM THAT MATTERS IS DETERMINISM. style_id travels with a hat forever so
# you keep wearing the one you stole -- which only means anything if the hat looks
# the same to everybody. A shape rolled with randf() at spawn would be a different
# hat on every machine, and a stolen hat would silently become someone else's
# again on the thief's screen. So: same id, same hat, always, everywhere.
#
# The second claim is VARIETY. A generator whose knobs are all driven by one draw
# produces hats that differ in size but never in proportion -- every tall hat also
# wide, every small one also narrow -- which reads as one hat at several scales
# rather than as different hats.

const HatStyle = preload("res://scripts/sim/hat_style.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const HatScene = preload("res://scenes/hat.tscn")

# THIS FILE IS ABOUT THE ORDINARY CATALOGUE, and since the merchant arrived that
# is no longer every style id. The low band is reserved for his hat, which is
# deliberately outside every range asserted below -- it is sized against the SLOT
# rather than against the catalogue, because that is the whole item. Sweeping
# from zero measured eight trophies against the catalogue's rules and reported
# fifteen failures about correct code.
#
# The band's own claims live in test_tall_hat.gd. What is asserted HERE is that
# the exclusion is exactly the band and not a cell more -- otherwise "skip the
# ones that fail" is a sweep that can be widened until it passes.
func _ordinary(i: int) -> int:
	return HatStyle.TALL_FIRST + HatStyle.TALL_STYLE_COUNT + i

func setup(main) -> void:
	_test_deterministic()
	_test_within_range()
	_test_variety()
	_test_palette()
	_test_meshes_are_per_hat(main)
	finish()

# --- 1. Same id, same hat -----------------------------------------------------

func _test_deterministic() -> void:
	for id in [0, 1, 7, 42, 1000, 65535]:
		var a: Dictionary = HatStyle.knobs(id)
		var b: Dictionary = HatStyle.knobs(id)
		for key in a.keys():
			eq(a[key], b[key], "style %d gives the same %s every time" % [id, key])

	# And it does not depend on the global RNG, which is entropy-seeded per launch
	# -- so re-seeding must not move a single number. This is the difference
	# between "reproducible" and "reproducible today".
	var before: Dictionary = HatStyle.knobs(99)
	seed(12345)
	randf()
	randi()
	var after: Dictionary = HatStyle.knobs(99)
	for key in before.keys():
		eq(before[key], after[key], "and does not touch the global RNG (%s)" % key)

# --- 2. Every knob inside its stated range ------------------------------------

func _test_within_range() -> void:
	# THE BAND IS EXACTLY THE BAND. Asserted before the sweep skips past it, so
	# that "the ids the catalogue rules do not apply to" cannot quietly grow.
	check(HatStyle.is_tall(_ordinary(0) - 1),
		"the id just below the catalogue is the last trophy")
	check(not HatStyle.is_tall(_ordinary(0)),
		"and the first id the sweep below looks at is an ordinary hat")

	for i in 200:
		var id: int = _ordinary(i)
		var k: Dictionary = HatStyle.knobs(id)
		check(k["height"] >= HatStyle.HEIGHT_MIN - 0.001 and k["height"] <= HatStyle.HEIGHT_MAX + 0.001,
			"height in range for %d (%.3f)" % [id, k["height"]])
		check(k["base"] >= HatStyle.BASE_MIN - 0.001 and k["base"] <= HatStyle.BASE_MAX + 0.001,
			"base in range for %d (%.3f)" % [id, k["base"]])
		check(k["top"] > 0.0, "top is a real radius for %d (%.3f)" % [id, k["top"]])
		check(k["rim"] > k["base"] * 0.9,
			"the brim is at least as wide as the crown for %d" % id)

# --- 3. Genuinely different hats, not one hat at several sizes ----------------

func _test_variety() -> void:
	var heights: Array = []
	var rim_ratios: Array = []
	for i in 60:
		var k: Dictionary = HatStyle.knobs(_ordinary(i))
		heights.append(float(k["height"]))
		rim_ratios.append(float(k["rim"]) / float(k["base"]))

	heights.sort()
	# A TINY ONE AND A BIG FLOPPY ONE, which was the actual request. If the range
	# collapsed, every hat would be the same hat.
	check(heights[heights.size() - 1] - heights[0] > 0.3,
		"heights span from short to tall (%.2f to %.2f)" % [heights[0], heights[heights.size() - 1]])

	rim_ratios.sort()
	check(rim_ratios[rim_ratios.size() - 1] - rim_ratios[0] > 0.7,
		"and brims from barely-there to floppy (%.2f to %.2f x the crown)"
			% [rim_ratios[0], rim_ratios[rim_ratios.size() - 1]])

	# THE KNOBS MUST BE INDEPENDENT. Salted separately for exactly this reason:
	# driven by one draw, every tall hat would also be a wide one and the
	# generator would only really have a single dial.
	var tall_and_narrow := false
	var short_and_wide := false
	for i in 200:
		var k: Dictionary = HatStyle.knobs(_ordinary(i))
		var tall: bool = float(k["height"]) > 0.4
		var wide: bool = float(k["rim"]) / float(k["base"]) > 1.7
		if tall and not wide:
			tall_and_narrow = true
		if not tall and wide:
			short_and_wide = true
	check(tall_and_narrow and short_and_wide,
		"height and brim vary independently -- there is a stovepipe AND a pancake")

# --- 4. Colours come from the palette ----------------------------------------

func _test_palette() -> void:
	var used: Dictionary = {}
	for i in 200:
		var id: int = _ordinary(i)
		var colour: Color = HatStyle.knobs(id)["colour"]
		check(HatStyle.PALETTE.has(colour), "colour %d is from the palette" % id)
		used[colour] = true
	# NOT RANDOM RGB, but not one colour either -- a palette nobody spreads across
	# is a palette with one entry.
	check(used.size() >= 4, "and the palette is actually used (%d of %d)"
		% [used.size(), HatStyle.PALETTE.size()])

# --- 5. Each hat owns its own mesh --------------------------------------------

func _test_meshes_are_per_hat(main) -> void:
	# THE TRAP THIS AVOIDS has already been paid for once, on the status bar: mesh
	# and material sub-resources in a .tscn are SHARED by every instance of that
	# scene, so setting a radius on one hat sets it on every hat on the bridge --
	# and the symptom reads as hats being wrong at random rather than as anything
	# shared.
	# TWO STYLES OF DIFFERENT HEIGHT, and asserted to be. The pair used to be ids 3
	# and 4, which the reserved band swallowed -- and every trophy is deliberately
	# the SAME height, so "built to its own style rather than to whichever was made
	# last" became a claim that could not fail. Two hats of one height satisfy it
	# whether or not they share a mesh.
	var id_a: int = _ordinary(0)
	var id_b: int = _ordinary(0)
	for i in 40:
		if absf(float(HatStyle.knobs(_ordinary(i))["height"])
				- float(HatStyle.knobs(id_a)["height"])) > 0.1:
			id_b = _ordinary(i)
			break
	if not check(id_a != id_b,
			"two catalogue styles that really differ in height, or the assertions "
			+ "below cannot tell a per-hat mesh from a shared one"):
		return

	var a: Node3D = HatScene.instantiate()
	a.style_id = id_a
	main.add_child(a)
	var b: Node3D = HatScene.instantiate()
	b.style_id = id_b
	main.add_child(b)

	var crown_a := a.get_node("Crown") as MeshInstance3D
	var crown_b := b.get_node("Crown") as MeshInstance3D
	check(crown_a.mesh != crown_b.mesh, "two hats do not share one mesh")
	check(crown_a.material_override != crown_b.material_override,
		"nor one material")
	near(crown_a.mesh.height, float(HatStyle.knobs(id_a)["height"]), 0.001,
		"and each is built to its own style")
	near(crown_b.mesh.height, float(HatStyle.knobs(id_b)["height"]), 0.001,
		"rather than to whichever was made last")

	a.queue_free()
	b.queue_free()
