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
	# M5. A chaotic pinwheeling bounce that KEEPS its momentum rather than
	# sliding to a stop -- displacement is the threat on a bridge full of holes,
	# not the damage.
	#
	# There is no SWING state, and an earlier design that had one was wrong: a
	# tumbling player on the end of a taut rope swings because that is what a
	# body on a line does. It falls out of the constraint. Two states describing
	# the same physical situation only ever drift apart.
	TUMBLE,
	LEDGE_HANG,  # M5 -- caught a lip; cannot mantle unaided, can while pulled
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

# --- Health and rescue --------------------------------------------------------

var health: int = SimConfig.MAX_HEALTH
var invulnerable: float = 0.0     # counts down after any hit

# While hanging: the compass direction from this body toward the deck it caught,
# which is the way a mantle has to go.
var hang_dir: int = GridConfig.DIR_NORTH

# How long a teammate has been stood next to this body while it waits to be
# rescued. Shared by LEDGE_HANG and DOWNED, because they are the same machinery.
var rescue_progress: float = 0.0

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

	invulnerable = maxf(0.0, invulnerable - SimConfig.TICK_DELTA)

	match state:
		State.WALK:
			_step_walk(move, actions)
		State.SHOVE:
			_step_shove()
		State.TUMBLE:
			_step_tumble()
		State.LEDGE_HANG:
			_step_hang()
		State.DOWNED:
			pass          # immobile; the world runs the countdown and the rescue
		_:
			_step_inert()

	motion_delta = position - before
	carrier = _find_carrier()
	_point_nose()

# Turn the facing marker to match the compass axis a dash would take. Driven from
# `facing`, which is captured state, so it survives a reconciliation replay
# rather than being animated independently on each machine.
func _point_nose() -> void:
	var nose := get_node_or_null("Facing") as Node3D
	if nose == null:
		return
	# The marker points along -Z at rest, which is DIR_NORTH; the rest follow
	# clockwise from there.
	match facing:
		GridConfig.DIR_NORTH: nose.rotation.y = 0.0
		GridConfig.DIR_EAST: nose.rotation.y = -PI * 0.5
		GridConfig.DIR_SOUTH: nose.rotation.y = PI
		GridConfig.DIR_WEST: nose.rotation.y = PI * 0.5

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
	if state == State.DOWNED or state == State.LEDGE_HANG:
		return
	var axis: Vector3 = GridConfig.DIR_VECTORS[dir]
	# A dash arrives at 56 m/s. That is not a nudge -- it TUMBLES you, which is
	# where the comedy lives: the shoved player loses control and goes wherever
	# the bridge sends them.
	begin_tumble(Vector3(
		axis.x * SimConfig.SHOVE_TRANSFER_SPEED,
		SimConfig.SHOVE_TRANSFER_LIFT,
		axis.z * SimConfig.SHOVE_TRANSFER_SPEED))

# --- Tumble -------------------------------------------------------------------

func _step_tumble() -> void:
	var dt := SimConfig.TICK_DELTA
	velocity.y -= SimConfig.GRAVITY * dt

	# Ground friction only. Airborne, the body keeps everything it was given --
	# that is what makes a tumble carry you somewhere you did not want to go.
	if grounded:
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		horizontal = horizontal.move_toward(Vector3.ZERO, SimConfig.TUMBLE_FRICTION * dt * horizontal.length())
		velocity.x = horizontal.x
		velocity.z = horizontal.z

	move_and_slide()
	grounded = is_on_floor()

	# BOUNCE off whatever it hits, rather than stopping dead against it. A
	# tumbling player ricocheting off a parapet and back into the pillar field is
	# the whole point; sliding to a halt at the first wall is not a threat.
	for i in get_slide_collision_count():
		var normal := get_slide_collision(i).get_normal()
		if velocity.dot(normal) < 0.0:
			velocity = velocity.bounce(normal) * SimConfig.TUMBLE_BOUNCE

	_spin_mesh()

	# Falling past a lip is the rescue window: catching it is automatic.
	if not grounded and _try_catch_ledge():
		return

	var slow_enough: bool = velocity.length() < SimConfig.TUMBLE_RECOVER_SPEED
	if state_timer >= SimConfig.TUMBLE_MAX_SECONDS \
			or (state_timer >= SimConfig.TUMBLE_MIN_SECONDS and grounded and slow_enough):
		_end_tumble()

func begin_tumble(launch: Vector3) -> void:
	if state == State.DOWNED or state == State.LEDGE_HANG:
		return
	state = State.TUMBLE
	state_timer = 0.0
	velocity = launch
	grounded = false

func _end_tumble() -> void:
	state = State.WALK
	state_timer = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	_reset_mesh()

# The MESH pinwheels; the collider never tips. A rolling player has to stay
# something a friend can stand on -- see design_ideas/3d_conventions.md.
func _spin_mesh() -> void:
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh == null:
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	# Spin about the axis perpendicular to travel, so the body rolls the way it
	# is going rather than spinning on the spot.
	var axis := Vector3(velocity.z, 0.0, -velocity.x)
	if axis.length_squared() < 0.001:
		return
	mesh.rotate(axis.normalized(), SimConfig.TUMBLE_SPIN_RATE * SimConfig.TICK_DELTA * minf(speed / 10.0, 1.5))

func _reset_mesh() -> void:
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh != null:
		mesh.rotation = Vector3.ZERO

# --- Ledges -------------------------------------------------------------------

# Catch a lip you are falling past. AUTOMATIC, no input: this fires most often
# mid-tumble, when the player has no control to answer a prompt with.
#
# Grid-based rather than a geometric probe, because the bridge IS a grid: "am I
# over a hole with solid deck beside me at about my height" is exactly the
# question, and it is a pure function of position, so a replay re-derives it.
func _try_catch_ledge() -> bool:
	if world == null or world.grid == null:
		return false
	if velocity.y > 0.0 or velocity.length() > SimConfig.LEDGE_CATCH_MAX_SPEED:
		return false

	var grid: Node = world.grid
	var cell: Vector2i = grid.cell_of_world(position)
	if grid.is_solid(cell):
		return false          # still over deck; nothing to catch

	for dir in 4:
		var neighbour: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if not grid.is_solid(neighbour):
			continue
		var lip: Vector3 = grid.cell_surface_world(neighbour)
		# Level with the lip, or just below it. Far below and you are past it --
		# which is exactly the "launched clear of the deck" case that is meant to
		# have no rescue.
		if position.y > lip.y or lip.y - position.y > SimConfig.LEDGE_CATCH_REACH:
			continue
		_begin_hang(lip, dir)
		return true
	return false

func _begin_hang(lip: Vector3, dir: int) -> void:
	state = State.LEDGE_HANG
	state_timer = 0.0
	velocity = Vector3.ZERO
	grounded = false
	hang_dir = dir
	_reset_mesh()
	# Hanging just off the edge on the hole side, head about level with the deck.
	var outward: Vector3 = GridConfig.DIR_VECTORS[dir]
	position = lip - outward * (GridConfig.CELL_SIZE * 0.5 + 0.35) - Vector3(0.0, HALF_HEIGHT, 0.0)

func _step_hang() -> void:
	# Nothing to simulate: a hanging player holds still. The world runs the
	# countdown, because letting go and being drone-returned are its business.
	velocity = Vector3.ZERO

# Climb onto the deck being hung from. A hanging player CANNOT call this on their
# own -- that is the whole point of the state. It exists for whatever is pulling
# them: the rope, in M4.
func mantle() -> bool:
	if state != State.LEDGE_HANG or world == null or world.grid == null:
		return false
	var grid: Node = world.grid
	var cell: Vector2i = grid.cell_of_world(position)
	var target: Vector2i = cell + GridConfig.DIR_CELLS[hang_dir]
	if not grid.is_solid(target):
		return false
	position = grid.cell_surface_world(target) + Vector3(0.0, HALF_HEIGHT + 0.05, 0.0)
	state = State.WALK
	state_timer = 0.0
	velocity = Vector3.ZERO
	grounded = true
	return true

# Let go, and fall. What happens when the hang timer runs out.
func release_ledge() -> void:
	if state != State.LEDGE_HANG:
		return
	state = State.TUMBLE
	state_timer = 0.0
	grounded = false

# --- Damage -------------------------------------------------------------------

# Returns true if the hit landed. The grace window is the reason it might not:
# without it one tumble through a pillar field costs the whole bar.
func take_damage(amount: int) -> bool:
	if amount <= 0 or invulnerable > 0.0:
		return false
	if state == State.DOWNED:
		return false          # already out; nothing left to take
	health = maxi(0, health - amount)
	invulnerable = SimConfig.HIT_GRACE
	if health == 0:
		begin_downed()
	return true

func heal(amount: int) -> bool:
	if health >= SimConfig.MAX_HEALTH or state == State.DOWNED:
		return false
	health = mini(SimConfig.MAX_HEALTH, health + amount)
	return true

func begin_downed() -> void:
	state = State.DOWNED
	state_timer = 0.0
	rescue_progress = 0.0
	health = 0
	velocity = Vector3.ZERO
	_reset_mesh()

func revive() -> void:
	state = State.WALK
	state_timer = 0.0
	rescue_progress = 0.0
	health = SimConfig.REVIVE_HEALTH
	invulnerable = SimConfig.HIT_GRACE

func is_awaiting_rescue() -> bool:
	return state == State.DOWNED or state == State.LEDGE_HANG

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
	return [position, velocity, state, state_timer, grounded, shove_dir, shove_cooldown,
		facing, health, invulnerable, hang_dir]

func apply_state(s: Array) -> void:
	position = s[0]
	velocity = s[1]
	state = int(s[2])
	state_timer = float(s[3])
	grounded = bool(s[4])
	shove_dir = int(s[5])
	shove_cooldown = float(s[6])
	facing = int(s[7])
	health = int(s[8])
	invulnerable = float(s[9])
	hang_dir = int(s[10])

# There is no per-player camera. The game has ONE camera, owned by the world,
# fixed-yaw and locked to the bridge's centre line -- see
# scripts/ui/bridge_camera.gd. Per-avatar cameras were removed with it, which
# also retires the "last avatar spawned wins the viewport" hazard entirely.
