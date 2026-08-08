extends "res://scripts/test_support/test_case.gd"

# The friends panel's roster: who is on it, what they are called, and in what
# order.
#
# Names are the half of D5 the codebase did not have. Until M9 a peer was an
# integer, and "each friend's NAME, health and special" had no source at all --
# the obvious one, Steam's persona API, is exactly what gameplay code is barred
# from touching, because the gate has no Steam client. So names are world state
# announced over the world's own multiplayer, and the fallback has to be good
# enough that a session with no Steam still reads as a list of people.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")

var world: Node3D = null

func setup(main) -> void:
	world = Node3D.new()
	world.name = "HudRosterWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)

	_check_names()
	_check_full_party()
	_check_ordering()
	_check_leaving()
	finish()

func _friends() -> Array:
	return HudModel.build(world)["friends"]

# --- Everyone has a name, with or without Steam -------------------------------

func _check_names() -> void:
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)

	# The host records its own name when the world starts. Without this the local
	# player is the one person on the HUD with no name, which is a silly way to
	# find out the announcement never ran.
	check(world.player_names.has(1), "the host records its own name at start")

	# ASSERT THE RULE, NOT THE ENVIRONMENT. What the host announces depends on
	# whether the machine running this has a Steam client -- a dev box says
	# "duckbob" and a CI box says "Player 1" -- so an assertion on the literal
	# passes in one place and fails in the other for no reason the code controls.
	# The FALLBACK is ours and is what gets pinned.
	eq(GameWorldScript.default_player_name(1), "Player 1", "a peer id alone yields a name")
	eq(world.player_name(2), "Player 2", "and a peer that never announced one gets it")
	eq(str(HudModel.build(world)["own"]["name"]), world.player_name(1), "which reaches the model")
	eq(str(_friends()[0]["name"]), "Player 2", "for friends too")

	# What a Steam session actually produces.
	world.player_names[2] = "Ada"
	eq(str(_friends()[0]["name"]), "Ada", "an announced name replaces the fallback")

	# An empty announcement is not a name. A blank row is worse than "Player 2".
	world.player_names[2] = ""
	eq(str(_friends()[0]["name"]), "Player 2", "and an empty one falls back rather than blanking")
	world.player_names[2] = "Ada"

	# Practice partners are not peers and should not read as one.
	eq(GameWorldScript.default_player_name(GameWorldScript.PRACTICE_PEER_BASE), "Partner 1",
		"a practice partner is named as one")
	eq(GameWorldScript.default_player_name(GameWorldScript.PRACTICE_PEER_BASE + 2), "Partner 3",
		"and they count from one")

# --- Four players is three friend rows ----------------------------------------

func _check_full_party() -> void:
	world._spawn_player(3, 2)
	world._spawn_player(4, 3)
	eq(world.players.size(), 4, "a full party")
	eq(_friends().size(), 3, "is three friend rows -- never counting yourself")

# --- Stable order, because a list that reshuffles cannot be read --------------

func _check_ordering() -> void:
	var seen: Array = []
	for entry in _friends():
		seen.append(int(entry["peer"]))
	eq(seen, [2, 3, 4], "friends come back sorted by peer id")

	# Godot does not promise two machines iterate a Dictionary the same way, and
	# a row that moves between frames is a row you reach for and miss. Re-reading
	# must give the same answer.
	var again: Array = []
	for entry in _friends():
		again.append(int(entry["peer"]))
	eq(again, seen, "and in the same order every time")

# --- Leaving --------------------------------------------------------------

func _check_leaving() -> void:
	world._despawn_player(3)
	var seen: Array = []
	for entry in _friends():
		seen.append(int(entry["peer"]))
	eq(seen, [2, 4], "a peer who leaves drops off the panel")
	check(not world.player_names.has(3), "and stops being named")

	world._despawn_player(2)
	world._despawn_player(4)
	eq(_friends().size(), 0, "a solo player has no friend rows")
	check(bool(HudModel.build(world)["active"]),
		"but still has a HUD of their own -- drop-in means the party can be one player")
