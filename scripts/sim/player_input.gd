extends RefCounted

# One tick of a player's intent, and the only thing a client is allowed to tell
# the host about itself.
#
# WIRE FORMAT is a plain 3-element Array: [tick: int, move: Vector2, actions: int].
# An Array rather than a class because it serialises natively over an RPC with no
# encode/decode step to get wrong, and this crosses the network 60 times a second
# per player.
#
# `move` is WORLD-SPACE, not camera-space. The camera is fixed-yaw (a consequence
# of the compass-locked shove -- see design_ideas/mvp_success_criteria.md D4), so
# "north" is the same direction on every screen and there is no camera basis to
# transmit or agree on. If the camera ever gains free yaw, this becomes a lie and
# the aim direction has to travel with the input.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

const TICK := 0
const MOVE := 1
const ACTIONS := 2

static func make(tick: int, move: Vector2, actions: int) -> Array:
	return [tick, move, actions]

static func empty(tick: int) -> Array:
	return [tick, Vector2.ZERO, 0]

# Reads the live InputMap. Only ever called on the machine a human is sitting at;
# headless tests build inputs with make() instead, which is the same path the
# host consumes -- there is no separate test-only movement code.
static func sample(tick: int) -> Array:
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var actions := 0
	# Edge-triggered: set for exactly the tick the key went down. That is what
	# survives a reconciliation replay -- a level-triggered "is held" bit would
	# re-fire the jump on every replayed tick.
	if Input.is_action_just_pressed("shove"):
		actions |= SimConfig.ACTION_SHOVE
	return [tick, move, actions]

# True when this input carries anything the host must not miss. Used to decide
# whether a packet is worth repeating beyond the standard redundancy window.
static func has_edge_action(input: Array) -> bool:
	return int(input[ACTIONS]) != 0
