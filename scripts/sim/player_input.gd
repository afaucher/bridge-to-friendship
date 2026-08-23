extends RefCounted

# One tick of a player's intent, and the only thing a client is allowed to tell
# the host about itself.
#
# WIRE FORMAT is a plain 4-element Array:
#   [tick: int, move: Vector2, actions: int, aim: float, aim_point: Vector3]
# An Array rather than a class because it serialises natively over an RPC with no
# encode/decode step to get wrong, and this crosses the network 60 times a second
# per player.
#
# `move` is WORLD-SPACE, not camera-space. The camera is fixed-yaw, so "north" is
# the same direction on every screen and there is no camera basis to transmit or
# agree on.
#
# `aim` IS ON THE WIRE, and it has to be. It is resolved from a mouse cursor or a
# right stick, which are devices only the owning client has -- the host cannot
# re-derive it from anything, unlike `move`, which is just a stick. It is also
# the direction a dash commits to, so a host that guessed it would send players
# somewhere they did not point. This is the field the old note here said would be
# needed "if the camera ever gains free yaw"; free AIM arrived first and needs it
# for the same reason.
#
# It is an absolute angle, not a delta, so a dropped input packet costs one tick
# of staleness rather than a facing that is permanently rotated.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const AimSource = preload("res://scripts/sim/aim_source.gd")

const TICK := 0
const MOVE := 1
const ACTIONS := 2
const AIM := 3
const AIM_POINT := 4

# WHERE THE CURSOR IS IN THE WORLD, not just which way it lies (M20).
#
# `aim` is a bearing on the deck plane and cannot say ANYTHING about height, which
# is why every shot in the game leaves level. This is the same cursor resolved
# against the world instead of against a plane, so it carries the up-and-down that
# a bearing threw away.
#
# A POINT AND NOT A PITCH. The muzzle is not the player -- it is the barrel tip,
# held to one side -- so a direction computed at the body and reused at the muzzle
# is off by that offset forever. Given a place, the shot can be aimed at it from
# wherever the gun actually is, which is the whole feature.
#
# CARRIED, NOT DERIVED, for exactly the reason `aim` is: it comes from a cursor,
# and the host has no cursor.
#
# NOT IN capture_state. It is an INPUT, refreshed every tick like `move`, and it
# changes only where a shot goes -- never how the body steps. `facing` already
# carries the bearing and is already replicated, so a replay that re-runs step()
# with the recorded input reproduces everything that matters.
const AIM_POINT_NONE := Vector3.INF

# No aiming device has been touched. Kept as a distinct value rather than
# defaulting to north, so the body can fall back to the direction of travel --
# which is what a keyboard-only player, and every existing test, expects.
const AIM_NONE := AimSource.NONE

static func make(tick: int, move: Vector2, actions: int, aim: float = AIM_NONE,
		aim_point: Vector3 = AIM_POINT_NONE) -> Array:
	return [tick, move, actions, aim, aim_point]

static func empty(tick: int) -> Array:
	return [tick, Vector2.ZERO, 0, AIM_NONE, AIM_POINT_NONE]

# Reads the live InputMap. Only ever called on the machine a human is sitting at;
# headless tests build inputs with make() instead, which is the same path the
# host consumes -- there is no separate test-only movement code.
#
# `aim` is passed IN rather than read here: resolving a cursor to a direction
# needs the camera and the player's position, and this is a static function that
# has neither. GameWorld owns both, so it does that half and hands the answer
# down. See aim_source.gd.
static func sample(tick: int, aim: float = AIM_NONE,
		aim_point: Vector3 = AIM_POINT_NONE) -> Array:
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var actions := 0
	# Edge-triggered: set for exactly the tick the key went down. That is what
	# survives a reconciliation replay -- a level-triggered "is held" bit would
	# re-fire the dash on every replayed tick.
	if Input.is_action_just_pressed("shove"):
		actions |= SimConfig.ACTION_SHOVE
	# LEVEL-TRIGGERED, and the only bit here that is. A machine gun is held down;
	# see SimConfig.ACTION_SPECIAL_HELD for why that is safe for a weapon and would
	# not be for legs.
	if Input.is_action_pressed("special"):
		actions |= SimConfig.ACTION_SPECIAL_HELD
	# Edge-triggered, like the dash. Holding it is answered by CALL_COOLDOWN
	# rather than by the bit, so that the rule lives with the behaviour.
	if Input.is_action_just_pressed("call_help"):
		actions |= SimConfig.ACTION_CALL
	return [tick, move, actions, aim, aim_point]

# Older inputs on the wire, and every test that builds a 3-element array by hand,
# are still legal. Reading the field through here rather than by index means a
# short array is a fallback rather than an out-of-bounds read -- which in
# GDScript aborts the rest of the frame's function silently.
static func aim_of(input: Array) -> float:
	if input.size() <= AIM:
		return AIM_NONE
	return float(input[AIM])

# Same tolerance, one field later. Every test that hand-builds a 4-element array,
# and every packet from a build without this field, reads as "no point" rather
# than as an out-of-bounds access -- which in GDScript aborts the rest of the
# calling function silently and would take the whole tick with it.
static func point_of(input: Array) -> Vector3:
	if input.size() <= AIM_POINT:
		return AIM_POINT_NONE
	return input[AIM_POINT]

static func has_point(input: Array) -> bool:
	return is_finite(point_of(input).x)

# True when this input carries anything the host must not miss. Used to decide
# whether a packet is worth repeating beyond the standard redundancy window.
static func has_edge_action(input: Array) -> bool:
	return int(input[ACTIONS]) != 0
