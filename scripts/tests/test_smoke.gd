extends "res://scripts/test_support/test_case.gd"

# The gate's canary. Everything else in scripts/tests/ assumes the project
# BOOTS -- this is the test that says so, and it is the one to read first when
# the whole suite goes red at once (a broken autoload or a renamed scene fails
# every test, and only this one says why in a single line).

func setup(main) -> void:
	# Autoloads, by the names the rest of the code calls them.
	check(DebugSettings != null, "DebugSettings autoload is present")
	check(SteamManager != null, "SteamManager autoload is present")
	check(NetworkManager != null, "NetworkManager autoload is present")

	# The main scene really is the 3D root, not a 2D one left over from a
	# template. Cheap to assert, and the failure is otherwise a pile of
	# confusing type errors deep in a movement test.
	check(main is Node3D, "main scene root is a Node3D")
	check(main.get_node_or_null("World/Ground") != null, "world has a ground body")
	check(main.get_node_or_null("Players") != null, "world has a Players container")

	# The player scene loads and instantiates. Loading a .tscn is where a bad
	# sub-resource or a renamed script surfaces.
	var player_scene := load("res://scenes/player.tscn") as PackedScene
	if check(player_scene != null, "player scene loads"):
		var player := player_scene.instantiate()
		check(player is CharacterBody3D, "player root is a CharacterBody3D")
		check(player.get_node_or_null("Shape") != null, "player has a collision shape")
		check(player.get_node_or_null("CameraPivot/Camera") != null, "player has a camera")
		player.free()

	# No session has been started, so nothing should think it is networked.
	eq(NetworkManager.active, false, "no session is active at boot")
	eq(NetworkManager.peers.size(), 0, "no peers at boot")

	finish()
