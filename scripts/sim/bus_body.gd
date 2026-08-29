extends CharacterBody3D

# THE BUS. M25 phase 3: a drivable vehicle that lives in the blank zone.
#
# A CHARACTERBODY3D, NOT A RIGIDBODY, and this project has the receipt for why.
# `CharacterBody3D` is the wrong body for anything that ROLLS -- the plinko balls
# proved that -- but a bus is not rolling, it is DRIVEN: its motion is a designed
# rule rather than a physics outcome, it is host-authoritative, and the wheels are
# scenery. That is exactly the case `move_and_slide` is for.
#
# IT GROWS. One rider is a cab; each extra rider adds a seat and the body gets
# longer. So the shape is rebuilt when the roster changes rather than sized once,
# and every offset is computed from the CURRENT length rather than baked.
#
# RIDERS ARE PLANTED, NOT CARRIED. They are posed onto their slot every tick, the
# way a worn hat is posed onto a head -- nothing rides the platform in the physics
# sense. That is deliberate and it retires the milestone's biggest technical
# unknown before it can be asked: "does a predicted client riding a moving platform
# stay put?" has no answer here because nothing rides. It also sidesteps the whole
# carrier/rider tangle CLAUDE.md opens with -- a body cannot walk while another
# body rests on it, `add_collision_exception_with` is mutual, and Godot transports
# a rider one tick late.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

const LAYER := 2048             # `bus`, see project.godot [layer_names]

# THE SHAPE. A tiny platform on purpose -- no walls, no roof -- because the whole
# point is that the party is visibly standing on it. A box with sides would hide
# the thing it is carrying.
# BARELY WIDER THAN THE PERSON STANDING ON IT. A player is 0.8 m across, so this
# is a hand's width of deck either side -- it reads as a board with wheels rather
# than as a vehicle you stand inside, which is the whole look: the party is
# visibly balanced on it.
const WIDTH := 1.1
const DECK_THICK := 0.35
# The cab, before anybody is aboard, and what each rider past the first adds.
#
# TIGHT AT BOTH ENDS. These were 3.2 and 1.5, which left a metre of empty deck in
# front of the driver and behind the last passenger -- so a full bus read as a
# platform with people somewhere on it rather than as a queue of people with just
# enough bus to stand on. The seat is a shade over a body width and the cab adds
# only what the wheels need.
const BASE_LENGTH := 1.6
const SEAT_LENGTH := 1.0
const WHEEL_RADIUS := 0.42
const WHEEL_WIDTH := 0.3

# HOW IT DRIVES. Faster than a walk (6 m/s) because a vehicle that is not faster
# than walking is a worse way of walking.
const TOP_SPEED := 13.0
const ACCEL := 9.0
const BRAKE := 16.0
const REVERSE_SPEED := 4.5
# Radians per second at full lock, scaled by how fast it is going: a bus that
# turns on the spot at a standstill is a turret, and one that turns as hard at
# 13 m/s as at 3 is undrivable.
const TURN_RATE := 1.9
const TURN_AT_SPEED := 0.45

# THE LEAN. Cosmetic, and the one piece of feel this thing has: roll away from the
# turn, in proportion to how fast it is going INTO it. A tilt that ignored speed
# would lean just as hard at walking pace, which reads as a broken suspension
# rather than as momentum.
const TILT_MAX_DEG := 14.0
const TILT_RESPONSE := 6.0

var riders: Array = []          # peer ids, in boarding order; riders[0] drives
var heading: float = 0.0        # yaw, the project's convention
var speed: float = 0.0
var tilt: float = 0.0           # current roll, radians

var _deck: MeshInstance3D = null
var _shape: CollisionShape3D = null
var _wheels: Array = []
var _built_for: int = -1        # the rider count the body was last built at

func _ready() -> void:
	collision_layer = LAYER
	# THE WORLD AND THE ROUND BARRIER. It drives over the deck and is stopped by
	# it, and it does NOT ask about players -- riders are posed rather than
	# collided with, and a bus that shoved people off the bridge would be a
	# different feature.
	#
	# THE BARRIER BIT IS THE FIX FOR "the bus can drive back through the blue wall"
	# (reported 2026-08-25). The front wall is layer 8, and a mask of world-only
	# meant the one thing in this game that is explicitly there to stop you was the
	# one thing the bus ignored. Sixth time a bug in this project has been one bit
	# in a mask, and the same shape every time: the wall existed, was positioned,
	# was drawn and was replicated, and something drove straight through it.
	collision_mask = 1 | (1 << 7)
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_rebuild()

# --- Shape ---------------------------------------------------------------------

func length() -> float:
	return BASE_LENGTH + SEAT_LENGTH * float(maxi(0, riders.size() - 1))

# REBUILT ONLY WHEN THE ROSTER CHANGES, which is what `_built_for` is for: this
# replaces meshes and a collision shape, and doing it every frame would be a new
# BoxShape3D sixty times a second for no reason.
func _rebuild() -> void:
	if _built_for == riders.size():
		return
	_built_for = riders.size()
	var l: float = length()

	if _shape == null:
		_shape = CollisionShape3D.new()
		_shape.shape = BoxShape3D.new()
		add_child(_shape)
	(_shape.shape as BoxShape3D).size = Vector3(WIDTH, DECK_THICK, l)
	_shape.position = Vector3(0.0, DECK_THICK * 0.5, 0.0)

	if _deck == null:
		_deck = MeshInstance3D.new()
		_deck.name = "Deck"
		_deck.mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.82, 0.68, 0.22)
		_deck.material_override = material
		add_child(_deck)
	(_deck.mesh as BoxMesh).size = Vector3(WIDTH, DECK_THICK, l)
	_deck.position = Vector3(0.0, DECK_THICK * 0.5, 0.0)

	# FOUR WHEELS, AT THE CORNERS, however long it gets. A bus that grew a wheel
	# per seat would read as a train.
	while _wheels.size() < 4:
		var wheel := MeshInstance3D.new()
		wheel.name = "Wheel%d" % _wheels.size()
		var mesh := CylinderMesh.new()
		mesh.top_radius = WHEEL_RADIUS
		mesh.bottom_radius = WHEEL_RADIUS
		mesh.height = WHEEL_WIDTH
		wheel.mesh = mesh
		var rubber := StandardMaterial3D.new()
		rubber.albedo_color = Color(0.12, 0.12, 0.14)
		wheel.material_override = rubber
		# A CYLINDER STANDS UP THE Y AXIS, so a quarter turn about Z lays it on its
		# side to be a wheel. Written as a Basis from an axis and an angle rather
		# than by hand: this project has shipped FOUR sign errors from hand-written
		# row-major bases, and the last one pointed a beak into a player's face.
		wheel.transform.basis = Basis(Vector3(0.0, 0.0, 1.0), PI * 0.5)
		add_child(wheel)
		_wheels.append(wheel)
	var half_l: float = l * 0.5 - WHEEL_RADIUS * 1.4
	# JUST PROUD OF THE BODY. At 1.1 m across, wheels flush with the sides would be
	# hidden under the deck they are holding up.
	var half_w: float = WIDTH * 0.5 + WHEEL_WIDTH * 0.4
	for i in 4:
		var front: bool = i < 2
		var left: bool = i % 2 == 0
		_wheels[i].position = Vector3(
			half_w * (-1.0 if left else 1.0),
			WHEEL_RADIUS * 0.5,
			half_l * (-1.0 if front else 1.0))

# --- Riders --------------------------------------------------------------------

func is_rider(peer: int) -> bool:
	return riders.has(peer)

func driver() -> int:
	return int(riders[0]) if riders.size() > 0 else 0

# THE FIRST ABOARD DRIVES, and everyone after queues behind them. Appending is the
# whole rule: the order riders is IN is the order they sit in and the order they
# are promoted in, so there is no second list to keep in step.
func board(peer: int) -> void:
	if riders.has(peer):
		return
	riders.append(peer)
	_rebuild()

# LEAVING PROMOTES THE NEXT IN LINE for free, because the driver is defined as
# riders[0] rather than stored. A stored driver would be a second fact to update
# and a second thing to get wrong on the tick somebody steps off.
func leave(peer: int) -> void:
	var at: int = riders.find(peer)
	if at < 0:
		return
	riders.remove_at(at)
	_rebuild()

# WHERE RIDER `index` STANDS, in world space. The driver is at the front and the
# queue runs back down the deck.
func slot_world(index: int) -> Vector3:
	var l: float = length()
	# -Z is up-bridge and also the bus's own forward, so the front seat is the
	# most negative local z.
	var front: float = -l * 0.5 + BASE_LENGTH * 0.5
	var local := Vector3(0.0, DECK_THICK, front + SEAT_LENGTH * float(index))
	return global_transform * local

# WHERE SOMEBODY STANDING NEARBY WOULD BOARD FROM. Used for the reach check, so
# that "am I close enough" is asked about the whole vehicle rather than about its
# origin -- a long bus whose origin is metres from where you are standing would
# otherwise be unboardable from the back.
func distance_to_deck(at: Vector3) -> float:
	var local: Vector3 = global_transform.affine_inverse() * at
	var half_l: float = length() * 0.5
	var half_w: float = WIDTH * 0.5
	var nearest := Vector3(
		clampf(local.x, -half_w, half_w),
		local.y,
		clampf(local.z, -half_l, half_l))
	return (local - nearest).length()

# --- Driving -------------------------------------------------------------------

# TANK CONTROLS: forward and back are the throttle, left and right are the wheel.
# Every other body in this game moves in ABSOLUTE compass directions because the
# camera is fixed-yaw -- but a vehicle steered that way is not being driven, it is
# being dragged, and the tilt would have nothing to lean into.
func drive(throttle: float, steer: float, dt: float) -> void:
	if throttle > 0.01:
		speed = minf(TOP_SPEED, speed + ACCEL * dt * throttle)
	elif throttle < -0.01:
		speed = maxf(-REVERSE_SPEED, speed - BRAKE * dt * absf(throttle))
	else:
		# COASTING IS A BRAKE, not a hold. A bus that keeps its speed when nobody
		# is touching the throttle is one that has to be actively stopped, which
		# with one action bit and a queue of passengers is a bus in the river.
		speed = move_toward(speed, 0.0, ACCEL * 0.6 * dt)

	# STEERING SCALES WITH SPEED, and cannot happen at a standstill: a vehicle that
	# turns on the spot is a turret. Reversed when reversing, which is what makes
	# backing off a ledge recoverable.
	var authority: float = clampf(absf(speed) / (TOP_SPEED * TURN_AT_SPEED), 0.0, 1.0)
	var turn: float = -steer * TURN_RATE * authority * dt * signf(speed if absf(speed) > 0.01 else 1.0)
	heading = wrapf(heading + turn, -PI, PI)

	var forward: Vector3 = GridConfig.yaw_vector(heading)
	velocity = forward * speed + Vector3(0.0, velocity.y, 0.0)
	velocity.y -= SimConfig.GRAVITY * dt
	move_and_slide()
	if is_on_floor():
		velocity.y = 0.0

	# THE LEAN, chased rather than set, so it settles out of a corner instead of
	# snapping back. Proportional to turn rate times speed -- which is the lateral
	# acceleration the passengers would feel, and the honest thing to lean by.
	#
	# TOWARD THE OUTSIDE OF THE TURN. Turning right throws the body LEFT, so the
	# left side drops and the right side rises -- which is what a bus does and the
	# opposite of what this did when it shipped (reported 2026-08-25: "the bus tilt
	# is backwards"). A distance assertion has no opinion about direction, and the
	# test measured only how FAR it leaned; it asserts which WAY now, from the turn
	# the bus actually took rather than from a sign somebody reasoned about.
	var want: float = clampf(steer * authority, -1.0, 1.0) * deg_to_rad(TILT_MAX_DEG)
	tilt = lerpf(tilt, want, clampf(TILT_RESPONSE * dt, 0.0, 1.0))
	_pose()

# Where the body is drawn, as opposed to where it IS.
#
# THE NODE ONLY YAWS; THE LEAN IS ON THE DECK MESH ALONE. Rolling the whole body
# rolled the WHEELS with it, so a bus in a corner drove on its rims -- reported
# 2026-08-25 as "fix the wheels to the ground level, just the bus body tilts".
#
# It also keeps two other things honest for free. The COLLISION BOX stays level,
# so how the thing drives does not change with how it looks; and `slot_world` is
# built from this transform, so RIDERS stay upright instead of being tipped
# through the deck they are standing on.
func _pose() -> void:
	global_transform = Transform3D(Basis(Vector3.UP, heading), global_position)
	if _deck != null:
		# Hinged about the axles rather than about the slab's own middle, which is
		# where a body leans from: rotating about the centre would sink one edge
		# into the wheels while lifting the other clear of them.
		var pivot := Vector3(0.0, WHEEL_RADIUS * 0.5, 0.0)
		var roll := Basis(Vector3(0.0, 0.0, 1.0), tilt)
		_deck.transform = Transform3D(roll,
			pivot + roll * (Vector3(0.0, DECK_THICK * 0.5, 0.0) - pivot))

# Applied on a client, which never drives. The transform arrives whole rather than
# being re-derived from a heading, because a client that integrated its own
# steering would be predicting a vehicle it has no input for.
func apply_remote(at: Vector3, yaw: float, roll: float, aboard: Array) -> void:
	global_position = at
	heading = yaw
	tilt = roll
	riders = aboard.duplicate()
	_rebuild()
	_pose()
