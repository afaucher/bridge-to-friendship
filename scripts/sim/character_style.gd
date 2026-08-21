extends RefCounted

# How a character LOOKS, derived from what the player chose.
#
# Today that is one rule -- the nose colour -- and it is here rather than in the
# screen that shows it because the screen is not the only caller it will ever
# have. See design_ideas/character_customization.md.
#
# THE NOSE COLOUR IS DERIVED AND NEVER STORED, and the reason is the whole
# argument for this file existing.
#
# player.tscn's marker is a hardcoded bright yellow, and it reads because the
# body is a hardcoded blue. BOTH HALVES OF THAT WERE CONSTANTS. The moment the
# body colour becomes something a player picks, a fixed nose is a facing marker
# that works for every colour anybody thinks to test with and vanishes for a
# region of the picker nobody visits -- pick yellow and the marker the dash
# depends on is gone. Not subtle: gone.
#
# player.tscn is explicit that the nose is not decoration. The shove commits to
# one of four compass axes at the instant of the press, so the marker is how a
# player knows which axis they are on BEFORE they commit. Losing it is a control
# bug wearing a cosmetic's clothes.
#
# THE CHANNEL IS LUMINANCE, not hue. Two colours of equal brightness and opposite
# hue are a well-known way to be invisible at distance, and this game is read from
# a camera framing 60 m of bridge. So the rule guarantees a LUMINANCE gap and
# treats the hue rotation as a bonus on top.

# Rec. 709 weights -- the standard perceptual luminance of an RGB triple, and the
# reason green counts for ten times what blue does.
const LUMA_R := 0.2126
const LUMA_G := 0.7152
const LUMA_B := 0.0722

# How far apart the nose and the body must be, in luminance. Calibrated against
# the pair the game already shipped: the blue body and the yellow nose sit about
# 0.28 apart and read correctly at camera distance, so 0.35 is that with margin.
const LUMA_GAP := 0.35

# Below this the nose goes BRIGHTER than the body; above it, darker.
#
# NOT 0.5, and that is a deliberate calibration rather than a round number. The
# shipped body blue has a luminance of 0.544 -- just over half -- so a midpoint
# threshold would have flipped the default player to a DARK nose and quietly
# restyled a character nobody asked to change. At 0.65 every mid and dark body
# keeps the bright marker the game has always had, and only genuinely pale
# choices get the dark one, which is the only case where bright is impossible.
const BRIGHT_BELOW := 0.65

static func luminance(c: Color) -> float:
	return LUMA_R * c.r + LUMA_G * c.g + LUMA_B * c.b

# What a test should measure, and what the rule below promises.
static func luma_gap(a: Color, b: Color) -> float:
	return absf(luminance(a) - luminance(b))

# The facing marker's colour for a given body colour.
#
# NOTE THE CLAMPS NEVER FIRE, and that is by construction rather than by luck.
# Going bright only happens below 0.65, so the target tops out at exactly 1.0;
# going dark only happens above it, so the target bottoms out above 0.30. The gap
# is therefore EXACTLY LUMA_GAP for every colour in the picker, which is what lets
# the test assert an equality rather than an inequality it cannot tune.
static func nose_colour(body: Color) -> Color:
	var l: float = luminance(body)
	var target: float = l + LUMA_GAP if l <= BRIGHT_BELOW else l - LUMA_GAP

	# A complementary hue so the marker does not read as a lighter patch of the
	# same paint. Saturation is floored so a grey body still gets a coloured nose,
	# and capped so the nose is never more lurid than a hazard.
	var candidate := Color.from_hsv(fposmod(body.h + 0.5, 1.0), clampf(body.s, 0.25, 0.85), 1.0)

	# Then slid to the target luminance along the one axis that moves it
	# monotonically. Lerping toward white or black is exactly solvable, where
	# nudging saturation or value is not -- a saturated blue at full value is
	# DARKER than a pale yellow at half, so "make it brighter" via HSV does not
	# reliably make it brighter at all.
	var lc: float = luminance(candidate)
	if target > lc:
		candidate = candidate.lerp(Color.WHITE, clampf((target - lc) / maxf(1.0 - lc, 0.0001), 0.0, 1.0))
	else:
		candidate = candidate.lerp(Color.BLACK, clampf(1.0 - target / maxf(lc, 0.0001), 0.0, 1.0))
	return candidate

# --- Eyes ---------------------------------------------------------------------
#
# EVERY CHARACTER HAS THEM AND NOBODY CHOOSES THEM (decided 2026-08-20). They are
# not a slot; they are what a face is. What varies is a small amount of shape,
# and a chance that the two do not match.
#
# DERIVED FROM A SAVED SEED, NEVER ROLLED AT SPAWN -- the constraint hat_style.gd
# opens with, and it is load-bearing for exactly the same reasons:
#
#   * A `randf()` at spawn would give you different eyes every launch, which is
#     the opposite of the thing this feature is for. "That one's me" needs the
#     face to still be mine tomorrow.
#   * It would also give you different eyes on every MACHINE at once, so the
#     asymmetry your friend is laughing at would not be the one you can see.
#   * And it would be untestable: an outcome drawn from the entropy-seeded global
#     RNG has no correct answer to assert.
#
# So the seed is rolled ONCE, saved, and replicated; everything below is a pure
# function of it. Randomise the id; derive the face from it.

# How many characters have mismatched eyes. A minority on purpose: asymmetry is
# only funny if it reads as THIS character being odd, and if everyone has it then
# nobody does.
const ASYMMETRY_CHANCE := 0.35

const EYE_SIZE_MIN := 0.038
const EYE_SIZE_MAX := 0.055

# How far apart, and how high up the face. The body is a cylinder of radius 0.4
# whose origin is its centre, and the nose sits at y = 0.35 -- so these put the
# eyes above the marker without crowding the top of the head.
const EYE_SPREAD_MIN := 0.10
const EYE_SPREAD_MAX := 0.145
const EYE_HEIGHT_MIN := 0.50
const EYE_HEIGHT_MAX := 0.60

# How much an asymmetric eye differs. Small: the intent is "something is slightly
# wrong with that one", not a joke shop.
const ASYM_SIZE := 0.45          # as a fraction of the base size
const ASYM_HEIGHT := 0.055       # metres up or down

# The same well-known integer mixer hat_style.gd and segment_pool.gd use, and for
# the same reason: NOT the global RNG, which is entropy-seeded per launch and
# would make every one of these answers different on Tuesday.
static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)

# A 0..1 draw for one knob. `salt` keeps the knobs independent -- without it every
# knob of a given face would be the same number, and wide-set eyes would always
# also be big ones.
static func _draw(character_seed: int, salt: int) -> float:
	return float(_mix(character_seed * 8191 + salt * 7919) % 10000) / 9999.0

# The one roll in the whole character system. Called once, on a first launch, and
# saved -- see character_config.gd.
static func random_character_seed() -> int:
	return absi(randi() % (1 << 30)) + 1

# Both eyes, as plain numbers a test can assert directly rather than infer from a
# mesh. Positions are in the FACING pivot's space: +X is the character's left as
# you look at them, +Y is up, and -Z is forward.
static func eye_knobs(character_seed: int) -> Dictionary:
	var size: float = EYE_SIZE_MIN + (EYE_SIZE_MAX - EYE_SIZE_MIN) * _draw(character_seed, 1)
	var spread: float = EYE_SPREAD_MIN + (EYE_SPREAD_MAX - EYE_SPREAD_MIN) * _draw(character_seed, 2)
	var height: float = EYE_HEIGHT_MIN + (EYE_HEIGHT_MAX - EYE_HEIGHT_MIN) * _draw(character_seed, 3)

	var left := {"size": size, "x": spread, "y": height}
	var right := {"size": size, "x": -spread, "y": height}

	var asymmetric: bool = _draw(character_seed, 4) < ASYMMETRY_CHANCE
	if asymmetric:
		# WHICH eye, and in WHAT WAY, are separate draws -- otherwise every odd
		# face would be odd in the same direction and it would read as a bug in
		# the model rather than as a face.
		var odd: Dictionary = left if _draw(character_seed, 5) < 0.5 else right
		var flavour: int = _mix(character_seed * 31 + 6) % 3
		var updown: float = 1.0 if _draw(character_seed, 7) < 0.5 else -1.0
		match flavour:
			0:
				odd["size"] = size * (1.0 + ASYM_SIZE)
			1:
				odd["y"] = height + ASYM_HEIGHT * updown
			_:
				odd["size"] = size * (1.0 + ASYM_SIZE * 0.6)
				odd["y"] = height + ASYM_HEIGHT * 0.7 * updown

	return {"left": left, "right": right, "asymmetric": asymmetric}

# Is this face mismatched? Its own function because the rate is a claim worth
# asserting on its own, and because a caller should not have to know that the
# answer lives under a key in a dictionary of dictionaries.
static func is_asymmetric(character_seed: int) -> bool:
	return _draw(character_seed, 4) < ASYMMETRY_CHANCE

# EYES CARRY THEIR OWN CONTRAST, which is why these are constants where the nose
# colour is derived. A pale sclera with a dark pupil reads against ANY body: on a
# dark character the white ring carries it, on a pale one the pupil does. There is
# no body colour that hides both, so there is nothing here to derive.
const EYE_SCLERA := Color(0.94, 0.94, 0.90)
const EYE_PUPIL := Color(0.06, 0.06, 0.08)

# The body colour a player starts with: the blue the game has always used.
#
# A DELIBERATE DEFAULT RATHER THAN THE ABSENCE OF ONE. It is what most players
# are seen as for their first session, and this is the one value the whole art
# direction was built around -- player.tscn picked it to be "obviously not
# scenery", and hat_style.gd keeps blue out of the hat palette to keep it
# unambiguous. An unconfigured player therefore looks exactly like a player has
# always looked.
const DEFAULT_BODY := Color(0.25, 0.6, 0.85)
