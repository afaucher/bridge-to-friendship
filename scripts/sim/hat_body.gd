extends RigidBody3D

# A hat. See implementation_plans/m8_5_hats.md.
#
# ONE RECORD IN EXACTLY ONE OF THREE MODES, which is the whole model:
#
#   WORN    on somebody's head, no physics, drawn at a stack offset
#   FLYING  just dislodged, arcing, NOT collectable
#   LOOSE   settled on the deck, collectable
#
# One representation, three modes -- deliberately not a cell record for a loose
# hat and a body for a flying one. A dislodged hat lands wherever it lands, so a
# grid form would mean two representations of one object and a conversion between
# them on every tumble.
#
# A RIGID BODY, like a plinko ball and for the same reason: what a thrown hat does
# is physics rather than a designed rule, and hats are host-authoritative and
# never predicted, so the determinism objection does not apply. See
# plinko_ball.gd, which argues this at length.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")

enum Mode { WORN, FLYING, LOOSE }

# Host-assigned and monotonic, NEVER a creation-order index. Stones get away with
# list indices because both machines load the same segments in the same order; a
# hat can be created mid-run by a player joining, so creation order is not agreed
# and copying that pattern is a bug that only shows up with a late joiner.
var hat_id: int = 0

# THE FIELD THAT MAKES THIS FUNNY RATHER THAN ADMINISTRATIVE. It travels with the
# hat forever and is never reset on pickup: you keep wearing the hat you stole,
# visibly, and everyone can see whose it was.
#
# It is also the seed the generated shape will be derived from -- see the
# follow-up section in the plan. Anything about how a hat LOOKS must be a pure
# function of this, or a stolen hat becomes a different hat on the thief's screen.
var style_id: int = 0:
	set(value):
		style_id = value
		# Rebuilt the moment the id is known, whether this hat was created here or
		# adopted from the wire -- so a client that has never seen this hat draws
		# the same one the host is drawing.
		if is_inside_tree():
			HatStyle.apply(self)

var mode: int = Mode.LOOSE

# Only meaningful while WORN: whose head, and how far up the stack.
var owner_peer: int = 0
var stack_index: int = 0

# Counts down once the hat has stopped moving. Only at zero is it collectable.
var settle_grace: float = 0.0

# HOW FAR THIS HAT LEANS AGAINST THE ONE BELOW IT, in radians, as a tilt toward
# world +X (x) and toward world +Z (y). Only meaningful while WORN.
#
# PURELY COSMETIC, and that is a design position rather than an admission. The
# obvious implementation is a real joint -- a ConeTwistJoint3D per pair, five
# simulated bodies chained off a head. That was considered and refused: see
# lean_step() for why.
var lean: Vector2 = Vector2.ZERO
var lean_vel: Vector2 = Vector2.ZERO

func _ready() -> void:
	gravity_scale = SimConfig.GRAVITY / 9.8
	continuous_cd = true

	# A HAT MUST NOT ROLL, and this is not a nicety.
	#
	# The generated shapes made some hats tall cylinders, and a cylinder that
	# lands on its side ROLLS -- down a bridge that is pitched 4 degrees by
	# design, forever. It never drops below HAT_SETTLE_SPEED, so it never becomes
	# LOOSE, so it is never collectable: a hat that runs away down the deck and
	# can never be picked up again. Caught by test_hat_tumble the moment the
	# shapes stopped being uniform, which is the whole reason to vary them in a
	# test rather than only in a playtest.
	#
	# Locking rotation also settles what a resting hat LOOKS like -- upright, the
	# way it was worn -- rather than however it happened to topple.
	lock_rotation = true
	linear_damp = 0.6
	# Again here, because the id is usually assigned BEFORE the node enters the
	# tree -- at which point the setter above cannot safely reach the children.
	HatStyle.apply(self)

# Bookkeeping only -- the physics server moves a flying hat. Called once per sim
# tick by the pool.
func step() -> void:
	if mode != Mode.FLYING:
		return
	# "Landed" is a speed test rather than a contact test: a hat that slid to a
	# halt against a parapet has landed just as much as one that dropped flat, and
	# a contact callback would also fire on the way past.
	if linear_velocity.length() > SimConfig.HAT_SETTLE_SPEED:
		settle_grace = SimConfig.HAT_SETTLE_GRACE
		return
	settle_grace = maxf(0.0, settle_grace - SimConfig.TICK_DELTA)
	if settle_grace <= 0.0:
		mode = Mode.LOOSE

# One tick of the lean spring. `kick` is an impulse straight onto the angular
# velocity, in radians per second, already pointed the way this hat should tip.
# dt <= 0 means "settle upright NOW" -- what a hat just placed on a head wants.
#
# WHY A SPRING AND NOT A JOINT, which is the first thing anybody reaches for:
#
#   * A JOINT GIVES YOU A LIMIT, NOT A LEAN. ConeTwistJoint3D's swing span is the
#     angle past which the solver pushes BACK; how far a hat actually tips inside
#     that span is whatever the masses and the softness happen to produce. "Five
#     degrees" is the number that was asked for, and here it is the number.
#   * IT WOULD PUT WORN HATS BACK IN THE PHYSICS WORLD. A worn hat is frozen with
#     its shape disabled for a stated reason -- a hat you can stand on is a
#     ladder, and five are a staircase past an authored ascender gate. Un-freezing
#     five bodies per player to drive a cosmetic wobble reopens that, and every
#     body in the contact graph is another chance for two machines to order
#     contacts differently.
#   * THE ANCHOR IS A CHARACTER BODY THAT TELEPORTS. A CharacterBody3D is moved by
#     move_and_slide, not by the solver, and it can cover 0.9 m in one tick during
#     a dash. A jointed chain hanging off it is the classic way to make a solver
#     either jitter or explode.
#
# Nothing is lost by faking it: no hat has ever collided with anything while worn,
# so there is no physics here to be right about.
func lean_step(kick: Vector2, dt: float) -> void:
	if dt <= 0.0:
		lean = Vector2.ZERO
		lean_vel = Vector2.ZERO
		return
	lean_vel += kick
	lean_vel += (-SimConfig.HAT_LEAN_STIFFNESS * lean - SimConfig.HAT_LEAN_DAMPING * lean_vel) * dt
	lean += lean_vel * dt

	var reach: float = lean.length()
	var limit: float = deg_to_rad(SimConfig.HAT_LEAN_MAX_DEG)
	if reach > limit:
		var out: Vector2 = lean / reach
		lean = out * limit
		# THE OUTWARD VELOCITY GOES WITH IT. Clamping the angle alone leaves the
		# spring still travelling outward into a wall it cannot pass, so a dash
		# would peg the stack at the limit and hold it there for as long as that
		# velocity took to bleed off -- a stack that leans over and STAYS there,
		# which is the one thing a wobble must not do.
		var outward: float = lean_vel.dot(out)
		if outward > 0.0:
			lean_vel -= out * outward

# This hat's tilt, in the frame of the hat below it. Composing these up the stack
# is what makes the tower lean rather than five hats all tipping the same way.
func lean_basis() -> Basis:
	# Rotating about +Z tips the local up-axis toward -X, hence the sign; about +X
	# it tips toward +Z, which is already the direction wanted.
	return Basis(Vector3(0.0, 0.0, 1.0), -lean.x) * Basis(Vector3(1.0, 0.0, 0.0), lean.y)

func is_collectable() -> bool:
	return mode == Mode.LOOSE

func is_gone() -> bool:
	return position.y < SimConfig.FALL_KILL_Y

# Dropped onto the deck by an author, or spawned already settled. Collectable at
# once: nobody dislodged it, so there is no re-collect to prevent.
func place_loose(at: Vector3) -> void:
	mode = Mode.LOOSE
	settle_grace = 0.0
	_set_simulated(true)
	position = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

# Knocked off a head. Arcs, lands, and is uncollectable until it has settled.
func launch(from: Vector3, velocity: Vector3) -> void:
	mode = Mode.FLYING
	settle_grace = SimConfig.HAT_SETTLE_GRACE
	_set_simulated(true)
	position = from
	linear_velocity = velocity
	# No spin: rotation is locked so a hat cannot roll away down the pitch. See
	# _ready.
	angular_velocity = Vector3.ZERO

# Put on a head. The physics body stops existing as far as the world is
# concerned: frozen, no collision, positioned by whoever is wearing it.
#
# THE WEARER'S COLLIDER NEVER CHANGES. player.tscn's cylinder is what M3's riding
# rules, _find_carrier and FOOT_PROBE are all denominated in, so a stack that grew
# the collider would silently change how players stand on each other, mid-run, per
# hat.
func wear(peer: int, index: int) -> void:
	mode = Mode.WORN
	owner_peer = peer
	stack_index = index
	settle_grace = 0.0
	# A hat arrives on a head UPRIGHT, whatever the last stack it was on was doing.
	lean = Vector2.ZERO
	lean_vel = Vector2.ZERO
	_set_simulated(false)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rotation = Vector3.ZERO

func _set_simulated(simulated: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not simulated
	# A worn hat must not be in the contact graph at all -- see the plan: a hat
	# you can stand on is a ladder, and a stack of hats is a staircase past an
	# authored ascender gate.
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		shape.disabled = not simulated

# Clients are TOLD where a loose hat is; they never simulate one.
func apply_remote(new_mode: int, at: Vector3) -> void:
	mode = new_mode
	_set_simulated(false)
	position = at
