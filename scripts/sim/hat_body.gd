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
const Hit = preload("res://scripts/sim/hit.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")

enum Mode { WORN, FLYING, LOOSE }

# TWO LAYERS, because a hat means two different things depending on where it is.
# A hat ON A HEAD is a target the round sweep masks; one on the DECK is not, or a
# dropped pile would be cover nobody built. Both are named in project.godot.
const LOOSE_LAYER := 1 << 5      # 6: "hats"
const WORN_LAYER := 1 << 8       # 9: "worn_hats"

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

# Where it was last tick, for the displacement test in step(). `_has_last` rather
# than a sentinel position, because the first tick after a launch has nothing to
# compare against and must not read as "it moved a very long way".
var _last_at: Vector3 = Vector3.ZERO
var _has_last: bool = false

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
	# lands on its side ROLLS -- down a bridge that WAS pitched 4 degrees by
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
	# "Landed" is a movement test rather than a contact test: a hat that slid to a
	# halt against a parapet has landed just as much as one that dropped flat, and
	# a contact callback would also fire on the way past.
	#
	# GROUND COVERED, NOT `linear_velocity`, AND THE DIFFERENCE IS A HAT THAT NEVER
	# SETTLES. Observed 2026-08-23, the day the bridge was flattened: a hat wedged
	# at the lip of a hole sat visibly STILL -- 7 cm/s of creep, sampled at zero --
	# while the solver depenetrated it every few ticks and spiked `linear_velocity`
	# to 3.44. Every spike reset the grace, so it stayed FLYING forever: exactly
	# the "hat stuck in an infinite bounce loop" this file's test was written for,
	# arriving by a different route.
	#
	# The tilt had been hiding it. A four-degree slope gave every loose body a
	# constant push, which worked a wedged hat out of the wedge before the grace
	# could matter -- a third job the pitch was doing that nobody had written down.
	#
	# Velocity and displacement disagree the moment anything is in the way, and it
	# is precisely the blocked case a settle test has to get right. zombie_body's
	# walk budget makes the same choice for the same reason, and CLAUDE.md's rule
	# about reading velocity around a collision is the same fact a third time.
	# OVER THE WHOLE WINDOW, not per tick, and the per-tick version was tried
	# first. A depenetration spike is a REAL 5.7 cm in one frame, so it defeats an
	# instantaneous test whether that test reads velocity or displacement -- the
	# hat is genuinely moved, it just arrives back where it started. What "settled"
	# actually means is "it is not getting anywhere", and that is a question about
	# a span of time.
	#
	# So: every HAT_SETTLE_GRACE, ask how far it really got. Under the distance
	# HAT_SETTLE_SPEED would have carried it, it has landed.
	if not _has_last:
		_last_at = position
		_has_last = true
		settle_grace = SimConfig.HAT_SETTLE_GRACE
		return
	settle_grace = maxf(0.0, settle_grace - SimConfig.TICK_DELTA)
	if settle_grace > 0.0:
		return
	var drift: float = _last_at.distance_to(position)
	_last_at = position
	settle_grace = SimConfig.HAT_SETTLE_GRACE
	if drift < SimConfig.HAT_SETTLE_SPEED * SimConfig.HAT_SETTLE_GRACE:
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

# SCATTERED BY A BLAST, AND BY NOTHING ELSE. Gunfire deliberately cannot strip a
# friend's hat stack or knock the gun out of their hands -- that would put the
# whole M8.5 reward curve at the mercy of a stray round -- but debris thrown by an
# explosion is free and looks right.
#
# A HELD or WORN one is untouched: it is not in the world to be thrown.
func receive_hit(hit) -> bool:
	if hit.kind != Hit.Kind.EXPLOSIVE or mode == Mode.WORN:
		return false
	launch(position, hit.launch_for(position))
	return true

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
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if shape == null:
		return
	if mode == Mode.WORN:
		# A WORN HAT IS A TARGET AND NOTHING ELSE.
		#
		# M8.5 gave it no collider at all, and the argument was sound: a hat you
		# can stand on is a ladder, and a stack of hats is a staircase past an
		# authored ascender gate. But "not in the contact graph" was a bigger
		# answer than that question needed. What must not happen is that a BODY
		# collides with it; a raycast asking what is in front of a bullet is not
		# a body.
		#
		# So the collider exists, on its own layer, MASKING NOTHING. No player
		# mask includes this layer, so a stack is still not a staircase, and the
		# only thing in the game that looks at it is the round sweep.
		shape.disabled = false
		collision_layer = WORN_LAYER
		collision_mask = 0
		# A UNIFORM HIT SHAPE, WHATEVER SHAPE THE HAT IS. This is the part that is
		# not obvious and is the whole difference between "a tower is a target" and
		# "a tower is a target sometimes".
		#
		# HatStyle sizes every hat's collider from its style id, so a stack is a
		# column of mismatched discs -- measured on one four-stack: heights of
		# 0.233, 0.101, 0.342 and 0.191, each starting at its own node origin,
		# leaving gaps of a hand's width BETWEEN the hats of a tower. A round
		# threads them, and what a player sees is "I shot him in the hat and
		# nothing happened", intermittently, depending on which hats they happened
		# to be wearing.
		#
		# A hat's own shape is for LANDING on the deck, where its real size is what
		# should decide how it settles. What it is worth as a TARGET is the slot it
		# occupies in the tower, which is the same for every hat: exactly
		# HAT_HEIGHT tall, centred on the node origin, so the slots tile with no
		# seam. Restored to the style's own shape the moment it comes off.
		# PER HAT NOW, NOT THE BARE CONSTANT. A merchant's hat occupies 3.5 slots,
		# and the spacing in HatPool.pose_stack asks the same function -- the two
		# MUST agree or the tower has 0.88 m of hat with no collider in it, which
		# is the 2026-08-16 gappy-tower bug rebuilt by hand.
		var column := shape.shape as CylinderShape3D
		if column != null:
			# CENTRED ON THE SLOT, NOT ON THE ORIGIN. It used to be Vector3.ZERO,
			# which was correct only because every hat was placed at its slot's
			# centre -- including the ordinary ones, which is the bug that left them
			# floating. Now that a hat hangs at `mount_offset` inside its slot, the
			# column has to be offset by the same amount in reverse or the art and
			# the hit test drift apart, which is the 2026-08-16 gappy tower rebuilt
			# by hand. Tall hats are unaffected: their offset is half a slot, so
			# this is still zero for them.
			shape.position = Vector3(0.0, slot_height() * 0.5 - mount_offset(), 0.0)
			column.height = slot_height()
			column.radius = SimConfig.HAT_HIT_RADIUS
	else:
		# On the deck or in the air: layer 6, world only, exactly as before -- and
		# the style's own collider back, because how a hat SETTLES should depend on
		# how big it actually is.
		HatStyle.apply(self)
		shape.disabled = not simulated
		collision_layer = LOOSE_LAYER
		collision_mask = 1

# HOW TALL A SLOT THIS HAT TAKES UP IN A TOWER. One question, one answer, asked
# by the two places that must never disagree: the stack spacing and the worn hit
# column. Delegated to HatStyle because it is a pure function of style_id like
# every other visible property of a hat -- which is what makes it replicate,
# persist and reach a late joiner with nothing extra on the wire.
func slot_height() -> float:
	return HatStyle.slot_height(style_id)

# Where inside its slot this hat's model hangs. See HatStyle.mount_offset -- an
# ordinary hat stands on its origin and a tall one straddles it, and placing both
# at the slot centre left every ordinary hat floating above the head.
func mount_offset() -> float:
	return HatStyle.mount_offset(style_id)

# Is this the merchant's hat? Asked by the trade (he will not take one as
# payment) and by the save rule (it does not survive a launch).
func is_tall() -> bool:
	return HatStyle.is_tall(style_id)

# Can a round hit this? The answer lives on the thing being hit, which is the
# rule _resolve_round_hit was rewritten around: the machine gun does not get to
# decide what everything else in the game is.
func takes_rounds() -> bool:
	return mode == Mode.WORN

# Clients are TOLD where a loose hat is; they never simulate one.
func apply_remote(new_mode: int, at: Vector3) -> void:
	mode = new_mode
	_set_simulated(false)
	position = at
