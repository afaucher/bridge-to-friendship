extends RefCounted

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

# Every knob for one hat. Returned as a dictionary so a test can assert the
# numbers directly rather than inferring them from a mesh.
static func knobs(style_id: int) -> Dictionary:
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
	}

# Build this hat's own meshes and material.
#
# PER HAT, NEVER SHARED. The meshes and material in hat.tscn are sub-resources,
# so every instance of that scene shares them -- setting a radius on one would set
# it on every hat on the bridge. That is the same trap the status bar hit, where
# one player's bar re-tinted the whole party's, and it presents as things looking
# wrong at random rather than as anything shared.
static func apply(hat: Node3D) -> void:
	var crown := hat.get_node_or_null("Crown") as MeshInstance3D
	var brim := hat.get_node_or_null("Brim") as MeshInstance3D
	if crown == null or brim == null:
		return
	var k: Dictionary = knobs(hat.style_id)

	var material := StandardMaterial3D.new()
	material.albedo_color = k["colour"]
	material.roughness = 0.85

	var crown_mesh := CylinderMesh.new()
	crown_mesh.bottom_radius = k["base"]
	crown_mesh.top_radius = k["top"]
	crown_mesh.height = k["height"]
	crown.mesh = crown_mesh
	crown.material_override = material
	crown.position = Vector3(0.0, float(k["height"]) * 0.5, 0.0)

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
	brim.position = Vector3(0.0, BRIM_THICKNESS * 0.5, 0.0)

	# The collider follows the CROWN only. A wide thin brim collider catches on
	# deck seams, which is the intermittent-by-position bug CLAUDE.md warns about,
	# and a hat is meant to land and settle rather than balance on its edge.
	var shape := hat.get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		var cyl := CylinderShape3D.new()
		cyl.radius = maxf(float(k["base"]), float(k["top"]))
		cyl.height = k["height"]
		shape.shape = cyl
		shape.position = Vector3(0.0, float(k["height"]) * 0.5, 0.0)
