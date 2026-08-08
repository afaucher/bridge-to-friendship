extends CharacterBody3D

# A simulated player.
#
# This body does NOT decide when to run. It exposes step() and someone else
# (GameWorld) calls it: on the host for every player, on a client for the local
# player only, as a prediction. That inversion is the whole point -- the same
# function produces the authoritative result and the predicted one, so they
# cannot drift apart by being two different pieces of code.
#
# THE INTEGRATOR IS OURS. Velocity is explicit, response rules are hand-written,
# and only the sweep (move_and_slide) is Godot's. Momentum transfer here is a set
# of designed, legible rules -- "a dash into a stone moves it exactly one cell" --
# not whatever a rigid-body solver produces from a contact manifold.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

enum State {
	WALK,        # full control
	SHOVE,       # committed dash along a compass axis
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
# one of every correction.
var grounded: bool = false

# The compass axis this player last faced. A shove pressed with no movement
# input goes THIS way -- a dash that refuses to fire because the stick was
# centred reads as a dropped input.
var facing: int = GridConfig.DIR_NORTH
var shove_dir: int = GridConfig.DIR_NORTH
var shove_cooldown: float = 0.0

# --- Riding -------------------------------------------------------------------
#
# Anything standing on another sim body is CARRIED by it: from the rider's point
# of view the thing underneath is not moving. Godot will not do this for us --
# CharacterBody3D inherits platform motion only from bodies the physics server
# tracks as platforms, so one CharacterBody3D standing on another just gets left
# behind as the lower one walks out from under it.

var carrier: Node = null          # what we are standing on, if it is a sim body
var motion_delta: Vector3 = Vector3.ZERO   # how far we moved in our last step

const HALF_HEIGHT := 0.9          # matches the CylinderShape3D in player.tscn
const FOOT_PROBE := 0.25          # how far below the feet to look for a carrier

# Set by GameWorld at spawn. The world owns the momentum-transfer rules, because
# they are rules about the world and not about any one body.
var world: Node = null

func _ready() -> void:
	# The co-op gate, enforced by the engine: a slope steeper than this is not a
	# floor, so a player walking at it slides back down and needs a shove or a
	# rope instead.
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

	# RIDER TRANSPORT USES GODOT'S BUILT-IN moving-platform support (the default
	# platform_floor_layers), not our ride(). Chosen deliberately for less code;
	# two known costs, both acceptable for now and both cheap to revisit because
	# ride() is still on this class and unused:
	#
	#   1. It is ONE TICK STALE -- Godot applies the platform's PREVIOUS step of
	#      motion, so a rider lags its carrier by a tick (~10 cm at walking
	#      speed, more while accelerating).
	#   2. It lives in engine-internal state that capture_state() cannot restore,
	#      so a client reconciliation replay cannot reproduce it exactly. Same
	#      class of trap as is_on_floor(); watch GameWorld.corrections if riding
	#      ever happens during networked play.
	#
	# What it does NOT solve is the carrier being blocked by its own rider --
	# that is still handled in GameWorld's step loop.

# --- Simulation ---------------------------------------------------------------

# Advance exactly one tick. Takes no delta on purpose: move_and_slide() reads the
# delta from the physics frame, so this is only correct when the sim tick and the
# physics tick are the same duration -- which is what lets a client replay N
# ticks inside one frame and land where N frames put it.
func step(move: Vector2, actions: int) -> void:
	var before := position
	state_timer += SimConfig.TICK_DELTA
	shove_cooldown = maxf(0.0, shove_cooldown - SimConfig.TICK_DELTA)

	match state:
		State.WALK:
			_step_walk(move, actions)
		State.SHOVE:
			_step_shove()
		_:
			_step_inert()

	motion_delta = position - before
	carrier = _find_carrier()

func _step_walk(move: Vector2, actions: int) -> void:
	var dt := SimConfig.TICK_DELTA

	if move.length_squared() > 0.04:
		facing = GridConfig.nearest_direction(move)

	if (actions & SimConfig.ACTION_SHOVE) != 0 and shove_cooldown <= 0.0:
		_begin_shove(move)
		_step_shove()
		return

	# No jump: Space is the dash. See the note in SimConfig -- a jump would
	# quietly solve obstacles that are meant to need a second player.
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * dt

	# Input is world-space: the camera is fixed-yaw, so "north" is the same
	# direction on every screen and there is no camera basis to agree on.
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

func _begin_shove(move: Vector2) -> void:
	# A shove commits to ONE of four axes. Chosen from the movement input at the
	# instant of the press, falling back to the way the player was already
	# facing -- never refused for want of a direction.
	shove_dir = GridConfig.nearest_direction(move) if move.length_squared() > 0.04 else facing
	facing = shove_dir
	state = State.SHOVE
	state_timer = 0.0
	var axis: Vector3 = GridConfig.DIR_VECTORS[shove_dir]
	velocity.x = axis.x * SimConfig.SHOVE_SPEED
	velocity.z = axis.z * SimConfig.SHOVE_SPEED

func _step_shove() -> void:
	var dt := SimConfig.TICK_DELTA

	# The dash holds its speed along its axis and cannot be steered, slowed or
	# cancelled. Gravity still applies, so a dash off the deck is a dash off the
	# deck -- that commitment is where the comedy lives, and it is also why the
	# client does not predict this state: there is no input to mispredict.
	var axis: Vector3 = GridConfig.DIR_VECTORS[shove_dir]
	velocity.x = axis.x * SimConfig.SHOVE_SPEED
	velocity.z = axis.z * SimConfig.SHOVE_SPEED
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * dt

	move_and_slide()
	grounded = is_on_floor()

	var hit_something := false
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		# Only side-on contacts count. Running along the floor is not "hitting
		# something", and neither is clipping a ceiling.
		if absf(collision.get_normal().y) > 0.7:
			continue
		hit_something = true
		if world != null:
			world.resolve_shove_contact(self, collision.get_collider(), shove_dir)

	if hit_something or state_timer >= SimConfig.SHOVE_DURATION:
		end_shove()

func end_shove() -> void:
	if state != State.SHOVE:
		return
	state = State.WALK
	state_timer = 0.0
	shove_cooldown = SimConfig.SHOVE_COOLDOWN
	velocity.x = 0.0
	velocity.z = 0.0

# Momentum arriving from someone else's dash. Called by the world, which owns
# the transfer rules.
func receive_shove(dir: int) -> void:
	var axis: Vector3 = GridConfig.DIR_VECTORS[dir]
	velocity.x = axis.x * SimConfig.SHOVE_TRANSFER_SPEED
	velocity.z = axis.z * SimConfig.SHOVE_TRANSFER_SPEED
	velocity.y = maxf(velocity.y, SimConfig.SHOVE_TRANSFER_LIFT)
	grounded = false
	# A shoved player is launched, not driving. End any dash of their own so two
	# dashes cannot compound into something unrecoverable.
	if state == State.SHOVE:
		end_shove()

func _step_inert() -> void:
	if not grounded:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()

# --- Riding -------------------------------------------------------------------

# Move with whatever this body is standing on, before it takes its own step.
func ride(delta: Vector3) -> void:
	if delta != Vector3.ZERO:
		position += delta

# What is directly underneath, if it is a sim body worth being carried by.
#
# A downward ray rather than the last move_and_slide's collision list: a body
# resting motionless can produce ZERO slide collisions, so reading the collision
# list would drop the carrier on exactly the frames where standing still on a
# friend matters most. The ray is a function of position alone, which is what
# lets a reconciliation replay re-derive the same answer instead of needing it
# in the snapshot.
func _find_carrier() -> Node:
	if not grounded:
		return null
	var space := get_world_3d().direct_space_state
	var from := global_position
	var to := global_position - Vector3(0.0, HALF_HEIGHT + FOOT_PROBE, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	query.collision_mask = collision_mask
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider = hit.get("collider")
	# Only bodies that can transport a rider. Static deck needs no carrying, and
	# asking it to would be a null check away from a crash.
	if collider != null and collider.has_method("ride"):
		return collider
	return null

# --- State capture ------------------------------------------------------------
#
# The complete simulation state of this body. Everything a reconciliation replay
# needs to rewind and re-run, and everything a snapshot carries. A field that
# affects stepping and is NOT here makes replays diverge, and the tell is
# GameWorld.corrections climbing every tick instead of sitting near zero.
#
# Position is LOCAL, not global: the wire format must not encode where a world
# happens to sit in someone's scene tree.

func capture_state() -> Array:
	return [position, velocity, state, state_timer, grounded, shove_dir, shove_cooldown, facing]

func apply_state(s: Array) -> void:
	position = s[0]
	velocity = s[1]
	state = int(s[2])
	state_timer = float(s[3])
	grounded = bool(s[4])
	shove_dir = int(s[5])
	shove_cooldown = float(s[6])
	facing = int(s[7])

# There is no per-player camera. The game has ONE camera, owned by the world,
# fixed-yaw and locked to the bridge's centre line -- see
# scripts/ui/bridge_camera.gd. Per-avatar cameras were removed with it, which
# also retires the "last avatar spawned wins the viewport" hazard entirely.
