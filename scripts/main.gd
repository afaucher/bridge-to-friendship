extends Node3D

# Root of the running game. Owns the menu, the spawned avatars, and the headless
# entry points used by the test gate.

const PlayerScene := preload("res://scenes/player.tscn")

# Where the Nth player appears, on a ring so two peers never spawn inside each
# other (a CharacterBody3D spawned overlapping another one gets pushed out in a
# way that reads as a physics bug).
const SPAWN_RADIUS := 4.0
const SPAWN_HEIGHT := 1.0

@onready var menu: VBoxContainer = $CanvasLayer/Menu
@onready var status_label: Label = $CanvasLayer/Menu/StatusLabel
@onready var players_root: Node3D = $Players
@onready var spectator_camera: Camera3D = $SpectatorCamera

# peer id -> player node. The host's copy is the source of truth for who exists;
# clients receive it through _spawn_player.
var players: Dictionary = {}

func _ready() -> void:
	# Headless entry points come first: a test run must not touch the menu, the
	# network, or Steam.
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--run-test" and i + 1 < args.size():
			_run_test(args[i + 1])
			return
		elif args[i] == "--run-sim" and i + 1 < args.size():
			_run_sim(args[i + 1])
			return

	$CanvasLayer/Menu/HostButton.pressed.connect(_on_host_pressed)
	$CanvasLayer/Menu/JoinButton.pressed.connect(_on_join_pressed)
	$CanvasLayer/Menu/LocalButton.pressed.connect(_on_local_pressed)

	NetworkManager.session_started.connect(_on_session_started)
	NetworkManager.session_ended.connect(_on_session_ended)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.session_error.connect(_set_status)
	SteamManager.lobby_error.connect(_set_status)

	if not SteamManager.available:
		_set_status("Steam not available -- solo only.")

func _unhandled_input(_event: InputEvent) -> void:
	if Input.is_action_just_pressed("system_exit"):
		get_tree().quit()

# --- Menu --------------------------------------------------------------------

func _on_host_pressed() -> void:
	_set_status("Creating lobby...")
	await NetworkManager.host(NetworkManager.Transport.STEAM)

func _on_join_pressed() -> void:
	if not SteamManager.request_lobby_list():
		return
	_set_status("Searching for lobbies...")
	var lobbies: Array = await SteamManager.lobby_list
	if lobbies.is_empty():
		_set_status("No lobbies found.")
		return
	# Placeholder: joins the first lobby found. A real lobby browser goes here.
	SteamManager.join_lobby(int(lobbies[0]))
	await SteamManager.lobby_joined
	NetworkManager.join(NetworkManager.Transport.STEAM)

func _on_local_pressed() -> void:
	menu.hide()
	_spawn_player(1)

# --- Session -----------------------------------------------------------------

func _on_session_started(is_host: bool) -> void:
	menu.hide()
	if is_host:
		_spawn_player.rpc(1)
	# A client spawns nothing itself: the host tells it about every avatar,
	# including its own, so there is exactly one place that decides who exists.

func _on_session_ended() -> void:
	for id in players.keys():
		_despawn_player(id)
	menu.show()
	spectator_camera.current = true
	_set_status("Disconnected.")

func _on_peer_joined(id: int) -> void:
	if not NetworkManager.is_host:
		return
	# Catch the newcomer up on everyone already here, THEN announce it to
	# everyone. In that order: the reverse makes the new peer's own avatar
	# arrive before it knows about the others, which is harmless now but is the
	# kind of ordering that breaks the moment spawn carries state.
	for existing_id in players.keys():
		_spawn_player.rpc_id(id, existing_id)
	_spawn_player.rpc(id)

func _on_peer_left(id: int) -> void:
	if NetworkManager.is_host:
		_despawn_player.rpc(id)

# --- Spawning ----------------------------------------------------------------

# call_local: the host runs this too, so there is one spawn path rather than a
# host branch and a client branch that can disagree.
@rpc("authority", "call_local", "reliable")
func _spawn_player(id: int) -> void:
	if players.has(id):
		return
	var player := PlayerScene.instantiate()
	player.name = "Player_%d" % id
	player.peer_id = id
	player.position = spawn_point(players.size())
	players_root.add_child(player)
	players[id] = player
	if id == _local_id():
		spectator_camera.current = false

@rpc("authority", "call_local", "reliable")
func _despawn_player(id: int) -> void:
	if not players.has(id):
		return
	players[id].queue_free()
	players.erase(id)

func spawn_point(index: int) -> Vector3:
	var angle := TAU * float(index) / float(NetworkManager.MAX_PLAYERS)
	return Vector3(cos(angle) * SPAWN_RADIUS, SPAWN_HEIGHT, sin(angle) * SPAWN_RADIUS)

func _local_id() -> int:
	return NetworkManager.local_id() if NetworkManager.active else 1

func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
	print("[Main] ", text)

# --- Headless entry points ---------------------------------------------------

func _run_test(test_name: String) -> void:
	print("Starting automated test: ", test_name)
	menu.hide()

	# Deterministic RNG for every test. The global randi/randf is otherwise
	# seeded from entropy per launch, which makes any test whose OUTCOME depends
	# on a random draw flaky run to run -- and a flaky gate gets ignored, which
	# costs the one real regression it exists to catch. One fixed seed here gives
	# the whole run a repeatable draw sequence. Do NOT remove it; if a new test
	# is flaky, check this first.
	seed(20260808)

	var path := "res://scripts/tests/%s.gd" % test_name
	if not ResourceLoader.exists(path):
		printerr("[TEST FAILED] test script not found: ", path)
		get_tree().quit(1)
		return
	var node := Node.new()
	node.name = test_name
	node.set_script(load(path))
	add_child(node)
	if node.has_method("setup"):
		node.setup(self)

func _run_sim(sim_name: String) -> void:
	print("Starting simulation: ", sim_name)
	menu.hide()
	var path := "res://sims/%s.gd" % sim_name
	if not ResourceLoader.exists(path):
		printerr("[SIM FAILED] sim script not found: ", path)
		get_tree().quit(1)
		return
	var node := Node.new()
	node.name = sim_name
	node.set_script(load(path))
	add_child(node)
	if node.has_method("setup"):
		node.setup(self)
