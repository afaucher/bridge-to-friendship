extends Node

# A real host and real clients, each with their own GameWorld, in ONE headless
# process, talking over a real ENet socket.
#
# This is the rig the authority model is tested with, and it is the reason the
# design insists gameplay code never calls Steam directly. A CI box has no Steam
# client, so a Steam-only networking layer could only ever be tested by two
# humans launching two builds and squinting. ENet is the same MultiplayerAPI, the
# same RPC routing and the same peer-id semantics with a different socket
# underneath, so what this proves about replication is true of the shipping
# transport too.
#
# HOW TWO PEERS FIT IN ONE PROCESS: a SceneTree can hold several MultiplayerAPI
# instances, each rooted at a different node, via SceneTree.set_multiplayer().
# RPC targets resolve by node path RELATIVE to that root, so `GameWorld` under
# NetHost and `GameWorld` under NetClient0 are the same address as far as the API
# is concerned and calls route between them across the socket.
#
# Usage:
#   harness = NetHarness.new()
#   add_child(harness)
#   harness.start(PORT, 1)
#   ...wait for harness.ready_to_run...
#   harness.host_world / harness.client_worlds[0]

const GameWorldScript = preload("res://scripts/sim/game_world.gd")

signal ready_to_run()

var host_world: Node3D = null
var client_worlds: Array = []

var host_mp: SceneMultiplayer = null
var client_mps: Array = []

var is_ready: bool = false
var failure: String = ""

# Set BEFORE start() to stand the session up on an assembled run instead of the
# gym. Both worlds get the same seed, which is the point: a client builds the
# bridge rather than being sent it.
var assemble_run: bool = false
var run_seed: int = 0

var _client_count: int = 0
var _connected: Array = []
var _started: bool = false

func start(port: int, client_count: int, level_scene_path: String = "res://scenes/gym.tscn") -> bool:
	_client_count = client_count

	var host_root := Node.new()
	host_root.name = "NetHost"
	add_child(host_root)
	host_mp = SceneMultiplayer.new()
	get_tree().set_multiplayer(host_mp, host_root.get_path())

	host_world = _make_world(host_root, level_scene_path)

	var host_peer := ENetMultiplayerPeer.new()
	if host_peer.create_server(port, maxi(client_count, 1)) != OK:
		failure = "host could not bind port %d" % port
		return false
	host_mp.multiplayer_peer = host_peer
	host_mp.peer_connected.connect(_on_host_saw_peer)
	host_mp.peer_disconnected.connect(_on_host_lost_peer)

	for i in client_count:
		var client_root := Node.new()
		client_root.name = "NetClient%d" % i
		add_child(client_root)
		var mp := SceneMultiplayer.new()
		get_tree().set_multiplayer(mp, client_root.get_path())
		client_mps.append(mp)
		client_worlds.append(_make_world(client_root, level_scene_path))

		var client_peer := ENetMultiplayerPeer.new()
		if client_peer.create_client("127.0.0.1", port) != OK:
			failure = "client %d could not open a socket" % i
			return false
		mp.multiplayer_peer = client_peer
		# Bind the index so the callback knows which client finished.
		mp.connected_to_server.connect(_on_client_connected.bind(i))

	# The host world runs from the start; client worlds start when their peer id
	# exists, which is not until the handshake completes.
	host_world.start(true, 1, true)
	host_world.host_spawn(1)
	_started = true
	return true

# Each world is placed far from the others in world space.
#
# NOT cosmetic. Every world in this process shares ONE physics space, so the
# host's copy of a player and a client's copy of the same player would otherwise
# occupy identical coordinates -- and two PERFECTLY coincident cylinders produce
# a degenerate depenetration that drives both of them DOWN THROUGH THE FLOOR
# (measured 2026-08-08: coincident bodies settle at y = -1.9 while separated ones
# land correctly at y = 0.9). The symptom is every player free-falling from tick
# one, which reads as broken gravity rather than as two rigs sharing a room.
#
# The offset is invisible to the game because the wire format is world-LOCAL (see
# player_body.capture_state), so a snapshot never carries these coordinates.
const WORLD_SPACING := 1000.0

var _world_count: int = 0

func _make_world(under: Node, level_scene_path: String) -> Node3D:
	var world := Node3D.new()
	world.name = "GameWorld"
	world.set_script(GameWorldScript)
	world.level_scene_path = level_scene_path
	world.assemble_run = assemble_run
	# Only the HOST is given the seed. A client is told it over the wire, which is
	# the thing being tested -- handing it to both here would prove nothing.
	if assemble_run and _world_count == 0:
		world.run_seed = run_seed
	world.position = Vector3(float(_world_count) * WORLD_SPACING, 0.0, 0.0)
	_world_count += 1
	under.add_child(world)
	return world

# WAIT FOR BOTH SIDES. A client's connected_to_server fires a frame or two before
# the host's peer_connected -- each MultiplayerAPI reports what its own poll has
# seen. Acting on either one alone means spawning into a session the other end
# does not agree exists yet; see CLAUDE.md.
func _on_client_connected(index: int) -> void:
	var mp: SceneMultiplayer = client_mps[index]
	client_worlds[index].start(false, mp.get_unique_id(), true)
	_check_ready()

func _on_host_saw_peer(peer_id: int) -> void:
	if not _connected.has(peer_id):
		_connected.append(peer_id)
	host_world.host_add_peer(peer_id)
	_check_ready()

func _on_host_lost_peer(peer_id: int) -> void:
	_connected.erase(peer_id)
	host_world.host_remove_peer(peer_id)

# Readiness is POLLED, not purely event-driven. Both connection events fire
# before the host's spawn RPCs have reached the client, so a check run only from
# those handlers always sees an incomplete roster and never runs again -- the
# session comes up fine and the harness reports "not ready" forever.
func _physics_process(_delta: float) -> void:
	if not is_ready and _started:
		_check_ready()

func _check_ready() -> void:
	if is_ready:
		return
	if _connected.size() < _client_count:
		return
	for i in _client_count:
		if not client_worlds[i].running:
			return
		# The client must have been told about every player, including itself,
		# before a test can meaningfully compare worlds.
		if client_worlds[i].players.size() < _client_count + 1:
			return
	is_ready = true
	ready_to_run.emit()

# Every world in the session, host first. Handy for "assert all peers agree".
func all_worlds() -> Array:
	var out: Array = [host_world]
	out.append_array(client_worlds)
	return out

# Drive every world's local input from one place, so a test writes a single
# script of intent rather than wiring each world separately.
func set_input_provider(peer_id: int, provider: Callable) -> void:
	for world in all_worlds():
		if world.local_peer == peer_id:
			world.input_provider = provider

func shutdown() -> void:
	for world in all_worlds():
		if world != null:
			world.stop()
	if host_mp != null and host_mp.multiplayer_peer != null:
		host_mp.multiplayer_peer.close()
	for mp in client_mps:
		if mp.multiplayer_peer != null:
			mp.multiplayer_peer.close()
