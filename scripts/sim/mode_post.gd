extends StaticBody3D

# THE SELECTOR. M25 phase 2: the in-world control that says what the next stretch
# of bridge will be.
#
# A MERCHANT WITH A DIFFERENT JOB, which is the plan's own description and most of
# the answer: a grid-resident thing you walk up to and DASH INTO. Everything about
# the shape is borrowed from `merchant_body.gd` deliberately -- a static body built
# in code rather than a scene, its own collision layer, and a marker method the
# shove dispatch keys on -- because a second control that worked differently would
# be a second thing to learn for no reason.
#
# WHY A DASH AND NOT AN INTERACT. The game has action bits for shove, special and
# call, and none of them is `interact`. The dash is the right verb rather than
# merely the available one: it is committed, aimed, and unmistakably deliberate,
# so nobody changes the party's next twenty minutes by walking past.
#
# LAST WRITE WINS, AND THAT IS THE DESIGN. Anyone may set it; there is no vote and
# no consensus. In a four-player co-op a vote can deadlock and losing one means
# being dragged somewhere you did not choose, so social pressure does the work a
# tie-break would -- and the failure mode is somebody being cheeky rather than
# nobody being able to start.
#
# IT LIVES IN THE LOBBY, which is why it is safe for it to be dashable at all: the
# lobby is always base, the corridor past it is speculative, and the party is
# standing still behind a wall while it is re-cut.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")

const LAYER := 1024             # `mode_post`, see project.godot [layer_names]

const POST_HEIGHT := 1.9
const POST_WIDTH := 0.34
const BANNER_HEIGHT := 0.55
const BANNER_WIDTH := 1.1

# Which cell it stands in, so the grid can find it again.
var cell: Vector2i = Vector2i.ZERO

# What it is currently showing. Display only -- the decision lives on the host in
# `GameWorld.selected_mode`, and this follows it. A client is told by RPC rather
# than deriving it, because a selection is a CHOICE and choices do not fall out of
# a seed the way terrain does.
var showing: int = GameMode.BASE

var _banner: MeshInstance3D = null

# ONE COLOUR PER MODE, and the post is the only place they are used. Deliberately
# not from the hat palette: a hat is loot and this is furniture, and the one thing
# a player must never do is read the selector as something to collect.
const MODE_COLOURS := {
	GameMode.BASE: Color(0.42, 0.62, 0.86),
	GameMode.BLANK: Color(0.86, 0.84, 0.52),
}
const UNKNOWN_COLOUR := Color(0.55, 0.55, 0.58)

func _ready() -> void:
	collision_layer = LAYER
	# MASKING NOTHING, exactly as the merchant does. It never moves and never asks
	# what it is touching -- the contact that matters is found in the DASHER's own
	# slide collisions, so the half that has to be true is that this layer is in
	# the PLAYER's mask. That is the bit this project has got wrong five times.
	collision_mask = 0
	_build()

# THE MARKER THE SHOVE DISPATCH KEYS ON. `resolve_shove_contact` asks
# `has_method("can_select")` the same way it asks `has_method("can_trade")` --
# which keeps the question "what did I just dash into" on the thing dashed into
# rather than in a chain of type tests inside the mover.
func can_select() -> bool:
	return true

func _build() -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(POST_WIDTH, POST_HEIGHT, POST_WIDTH)
	shape.shape = box
	shape.position = Vector3(0.0, POST_HEIGHT * 0.5, 0.0)
	add_child(shape)

	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(POST_WIDTH, POST_HEIGHT, POST_WIDTH)
	post.mesh = post_mesh
	post.position = Vector3(0.0, POST_HEIGHT * 0.5, 0.0)
	var post_material := StandardMaterial3D.new()
	post_material.albedo_color = Color(0.24, 0.23, 0.27)
	post.material_override = post_material
	add_child(post)

	# THE BANNER IS THE READOUT, and it is the whole of the art: a slab at head
	# height whose colour is the chosen mode. No text, because there is no font in
	# this game and a word nobody can read at sixty metres is worse than a colour
	# they can.
	_banner = MeshInstance3D.new()
	_banner.name = "Banner"
	var banner_mesh := BoxMesh.new()
	banner_mesh.size = Vector3(BANNER_WIDTH, BANNER_HEIGHT, 0.08)
	_banner.mesh = banner_mesh
	_banner.position = Vector3(0.0, POST_HEIGHT - BANNER_HEIGHT * 0.6, 0.0)
	# PER INSTANCE, never shared. A material on a mesh resource is shared by every
	# instance of it, so tinting one post would tint every post on the bridge --
	# the trap hat_style.gd carries a note about, and the status bar hit first.
	_banner.material_override = StandardMaterial3D.new()
	add_child(_banner)
	_apply_colour()

# SHOW A MODE. Called on both machines: the host when somebody dashes it, a client
# when it is told. Cheap enough to call every time rather than diffing, and a
# no-op when nothing changed.
func show_mode(mode: int) -> void:
	if mode == showing:
		return
	showing = mode
	_apply_colour()

func _apply_colour() -> void:
	if _banner == null:
		return
	var material := _banner.material_override as StandardMaterial3D
	if material == null:
		return
	var colour: Color = MODE_COLOURS.get(showing, UNKNOWN_COLOUR)
	material.albedo_color = colour
	# LIT FROM ITSELF, so the banner reads at a distance and in the shadow the
	# lobby's walls throw. It is a signal rather than a surface.
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = 0.6

# THE NEXT MODE IN THE REGISTRY, wrapping. Order is the registry's order, which
# puts base first -- so a party that dashes it until they are bored ends up back
# at the ordinary game rather than somewhere strange.
static func next_after(mode: int) -> int:
	var ids: Array = GameMode.ids()
	if ids.is_empty():
		return GameMode.BASE
	var at: int = ids.find(mode)
	return int(ids[(at + 1) % ids.size()]) if at >= 0 else int(ids[0])
