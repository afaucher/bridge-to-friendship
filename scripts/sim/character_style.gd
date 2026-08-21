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
	return to_luminance(candidate, target)

# Slide a colour to a target luminance, keeping as much of its hue as the target
# allows.
#
# TOWARD WHITE OR BLACK, because that is the one move that changes luminance
# MONOTONICALLY and is exactly solvable. Nudging saturation or value is neither:
# a saturated blue at full value is DARKER than a pale yellow at half, so "make
# it brighter" via HSV does not reliably make it brighter at all.
static func to_luminance(colour: Color, target: float) -> Color:
	var l: float = luminance(colour)
	if target > l:
		return colour.lerp(Color.WHITE, clampf((target - l) / maxf(1.0 - l, 0.0001), 0.0, 1.0))
	return colour.lerp(Color.BLACK, clampf(1.0 - target / maxf(l, 0.0001), 0.0, 1.0))

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

# SIZED FOR THE GAME CAMERA, NOT FOR THE PREVIEW (corrected 2026-08-20 from play).
#
# The first version of these numbers was five times smaller, and every one of
# them was wrong for the same reason: they were chosen against the character
# screen, where the camera is three metres away at eye level. The game is read
# from a camera framing 60 m of bridge, and at that zoom a 4 cm eye is nothing.
#
# THIS ALSO REVERSES A RULE THIS FEATURE WAS DESIGNED AROUND. The design doc said
# eyes must stay "small enough to lose at range, deliberately", so they could not
# compete with the nose for the facing channel. Played, that was wrong twice
# over: they were lost at every range including the preview, and eyes do not
# compete with the marker anyway -- a symmetric pair says "this is the front" and
# an asymmetric wedge says "this way", and the two AGREE. The channel they were
# supposed to be protecting is not one they take from.
const EYE_SIZE_MIN := 0.19
const EYE_SIZE_MAX := 0.215

# SPREAD IS DERIVED FROM SIZE, not drawn on its own.
#
# It used to be an independent knob, which was survivable while eyes were tiny
# and is not now: an independent small spread with an independent large size is
# one merged blob where a face should be. Deriving it makes the relationship hold
# at every size rather than only where the two ranges happen to agree.
#
# THE CEILING IS LOW ON PURPOSE, AND THAT IS A GEOMETRY CONSTRAINT RATHER THAN A
# TASTE ONE. The eyes sit on the surface of a cylinder of radius 0.4, so pushing
# them further apart does not move them sideways across a face -- it walks them
# AROUND THE HEAD. At a spread of 0.30 the surface has already turned to
# z = -0.265, and an eye there is on the side of the skull looking outward. Just
# touching at the front reads as a face; further apart reads as a hammerhead.
const EYE_SPREAD_FACTOR_MIN := 1.00
const EYE_SPREAD_FACTOR_MAX := 1.15

# How high up the face. Raised with the size: an eye of radius 0.22 centred at
# 0.55 reaches down to 0.33, and the nose occupies 0.20 to 0.50.
const EYE_HEIGHT_MIN := 0.55
const EYE_HEIGHT_MAX := 0.64

# How much an asymmetric eye differs. Scaled up with everything else -- a fixed
# offset that read as a wonky eye at 4 cm is invisible at 20 cm.
const ASYM_SIZE := 0.45          # as a fraction of the base size
const ASYM_HEIGHT := 0.10        # metres up or down

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
	var factor: float = EYE_SPREAD_FACTOR_MIN \
		+ (EYE_SPREAD_FACTOR_MAX - EYE_SPREAD_FACTOR_MIN) * _draw(character_seed, 2)
	var spread: float = size * factor
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

# --- The accessory slot -------------------------------------------------------
#
# ONE AT A TIME, or none (decided 2026-08-20). Horns, antlers, or a tail.
#
# The single slot is doing more work than it looks. The camera reads silhouette
# from above, the head already carries a tower of hats, and independent toggles
# would mean a player wearing horns AND antlers AND a tail is a shape nobody
# designed. One slot keeps every possible player a shape somebody drew.
#
# STORED BY NAME, NEVER BY INDEX. These strings go in a config file and on the
# wire, and an integer index into a list is a value that silently remaps the day
# anybody reorders the list -- every saved character would quietly grow different
# antlers. A name costs a handful of bytes on a packet sent once per session.
const ACCESSORY_NONE := "none"
const ACCESSORY_HORNS := "horns"
const ACCESSORY_ANTLERS := "antlers"
const ACCESSORY_TAIL := "tail"
# MOOSE, and it is a separate entry rather than a variant of `antlers` because it
# is a different STRUCTURE, not a different size of the same one. An elk rack is a
# beam with points along it; a moose rack is a flat PALM with points around its
# edge. Nothing about the elk data could be scaled into one.
const ACCESSORY_MOOSE := "moose"

# APPENDED, NEVER INSERTED. The order here is not load-bearing the way
# SetPieces.LIBRARY's is -- accessories are stored by NAME precisely so it cannot
# be -- but the character screen walks this list, so inserting in the middle
# reshuffles the buttons under somebody who had learned where theirs was.
const ACCESSORIES := [ACCESSORY_NONE, ACCESSORY_HORNS, ACCESSORY_ANTLERS,
	ACCESSORY_MOOSE, ACCESSORY_TAIL]

# THE SPREAD CEILING, and it is the mirror of the nose's protrusion FLOOR.
#
# The nose has to break the body's top-down circle to say anything; an accessory
# has to not break it so badly that the player stops reading as a player.
# Contract rule 1 in art_direction.md: silhouette carries identity, and the
# identity being carried is "that is a player, not a hazard". Measured as a
# half-width from the centreline, against a body of radius 0.4.
#
# RAISED FROM 0.45 TO 0.85 (2026-08-20, from play). The old ceiling was a
# speculative number that had never been looked at, and under it the horns were
# invisible and the antlers were "tiny". A budget nothing can be seen inside is
# not protecting the silhouette, it is preventing the feature -- and the
# silhouette rule was always about staying recognisable as a player, which a
# cylinder with a rack on it still is. The ceiling stays because a runaway is
# still worth catching; only the number moved.
# RAISED 2026-08-21, FROM 0.85 TO 1.50, FOR ONE ACCESSORY. Everything above still
# holds; what it did not anticipate is an antler whose entire identity IS its
# width.
#
# The arithmetic, against a head 0.80 across. A moose rack can start no closer to
# the centreline than the head allows, so this ceiling decides almost exactly how
# wide it can be -- and the rack reading too narrow was reported twice from
# renders, with the fault here both times rather than in the geometry:
#
#     ceiling 0.85   rack spans 1.70   =  2.1 x the head width
#     ceiling 1.15   rack spans 2.30   =  2.9 x
#     ceiling 1.50   rack spans 3.00   =  3.8 x
#     a real bull                      =  4.5 x measured, 6.3 x at the record
#
# See design_ideas/antler_research.md: 4.50x is the measured mean for a prime
# bull across 1,965 racks. So even at 1.50 this is under the honest figure, and
# the shipped rack measures 2.77 across -- 3.5x the head -- which leaves the
# ceiling doing real work rather than merely trailing the data.
#
# WHAT IT COSTS, stated plainly. The moose is the widest thing any player can
# wear by a factor of three; the other four accessories sit between 0.6 and 0.9
# and are untouched. Contract rule 1 in art_direction.md asks that a player still
# read as a player, and one option in a picker of five being this wide is right
# at that line. IT HAS NOT BEEN PLAYED. The 0.85 it replaces was tuned from play
# and this is not, which is the honest difference between the two numbers.
const ACCESSORY_SPREAD_MAX := 1.50

# THE ACCESSORY WEARS THE NOSE'S COLOUR (decided 2026-08-20, from play).
#
# It used to have a derived colour of its own, sitting a subtler 0.18 from the
# body so the marker would stay the loudest thing on the player. Looked at, that
# was a rule protecting against a problem that is not there: the nose and the
# accessory are at opposite ends of the body and completely different shapes, so
# nobody confuses a tail for a beak -- and giving them one shared colour makes
# them read as the character's TRIM, which is a better answer than either being
# quietly different.
#
# Kept as a function rather than inlined at the two call sites, so this stays one
# decision in one place if it ever moves back.
static func accessory_colour(body: Color) -> Color:
	return nose_colour(body)

# Aim a part's +Y axis along an arbitrary direction.
#
# A DIRECTION VECTOR RATHER THAN EULER ANGLES, and that is the third time this
# feature has run into the same wall. A part that has to sweep out AND up AND
# back needs two composed rotations, and composing Euler angles means knowing
# Godot's application order -- which is exactly the class of thing this project
# has shipped backwards three times (a bullet tail, a muzzle offset, and the beak
# earlier in this very feature).
#
# Naming the direction removes the question. "Out, up and back" is
# `Vector3(0.35, 0.55, 0.76)`, which is readable, reviewable, and impossible to
# get subtly transposed.
static func aim_basis(direction: Vector3) -> Basis:
	var y_axis: Vector3 = direction.normalized()
	# Any reference not parallel to the aim. Swapped near the poles because a
	# cross product with something parallel is the zero vector, and a basis built
	# from that is garbage rather than an error.
	var reference: Vector3 = Vector3.FORWARD if absf(y_axis.z) < 0.9 else Vector3.RIGHT
	var x_axis: Vector3 = reference.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis)
	return Basis(x_axis, y_axis, z_axis)

# The primitives that make up one accessory, in the FACING pivot's space.
#
# DATA RATHER THAN CODE, so a test can measure the design instead of the drawing.
# Each part is a tapered cylinder: a CENTRE, a direction its length runs along, a
# base radius, an optional tip radius (0 makes a point), and a length.
#
# ONE PRIMITIVE, AND THAT IS A DECISION RATHER THAN A LIMIT (2026-08-21). The
# moose briefly had a second -- a flat plate, for its palm -- on the reasoning
# that a palm is not a cone and the primitive has to be able to say what the
# anatomy is. Rendered, both versions of it read as BOXES, because a slab in a
# cast of cones is a slab however carefully it is shaped. The rack is a fan of
# cones now and reads as an antler, which is the argument the other way: the
# shape language of a thing built from parts is the parts.
#
# Remember the axes: -Z is forward, +Z is back, +X is the character's left as you
# look at them.
static func accessory_parts(kind: String) -> Array:
	match kind:
		ACCESSORY_HORNS:
			# THICK AND LONG ENOUGH TO SEE FROM THE BRIDGE CAMERA. The first
			# version was 0.075 x 0.34 and the report was "I can't see the horns
			# at all" -- sized against the preview, invisible in the game.
			#
			# Mounted at y = 0.62, on the SIDE of the head rather than the top,
			# sweeping out and slightly back. The vertical column above the head
			# belongs to hats.
			return [
				{"pos": Vector3(0.34, 0.62, 0.0), "dir": Vector3(0.62, 0.72, 0.31), "radius": 0.15, "length": 0.80},
				{"pos": Vector3(-0.34, 0.62, 0.0), "dir": Vector3(-0.62, 0.72, 0.31), "radius": 0.15, "length": 0.80},
			]
		ACCESSORY_ANTLERS:
			# ELK, and the fourth attempt. The previous three failed in order: they
			# grew out of the crown, then splayed flat sideways in one plane, then
			# read as "cones whose tip intersects the middle of the next" rather
			# than as branching. That last note is the useful one, and it names two
			# separate faults.
			#
			# FAULT ONE: THE BEAM WAS NOT CONTINUOUS. It was two cones that each
			# tapered to a point and happened to overlap. A beam is one tapering
			# stalk, so it is built the way the tail is -- a CHAIN, where every
			# segment's end is the next one's start and its tip radius is the next
			# one's base radius.
			#
			# FAULT TWO: THE TINES WERE NOT ATTACHED TO ANYTHING. They were placed
			# at eyeballed points that happened to cross the beam mid-span, which
			# is what "intersects the middle" means and why it read as a bundle
			# rather than a branch. Every tine below STARTS AT A JOINT of the beam
			# chain, so it emerges from the stalk instead of piercing it.
			#
			# The layout follows a 6x6 bull (Boone and Crockett's field-judging
			# description). The proportions are what make it read as elk rather
			# than as a generic branch, and the surprising one is the brow:
			#
			#   beam   up and slightly back, CURVING REARWARD -- on a real bull it
			#          reaches as far back as the haunches
			#   G1     the brow tine, projecting FORWARD over the face. The one
			#          part that points opposite to everything else, and the single
			#          most identifiable thing about an elk rack
			#   G2/G3  the bez and trez, off the SIDE of the beam, forward and out
			#   G4     the royal or dagger -- UP off the top of the beam, and the
			#          LONGEST point on the animal
			#   G5     up and behind the dagger, and much shorter
			#
			# Nine parts a side: four beam segments and five tines.
			return [
				# --- main beam: a chain, curving from up-and-out to nearly
				# horizontal as it sweeps back over the shoulders ---
				{"pos": Vector3(0.265, 0.920, 0.076), "dir": Vector3(0.32, 0.86, 0.40), "radius": 0.075, "tip": 0.062, "length": 0.28},
				{"pos": Vector3(0.345, 1.115, 0.239), "dir": Vector3(0.26, 0.55, 0.79), "radius": 0.062, "tip": 0.052, "length": 0.27},
				{"pos": Vector3(0.403, 1.228, 0.468), "dir": Vector3(0.18, 0.30, 0.94), "radius": 0.052, "tip": 0.042, "length": 0.26},
				{"pos": Vector3(0.443, 1.282, 0.713), "dir": Vector3(0.13, 0.12, 0.98), "radius": 0.042, "tip": 0.028, "length": 0.25},
				# --- G1 brow: forward, over the face ---
				{"pos": Vector3(0.269, 0.878, -0.099), "dir": Vector3(0.18, 0.12, -0.98), "radius": 0.045, "length": 0.30},
				# --- G2 bez and G3 trez: off the side, forward and out ---
				{"pos": Vector3(0.378, 1.072, 0.032), "dir": Vector3(0.55, 0.25, -0.80), "radius": 0.038, "length": 0.25},
				{"pos": Vector3(0.445, 1.242, 0.253), "dir": Vector3(0.52, 0.42, -0.74), "radius": 0.036, "length": 0.25},
				# --- G4 royal: up off the beam, the longest point ---
				{"pos": Vector3(0.460, 1.410, 0.623), "dir": Vector3(0.22, 0.95, 0.22), "radius": 0.042, "length": 0.30},
				# --- G5: up and behind the royal, short ---
				{"pos": Vector3(0.474, 1.371, 0.864), "dir": Vector3(0.18, 0.92, 0.35), "radius": 0.030, "length": 0.16},
				{"pos": Vector3(-0.265, 0.920, 0.076), "dir": Vector3(-0.32, 0.86, 0.40), "radius": 0.075, "tip": 0.062, "length": 0.28},
				{"pos": Vector3(-0.345, 1.115, 0.239), "dir": Vector3(-0.26, 0.55, 0.79), "radius": 0.062, "tip": 0.052, "length": 0.27},
				{"pos": Vector3(-0.403, 1.228, 0.468), "dir": Vector3(-0.18, 0.30, 0.94), "radius": 0.052, "tip": 0.042, "length": 0.26},
				{"pos": Vector3(-0.443, 1.282, 0.713), "dir": Vector3(-0.13, 0.12, 0.98), "radius": 0.042, "tip": 0.028, "length": 0.25},
				{"pos": Vector3(-0.269, 0.878, -0.099), "dir": Vector3(-0.18, 0.12, -0.98), "radius": 0.045, "length": 0.30},
				{"pos": Vector3(-0.378, 1.072, 0.032), "dir": Vector3(-0.55, 0.25, -0.80), "radius": 0.038, "length": 0.25},
				{"pos": Vector3(-0.445, 1.242, 0.253), "dir": Vector3(-0.52, 0.42, -0.74), "radius": 0.036, "length": 0.25},
				{"pos": Vector3(-0.460, 1.410, 0.623), "dir": Vector3(-0.22, 0.95, 0.22), "radius": 0.042, "length": 0.30},
				{"pos": Vector3(-0.474, 1.371, 0.864), "dir": Vector3(-0.18, 0.92, 0.35), "radius": 0.030, "length": 0.16},
			]
		ACCESSORY_MOOSE:
			# MOOSE, AND IT IS PALMATE -- the one word that separates it from the elk
			# rack next door.
			#
			# An elk antler is a BEAM with points along it: everything radiates from a
			# stalk, and the stalk is most of the shape. A moose antler is a broad
			# flattened PALM with points around its edge -- "shaped like the palm of a
			# hand with outstretched fingers" is the standard description, and Boone
			# and Crockett score a bull on three numbers of which two are the palm.
			#
			# TAKEN LITERALLY, THAT DESCRIPTION IS BUILDABLE OUT OF CONES, and that is
			# what this is: six long slender fingers splayed across a single plane, with
			# their bases spread along a short RIM rather than meeting at a point.
			#
			# THE FIRST VERSION MET AT A POINT AND WAS A BURR. Reported from a render as
			# "too bunched up to read as anything but a spiky block", and the numbers
			# say it plainly: six fingers of 0.25 with base radii of 0.088 is a ratio of
			# 0.33, which is a stubby spike rather than a point, and all twelve of them
			# left the same spot beside a head 0.8 across. The mass ended up in a ball
			# against the skull with short spines round it.
			#
			# What fixed it was proportion, in three places at once, and no one of them
			# alone would have:
			#
			#   SLENDER    r/L from 0.33 to 0.106. A point has to be long against its
			#              own thickness or it is a thorn
			#   OFF A RIM  the bases are spread 0.24 along a line across the wrist, so
			#              the shape is already wide where it LEAVES the wrist. From one
			#              origin a fan is a starburst however long its arms are
			#   FORE-AND-AFT  the fingers run mostly back rather than out, so their
			#              length is spent on depth instead of against the spread
			#              ceiling. A real palm is long front-to-back anyway, widest in
			#              the middle and sweeping back over the shoulders
			#
			# Measured after: 1.68 wide by 1.11 deep against a head 0.80 across -- so the
			# rack is 2.1x the width of the head, which is about what a bull carries
			# (roughly a 50 inch spread against 30 inches ear to ear).
			#
			# IT TOOK TWO WRONG ANSWERS TO GET HERE AND BOTH WERE THE SAME MISTAKE:
			# reaching for a new primitive instead of composing the one that was here.
			# The palm was a BoxMesh slab first -- a plank, the same width at both ends,
			# which a palm never is -- and then a PrismMesh fan, which fixed the outline
			# and not the problem. Rendered, both read as BOXES: a flat plate in a cast
			# of cones is a foreign object however carefully it is shaped, and the eye
			# reads the ODD ONE OUT before it reads the silhouette. The shape language
			# of a thing built from parts IS the parts.
			#
			# The anatomy, in the order it is built:
			#
			#   wrist    SHORT and stubby, MOUNTED ON THE HEAD'S SURFACE and aimed
			#            mostly UP. Its whole job is to carry the fan's origin clear of
			#            the skull -- see the burial note below. Mostly up rather than
			#            out because the spread budget belongs to the FAN: a wrist that
			#            leaned outward would spend half of it before a single finger
			#            existed. On an elk the beam is the whole antler; here it is a
			#            wrist, and getting that wrong in the other direction just
			#            builds an elk again
			#   fingers  six, splayed ACROSS one plane rather than branching out of a
			#            stalk, from bases spread along a rim. Longest in the middle and
			#            shortest at the ends, which is what makes the outer edge a
			#            curve instead of a straight comb
			#   brow     ONE forward point off the wrist, and NOT the brow palm a real
			#            bull has. That was built and removed: this character has no
			#            MUZZLE -- the front of its head is eyes -- so a plate over the
			#            brow lands squarely on top of them and reads as blinders
			#
			# THE NUMBERS WERE COMPUTED, NOT EYEBALLED. Every finger's direction is the
			# fan's centre line rotated about the fan's normal by a named angle, and
			# every base is the wrist's far end. Eyeballed joints are what made the elk
			# read as "cones whose tip intersects the middle of the next" for three
			# attempts running.
			#
			# IT MOUNTS ON THE SURFACE, NOT INSIDE THE HEAD. Reported from a render,
			# and the numbers say how badly the first version had it: the body is a
			# cylinder of radius 0.4, the wrist started at radius 0.29, and its far end
			# -- where every finger begins -- was STILL 0.04 inside. The whole palm grew
			# out of the middle of the skull and only the tips escaped.
			#
			# The two parts that touch the body now sit exactly 0.03 INSIDE it, which is
			# deliberate and is the opposite failure: a mount flush with the surface
			# shows a seam the moment anything moves, and one outside it floats. Every
			# other part is clear of the body by 0.07 or more. Asserted in
			# test_accessory, because "it is roughly in the right place" is exactly the
			# kind of claim that drifts silently.
			#
			# THE FAN LIES NEARLY FLAT (its normal is within 12 degrees of straight up)
			# and that is the reading, not a detail: a trophy bull's palms lie flat and
			# spread wide, and a rack whose fan stood upright would be an elk again.
			return [
				# --- ONE ROOT. Every limb below is TWO chained segments, so it curves ---
				{"pos": Vector3(0.418, 0.624, -0.030), "dir": Vector3(0.880, 0.440, -0.140), "radius": 0.090, "tip": 0.086, "length": 0.11},
				{"pos": Vector3(0.513, 0.673, -0.054), "dir": Vector3(0.843, 0.430, -0.302), "radius": 0.086, "tip": 0.083, "length": 0.11},
				# --- FORK 1: the butterfly -- brow branch forward, main branch out ---
				{"pos": Vector3(0.590, 0.706, -0.134), "dir": Vector3(0.425, 0.138, -0.888), "radius": 0.050, "tip": 0.046, "length": 0.14},
				{"pos": Vector3(0.640, 0.717, -0.263), "dir": Vector3(0.280, 0.017, -0.953), "radius": 0.046, "tip": 0.043, "length": 0.14},
				{"pos": Vector3(0.652, 0.693, -0.406), "dir": Vector3(-0.087, -0.314, -0.939), "radius": 0.038, "tip": 0.017, "length": 0.16},
				{"pos": Vector3(0.624, 0.675, -0.558), "dir": Vector3(-0.271, 0.097, -0.958), "radius": 0.017, "length": 0.16},
				{"pos": Vector3(0.696, 0.734, -0.382), "dir": Vector3(0.559, 0.244, -0.785), "radius": 0.034, "tip": 0.015, "length": 0.13},
				{"pos": Vector3(0.768, 0.791, -0.469), "dir": Vector3(0.542, 0.632, -0.554), "radius": 0.015, "length": 0.13},
				# --- the main branch, forking again at every joint ---
				# Each TINE's second segment lifts out of the palm plane, so the
				# points curve upward instead of lying flat along it.
				{"pos": Vector3(0.614, 0.721, -0.064), "dir": Vector3(0.894, 0.415, 0.124), "radius": 0.066, "tip": 0.064, "length": 0.12},
				{"pos": Vector3(0.721, 0.770, -0.042), "dir": Vector3(0.883, 0.389, 0.237), "radius": 0.064, "tip": 0.062, "length": 0.12},
				{"pos": Vector3(0.810, 0.777, 0.059), "dir": Vector3(0.368, -0.169, 0.907), "radius": 0.036, "tip": 0.016, "length": 0.19},
				{"pos": Vector3(0.890, 0.811, 0.214), "dir": Vector3(0.473, 0.521, 0.710), "radius": 0.016, "length": 0.19},
				{"pos": Vector3(0.825, 0.816, -0.014), "dir": Vector3(0.883, 0.389, 0.237), "radius": 0.051, "tip": 0.049, "length": 0.11},
				{"pos": Vector3(0.925, 0.858, 0.020), "dir": Vector3(0.862, 0.354, 0.347), "radius": 0.049, "tip": 0.048, "length": 0.11},
				{"pos": Vector3(1.008, 0.858, 0.132), "dir": Vector3(0.332, -0.203, 0.914), "radius": 0.034, "tip": 0.015, "length": 0.20},
				{"pos": Vector3(1.085, 0.886, 0.299), "dir": Vector3(0.437, 0.487, 0.757), "radius": 0.015, "length": 0.20},
				{"pos": Vector3(1.022, 0.898, 0.058), "dir": Vector3(0.862, 0.354, 0.347), "radius": 0.039, "tip": 0.038, "length": 0.11},
				{"pos": Vector3(1.114, 0.934, 0.102), "dir": Vector3(0.830, 0.311, 0.450), "radius": 0.038, "tip": 0.037, "length": 0.11},
				{"pos": Vector3(1.185, 0.929, 0.209), "dir": Vector3(0.295, -0.236, 0.919), "radius": 0.034, "tip": 0.015, "length": 0.18},
				{"pos": Vector3(1.248, 0.949, 0.365), "dir": Vector3(0.397, 0.450, 0.800), "radius": 0.015, "length": 0.18},
				{"pos": Vector3(1.213, 0.971, 0.156), "dir": Vector3(0.830, 0.311, 0.450), "radius": 0.036, "tip": 0.016, "length": 0.13},
				{"pos": Vector3(1.318, 1.008, 0.222), "dir": Vector3(0.782, 0.252, 0.560), "radius": 0.016, "length": 0.13},
				{"pos": Vector3(-0.418, 0.624, -0.030), "dir": Vector3(-0.880, 0.440, -0.140), "radius": 0.090, "tip": 0.086, "length": 0.11},
				{"pos": Vector3(-0.513, 0.673, -0.054), "dir": Vector3(-0.843, 0.430, -0.302), "radius": 0.086, "tip": 0.083, "length": 0.11},
				{"pos": Vector3(-0.590, 0.706, -0.134), "dir": Vector3(-0.425, 0.138, -0.888), "radius": 0.050, "tip": 0.046, "length": 0.14},
				{"pos": Vector3(-0.640, 0.717, -0.263), "dir": Vector3(-0.280, 0.017, -0.953), "radius": 0.046, "tip": 0.043, "length": 0.14},
				{"pos": Vector3(-0.652, 0.693, -0.406), "dir": Vector3(0.087, -0.314, -0.939), "radius": 0.038, "tip": 0.017, "length": 0.16},
				{"pos": Vector3(-0.624, 0.675, -0.558), "dir": Vector3(0.271, 0.097, -0.958), "radius": 0.017, "length": 0.16},
				{"pos": Vector3(-0.696, 0.734, -0.382), "dir": Vector3(-0.559, 0.244, -0.785), "radius": 0.034, "tip": 0.015, "length": 0.13},
				{"pos": Vector3(-0.768, 0.791, -0.469), "dir": Vector3(-0.542, 0.632, -0.554), "radius": 0.015, "length": 0.13},
				{"pos": Vector3(-0.614, 0.721, -0.064), "dir": Vector3(-0.894, 0.415, 0.124), "radius": 0.066, "tip": 0.064, "length": 0.12},
				{"pos": Vector3(-0.721, 0.770, -0.042), "dir": Vector3(-0.883, 0.389, 0.237), "radius": 0.064, "tip": 0.062, "length": 0.12},
				{"pos": Vector3(-0.810, 0.777, 0.059), "dir": Vector3(-0.368, -0.169, 0.907), "radius": 0.036, "tip": 0.016, "length": 0.19},
				{"pos": Vector3(-0.890, 0.811, 0.214), "dir": Vector3(-0.473, 0.521, 0.710), "radius": 0.016, "length": 0.19},
				{"pos": Vector3(-0.825, 0.816, -0.014), "dir": Vector3(-0.883, 0.389, 0.237), "radius": 0.051, "tip": 0.049, "length": 0.11},
				{"pos": Vector3(-0.925, 0.858, 0.020), "dir": Vector3(-0.862, 0.354, 0.347), "radius": 0.049, "tip": 0.048, "length": 0.11},
				{"pos": Vector3(-1.008, 0.858, 0.132), "dir": Vector3(-0.332, -0.203, 0.914), "radius": 0.034, "tip": 0.015, "length": 0.20},
				{"pos": Vector3(-1.085, 0.886, 0.299), "dir": Vector3(-0.437, 0.487, 0.757), "radius": 0.015, "length": 0.20},
				{"pos": Vector3(-1.022, 0.898, 0.058), "dir": Vector3(-0.862, 0.354, 0.347), "radius": 0.039, "tip": 0.038, "length": 0.11},
				{"pos": Vector3(-1.114, 0.934, 0.102), "dir": Vector3(-0.830, 0.311, 0.450), "radius": 0.038, "tip": 0.037, "length": 0.11},
				{"pos": Vector3(-1.185, 0.929, 0.209), "dir": Vector3(-0.295, -0.236, 0.919), "radius": 0.034, "tip": 0.015, "length": 0.18},
				{"pos": Vector3(-1.248, 0.949, 0.365), "dir": Vector3(-0.397, 0.450, 0.800), "radius": 0.015, "length": 0.18},
				{"pos": Vector3(-1.213, 0.971, 0.156), "dir": Vector3(-0.830, 0.311, 0.450), "radius": 0.036, "tip": 0.016, "length": 0.13},
				{"pos": Vector3(-1.318, 1.008, 0.222), "dir": Vector3(-0.782, 0.252, 0.560), "radius": 0.016, "length": 0.13},
			]
		ACCESSORY_TAIL:
			# SEGMENTED, SO IT CURVES UP.
			#
			# One straight cone could only ever point one way, and a tail that
			# does is a stick. Five segments chained nose-to-tail, each aimed a
			# little higher than the last, sweep from back-and-down at the rump to
			# nearly vertical at the tip -- the curve doing the work that length
			# alone could not.
			#
			# EACH SEGMENT'S TIP RADIUS IS THE NEXT ONE'S BASE, which is what makes
			# it read as one tapering tail rather than as five separate spikes.
			# Only the last comes to a point.
			#
			# The positions are the chain worked out by hand: every centre is the
			# previous segment's end plus half of its own length along its own
			# direction. They are written out rather than computed so the data
			# stays inspectable, and test_accessory.gd checks the joins line up.
			return [
				{"pos": Vector3(0.0, -0.100, 0.594), "dir": Vector3(0.0, -0.25, 0.97), "radius": 0.220, "tip": 0.185, "length": 0.40},
				{"pos": Vector3(0.0, -0.132, 0.966), "dir": Vector3(0.0, 0.10, 0.995), "radius": 0.185, "tip": 0.150, "length": 0.36},
				{"pos": Vector3(0.0, -0.042, 1.288), "dir": Vector3(0.0, 0.45, 0.893), "radius": 0.150, "tip": 0.115, "length": 0.32},
				{"pos": Vector3(0.0, 0.135, 1.524), "dir": Vector3(0.0, 0.75, 0.661), "radius": 0.115, "tip": 0.080, "length": 0.28},
				{"pos": Vector3(0.0, 0.354, 1.654), "dir": Vector3(0.0, 0.95, 0.312), "radius": 0.080, "tip": 0.0, "length": 0.24},
			]
		_:
			return []

static func is_accessory(kind: String) -> bool:
	return ACCESSORIES.has(kind)

# The body colour a player starts with: the blue the game has always used.
#
# A DELIBERATE DEFAULT RATHER THAN THE ABSENCE OF ONE. It is what most players
# are seen as for their first session, and this is the one value the whole art
# direction was built around -- player.tscn picked it to be "obviously not
# scenery", and hat_style.gd keeps blue out of the hat palette to keep it
# unambiguous. An unconfigured player therefore looks exactly like a player has
# always looked.
const DEFAULT_BODY := Color(0.25, 0.6, 0.85)
