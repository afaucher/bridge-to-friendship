extends CharacterBody3D

# One player avatar. Spawned by main.gd, one per peer, on every machine.
#
# AUTHORITY MODEL: each player node's multiplayer authority is its own peer, so
# a client simulates its OWN avatar and broadcasts the result; remote avatars are
# interpolated toward the last state received. That is client-authoritative
# movement -- fine for a co-op game, wrong for a competitive one. If this ever
# needs to be cheat-resistant, the change is: clients send INPUT to the host, the
# host simulates every body and broadcasts state. The split is deliberately
# confined to _physics_process below so that swap stays a local edit.

const SPEED := 5.0
const JUMP_VELOCITY := 4.5
# How hard a remote avatar is pulled toward its last reported position, per
# second. Not a physical constant -- purely a smoothing rate for a state stream
# that arrives at whatever rate the network gives us.
const REMOTE_LERP_RATE := 12.0

@export var peer_id: int = 1

# Headless tests have no keyboard. When `input_override_active` is set, movement
# reads `input_override` (x = strafe, y = forward, jump via `jump_override`)
# instead of the InputMap, so a test can drive the same code path the player
# does rather than a parallel one that could drift out of sync with it.
var input_override_active: bool = false
var input_override: Vector2 = Vector2.ZERO
var jump_override: bool = false

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _remote_position: Vector3 = Vector3.ZERO
var _remote_yaw: float = 0.0
var _has_remote_state: bool = false

func _ready() -> void:
	set_multiplayer_authority(peer_id)
	_remote_position = global_position
	# Only the local player's camera renders. `current` is a per-viewport
	# exclusive flag, so leaving every avatar's camera enabled means the last
	# one spawned wins -- which looks like "I am playing as someone else".
	var cam := get_node_or_null("CameraPivot/Camera")
	if cam != null:
		cam.current = has_control()

# True when this machine simulates this avatar: always in solo, and for the
# owning peer in a session. NOT the same as is_multiplayer_authority() alone --
# with no peer assigned the multiplayer API's answer is not meaningful.
func has_control() -> bool:
	if not NetworkManager.active:
		return true
	return is_multiplayer_authority()

func _physics_process(delta: float) -> void:
	if not has_control():
		_apply_remote_state(delta)
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta

	var wants_jump := jump_override if input_override_active else Input.is_action_just_pressed("jump")
	if wants_jump and is_on_floor():
		velocity.y = JUMP_VELOCITY
	jump_override = false

	var axis := input_override
	if not input_override_active:
		axis = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# -Z is forward in Godot. axis.y is +1 for "back", so the forward component
	# is +axis.y on Z.
	var direction := (transform.basis * Vector3(axis.x, 0.0, axis.y)).normalized()
	if direction.length_squared() > 0.0:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()

	if NetworkManager.active:
		_push_state.rpc(global_position, rotation.y)

func _apply_remote_state(delta: float) -> void:
	if not _has_remote_state:
		return
	var t: float = clampf(REMOTE_LERP_RATE * delta, 0.0, 1.0)
	global_position = global_position.lerp(_remote_position, t)
	rotation.y = lerp_angle(rotation.y, _remote_yaw, t)

# "authority" means the multiplayer API drops this packet unless it came from
# THIS node's authority peer -- so a client cannot move another client's avatar
# by forging the call. call_remote (the default) keeps the sender from also
# running it on itself, which would fight its own simulation.
@rpc("authority", "call_remote", "unreliable_ordered")
func _push_state(pos: Vector3, yaw: float) -> void:
	_remote_position = pos
	_remote_yaw = yaw
	_has_remote_state = true
