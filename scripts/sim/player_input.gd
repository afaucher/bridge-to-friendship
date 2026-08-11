extends RefCounted

# One tick of a player's intent, and the only thing a client is allowed to tell
# the host about itself.
#
# WIRE FORMAT is a plain 4-element Array:
#   [tick: int, move: Vector2, actions: int, aim: float]
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

# No aiming device has been touched. Kept as a distinct value rather than
# defaulting to north, so the body can fall back to the direction of travel --
# which is what a keyboard-only player, and every existing test, expects.
const AIM_NONE := AimSource.NONE

static func make(tick: int, move: Vector2, actions: int, aim: float = AIM_NONE) -> Array:
	return [tick, move, actions, aim]

static func empty(tick: int) -> Array:
	return [tick, Vector2.ZERO, 0, AIM_NONE]

# Reads the live InputMap. Only ever called on the machine a human is sitting at;
# headless tests build inputs with make() instead, which is the same path the
# host consumes -- there is no separate test-only movement code.
#
# `aim` is passed IN rather than read here: resolving a cursor to a direction
# needs the camera and the player's position, and this is a static function that
# has neither. GameWorld owns both, so it does that half and hands the answer
# down. See aim_source.gd.
static func sample(tick: int, aim: float = AIM_NONE) -> Array:
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var actions := 0
	# Edge-triggered: set for exactly the tick the key went down. That is what
	# survives a reconciliation replay -- a level-triggered "is held" bit would
	# re-fire the dash on every replayed tick.
	if Input.is_action_just_pressed("shove"):
		actions |= SimConfig.ACTION_SHOVE
	return [tick, move, actions, aim]

# Older inputs on the wire, and every test that builds a 3-element array by hand,
# are still legal. Reading the field through here rather than by index means a
# short array is a fallback rather than an out-of-bounds read -- which in
# GDScript aborts the rest of the frame's function silently.
static func aim_of(input: Array) -> float:
	if input.size() <= AIM:
		return AIM_NONE
	return float(input[AIM])

# True when this input carries anything the host must not miss. Used to decide
# whether a packet is worth repeating beyond the standard redundancy window.
static func has_edge_action(input: Array) -> bool:
	return int(input[ACTIONS]) != 0
