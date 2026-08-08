extends Node3D

# The simulated world, and the only thing that decides what is true.
#
# ONE INSTANCE PER MACHINE. On the host it runs the authoritative simulation for
# every player and broadcasts the result. On a client it predicts the local
# player only, and takes everyone else's state from the host.
#
# It deliberately does NOT use the NetworkManager autoload. Everything here goes
# through `multiplayer`, which for a Node resolves to whichever MultiplayerAPI
# owns its subtree -- so two GameWorlds can live in one process under two
# different multiplayer roots and genuinely play against each other over a
# socket. That is what makes the authority model testable in the gate rather
# than testable by two humans launching two builds; see
# scripts/test_support/net_harness.gd.
#
# WHY THE HOST OWNS EVERYTHING: see design_ideas/physics_and_authority.md. Short
# version -- every verb in this game is an interaction between two players'
# bodies, and two machines each owning one end of a momentum transfer or a rope
# constraint cannot agree on the result.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerScene = preload("res://scenes/player.tscn")

signal player_spawned(peer_id: int)
signal player_despawned(peer_id: int)

# Snapshot entry layout. Named because a bare e[3] in the reconciler is how a
# field silently ends up read as the wrong thing.
const S_PEER := 0
const S_POSITION := 1
const S_VELOCITY := 2
const S_STATE := 3
const S_STATE_TIMER := 4
const S_GROUNDED := 5
const S_ACKED_INPUT := 6

@export var level_scene_path: String = "res://scenes/gym.tscn"

var is_host: bool = false
var local_peer: int = 1
var networked: bool = false
var running: bool = false
var tick: int = 0

var players: Dictionary = {}       # peer_id -> PlayerBody

# Tests and tools drive the sim by supplying inputs instead of a keyboard. When
# set, called as input_provider.call(tick) -> [tick, move, actions]. It feeds the
# SAME path a human's input takes, so a test cannot accidentally exercise
# movement code the game does not use.
var input_provider: Callable = Callable()

# Test-only inbound latency, in ticks. Delays applying authoritative snapshots so
# prediction and reconciliation can be exercised against a round trip that
# localhost does not provide.
var debug_inbound_delay_ticks: int = 0

# Observability. A client that corrects constantly is mispredicting, and the
# count is the cheapest possible signal that a state field is missing from
# capture_state() or from the snapshot.
var corrections: int = 0

var _level: Node = null
var _players_root: Node3D = null
var _spawn_index: Dictionary = {}

# --- host-side ---
var _inbox: Dictionary = {}            # peer -> queued inputs not yet applied
var _current_input: Dictionary = {}    # peer -> the input being applied this tick
var _last_input_tick: Dictionary = {}  # peer -> tick of the input we last applied
var _highest_queued: Dictionary = {}   # peer -> highest tick accepted into _inbox
var _next_spawn_index: int = 0

# --- client-side ---
var _pending_inputs: Array = []        # inputs the host has not acknowledged
var _predicted: Array = []             # [tick, captured_state] for each pending input
var _delayed_snapshots: Array = []

func _ready() -> void:
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)

func start(as_host: bool, peer_id: int, is_networked: bool) -> void:
	is_host = as_host
	local_peer = peer_id
	networked = is_networked
	_build_level()
	running = true

func stop() -> void:
	running = false

func _build_level() -> void:
	if _level != null or level_scene_path == "":
		return
	var packed := load(level_scene_path) as PackedScene
	if packed == null:
		printerr("[GameWorld] could not load level: ", level_scene_path)
		return
	_level = packed.instantiate()
	_level.name = "Level"
	add_child(_level)
	# Ahead of the players in the tree so its static bodies are registered with
	# the physics server before anything is asked to stand on them.
	move_child(_level, 0)

# --- Tick ---------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not running:
		return
	if is_host:
		_host_tick()
	else:
		_client_tick()

func _host_tick() -> void:
	tick += 1

	var local_input: Array = _gather_local_input(tick)
	_current_input[local_peer] = local_input
	_last_input_tick[local_peer] = tick

	# NOTE: step order becomes significant once bodies can stand on each other
	# (riding -- see design_ideas/physics_and_authority.md). Carriers will have
	# to step before their riders. Today nothing is carried, so insertion order
	# is fine.
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		if peer != local_peer:
			_consume_remote_input(peer)
		var inp: Array = _current_input.get(peer, PlayerInput.empty(0))
		players[peer].step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS])

	if tick % SimConfig.SNAPSHOT_INTERVAL_TICKS == 0:
		_broadcast_snapshot()

func _client_tick() -> void:
	tick += 1
	_release_delayed_snapshots()

	var inp: Array = _gather_local_input(tick)
	_pending_inputs.append(inp)
	_send_input()

	var body: Node = players.get(local_peer)
	if body != null:
		body.step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS])
		_predicted.append([tick, body.capture_state()])

	_trim_history()

func _gather_local_input(for_tick: int) -> Array:
	if input_provider.is_valid():
		return input_provider.call(for_tick)
	return PlayerInput.sample(for_tick)

func _trim_history() -> void:
	while _pending_inputs.size() > SimConfig.HISTORY_TICKS:
		_pending_inputs.pop_front()
	while _predicted.size() > SimConfig.HISTORY_TICKS:
		_predicted.pop_front()

# --- Host: consuming client input ---------------------------------------------

func _consume_remote_input(peer: int) -> void:
	var queue: Array = _inbox.get(peer, [])
	if queue.size() > 0:
		var e: Array = queue.pop_front()
		_current_input[peer] = e
		_last_input_tick[peer] = int(e[PlayerInput.TICK])
		return
	# Nothing arrived in time. Repeat the last input and DO NOT advance the ack.
	# Both halves matter: repeating keeps a player walking through a dropped
	# packet instead of stuttering, and holding the ack keeps the client's replay
	# aligned -- if we acknowledged an input we never applied, the client would
	# discard it and replay from a state the host never reached.

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _submit_input(batch: Array) -> void:
	if not is_host:
		return
	var peer: int = multiplayer.get_remote_sender_id()
	if not players.has(peer):
		return
	var highest: int = int(_highest_queued.get(peer, 0))
	var queue: Array = _inbox.get(peer, [])
	# The batch is oldest-first and overlaps the previous one (see
	# INPUT_REDUNDANCY); take only what is genuinely new, in order.
	for e in batch:
		var t: int = int(e[PlayerInput.TICK])
		if t > highest:
			queue.append(e)
			highest = t
	_inbox[peer] = queue
	_highest_queued[peer] = highest

func _send_input() -> void:
	if not networked:
		return
	var count: int = mini(SimConfig.INPUT_REDUNDANCY, _pending_inputs.size())
	var batch: Array = _pending_inputs.slice(_pending_inputs.size() - count)
	_submit_input.rpc_id(1, batch)

# --- Host: broadcasting state -------------------------------------------------

func _broadcast_snapshot() -> void:
	if not networked:
		return
	var entries: Array = []
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		entries.append([
			peer,
			body.position,
			body.velocity,
			body.state,
			body.state_timer,
			body.grounded,
			int(_last_input_tick.get(peer, 0)),
		])
	_apply_snapshot.rpc(tick, entries)

@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_snapshot(server_tick: int, entries: Array) -> void:
	if is_host:
		return
	if debug_inbound_delay_ticks > 0:
		_delayed_snapshots.append([tick + debug_inbound_delay_ticks, server_tick, entries])
		return
	_consume_snapshot(entries)

func _release_delayed_snapshots() -> void:
	while _delayed_snapshots.size() > 0 and int(_delayed_snapshots[0][0]) <= tick:
		var held: Array = _delayed_snapshots.pop_front()
		_consume_snapshot(held[2])

func _consume_snapshot(entries: Array) -> void:
	for e in entries:
		var peer: int = int(e[S_PEER])
		var body: Node = players.get(peer)
		if body == null:
			# The spawn RPC is reliable and will arrive; an unreliable snapshot
			# is allowed to mention a player we have not built yet.
			continue
		if peer == local_peer:
			_reconcile(body, e)
		else:
			# Remote players are pure authority -- no prediction, no
			# extrapolation. Visual interpolation is a later, cosmetic concern;
			# what matters now is that the client never invents a position for
			# someone else.
			body.apply_state([e[S_POSITION], e[S_VELOCITY], e[S_STATE], e[S_STATE_TIMER], e[S_GROUNDED]])

# --- Client: reconciliation ---------------------------------------------------

func _reconcile(body: Node, e: Array) -> void:
	var acked: int = int(e[S_ACKED_INPUT])

	# Everything the host has consumed is settled; drop it.
	while _pending_inputs.size() > 0 and int(_pending_inputs[0][PlayerInput.TICK]) <= acked:
		_pending_inputs.pop_front()
	while _predicted.size() > 0 and int(_predicted[0][0]) < acked:
		_predicted.pop_front()

	# Compare what we predicted for the acked tick against what actually
	# happened. If we were close enough, the prediction stands and the player
	# sees nothing -- which is the common case and the whole point.
	if _predicted.size() > 0 and int(_predicted[0][0]) == acked:
		var predicted_position: Vector3 = _predicted[0][1][0]
		if predicted_position.distance_to(e[S_POSITION]) <= SimConfig.CORRECTION_EPSILON:
			return

	corrections += 1

	# Rewind to the authoritative frame and replay every input the host has not
	# seen yet. Because step() is the same function the host ran, and because a
	# sim tick is exactly one physics tick, replaying N inputs inside this single
	# frame lands where N frames of host simulation will land.
	body.apply_state([e[S_POSITION], e[S_VELOCITY], e[S_STATE], e[S_STATE_TIMER], e[S_GROUNDED]])
	_predicted.clear()
	for pending in _pending_inputs:
		body.step(pending[PlayerInput.MOVE], pending[PlayerInput.ACTIONS])
		_predicted.append([int(pending[PlayerInput.TICK]), body.capture_state()])

# --- Spawning -----------------------------------------------------------------
#
# The host decides who exists. call_local means the host runs the same function
# it asks clients to run, rather than a host branch and a client branch that can
# disagree about spawn position.

func host_spawn(peer: int) -> void:
	if not is_host:
		return
	var index: int = _next_spawn_index
	_next_spawn_index += 1
	if networked:
		_spawn_player.rpc(peer, index)
	else:
		_spawn_player(peer, index)

func host_add_peer(peer: int) -> void:
	if not is_host:
		return
	# Catch the newcomer up on everyone already here, THEN announce it to
	# everyone. That order matters the moment a spawn carries state: the new peer
	# should know the world before the world knows it.
	for existing_key in players.keys():
		var existing: int = int(existing_key)
		_spawn_player.rpc_id(peer, existing, int(_spawn_index.get(existing, 0)))
	host_spawn(peer)

func host_remove_peer(peer: int) -> void:
	if not is_host:
		return
	if networked:
		_despawn_player.rpc(peer)
	else:
		_despawn_player(peer)

@rpc("authority", "call_local", "reliable")
func _spawn_player(peer: int, index: int) -> void:
	if players.has(peer):
		return
	var body: Node = PlayerScene.instantiate()
	body.name = "Player_%d" % peer
	body.peer_id = peer
	body.position = spawn_point(index)
	_players_root.add_child(body)
	players[peer] = body
	_spawn_index[peer] = index
	if not _inbox.has(peer):
		_inbox[peer] = []
	body.set_view_active(peer == local_peer)
	player_spawned.emit(peer)

@rpc("authority", "call_local", "reliable")
func _despawn_player(peer: int) -> void:
	if not players.has(peer):
		return
	players[peer].queue_free()
	players.erase(peer)
	_inbox.erase(peer)
	_current_input.erase(peer)
	_last_input_tick.erase(peer)
	_highest_queued.erase(peer)
	_spawn_index.erase(peer)
	player_despawned.emit(peer)

func spawn_point(index: int) -> Vector3:
	# A ring, so two players never spawn inside each other -- overlapping
	# CharacterBody3Ds resolve by shoving each other apart, which reads as a
	# physics bug at the exact moment a new player is looking at the game.
	var angle: float = TAU * float(index) / 4.0
	return Vector3(cos(angle) * 4.0, 1.5, sin(angle) * 4.0)

# --- Queries (used by tests and the HUD) --------------------------------------

func player_position(peer: int) -> Vector3:
	var body: Node = players.get(peer)
	return body.position if body != null else Vector3.ZERO

func player_state(peer: int) -> int:
	var body: Node = players.get(peer)
	return body.state if body != null else -1
