extends "res://scripts/test_support/test_case.gd"

# The derived nose colour, swept across the whole picker.
#
# THE BUG THIS EXISTS TO PREVENT IS A REGION, NOT A CASE. player.tscn's marker
# was a hardcoded yellow that read because the body was a hardcoded blue; the
# moment a player can pick the body colour, a fixed nose works for every colour
# anybody would think to test with and vanishes for the handful nobody visits.
# A test with one colour -- or ten hand-picked ones -- passes for the entire life
# of that bug.
#
# So this sweeps. And it sweeps the ONE COLOUR that used to be the constant, on
# purpose, because "the player picked the old nose yellow" is the exact case the
# feature breaks on and the exact case a hand-written list omits.
#
# WHAT IS ASSERTED IS A RELATIONSHIP, NEVER A VALUE. CLAUDE.md's rule about never
# asserting a display name generalises here: "the nose is yellow" is a claim about
# one body colour, and there are now infinitely many. "The nose is far from the
# body in luminance" is a claim about all of them.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")

# The floor the rule promises. Deliberately read off the constant rather than
# written again here -- a test that restates a number is a test that passes when
# somebody changes the number and forgets the rule.
const MIN_GAP := CharacterStyle.LUMA_GAP

func setup(_main) -> void:
	_test_sweep()
	_test_the_colour_that_used_to_be_the_constant()
	_test_the_gap_is_exact()
	_test_hue_moves_too()
	_test_deterministic()
	finish()

# --- 1. The whole picker ------------------------------------------------------

func _test_sweep() -> void:
	var worst: float = INF
	var worst_at := Color.BLACK
	var samples: int = 0
	# Hue, saturation and value across their full ranges. Greys (s = 0) and both
	# ends of value are included deliberately: they are where a hue-based rule
	# degenerates, because a black body has no hue to be complementary to.
	for h in 12:
		for s in 5:
			for v in 5:
				var body := Color.from_hsv(float(h) / 12.0, float(s) / 4.0, float(v) / 4.0)
				var gap: float = CharacterStyle.luma_gap(body, CharacterStyle.nose_colour(body))
				samples += 1
				if gap < worst:
					worst = gap
					worst_at = body
	check(samples == 300, "the sweep covered every sample it meant to -- got %d" % samples)
	check(worst >= MIN_GAP - 0.001,
		"every colour in the picker keeps the nose %.2f clear of the body in luminance -- worst was %.3f at %s"
			% [MIN_GAP, worst, worst_at])

# --- 2. The case the old code was built on ------------------------------------
#
# The nose used to BE this colour. A player choosing it is the sharpest version
# of the bug, and the one a hand-written sample list never contains.

func _test_the_colour_that_used_to_be_the_constant() -> void:
	var old_nose := Color(0.95, 0.85, 0.25)
	var gap: float = CharacterStyle.luma_gap(old_nose, CharacterStyle.nose_colour(old_nose))
	check(gap >= MIN_GAP - 0.001,
		"a player who picks the old nose yellow still has a visible nose -- gap %.3f" % gap)

	# And the same for the body blue, from the other direction: the pair the game
	# shipped must not get WORSE by being derived.
	var shipped: float = CharacterStyle.luma_gap(
		CharacterStyle.DEFAULT_BODY, CharacterStyle.nose_colour(CharacterStyle.DEFAULT_BODY))
	check(shipped >= MIN_GAP - 0.001,
		"and the default body keeps its marker -- gap %.3f" % shipped)

# --- 3. The gap is exact, not merely sufficient -------------------------------
#
# The rule is built so the clamps never fire: bright is chosen only below
# BRIGHT_BELOW, so the target tops out at 1.0, and dark only above it, so it
# bottoms out over 0.30. That makes the gap EXACTLY LUMA_GAP everywhere, which is
# a much stronger claim than "at least" -- and if a future edit makes a clamp
# start firing, this is what notices.

func _test_the_gap_is_exact() -> void:
	for h in 6:
		for v in 5:
			var body := Color.from_hsv(float(h) / 6.0, 0.7, float(v) / 4.0)
			var gap: float = CharacterStyle.luma_gap(body, CharacterStyle.nose_colour(body))
			near(gap, MIN_GAP, 0.002,
				"the gap is exactly the constant, so no clamp fired at v=%.2f" % (float(v) / 4.0))

# --- 4. Luminance is the channel, but not the only one ------------------------
#
# Two colours far apart in brightness read at distance; the hue rotation is a
# bonus on top, and worth pinning so a later simplification does not quietly
# reduce the nose to a grey.

func _test_hue_moves_too() -> void:
	# A saturated body, where "complementary" means something. A grey one has no
	# hue to rotate and is excluded on purpose rather than by accident.
	var body := Color.from_hsv(0.58, 0.8, 0.7)
	var nose: Color = CharacterStyle.nose_colour(body)
	check(nose.s > 0.05, "the nose keeps some colour rather than going flat grey")
	var apart: float = absf(nose.h - body.h)
	apart = minf(apart, 1.0 - apart)
	check(apart > 0.2, "and sits well away from the body's hue -- %.2f apart" % apart)

# --- 5. Same colour, same nose ------------------------------------------------
#
# It is a pure function and nothing rolls. Cheap to assert and the property every
# replicated look in this game depends on.

func _test_deterministic() -> void:
	var body := Color(0.31, 0.77, 0.42)
	var first: Color = CharacterStyle.nose_colour(body)
	seed(4321)
	randf()
	var second: Color = CharacterStyle.nose_colour(body)
	check(first == second, "the same body colour gives the same nose, and does not touch the global RNG")
