extends StaticBody3D

# A POST YOU DASH INTO TO GET A BUS.
#
# THE SAME VERB AS THE MERCHANT AND THE MODE SELECTOR, and for the same reasons
# the merchant took it: this game has two action bits and neither of them is
# `interact`, and a dash is not merely the available verb but the right one. It
# is committed, it is aimed, and it is unmistakably deliberate -- nobody calls a
# bus by walking past one.
#
# WHY A POST RATHER THAN A RULE. The world could simply keep a bus per player
# alive and replace them silently, and an earlier draft did. It is worse in a way
# that is easy to miss: a vehicle that reappears on its own has no cost, so
# driving into the void stops being a mistake, and the party never has to decide
# whether the walk back is worth it. A post is a PLACE, so losing your bus means
# going somewhere, and where it is placed is a design decision rather than an
# absence of one.
#
# ONE AT THE MIDDLE OF EVERY LEVEL THAT HAS BUSES IN IT. Halfway is the furthest
# you can ever be from it, which is the walk being paid for.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

const LAYER := 1024             # shared with the mode post: both are `posts`

const POST_HEIGHT := 1.9
const POST_WIDTH := 0.3
const SIGN_WIDTH := 0.9
const SIGN_HEIGHT := 0.5

const POST_COLOUR := Color(0.24, 0.23, 0.27)
# The bus's own deck yellow, so the sign says what it gives you without a word
# on it -- there is no font in this game and a colour is legible at sixty metres.
const SIGN_COLOUR := Color(0.82, 0.68, 0.22)

# WHICH CELL IT STANDS IN, so the world can put the bus down beside it rather
# than beside the person who dashed it -- who is, by definition, moving fast in a
# direction they chose.
var cell: Vector2i = Vector2i.ZERO

# WHEN IT MAY BE HAILED AGAIN, in world ticks.
#
# A COOLDOWN RATHER THAN AN EDGE, because the contact is not a single event: a
# dash sweeps several times against the same body, and `move_and_slide` reports
# each one. Without this a single dash produces a heap of buses in one tick --
# which is also the coincident-bodies trap, so it would put them through the
# floor as well.
var ready_at: int = 0

var _sign: MeshInstance3D = null

func _ready() -> void:
	collision_layer = LAYER
	_build()

# THE DUCK THE DASH ASKS FOR. `_apply_shove_contact` dispatches on what a body
# can DO rather than on what it is -- the same shape as `can_trade` and
# `can_select` -- so adding a post is a method here and one branch there.
func can_hail() -> bool:
	return true

func hailed(at_tick: int) -> bool:
	if at_tick < ready_at:
		return false
	ready_at = at_tick + SimConfig.BUS_POST_COOLDOWN_TICKS
	return true

func _build() -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(POST_WIDTH, POST_HEIGHT, POST_WIDTH)
	shape.shape = box
	shape.position = Vector3(0.0, POST_HEIGHT * 0.5, 0.0)
	add_child(shape)

	var post := MeshInstance3D.new()
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(POST_WIDTH, POST_HEIGHT, POST_WIDTH)
	post.mesh = post_mesh
	post.position = Vector3(0.0, POST_HEIGHT * 0.5, 0.0)
	var post_material := StandardMaterial3D.new()
	post_material.albedo_color = POST_COLOUR
	post.material_override = post_material
	add_child(post)
	post.name = "Post"

	# THE SIGN, at head height and lit from itself so it reads across a lobby and
	# in the shadow the walls throw. Per-instance material: a material on a mesh
	# resource is shared by every instance of it, so tinting one would tint every
	# post on the bridge -- the trap hat_style.gd carries a note about.
	_sign = MeshInstance3D.new()
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(SIGN_WIDTH, SIGN_HEIGHT, 0.08)
	_sign.mesh = sign_mesh
	_sign.position = Vector3(0.0, POST_HEIGHT - SIGN_HEIGHT * 0.6, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = SIGN_COLOUR
	material.emission_enabled = true
	material.emission = SIGN_COLOUR
	material.emission_energy_multiplier = 0.6
	_sign.material_override = material
	add_child(_sign)
	_sign.name = "Sign"
