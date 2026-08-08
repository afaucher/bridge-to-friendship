extends CharacterBody3D

# A simulated player. Replaces M0's player.gd, which simulated itself on its
# owner's machine and broadcast the result -- see
# design_ideas/physics_and_authority.md for why that cannot survive this design.
#
# This body does NOT decide when to run. It exposes step() and someone else
# (GameWorld) calls it: on the host for every player, on a client for the local
# player only, as a prediction. That inversion is the whole point -- the same
# function produces the authoritative result and the predicted one, so they
# cannot drift apart by being two different pieces of code.
#
# THE INTEGRATOR IS OURS. Velocity is explicit, response rules are hand-written,
# and only the sweep (move_and_slide) is Godot's. Momentum transfer in this game
# is a set of designed, legible rules -- "a dash into a stone moves it exactly one
# cell" -- not whatever a rigid-body solver produces from a contact manifold.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")

# The full set, declared now and mostly unreachable until later milestones.
# Declared early because "the bus driver loses every other verb" is a statement
# about the PLAYER's state, and discovering that after every ability check is
# written means unpicking all of them.
enum State {
	WALK,        # M1 -- the only reachable state today
	SHOVE,       # M3
	TUMBLE,      # M5
	SWING,       # M4 -- roped and taut; replaces TUMBLE on impact
	LEDGE_HANG,  # M5 -- caught an edge, bleeding out, rescuable by rope
	DOWNED,      # M5
	BUS_DRIVER,  # M11 -- steering only
	BUS_RIDER,   # M11 -- verbs but no movement
}

@export var peer_id: int = 1

var state: int = State.WALK
var state_timer: float = 0.0

# Our own floor flag, refreshed from is_on_floor() after every move_and_slide.
#
# NOT a convenience wrapper. is_on_floor() is derived state living inside the
# CharacterBody3D, and apply_state() cannot touch it -- so a client that rewinds
# to an airborne authoritative frame would replay its first tick still believing
# it was standing, take the grounded branch, and diverge from the host on tick
# one of every correction. Reading a value we captured ourselves makes the
# grounded flag rewindable like everything else in capture_state().
var grounded: bool = false

# --- Simulation ---------------------------------------------------------------

# Advance exactly one tick. Takes no delta on purpose: move_and_slide() reads the
# delta from the physics frame, so this is only correct when the sim tick and the
# physics tick are the same duration. That equality is what lets a client replay
# N ticks inside one frame and land where N frames put it -- see
# SimConfig.TICK_DELTA.
func step(move: Vector2, actions: int) -> void:
	state_timer += SimConfig.TICK_DELTA
	match state:
		State.WALK:
			_step_walk(move, actions)
		_:
			# Every other state arrives with its milestone. Until then they fall
			# and slide rather than freezing in mid-air, so an accidental
			# transition is visible as odd behaviour instead of a locked player.
			_step_inert()

func _step_walk(move: Vector2, actions: int) -> void:
	var dt := SimConfig.TICK_DELTA

	if grounded:
		# Clamp accumulated downward velocity while grounded. Without this,
		# gravity integrates forever into a large negative y that has to be paid
		# off before a jump reads as a jump.
		if velocity.y < 0.0:
			velocity.y = 0.0
		if (actions & SimConfig.ACTION_JUMP) != 0:
			velocity.y = SimConfig.JUMP_VELOCITY
	else:
		velocity.y -= SimConfig.GRAVITY * dt

	# Input is world-space (see player_input.gd). -Z is forward in Godot and the
	# input map's "back" is +1 on y, so y maps straight onto +Z.
	var wish := Vector3(move.x, 0.0, move.y)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var target := wish * SimConfig.WALK_SPEED
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := SimConfig.WALK_ACCEL if wish.length_squared() > 0.0 else SimConfig.WALK_FRICTION
	horizontal = horizontal.move_toward(target, rate * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	move_and_slide()
	grounded = is_on_floor()

func _step_inert() -> void:
	if not grounded:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()

# --- State capture ------------------------------------------------------------
#
# The complete simulation state of this body, and nothing else. Everything a
# reconciliation replay needs to rewind to a past tick and re-run forward from
# it, and everything a snapshot needs to carry. If a future milestone adds a
# field that affects stepping -- rope attachment, tumble momentum, what this body
# is standing on -- it belongs here, and the tell that it was forgotten is a
# client that corrects endlessly because its replay cannot reproduce the host's
# result.

# Position is LOCAL (relative to the GameWorld), not global. The wire format must
# not encode where a world happens to sit in someone's scene tree -- in the
# shipping game there is one world at the origin so the two are identical, but
# the test harness runs several worlds side by side in one physics space, and a
# protocol carrying absolute coordinates would teleport a client's player into
# the host's copy of the world.
func capture_state() -> Array:
	return [position, velocity, state, state_timer, grounded]

func apply_state(s: Array) -> void:
	position = s[0]
	velocity = s[1]
	state = int(s[2])
	state_timer = float(s[3])
	grounded = bool(s[4])

# --- View ---------------------------------------------------------------------

func set_view_active(active: bool) -> void:
	# Camera `current` is a per-viewport exclusive flag: leaving every avatar's
	# camera enabled means the last one spawned wins, which presents as "I am
	# playing as someone else" rather than as a camera bug.
	var cam := get_node_or_null("CameraPivot/Camera") as Camera3D
	if cam != null:
		cam.current = active
