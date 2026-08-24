extends RefCounted

# Safe: sim_config.gd preloads nothing at all, so this cannot close a class cycle
# -- which CLAUDE.md notes HANGS a run rather than failing it.
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# What a hat LOOKS like, derived entirely from its style_id.
#
# A PURE FUNCTION OF THE ID, NEVER ROLLED AT SPAWN, and that is the constraint
# the whole thing hangs on rather than a preference.
#
# style_id travels with a hat forever and is deliberately not reset on pickup:
# you keep wearing the hat you stole, and "that is MY hat on your head" is the
# sentence the feature exists to produce. If the knobs were rolled with randf()
# when a hat spawned, the same hat would be a different shape on every machine
# and a stolen hat would silently become a different hat. Randomise the ID;
# derive the hat from it.
#
# It is also free to replicate -- the wire already carries style_id and nothing
# else has to travel -- and free to test, because an id has one correct answer on
# every machine and in every run.
#
# The generator is the same well-known integer mixer segment_pool.plan() uses to
# derive a run from a seed, and for the same reason: NOT the global RNG, which is
# entropy-seeded per launch and would make every one of these answers different
# on Tuesday.

# HAND-PICKED, NOT RANDOM RGB. Random colour produces mud, and this palette has a
# narrow window to hit: the deck is two browns, the parapets and stones are more
# brown, the players are blue, a rusher is hot red-orange and a plinko ball is
# near-black. A hat has to read as "not scenery, not a player, not a threat" from
# across a 60 m bridge, so blues and red-oranges are deliberately absent.
const PALETTE := [
	Color(0.95, 0.82, 0.25),   # yellow
	Color(0.87, 0.35, 0.62),   # pink
	Color(0.58, 0.40, 0.88),   # violet
	Color(0.22, 0.76, 0.70),   # teal
	Color(0.58, 0.83, 0.30),   # lime
	Color(0.94, 0.93, 0.88),   # cream
	Color(0.55, 0.28, 0.72),   # deep purple
	Color(0.30, 0.55, 0.35),   # forest green
]

# The ranges. Wide on purpose: the point is that one segment turns up a tiny
# pillbox and an enormous floppy thing, so the extremes have to be genuinely far
# apart or every hat reads as the same hat.
const HEIGHT_MIN := 0.10
const HEIGHT_MAX := 0.55

const BASE_MIN := 0.16          # where the crown meets the head
const BASE_MAX := 0.30

# The top, as a multiple of the base: under 1 is a cone, over 1 is a bucket.
const TOP_RATIO_MIN := 0.45
const TOP_RATIO_MAX := 1.35

# The brim, as a multiple of the base. 1.05 is barely a brim at all; 2.2 is the
# big floppy one.
const RIM_RATIO_MIN := 1.05
const RIM_RATIO_MAX := 2.20

# How much the brim's outer edge lifts or droops, as a fraction of the rim.
# Positive turns the edge up, negative lets it sag.
const CURL_MIN := -0.22
const CURL_MAX := 0.30

const BRIM_THICKNESS := 0.05

# --- The merchant's hat -------------------------------------------------------
#
# A RESERVED BAND OF STYLE IDS, NOT A FLAG ON THE BODY. See
# design_ideas/merchant.md; the short version is that style_id is the only thing
# about a hat's appearance that travels, so anything derived from it replicates,
# persists and reaches a late joiner for free, while a second field would have to
# be taught to do each of those separately.
#
# THE LOW BAND, AND THAT IS NOT ARBITRARY. `negative means tall` was the other
# obvious encoding and it is a live grenade: HatPool.spawn_loose rolls a raw
# randi(), which is negative half the time, so it would promote half of every hat
# already saved on every machine to a stovepipe on the next launch. A saved id
# landing in 0..7 by chance is one in 2^28.
const TALL_STYLE_COUNT := 8

# How many ordinary slots one of these occupies. 3.5 x HAT_HEIGHT is 1.225 m in a
# single slot -- see SimConfig.TALL_HAT_SLOTS, which is where the number lives so
# that the sim and the look cannot drift apart.
const TALL_FIRST := 0

static func is_tall(style_id: int) -> bool:
	return style_id >= TALL_FIRST and style_id < TALL_FIRST + TALL_STYLE_COUNT

# A style id for an ORDINARY hat. The one and only roll in the hat system, and it
# exists so that "the merchant is the only source" is a property of the code
# rather than a promise in a document: every other spawn path goes through here.
static func random_ordinary_style() -> int:
	return TALL_FIRST + TALL_STYLE_COUNT + absi(randi() % (1 << 30))

# Which tall hat, 0-based. Rolled by the merchant so two players who both traded
# are not wearing the identical trophy.
static func random_tall_style() -> int:
	return TALL_FIRST + absi(randi()) % TALL_STYLE_COUNT

static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)

# A 0..1 draw for one knob. `salt` keeps the knobs independent -- without it every
# knob of a given hat would be the same number, and a tall hat would always be a
# wide one.
static func _draw(style_id: int, salt: int) -> float:
	return float(_mix(style_id * 8191 + salt * 7919) % 10000) / 9999.0

static func _between(style_id: int, salt: int, low: float, high: float) -> float:
	return low + (high - low) * _draw(style_id, salt)

# HOW TALL A SLOT THIS HAT OCCUPIES IN A WORN TOWER.
#
# THE SLOT IS THE HAT. One number for the spacing, the hit column, the art and the
# score, so none of them can disagree with any other -- and every site that stacks
# or shoots at a hat asks this one function. Get the SPACING from here and leave
# the HIT COLUMN on a constant and you have rebuilt the 2026-08-16 gappy tower on
# purpose, with 0.88 m of hat a round passes straight through.
#
# IT USED TO BE A FLAT `HAT_HEIGHT` FOR ORDINARY HATS, on the reasoning that a
# fixed slot is what makes the hit columns tile. That is true and it is not the
# only way to be true: columns tile whenever the spacing equals the column, and
# equal-to-the-art tiles just as exactly as equal-to-a-constant. What the constant
# bought was uniformity; what it cost was the art.
#
# MEASURED 2026-08-23, from a playtest of the character screen -- "the first hat
# was flat on the head but the second was floating above the first". Ordinary hats
# are drawn 0.10 to 0.55 tall against a 0.35 slot, so a stacked hat floated by up
# to **0.226 m** or sank **0.183 m** into the one below. Tall hats never had the
# problem: `_tall_knobs` sizes the model FROM the slot, so theirs already agreed.
# This makes ordinary hats behave the way tall ones already did.
#
# WHAT IT COSTS, stated because a hit column is a fairness question: a short hat is
# now a genuinely smaller target, 0.12 m against 0.55 m at the extremes. That is
# the honest version -- the hit test matches what the shooter can see, which is
# the rule this project keeps relearning, most recently on the spikes whose damage
# ring bore no relation to the cones drawn in it.
static func slot_height(style_id: int) -> float:
	if is_tall(style_id):
		return SimConfig.HAT_HEIGHT * SimConfig.TALL_HAT_SLOTS
	return float(knobs(style_id)["height"])

# HOW FAR ABOVE THE BOTTOM OF ITS SLOT THIS HAT'S ORIGIN SITS.
#
# The two kinds of hat put their origin in different places -- see `floor_y` in
# apply_style: an ordinary hat STANDS ON its origin, a tall one STRADDLES it --
# and every stacking site was placing both at the slot's CENTRE regardless.
#
# For a tall hat that is right. For an ordinary one it lifts the brim half a slot
# clear of whatever it is meant to be resting on: HAT_HEIGHT is 0.35, so **every
# ordinary hat in the game floated 17.5 cm above the head**. Reported 2026-08-22
# off the character screen, where a close side view made it obvious; in play the
# camera looks down at 45 degrees and it read as a tall hat rather than as a bug.
#
# THE SLOT DOES NOT MOVE. Spacing and the worn hit column are still `slot_height`
# and still tile with no seam -- this only says where inside its slot the model
# hangs, which is the one thing that was wrong.
static func mount_offset(style_id: int) -> float:
	if is_tall(style_id):
		return slot_height(style_id) * 0.5
	return 0.0

# THE TROPHY, and the reason it is not just an ordinary hat with the height knob
# turned up: it is sized against the SLOT rather than against the catalogue.
#
# The eight differ in colour and in width, never in height. A tall hat has to be
# recognisable as THE tall hat from across a 60 m bridge -- that is the entire
# thing being sold -- so the silhouette is fixed and only the paint changes.
static func _tall_knobs(style_id: int) -> Dictionary:
	var slot: float = slot_height(style_id)
	var base: float = 0.28 + 0.05 * _draw(style_id, 11)
	return {
		"base": base,
		# Very slightly flared, so it reads as a stovepipe rather than as a pipe.
		"top": base * (1.02 + 0.10 * _draw(style_id, 12)),
		"rim": base * (1.35 + 0.25 * _draw(style_id, 13)),
		"height": slot,
		"curl": -0.05 + 0.15 * _draw(style_id, 14),
		"colour": PALETTE[_mix(style_id * 104729 + 17) % PALETTE.size()],
		# CENTRED ON THE ORIGIN rather than standing on it, which is what an
		# ordinary hat does. See apply(): it is what makes the art and the worn hit
		# column occupy exactly the same 1.225 m, and at this size that stops being
		# a detail -- a hat drawn 0.6 m above the box that catches bullets is the
		# "hit test disagrees with the art" trap, which has reached playtest twice
		# in this project already.
		"centred": true,
	}

# Every knob for one hat. Returned as a dictionary so a test can assert the
# numbers directly rather than inferring them from a mesh.
static func knobs(style_id: int) -> Dictionary:
	if is_tall(style_id):
		return _tall_knobs(style_id)
	var base: float = _between(style_id, 1, BASE_MIN, BASE_MAX)
	var top: float = base * _between(style_id, 2, TOP_RATIO_MIN, TOP_RATIO_MAX)
	var rim: float = base * _between(style_id, 3, RIM_RATIO_MIN, RIM_RATIO_MAX)
	var height: float = _between(style_id, 4, HEIGHT_MIN, HEIGHT_MAX)
	var curl: float = _between(style_id, 5, CURL_MIN, CURL_MAX)
	return {
		"base": base,
		"top": top,
		"rim": rim,
		"height": height,
		"curl": curl,
		"colour": PALETTE[_mix(style_id * 104729 + 17) % PALETTE.size()],
		# An ordinary hat STANDS ON its origin, which is what a hat resting on the
		# deck wants: place_loose puts the origin on the surface and the hat sits
		# on top of it.
		"centred": false,
	}

# Build this hat's own meshes and material.
#
# PER HAT, NEVER SHARED. The meshes and material in hat.tscn are sub-resources,
# so every instance of that scene shares them -- setting a radius on one would set
# it on every hat on the bridge. That is the same trap the status bar hit, where
# one player's bar re-tinted the whole party's, and it presents as things looking
# wrong at random rather than as anything shared.
static func apply(hat: Node3D) -> void:
	apply_style(hat, hat.style_id)

# The same thing with the style passed IN, for a node that is not a HatBody.
#
# The merchant holds one of these up as signage, and it is built from this
# function rather than modelled by hand so that the thing on the counter is
# provably the thing you get -- a lookalike would drift the first time the
# trophy's proportions were tuned. A plain Node3D has no `style_id`, and reading
# a property that does not exist RAISES and silently aborts the rest of the
# calling function, which is the GDScript trap CLAUDE.md opens with.
static func apply_style(hat: Node3D, style_id: int) -> void:
	var crown := hat.get_node_or_null("Crown") as MeshInstance3D
	var brim := hat.get_node_or_null("Brim") as MeshInstance3D
	if crown == null or brim == null:
		return
	var k: Dictionary = knobs(style_id)

	var material := StandardMaterial3D.new()
	material.albedo_color = k["colour"]
	material.roughness = 0.85

	# WHERE THE HAT SITS RELATIVE TO ITS OWN ORIGIN. An ordinary hat stands on it
	# (base = 0); a tall hat straddles it. Everything below -- crown, brim and the
	# loose collider -- is measured from this one number, so the three cannot drift
	# apart and a loose tall hat still rests on the deck rather than half inside
	# it: the collider is what decides where a rigid body settles, and it moves
	# with the mesh.
	var floor_y: float = -float(k["height"]) * 0.5 if bool(k.get("centred", false)) else 0.0

	var crown_mesh := CylinderMesh.new()
	crown_mesh.bottom_radius = k["base"]
	crown_mesh.top_radius = k["top"]
	crown_mesh.height = k["height"]
	crown.mesh = crown_mesh
	crown.material_override = material
	crown.position = Vector3(0.0, floor_y + float(k["height"]) * 0.5, 0.0)

	# CURL IS THE CONE OF THE BRIM. A cylinder whose top radius exceeds its
	# bottom radius has its widest edge at the top, which reads as an upturned
	# brim; the other way round it sags. One knob, no extra geometry.
	var brim_mesh := CylinderMesh.new()
	var curl: float = float(k["rim"]) * float(k["curl"])
	brim_mesh.bottom_radius = maxf(0.02, float(k["rim"]) - curl * 0.5)
	brim_mesh.top_radius = maxf(0.02, float(k["rim"]) + curl * 0.5)
	brim_mesh.height = BRIM_THICKNESS
	brim.mesh = brim_mesh
	brim.material_override = material
	brim.position = Vector3(0.0, floor_y + BRIM_THICKNESS * 0.5, 0.0)

	# The collider follows the CROWN only. A wide thin brim collider catches on
	# deck seams, which is the intermittent-by-position bug CLAUDE.md warns about,
	# and a hat is meant to land and settle rather than balance on its edge.
	var shape := hat.get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		var cyl := CylinderShape3D.new()
		cyl.radius = maxf(float(k["base"]), float(k["top"]))
		cyl.height = k["height"]
		shape.shape = cyl
		shape.position = Vector3(0.0, floor_y + float(k["height"]) * 0.5, 0.0)
