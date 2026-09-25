extends RigidBody3D

# SOMETHING A PLAYER PICKS UP AND CARRIES: a hat (worn) or a special (held).
#
# Both are the same object with a different name for "on a player": a rigid body
# that is LOOSE on the deck, FLYING after being knocked or dropped, or CARRIED --
# frozen, not simulated, and posed by whoever holds it. They had each written the
# same _ready, the same place/launch/carry, the same "only a blast knocks one
# loose" rule and the same freeze toggle.
#
# THE MODE VALUES ARE SHARED: each subclass keeps its own enum (HatBody.Mode.WORN,
# SpecialBody.Mode.HELD) and every one of them is CARRIED = 0, FLYING = 1,
# LOOSE = 2, which is what these constants name for code that handles either.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

const MODE_CARRIED := 0
const MODE_FLYING := 1
const MODE_LOOSE := 2

var id: int = 0
var mode: int = MODE_LOOSE
var owner_peer: int = 0

# While FLYING: how long it has to be still before it counts as settled (and so
# collectable). See each subclass's `step()`.
var settle_grace: float = 0.0

func _ready() -> void:
	gravity_scale = SimConfig.GRAVITY / 9.8
	continuous_cd = true
	# A hat that lands on its side rolls, and so does a weapon; neither ever
	# settles. Rotation is a pose, not physics, for anything carried.
	lock_rotation = true
	linear_damp = 0.6

func _settle_grace() -> float:
	return 0.0

func is_collectable() -> bool:
	return mode == MODE_LOOSE

func is_gone() -> bool:
	return position.y < SimConfig.FALL_KILL_Y

func place_loose(at: Vector3) -> void:
	mode = MODE_LOOSE
	settle_grace = 0.0
	_set_simulated(true)
	position = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

# Knocked, thrown or dropped: in the air until it settles.
func launch(from: Vector3, velocity: Vector3) -> void:
	mode = MODE_FLYING
	settle_grace = _settle_grace()
	_set_simulated(true)
	position = from
	linear_velocity = velocity
	angular_velocity = Vector3.ZERO

# Onto a player. The subclass's wear()/hold() adds what that means for it.
func _carry(peer: int) -> void:
	mode = MODE_CARRIED
	owner_peer = peer
	settle_grace = 0.0
	_set_simulated(false)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rotation = Vector3.ZERO

# ONLY A BLAST MOVES ONE, and never one somebody is carrying -- that is the
# owner's business (a tumble dislodges a hat stack, it does not shoot it off).
func receive_hit(hit) -> bool:
	if hit.kind != Hit.Kind.EXPLOSIVE or mode == MODE_CARRIED:
		return false
	launch(position, hit.launch_for(position))
	return true

# Simulated by the physics server, or frozen and posed by hand.
func _set_simulated(simulated: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not simulated
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		shape.disabled = not simulated
