extends RefCounted

# HOW A PLAYER LOOKS: the body colour and the facing marker derived from it, the
# eyes, and the accessory. Presentation only -- nothing here is simulated, nothing
# rides capture_state(), and none of it collides (see the accessory's note).
# Part of PlayerBody, which forwards `apply_look` here.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const CharacterStyle = preload("res://scripts/present/models/character_style.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

# This avatar's own materials. Built on first use and then written through, so
# changing a colour never allocates again.
var body_material: StandardMaterial3D = null

var nose_material: StandardMaterial3D = null

# How far out of the head the eyes sit.
#
# The body is a cylinder of radius 0.4, so its surface at a given lateral offset
# x is at z = -sqrt(0.4^2 - x^2). Sitting an eye exactly there would bisect it;
# these push it slightly proud so it reads as a bump rather than as a decal, and
# the pupil sits proud of the sclera for the same reason.
const EYE_SINK := 0.015

# How far forward the pupil sits inside its own eye, as a fraction of that eye's
# radius. Past 1.0 it would float free of the sclera.
const PUPIL_FORWARD := 0.7

# Wear a body colour, and the facing marker that goes with it.
#
# PER-INSTANCE MATERIALS, CREATED HERE AND NEVER THE SCENE'S. player.tscn's Mat_1
# and NoseMat_1 are sub-resources, so EVERY INSTANCE OF THE SCENE SHARES THEM --
# writing albedo_color through the node would recolour the whole party. The
# status bar a hundred lines above hit precisely this and its comment records the
# fix; this is the same fix for the body.
#
# THE NOSE IS DERIVED, NOT PASSED IN. It is not a second choice the player makes
# and it must never become one: the marker's whole job is to be findable against
# the body behind it, and a player who could set both could set them equal. See
# character_style.gd -- pick yellow for both and the thing the dash depends on is
# gone.
func apply_look(body_colour: Color, character_seed: int = 0, accessory: String = "none") -> void:
	var mesh := body.get_node_or_null("Mesh") as MeshInstance3D
	var nose := body.get_node_or_null("Facing/Nose") as MeshInstance3D
	if mesh == null or nose == null:
		return
	if body_material == null:
		body_material = StandardMaterial3D.new()
		body_material.roughness = 0.7
		mesh.material_override = body_material
	if nose_material == null:
		nose_material = StandardMaterial3D.new()
		nose_material.roughness = 0.6
		nose.material_override = nose_material
	body_material.albedo_color = body_colour
	nose_material.albedo_color = CharacterStyle.nose_colour(body_colour)
	apply_eyes(character_seed)
	apply_accessory(accessory, body_colour)

# Build or update the four little meshes.
#
# IN CODE RATHER THAN IN player.tscn, because they are sized PER CHARACTER --
# hat_style.gd builds its crown and brim the same way and for the same reason. A
# scene cannot hold a shape that depends on a number the player carries.
#
# They hang off `Facing` so they turn with the aim, exactly like the nose. A face
# that stayed pointing north while the body turned would be worse than no face.
func apply_eyes(character_seed: int) -> void:
	var facing := body.get_node_or_null("Facing") as Node3D
	if facing == null:
		return
	var knobs: Dictionary = CharacterStyle.eye_knobs(character_seed)
	place_eye(facing, "EyeLeft", knobs["left"])
	place_eye(facing, "EyeRight", knobs["right"])

func place_eye(facing: Node3D, node_name: String, eye: Dictionary) -> void:
	var sclera := facing.get_node_or_null(node_name) as MeshInstance3D
	if sclera == null:
		sclera = MeshInstance3D.new()
		sclera.name = node_name
		facing.add_child(sclera)
		var pupil := MeshInstance3D.new()
		pupil.name = "Pupil"
		sclera.add_child(pupil)

	var size: float = float(eye["size"])
	var x: float = float(eye["x"])
	var y: float = float(eye["y"])
	# Where the cylinder's surface is at this lateral offset. Clamped because an
	# eye set wider than the body has no surface to sit on, and a NAN from a
	# negative square root would put the mesh nowhere at all.
	var span: float = maxf(RADIUS * RADIUS - x * x, 0.0001)
	var z: float = -sqrt(span) + EYE_SINK

	var ball := SphereMesh.new()
	ball.radius = size
	ball.height = size * 2.0
	sclera.mesh = ball
	sclera.position = Vector3(x, y, z)
	if sclera.material_override == null:
		var white := StandardMaterial3D.new()
		white.albedo_color = CharacterStyle.EYE_SCLERA
		white.roughness = 0.55
		sclera.material_override = white

	var pupil_node := sclera.get_node_or_null("Pupil") as MeshInstance3D
	if pupil_node == null:
		return
	var dot := SphereMesh.new()
	dot.radius = size * 0.45
	dot.height = size * 0.9
	pupil_node.mesh = dot
	# In the SCLERA's space, so it tracks whatever that eye's size and position
	# turn out to be rather than needing the maths done twice -- including on an
	# asymmetric face, where the two eyes are different sizes and a pupil offset
	# computed once would be wrong on one of them.
	pupil_node.position = Vector3(0.0, 0.0, -size * PUPIL_FORWARD)
	if pupil_node.material_override == null:
		var dark := StandardMaterial3D.new()
		dark.albedo_color = CharacterStyle.EYE_PUPIL
		dark.roughness = 0.4
		pupil_node.material_override = dark

# The chosen accessory: horns, antlers, a tail, or nothing.
#
# MESH ONLY. NO CollisionShape3D, NO LAYER, NO MASK, AND THAT IS A RULE RATHER
# THAN AN OVERSIGHT. art_direction.md's contract rule 3 allows decorative
# overhang exactly where nothing collides. A tail that catches a dash is a
# cosmetic that changes a fight; a horn you can stand on is the "hat you can
# stand on is a ladder" note in player.tscn, which is why worn hats have their
# shapes disabled. This slot is the line the whole feature sits on the safe side
# of -- the moment it acquires a collider it is equipment.
#
# It also cannot move the hats. `pose_stack` mounts a tower at
# `PlayerBody.HALF_HEIGHT`, a CONSTANT, so nothing here can raise it -- and
# test_accessory.gd asserts the spacing anyway, because that is only true for as
# long as the mount stays a constant.
#
# REBUILT WHOLESALE ON EVERY CHANGE. Accessories are exclusive, so switching from
# antlers to horns has to remove six parts and add two; growing the node list in
# place is how you end up wearing both.
func apply_accessory(kind: String, body_colour: Color) -> void:
	var facing := body.get_node_or_null("Facing") as Node3D
	if facing == null:
		return
	var root := facing.get_node_or_null("Accessory") as Node3D
	if root != null:
		facing.remove_child(root)
		root.queue_free()
	var parts: Array = CharacterStyle.accessory_parts(kind)
	if parts.is_empty():
		return

	root = Node3D.new()
	root.name = "Accessory"
	facing.add_child(root)

	var material := StandardMaterial3D.new()
	material.albedo_color = CharacterStyle.accessory_colour(body_colour)
	material.roughness = 0.75

	for part in parts:
		var piece := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.bottom_radius = float(part["radius"])
		# A POINT unless the part names a tip, which the tail's segments do so
		# each one's end matches the next one's start. Without that a chained tail
		# is five separate spikes rather than one tapering curve.
		cone.top_radius = float(part.get("tip", 0.0))
		cone.height = float(part["length"])
		piece.mesh = cone
		piece.material_override = material
		# AIMED BY DIRECTION, NOT BY EULER ANGLES. See CharacterStyle.aim_basis --
		# a part that sweeps out and up and back needs two composed rotations, and
		# composing Euler angles by hand is what this project has shipped
		# backwards three times.
		piece.position = part["pos"]
		piece.basis = CharacterStyle.aim_basis(part["dir"])
		root.add_child(piece)
