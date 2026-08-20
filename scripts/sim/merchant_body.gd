extends StaticBody3D

# THE MERCHANT. The first NPC in this game that is not trying to kill you, and
# the first place one kind of value turns into another.
#
# He takes one hat off your tower and gives back one three and a half times
# taller -- the only source of such a hat -- and you pay by DASHING INTO HIM.
# Full design and the reasoning behind each rule is in design_ideas/merchant.md.
#
# A STATIC BODY WITH A SCRIPT, not a scene, and built in code like cover and
# spikes are. There is nothing to author per-instance: every merchant is the same
# merchant, and the only thing that varies is whether he has sold yet.
#
# HE IS GRID CONTENT, so he is a pure function of the seed like a mound or a
# shooter: every machine builds him from the segment, and the ONLY thing that
# crosses the wire is that he is spent. That is the same treatment
# BridgeGrid._spent_mounds gets and for the same reason -- a merchant changes
# state exactly once in his life, so one compact message on join beats a field in
# the per-tick snapshot.
#
# HIS OWN COLLISION LAYER (10), rather than parking him on `stones` because that
# bit is already in the player mask. Stones would have worked today and would
# have meant every rule ever written about a stone quietly acquiring an opinion
# about the shopkeeper -- starting with resolve_shove_contact directly, where a
# dash into a stone pushes it one cell.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")

const LAYER := 512              # `merchant`, see project.godot [layer_names]

# Sold or not. One sale each, which is what makes him CONTESTED -- four players
# and an unlimited shopkeeper is four dumped hats and four tall ones, which is
# neither rare nor a decision.
var spent: bool = false

# Which cell he stands in, so BridgeGrid can record him as spent by cell the way
# it records a taken mound.
var cell: Vector2i = Vector2i.ZERO

var _stock: Node3D = null

const BODY_HEIGHT := 1.6
const BODY_WIDTH := 0.7

# Deliberately NOT any of the palette colours a hat can be: he has to read as a
# person rather than as a large hat somebody left standing there.
const COAT_COLOUR := Color(0.30, 0.26, 0.38)
const HEAD_COLOUR := Color(0.78, 0.63, 0.50)

func _ready() -> void:
	collision_layer = LAYER
	# MASKING NOTHING. He never moves and never asks what he is touching; the
	# contact that matters is detected from the DASHER's own slide collisions, so
	# what has to be true is that HIS layer is in the PLAYER's mask -- which is
	# the half that has been one wrong bit five separate times in this project.
	collision_mask = 0
	_build()

func _build() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(BODY_WIDTH, BODY_HEIGHT, BODY_WIDTH)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(col)

	var coat := StandardMaterial3D.new()
	coat.albedo_color = COAT_COLOUR
	coat.roughness = 0.9

	var torso := MeshInstance3D.new()
	var torso_box := BoxMesh.new()
	torso_box.size = Vector3(BODY_WIDTH, BODY_HEIGHT, BODY_WIDTH)
	torso.mesh = torso_box
	torso.material_override = coat
	torso.position = col.position
	add_child(torso)

	var skin := StandardMaterial3D.new()
	skin.albedo_color = HEAD_COLOUR
	skin.roughness = 0.85

	var head := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.26
	ball.height = 0.52
	head.mesh = ball
	head.material_override = skin
	head.position = Vector3(0.0, BODY_HEIGHT + 0.2, 0.0)
	add_child(head)

	_build_stock()

# WHAT HE IS SELLING, HELD UP WHERE YOU CAN SEE IT.
#
# This is the whole of the "interface". There is no dialogue system and this does
# not want one: a reward you can see from the entry row pulls a player through a
# hazard, and one they discover afterwards was a tax. He is holding the tall hat;
# after a sale he is not, which is also the only feedback needed for "this one is
# used up".
#
# Drawn from the REAL style function rather than modelled by hand, so the thing
# on the counter is the thing you get. A hand-built lookalike would drift the
# first time the trophy's proportions were tuned.
func _build_stock() -> void:
	var sample := Node3D.new()
	sample.name = "Stock"

	var crown := MeshInstance3D.new()
	crown.name = "Crown"
	sample.add_child(crown)
	var brim := MeshInstance3D.new()
	brim.name = "Brim"
	sample.add_child(brim)

	# apply_style rather than apply, because a plain Node3D has no `style_id` and
	# reading one that does not exist raises. It writes the two meshes and skips
	# the `Shape` child when there is none, which is what makes it reusable as a
	# display model with no collider.
	#
	# The FIRST tall style rather than a roll: this is signage, so it must look the
	# same on every machine without anything being replicated to make it so. What
	# you actually receive is rolled at the moment of the trade.
	HatStyle.apply_style(sample, HatStyle.TALL_FIRST)

	# Held out to one side at chest height, clear of the body so its silhouette
	# reads against the deck rather than against his coat.
	sample.position = Vector3(0.55, BODY_HEIGHT * 0.62, 0.0)
	add_child(sample)
	_stock = sample

# --- The trade ----------------------------------------------------------------

# Called by GameWorld.resolve_shove_contact when a dash lands on him. The world
# owns the rules -- what the top hat is, whether it is tall, what the payment
# gets destroyed by -- because all of that is hat-pool state he has no business
# knowing about. He owns exactly one fact: whether he has sold.
func can_trade() -> bool:
	return not spent

func mark_spent() -> void:
	spent = true
	if is_instance_valid(_stock):
		_stock.visible = false

# Told, not decided. A client builds the same merchant from the same seed and is
# handed the spent set on join; this is the line that applies it.
func apply_spent(is_spent: bool) -> void:
	if is_spent and not spent:
		mark_spent()
