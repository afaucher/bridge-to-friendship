extends RigidBody3D

# A special: a pickup with a fixed number of uses, of which the machine gun is
# the first. See implementation_plans/m12_machine_gun.md and game_concept.md
# §Special.
#
# ONE RECORD IN EXACTLY ONE OF THREE MODES, the same model hat_body.gd uses and
# for the same reasons:
#
#   HELD    in somebody's hands, no physics, drawn on their Facing pivot
#   FLYING  just dropped, landing, NOT collectable
#   LOOSE   settled on the deck, collectable
#
# A RIGID BODY, like a plinko ball and a hat: what a dropped weapon does on the
# way down is physics rather than a designed rule, and specials are
# host-authoritative and never predicted, so the determinism objection does not
# apply.
#
# WHAT IS DELIBERATELY NOT HERE: anything that affects stepping. Firing does not
# move you -- there is no recoil, on purpose -- so no field on this object belongs
# in PlayerBody.capture_state(), and none of it is replayed. That is the roadmap's
# own split for M12, applied: the half of a special that affects walking is legs,
# and legs are not this.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

enum Mode { HELD, FLYING, LOOSE }

# WHICH SPECIAL. One kind today; the enum exists because the pool, the slot, the
# drop rule and the HUD box are shared and a sword is a different resolve
# function rather than a different object.
enum Kind { MACHINE_GUN }

# Host-assigned and monotonic, NEVER a creation-order index. A special can be
# created mid-run by a swap, so creation order is not agreed between machines --
# the same trap hat_body.gd documents.
var special_id: int = 0

var kind: int = Kind.MACHINE_GUN

# THE RESOURCE. Fixed uses is the model every special shares, and this is it.
# It lives HERE rather than on the player because it belongs to the object: a
# gun dropped with 12 rounds left is picked up with 12 rounds left, which is what
# makes a half-spent weapon on the deck a real decision rather than litter.
var ammo: int = 0

var mode: int = Mode.LOOSE

# Only meaningful while HELD.
var owner_peer: int = 0

# Seconds until the next round may leave. Host-side, and reset on pickup so a
# swap is not a way to fire faster.
var fire_timer: float = 0.0

# Counts down once the body has stopped moving. Only at zero is it collectable.
var settle_grace: float = 0.0

func _ready() -> void:
	gravity_scale = SimConfig.GRAVITY / 9.8
	continuous_cd = true
	# A DROPPED WEAPON MUST NOT ROLL. The deck is pitched 4 degrees by design, and
	# a body that keeps rolling never drops below SPECIAL_SETTLE_SPEED, so it never
	# becomes LOOSE and is never collectable -- a gun that runs away down the
	# bridge. Cost hat_body.gd a test to find; inherited here rather than
	# rediscovered.
	lock_rotation = true
	linear_damp = 0.6

func kind_name() -> String:
	match kind:
		Kind.MACHINE_GUN:
			return "MG"
	return "?"

# Bookkeeping only -- the physics server moves a dropped special. Called once per
# sim tick by the pool.
func step() -> void:
	if mode != Mode.FLYING:
		return
	# "Landed" is a speed test rather than a contact test: a weapon that slid to a
	# halt against a parapet has landed just as much as one that dropped flat.
	if linear_velocity.length() > SimConfig.SPECIAL_SETTLE_SPEED:
		settle_grace = SimConfig.SPECIAL_SETTLE_GRACE
		return
	settle_grace = maxf(0.0, settle_grace - SimConfig.TICK_DELTA)
	if settle_grace <= 0.0:
		mode = Mode.LOOSE

func is_collectable() -> bool:
	return mode == Mode.LOOSE and ammo > 0

func is_gone() -> bool:
	return position.y < SimConfig.FALL_KILL_Y

func is_spent() -> bool:
	return ammo <= 0

# Placed by an author, or spawned already settled. Collectable at once: nobody
# dropped it, so there is no re-collect to prevent.
func place_loose(at: Vector3) -> void:
	mode = Mode.LOOSE
	settle_grace = 0.0
	_set_simulated(true)
	position = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

# Dropped, because its holder picked up a different one. Lands, and is
# uncollectable until it settles -- so a swap is not a way to pick your own gun
# straight back up.
func drop(from: Vector3, velocity: Vector3) -> void:
	mode = Mode.FLYING
	settle_grace = SimConfig.SPECIAL_SETTLE_GRACE
	_set_simulated(true)
	position = from
	linear_velocity = velocity
	angular_velocity = Vector3.ZERO

# Into somebody's hands. The physics body stops existing as far as the world is
# concerned: frozen, no collision, positioned by whoever is holding it.
func hold(peer: int) -> void:
	mode = Mode.HELD
	owner_peer = peer
	settle_grace = 0.0
	# RESET ON PICKUP, so walking over a fresh gun does not fire a free round from
	# a timer that ran down while the last one was on the floor.
	fire_timer = SimConfig.MG_FIRE_INTERVAL
	_set_simulated(false)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rotation = Vector3.ZERO

func _set_simulated(simulated: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not simulated
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		shape.disabled = not simulated

# Clients are TOLD where a loose special is; they never simulate one.
func apply_remote(new_mode: int, at: Vector3, remaining: int) -> void:
	mode = new_mode
	ammo = remaining
	_set_simulated(false)
	position = at
