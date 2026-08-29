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

# THE SHAPE. A tub, open at the top: sides high enough that a rider is standing
# IN it rather than balanced on a plank, and low enough that they can still shoot
# over them. Both halves of that are measured against the body, not chosen -- see
# SIDE_HEIGHT.
# BARELY WIDER THAN THE PERSON STANDING IN IT. A player is 0.8 m across, so the
# interior between the two side panels is 0.96 -- eight centimetres of shoulder
# room. Deliberately tight: this is a bus you are wedged into, not a truck bed.
#
# THE REASON FOR THE WIDTH USED TO BE THE OPPOSITE ONE. It was chosen so the bus
# read as a board with wheels, with the party visibly balanced on top; the report
# was that this looked like riding a platform rather than being in a vehicle, and
# the sides are the answer. The number survived the change of mind because a
# narrow tub reads even better than a narrow plank -- but it is worth knowing the
# argument here is now the second one, not the first.
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
# HOW HIGH THE SIDES COME, above the deck's top face.
#
# THE TWO NUMBERS THIS SITS BETWEEN ARE BOTH THE PLAYER'S, which is why it is not
# a look-and-see value. A rider's feet are on the deck and its origin is
# PlayerBody.HALF_HEIGHT (0.9 m) above it; the muzzle of whatever it is holding is
# that plus 0.25 -- 1.15 m -- and that number is a HITBOX decision made elsewhere,
# for reasons about shooting rushers, not a cosmetic one. So the sides have to
# clear the feet by enough to read as a body and stay clear of 1.15 by enough
# that nobody ever wonders whether their round will hit the door.
#
# 1.15 IS THE FALLBACK AND NOT THE ANSWER. `_muzzle_of` only computes
# body-plus-0.25 when the holder has no weapon; with a gun in their hands it
# returns the tip of that gun's Barrel node, and MEASURED that is 0.92 m above
# the deck -- LOWER than the number you get by reading the fallback and reasoning
# from it. Sizing the sides against 1.15 left 17 cm of daylight where it looked
# like 40.
#
# 0.68 is knee height on a 1.8 m body: the feet and shins are gone, and the
# lowest gun in the game still clears it by 0.24 m. `test_bus_look` measures that
# clearance against EVERY weapon kind through `_muzzle_of` itself rather than
# against this comment -- the muzzle is a hitbox decision made for reasons about
# shooting rushers, and it can move without anybody thinking about the bus.
const SIDE_HEIGHT := 0.68
const SIDE_THICK := 0.07
# The band around it at floor level, and how far it stands proud of the sides.
const STRIPE_HEIGHT := 0.1
const STRIPE_PROUD := 0.025
const HEADLIGHT_RADIUS := 0.07
const RADIATOR_INSET := 0.27
const HUBCAP_RADIUS := 0.19
const HUBCAP_THICK := 0.07

const BODY_COLOUR := Color(0.82, 0.68, 0.22)
const STRIPE_COLOUR := Color(0.36, 0.16, 0.13)
const CHROME_COLOUR := Color(0.87, 0.86, 0.80)
const GRILLE_COLOUR := Color(0.2, 0.2, 0.23)
const LAMP_COLOUR := Color(1.0, 0.94, 0.72)

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

# THE WIRE IDENTITY. Every replicated pool in this game is keyed by an id the
# host allocates, and a bus is no different -- the client's copy is found by it,
# and a bus the host stops mentioning is one the client removes without being
# told which. Zero means "never sent", which is what a solo world's bus stays.
var bus_id: int = 0

var riders: Array = []          # peer ids, in boarding order; riders[0] drives
var heading: float = 0.0        # yaw, the project's convention
var speed: float = 0.0
var tilt: float = 0.0           # current roll, radians

var _deck: MeshInstance3D = null
var _shape: CollisionShape3D = null
var _wheels: Array = []
# THE BODYWORK, ALL OF IT PARENTED TO `_deck`. That is not tidiness: the deck is
# the only thing that ROLLS (see _pose -- rolling the whole node drove the bus on
# its rims), so anything that is part of the body has to hang off it or the bus
# would lean out from under its own sides. The hubcaps are the exception and
# belong to the wheels, which stay level.
var _panels: Dictionary = {}
var _hubcaps: Array = []
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
	_build_body(l)

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
		add_child(wheel)
		_wheels.append(wheel)
	var half_l: float = l * 0.5 - WHEEL_RADIUS * 1.4
	# JUST PROUD OF THE BODY. At 1.1 m across, wheels flush with the sides would be
	# hidden under the deck they are holding up.
	var half_w: float = WIDTH * 0.5 + WHEEL_WIDTH * 0.4
	for i in 4:
		var front: bool = i < 2
		var left: bool = i % 2 == 0
		var side: float = -1.0 if left else 1.0
		_wheels[i].position = Vector3(
			half_w * side,
			WHEEL_RADIUS * 0.5,
			half_l * (-1.0 if front else 1.0))
		# A CYLINDER STANDS UP THE Y AXIS, so a quarter turn about Z lays it on its
		# side to be a wheel. Written as a Basis from an axis and an angle rather
		# than by hand: this project has shipped FOUR sign errors from hand-written
		# row-major bases, and the last one pointed a beak into a player's face.
		#
		# AND THE TURN GOES THE OTHER WAY ON THE OTHER SIDE, which for a plain
		# cylinder changes nothing you can see and everything about what "local up"
		# means inside it. That is the point: a hubcap is then at local +Y on every
		# wheel and OUTBOARD on every wheel. With one shared basis the caps on one
		# side sat 15 cm INSIDE their tyres -- invisible, and correct by every
		# property you can print about them.
		#
		# NEGATED, and that is not a typo to tidy away later. A turn of +90 about Z
		# sends local +Y to world -X, so the LEFT wheel -- the one at negative x --
		# is the one that wants the POSITIVE turn. Written the intuitive way round
		# it put all four hubcaps 15 cm inside their tyres, on both sides at once,
		# which is what a wrong sign looks like when it is shared.
		_wheels[i].transform.basis = Basis(Vector3(0.0, 0.0, 1.0), PI * -0.5 * side)
	_build_hubcaps()

# --- The bodywork --------------------------------------------------------------
#
# Everything here is DRAWN AND NOT SOLID. The one collision shape is the level
# deck box built above, and that is deliberate: a rider is POSED onto its seat
# rather than colliding with anything, and the bus's mask does not include
# players at all. Giving the sides colliders would put a wall between a passenger
# and the world for no gain -- and worse, it would be a hit test that disagrees
# with what the art promises, which this project has already shipped once with
# the spikes.
#
# A ROUND FIRED FROM ABOARD CLEARS THE SIDES BY GEOMETRY, not by an exception:
# the muzzle is 1.15 m above the deck and the sides stop at SIDE_HEIGHT. That is
# the honest version of "you can still shoot" -- nothing is filtering rounds, the
# gun is simply above the door.
func _build_body(l: float) -> void:
	var top: float = DECK_THICK * 0.5          # the deck's top face, in deck space
	var half_w: float = WIDTH * 0.5
	var mid: float = top + SIDE_HEIGHT * 0.5

	# The two long sides, set just inside the deck edge so the bus does not get
	# wider than the person it carries.
	var side_x: float = half_w - SIDE_THICK * 0.5
	_panel("SideLeft", BODY_COLOUR, Vector3(SIDE_THICK, SIDE_HEIGHT, l),
		Vector3(-side_x, mid, 0.0))
	_panel("SideRight", BODY_COLOUR, Vector3(SIDE_THICK, SIDE_HEIGHT, l),
		Vector3(side_x, mid, 0.0))

	# FRONT IS -Z, which is the same convention the wheels above use and the same
	# one GridConfig.yaw_vector produces. Worth stating rather than leaving to be
	# rediscovered: a headlight on the back of the bus has an identical bounding
	# box to one on the front, and this project has shipped four sign errors of
	# exactly that shape.
	var end_z: float = l * 0.5 - SIDE_THICK * 0.5
	_panel("Nose", BODY_COLOUR, Vector3(WIDTH, SIDE_HEIGHT, SIDE_THICK),
		Vector3(0.0, mid, -end_z))
	_panel("Tail", BODY_COLOUR, Vector3(WIDTH, SIDE_HEIGHT, SIDE_THICK),
		Vector3(0.0, mid, end_z))

	# THE STRIPE, AT FLOOR LEVEL -- the line where the deck meets the sides, which
	# is what makes the tub read as a body with a floor in it rather than as four
	# panels. A ring of four rather than one box around everything: a single slab
	# would cover the deck's own top face and fight it for the same pixels.
	var stripe_y: float = top + STRIPE_HEIGHT * 0.5
	var stripe_x: float = half_w + STRIPE_PROUD * 0.5
	var stripe_z: float = l * 0.5 + STRIPE_PROUD * 0.5
	_panel("StripeLeft", STRIPE_COLOUR,
		Vector3(SIDE_THICK + STRIPE_PROUD, STRIPE_HEIGHT, l),
		Vector3(-stripe_x + SIDE_THICK * 0.5, stripe_y, 0.0))
	_panel("StripeRight", STRIPE_COLOUR,
		Vector3(SIDE_THICK + STRIPE_PROUD, STRIPE_HEIGHT, l),
		Vector3(stripe_x - SIDE_THICK * 0.5, stripe_y, 0.0))
	_panel("StripeNose", STRIPE_COLOUR,
		Vector3(WIDTH, STRIPE_HEIGHT, SIDE_THICK + STRIPE_PROUD),
		Vector3(0.0, stripe_y, -stripe_z + SIDE_THICK * 0.5))
	_panel("StripeTail", STRIPE_COLOUR,
		Vector3(WIDTH, STRIPE_HEIGHT, SIDE_THICK + STRIPE_PROUD),
		Vector3(0.0, stripe_y, stripe_z - SIDE_THICK * 0.5))

	# THE RADIATOR, low and central on the nose, standing proud of it so it reads
	# as a grille bolted on rather than as a painted rectangle.
	var grille_h: float = SIDE_HEIGHT - RADIATOR_INSET * 2.0
	_panel("Radiator", GRILLE_COLOUR,
		Vector3(WIDTH - RADIATOR_INSET * 2.0, grille_h, SIDE_THICK * 0.8),
		Vector3(0.0, top + RADIATOR_INSET + grille_h * 0.5,
			-end_z - SIDE_THICK * 0.5))

	# TWO LAMPS, at the top corners of the nose and above the grille. Emissive, so
	# they read as lit rather than as pale paint -- a bus that only has headlights
	# in daylight is a bus with two grey circles on it.
	var lamp_y: float = top + SIDE_HEIGHT - HEADLIGHT_RADIUS - 0.1
	var lamp_x: float = half_w - HEADLIGHT_RADIUS - 0.06
	for i in 2:
		var lamp := _disc("Headlight%d" % i, LAMP_COLOUR, HEADLIGHT_RADIUS,
			SIDE_THICK * 0.7, _deck)
		lamp.position = Vector3(lamp_x * (-1.0 if i == 0 else 1.0), lamp_y,
			-end_z - SIDE_THICK * 0.35)
		# A CYLINDER STANDS UP ITS OWN Y, so a quarter turn about X lays its face
		# forward. From an axis and an angle, never nine hand-written numbers.
		lamp.transform.basis = Basis(Vector3(1.0, 0.0, 0.0), PI * 0.5)
		var glow := lamp.material_override as StandardMaterial3D
		glow.emission_enabled = true
		glow.emission = LAMP_COLOUR
		glow.emission_energy_multiplier = 1.6

# ONE PER WHEEL, ON ITS OUTER FACE. Proud along the wheel's own axis, which is X
# once the cylinder has been laid on its side -- a hubcap at the wheel's centre is
# a hubcap inside the tyre, invisible and perfectly present in every test that
# only asks whether it was created.
func _build_hubcaps() -> void:
	while _hubcaps.size() < 4:
		var cap := _disc("Hubcap%d" % _hubcaps.size(), CHROME_COLOUR,
			HUBCAP_RADIUS, HUBCAP_THICK, _wheels[_hubcaps.size()])
		# The wheel is already rotated onto its side, so inside it "up" is outboard.
		cap.position = Vector3(0.0, WHEEL_WIDTH * 0.5, 0.0)
		_hubcaps.append(cap)

# A box on the deck, created once and resized after. Returns it so a caller can
# keep going -- the lamps need a material change on top.
func _panel(part: String, colour: Color, size: Vector3, at: Vector3) -> MeshInstance3D:
	var node: MeshInstance3D = _panels.get(part)
	if node == null:
		node = MeshInstance3D.new()
		node.mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = colour
		node.material_override = material
		_deck.add_child(node)
		# NAMED AFTER THE ADD. Setting a name before add_child is discarded when a
		# sibling already holds it, and what you get is not "Nose2" but a generated
		# @MeshInstance3D@341 -- which is a node no test can find by name.
		node.name = part
		_panels[part] = node
	(node.mesh as BoxMesh).size = size
	node.position = at
	return node

func _disc(part: String, colour: Color, radius: float, thick: float,
		under: Node3D) -> MeshInstance3D:
	var node: MeshInstance3D = _panels.get(part)
	if node == null:
		node = MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = radius
		mesh.bottom_radius = radius
		mesh.height = thick
		node.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = colour
		node.material_override = material
		under.add_child(node)
		node.name = part
		_panels[part] = node
	return node

# --- Riders --------------------------------------------------------------------

func is_rider(peer: int) -> bool:
	return riders.has(peer)

# THE CELL TO PUT A BUS DOWN IN, searched forward from `from` along the rows.
#
# Columns are tried by DISTANCE FROM THE CENTRE rather than left to right, which
# is the whole reason this is a search and not a clamp: on a serpentine the first
# solid cell in a row is against whichever rail that row's lane happens to start
# at, and a bus parked on the rail of a lane the party is not in is a bus nobody
# finds. Nearest-to-centre lands it on the road the party will actually drive.
#
# Returns (-1, -1) when the whole span is void, so the caller decides what an
# impossible placement means rather than being handed a plausible wrong cell. A
# clamp is the wrong answer to an out-of-range index anywhere a body is placed.
static func spawn_cell(grid, from: Vector2i) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	var mid: int = grid.width / 2
	for ahead in range(SimConfig.BUS_SPAWN_NEAR, SimConfig.BUS_SPAWN_FAR):
		for step in grid.width:
			var x: int = mid + (step + 1) / 2 * (1 if step % 2 == 0 else -1)
			if x < 0 or x >= grid.width:
				continue
			var cell := Vector2i(x, from.y + ahead)
			if grid.is_solid(cell):
				return cell
	return Vector2i(-1, -1)

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
	return transform * local

# WHERE SOMEBODY STANDING NEARBY WOULD BOARD FROM. Used for the reach check, so
# that "am I close enough" is asked about the whole vehicle rather than about its
# origin -- a long bus whose origin is metres from where you are standing would
# otherwise be unboardable from the back.
func distance_to_deck(at: Vector3) -> float:
	var local: Vector3 = transform.affine_inverse() * at
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
# WORLD-LOCAL THROUGHOUT, NOT GLOBAL, and that is not a style choice.
#
# Two worlds share one process here -- the net harness stands the host and the
# client a kilometre apart so their physics do not intersect -- and the snapshot
# wire format carries world-LOCAL coordinates for exactly that reason. A bus that
# worked in global space read the same as local in solo, where the offset is zero,
# and put the client's copy a kilometre off the instant a second world existed.
# Every trap in this file's neighbourhood has the same shape: correct on one
# machine, meaningless on two.
func _pose() -> void:
	transform = Transform3D(Basis(Vector3.UP, heading), position)
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
	position = at
	heading = yaw
	tilt = roll
	riders = aboard.duplicate()
	_rebuild()
	_pose()
