extends "res://scripts/test_support/test_case.gd"

# The gate's canary. Everything else in scripts/tests/ assumes the project
# BOOTS -- this is the test that says so, and it is the one to read first when
# the whole suite goes red at once (a broken autoload or a renamed scene fails
# every test, and only this one says why in a single line).

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

func setup(main) -> void:
	# Autoloads, by the names the rest of the code calls them.
	check(DebugSettings != null, "DebugSettings autoload is present")
	check(SteamManager != null, "SteamManager autoload is present")
	check(NetworkManager != null, "NetworkManager autoload is present")

	# The main scene is the application shell: menu and camera, no world. The
	# world is a GameWorld created at runtime, which is what lets a test stand up
	# two of them in one process.
	check(main is Node3D, "main scene root is a Node3D")
	check(main.get_node_or_null("CanvasLayer/Menu") != null, "main scene has a menu")
	check(main.get_node_or_null("SpectatorCamera") != null, "main scene has a spectator camera")

	# The level loads and has something to stand on.
	var gym := load("res://scenes/gym.tscn") as PackedScene
	if check(gym != null, "gym level loads"):
		var level := gym.instantiate()
		check(level.get_node_or_null("Ground") != null, "gym has a ground body")
		level.free()

	# The player scene loads and instantiates. Loading a .tscn is where a bad
	# sub-resource or a renamed script surfaces.
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	if check(player_scene != null, "player scene loads"):
		var player := player_scene.instantiate()
		check(player is CharacterBody3D, "player root is a CharacterBody3D")
		check(player.has_method("step"), "player exposes the sim step() entry point")
		check(player.get_node_or_null("Shape") != null, "player has a collision shape")
		# No per-player camera: the game has ONE camera, owned by the world.
		check(player.get_node_or_null("CameraPivot") == null,
			"player carries no camera of its own")
		player.free()

	# A GameWorld runs standalone, with no networking at all -- the solo path.
	var world := Node3D.new()
	world.name = "SmokeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)
	world.host_spawn(1)
	eq(world.players.size(), 1, "a solo world spawns exactly one player")
	eq(world.player_state(1), PlayerBody.State.WALK, "the spawned player is in WALK")
	check(world.get_node_or_null("Level") != null, "the world built its level")
	check(world.camera != null, "the world built its camera")
	eq(world.camera.focus_target, world.player_body(1), "and pointed it at the local player")
	world.stop()

	# No session has been started, so nothing should think it is networked.
	eq(NetworkManager.active, false, "no session is active at boot")
	eq(NetworkManager.peers.size(), 0, "no peers at boot")

	finish()
