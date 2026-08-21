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

# The body colour a player starts with: the blue the game has always used.
#
# A DELIBERATE DEFAULT RATHER THAN THE ABSENCE OF ONE. It is what most players
# are seen as for their first session, and this is the one value the whole art
# direction was built around -- player.tscn picked it to be "obviously not
# scenery", and hat_style.gd keeps blue out of the hat palette to keep it
# unambiguous. An unconfigured player therefore looks exactly like a player has
# always looked.
const DEFAULT_BODY := Color(0.25, 0.6, 0.85)
