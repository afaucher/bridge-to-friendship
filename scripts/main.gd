extends Node3D

# Application shell: the menu, the headless entry points, and the one GameWorld
# that holds the running game. It deliberately holds no simulation itself --
# everything that is part of the game world lives in scripts/sim/game_world.gd,
# which is what lets a test stand up two of them in one process.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudScript = preload("res://scripts/ui/hud.gd")
const DebugConsoleScript = preload("res://scripts/ui/debug_console.gd")
const BuildVersion = preload("res://scripts/ui/build_version.gd")

# A session plays an assembled RUN, not a fixed map -- see scripts/grid/
# segment_pool.gd. Every run opens on the same first segment, so nobody is
# dropped straight into the hardest thing in the pool, and the test fixtures are
# deliberately not in that pool: tuning content for feel can never break the gate.

@onready var menu: VBoxContainer = $CanvasLayer/Menu
@onready var status_label: Label = $CanvasLayer/Menu/StatusLabel
@onready var spectator_camera: Camera3D = $SpectatorCamera

var world: Node3D = null
var hud: CanvasLayer = null
var debug_console: CanvasLayer = null

func _ready() -> void:
	# Headless entry points first, before any menu, network or Steam wiring: a
	# test run must not touch any of it.
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--run-test" and i + 1 < args.size():
			_run_test(args[i + 1])
			return
		elif args[i] == "--run-sim" and i + 1 < args.size():
			_run_sim(args[i + 1])
			return

	# A sibling of the menu rather than a child of it, so hiding the menu to start
	# a game leaves the build stamp on screen. It is added here and not in the
	# .tscn because every other piece of UI in this project is built in code (see
	# hud.gd) -- and because a headless run returns above this line, so a test
	# never builds a Label it will not look at.
	$CanvasLayer.add_child(BuildVersion.make_label())

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
		return
	# F1 opens the debug console. Deliberately available WITHOUT a world, so the
	# knobs can be read and set from the main menu -- and deliberately the same
	# key whether hosting, joining or solo, because the panel is identical in all
	# three and any player may change anything.
	if Input.is_action_just_pressed("debug_console"):
		_toggle_debug_console()
		return
	if world == null:
		return
	# F2 adds a practice partner, F3 hands control to the next player. Every verb
	# in this game needs two bodies, and standing up two networked clients to
	# find out whether a dash feels right is a disproportionate loop.
	if Input.is_action_just_pressed("debug_add_player"):
		_set_status("Practice partner %d added (F3 to switch)" % world.debug_add_practice_player())
	elif Input.is_action_just_pressed("debug_switch_player"):
		_set_status("Controlling player %d" % world.debug_cycle_control())

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
	spectator_camera.current = false
	_create_world(true, 1, false)
	world.host_spawn(1)

# --- Session -----------------------------------------------------------------

func _on_session_started(is_host: bool) -> void:
	menu.hide()
	spectator_camera.current = false
	_create_world(is_host, NetworkManager.local_id(), true)
	if is_host:
		world.host_spawn(1)
	# A client spawns nothing itself: the host tells it about every avatar,
	# including its own, so exactly one machine decides who exists.

func _on_session_ended() -> void:
	if world != null:
		world.stop()
		world.queue_free()
		world = null
	if hud != null:
		# Cleared, not just hidden: the HUD holds a reference to the world we are
		# about to free, and it reads it every frame.
		hud.world = null
		hud.hide()
	menu.show()
	spectator_camera.current = true
	_set_status("Disconnected.")

func _on_peer_joined(id: int) -> void:
	if world != null and NetworkManager.is_host:
		world.host_add_peer(id)

func _on_peer_left(id: int) -> void:
	if world != null and NetworkManager.is_host:
		world.host_remove_peer(id)

func _create_world(is_host: bool, local_peer: int, networked: bool) -> void:
	world = Node3D.new()
	world.name = "GameWorld"
	world.set_script(GameWorldScript)
	world.assemble_run = true
	# Only the host picks a seed. A client is told which run this is over the
	# wire and builds the identical bridge from it -- that one number is the
	# whole world, which is what makes joining a run in progress affordable.
	if is_host:
		world.run_seed = randi()
	# This is the world a human is looking at, so its camera takes the viewport.
	world.view_active = true
	add_child(world)
	# Started after being added to the tree: the RPC paths a GameWorld uses are
	# resolved from its position in the tree, so it must be parented first.
	world.start(is_host, local_peer, networked)
	_show_hud()

func _show_hud() -> void:
	if hud == null:
		hud = HudScript.new()
		hud.name = "Hud"
		add_child(hud)
	hud.world = world
	hud.show()

func _toggle_debug_console() -> void:
	if debug_console == null:
		debug_console = DebugConsoleScript.new()
		debug_console.name = "DebugConsole"
		add_child(debug_console)
	# Re-pointed every time rather than once at creation: the panel outlives a
	# session, and a stale world reference would send every request into the
	# world somebody just left.
	debug_console.world = world
	debug_console.toggle()

func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
	print("[Main] ", text)

# --- Headless entry points ---------------------------------------------------

func _run_test(test_name: String) -> void:
	print("Starting automated test: ", test_name)

	# Deterministic RNG for every test. The global randi/randf is otherwise
	# seeded from entropy per launch, which makes any test whose outcome depends
	# on a random draw flaky run to run -- and a flaky gate gets ignored, which
	# costs the one real regression it exists to catch. Do NOT remove it; if a
	# new test is flaky, check this first.
	seed(20260808)

	var path := "res://scripts/tests/%s.gd" % test_name
	if not ResourceLoader.exists(path):
		printerr("[TEST FAILED] test script not found: ", path)
		get_tree().quit(1)
		return

	# A script with a PARSE ERROR loads as null. Setting a null script leaves a
	# bare Node that has no setup(), runs nothing, and never quits -- so a typo
	# presented as a 600s HANG rather than a failure, and the real message
	# (Parse Error) scrolled past in the .err.log while the runner sat there.
	# Cost 300s on 2026-08-08 before anyone read the log. Fail loudly instead.
	var script: Resource = load(path)
	if script == null:
		printerr("[TEST FAILED] ", test_name, " did not compile -- see the .err.log for the Parse Error")
		get_tree().quit(1)
		return

	var node := Node.new()
	node.name = test_name
	node.set_script(script)
	add_child(node)
	if not node.has_method("setup"):
		printerr("[TEST FAILED] ", test_name, " has no setup(main) entry point")
		get_tree().quit(1)
		return
	node.setup(self)

func _run_sim(sim_name: String) -> void:
	print("Starting simulation: ", sim_name)
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
