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
# THE PLATE IS DARK AND THE DEVICE ON IT IS BRIGHT, which is the way round that
# makes it a sign.
#
# It was a plain slab of the bus's own yellow, and it was reported twice as
# "facing the wrong way" -- for the mode post first and then for this one. The
# diagnosis that suggests itself is orientation, and it is wrong: a box has two
# identical faces and neither of them is the back. THERE WAS NOTHING ON IT. A
# blank rectangle reads as the back of a sign because a sign is a thing with
# something on its front, and an empty one has no front to be looking at.
#
# So the plate went dark and the bus went on it. There is no font in this game --
# see the note in mode_post.gd -- so the legend is geometry, which also survives
# being sixty metres away better than a word would.
const PLATE_COLOUR := Color(0.16, 0.15, 0.18)
const SIGN_COLOUR := Color(0.82, 0.68, 0.22)
const WHEEL_COLOUR := Color(0.12, 0.12, 0.14)

# The little bus, in sign-plate units.
const DEVICE_WIDTH := 0.52
const DEVICE_HEIGHT := 0.2
const DEVICE_WHEEL := 0.07
# HOW FAR THE DEVICE STANDS OFF THE PLATE. Proud rather than flush: co-planar
# faces z-fight, and a raised device also catches the light differently from the
# plate behind it, which is most of what makes it read as ON something.
const DEVICE_PROUD := 0.045

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

	# THE SIGN: a dark plate at head height, with a bus on the front of it.
	#
	# Lit from itself so it reads across a lobby and in the shadow the walls
	# throw. Per-instance material: a material on a mesh resource is shared by
	# every instance of it, so tinting one would tint every post on the bridge --
	# the trap hat_style.gd carries a note about.
	_sign = MeshInstance3D.new()
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(SIGN_WIDTH, SIGN_HEIGHT, 0.08)
	_sign.mesh = sign_mesh
	# MOUNTED ON THE FRONT OF THE POST, NOT THROUGH IT.
	#
	# THIS IS THE ACTUAL BUG, and it was reported as "facing the wrong way" for
	# both posts. The plate sat at z = 0, the same as the pole -- so the pole's
	# near half stood 15 cm PROUD of a plate 4 cm thick, straight down the middle
	# of it. From behind, which is the only place anybody stands, a post is a
	# stripe across its own sign, and a sign you cannot read the middle of reads
	# as one whose front is somewhere else.
	#
	# Two wrong diagnoses came first and both are worth the room: that the sign
	# needed tilting toward the 45-degree camera, and that it needed something ON
	# it. The second was true and insufficient -- a device at z = 0 would have been
	# hidden behind the pole exactly as the blank plate was.
	_sign.position = Vector3(0.0, POST_HEIGHT - SIGN_HEIGHT * 0.6,
		POST_WIDTH * 0.5 + 0.04)
	_sign.material_override = _lit(PLATE_COLOUR, 0.25)
	add_child(_sign)
	_sign.name = "Plate"

	# THE DEVICE, ON THE FRONT. Front is +Z: the party walks up-bridge toward -Z
	# and the camera sits behind them, so +Z is the face anybody ever sees. A
	# device on the other side would be a sign for nobody -- and this is the sort
	# of sign error a bounding box cannot see, so `test_bus_post` asserts the
	# device is on the +Z side of the plate rather than merely present.
	var front: float = 0.04 + DEVICE_PROUD
	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(DEVICE_WIDTH, DEVICE_HEIGHT, DEVICE_PROUD * 2.0)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.05, front)
	body.material_override = _lit(SIGN_COLOUR, 0.7)
	_sign.add_child(body)
	body.name = "Bus"

	# TWO WHEELS UNDER IT, which is the whole of what makes a yellow rectangle a
	# bus rather than a yellow rectangle.
	for i in 2:
		var wheel := MeshInstance3D.new()
		var wheel_mesh := BoxMesh.new()
		wheel_mesh.size = Vector3(DEVICE_WHEEL, DEVICE_WHEEL, DEVICE_PROUD * 2.0)
		wheel.mesh = wheel_mesh
		wheel.position = Vector3(
			DEVICE_WIDTH * (0.28 if i == 0 else -0.28),
			0.05 - DEVICE_HEIGHT * 0.5 - DEVICE_WHEEL * 0.35,
			front)
		wheel.material_override = _lit(WHEEL_COLOUR, 0.0)
		_sign.add_child(wheel)
		wheel.name = "Wheel%d" % i

# A material that carries its own light, so a sign is legible at distance and in
# shadow. Emission energy is a separate argument because the plate wants a hint
# and the device wants to glow.
func _lit(colour: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	if energy > 0.0:
		material.emission_enabled = true
		material.emission = colour
		material.emission_energy_multiplier = energy
	return material
