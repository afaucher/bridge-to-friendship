extends "res://scripts/test_support/test_case.gd"

# EVERY ENEMY COLLIDES WITH THE SAME THINGS, AND COLLISION IS SYMMETRIC.
#
# Reported from play: "the pink enemies don't seem to collide with much, like
# each other or plinko balls." The pink one is the skirmisher; it shares a layer
# and a mask with the rusher and the turret, so whatever was true of it was true
# of all three.
#
# WHAT THE AUDIT FOUND. Layer 5 is "rushers" and NOTHING outside layer 5 masked
# it -- not the player (mask 135) and not a plinko ball (mask 15). So an enemy
# stopped for a player while the player walked straight through it, and a ball
# passed through an enemy in both directions. Enemies only ever blocked each
# other, which is exactly "doesn't collide with much".
#
# THE RULE THIS FILE ENFORCES IS SYMMETRY. If A's mask contains B's layer but B's
# does not contain A's, then A is stopped by B and B sails through A -- and that
# reads as a bug whichever end you are standing at. Asserted as a relationship
# between two scenes rather than against magic numbers, so it survives a layer
# being renumbered and fails when somebody edits one scene and not its partner.
#
# THIS IS THE SIXTH BUG IN THIS PROJECT TO BE ONE WRONG BIT IN A MASK, which is
# why the last section drives a body into one rather than trusting the numbers.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PlayerScene = preload("res://scenes/player.tscn")
const RusherScene = preload("res://scenes/rusher.tscn")
const SkirmisherScene = preload("res://scenes/skirmisher.tscn")
const TurretScene = preload("res://scenes/turret.tscn")
const BallScene = preload("res://scenes/plinko_ball.tscn")

const WORLD_BIT := 1 << 0
const PLAYERS_BIT := 1 << 1
const STONES_BIT := 1 << 2
const BALLS_BIT := 1 << 3
const RUSHERS_BIT := 1 << 4

var world: Node3D = null
var walker: CharacterBody3D = null
var blocker: Node3D = null
var start_z: float = 0.0
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	_check_masks()

	world = Node3D.new()
	world.name = "EnemyCollisionWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	walker = world.player_body(1)

	# A SKIRMISHER PARKED IN THE WAY. Added as a plain body rather than through the
	# gunner pool: nothing here is about what it DOES, only about whether it is
	# solid, and a body that never steps is the cleanest possible obstacle.
	blocker = SkirmisherScene.instantiate()
	world.add_child(blocker)
	blocker.global_position = walker.global_position + Vector3(0.0, 0.0, -3.0)
	start_z = walker.global_position.z

	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(0.0, -1.0), 0)

# --- The masks, as relationships ----------------------------------------------

func _pair(a_name: String, a: PackedScene, b_name: String, b: PackedScene) -> void:
	var one: Node = a.instantiate()
	var two: Node = b.instantiate()
	var a_layer: int = int(one.collision_layer)
	var a_mask: int = int(one.collision_mask)
	var b_layer: int = int(two.collision_layer)
	var b_mask: int = int(two.collision_mask)
	one.free()
	two.free()
	check(a_mask & b_layer != 0,
		"%s masks %s's layer (mask %d, layer %d)" % [a_name, b_name, a_mask, b_layer])
	check(b_mask & a_layer != 0,
		"and %s masks %s's back -- collision is SYMMETRIC or one of them sails "
			% [b_name, a_name]
		+ "through the other, which reads as a bug from whichever end you are on "
		+ "(mask %d, layer %d)" % [b_mask, a_layer])

func _check_masks() -> void:
	var enemies := {
		"rusher": RusherScene, "skirmisher": SkirmisherScene, "turret": TurretScene,
	}

	# ALL THREE ARE THE SAME KIND OF THING. They share a layer, so a rule written
	# for one is a rule for all -- and the report about the pink one was really a
	# report about the layer.
	var layer: int = -1
	for name in enemies:
		var body: Node = enemies[name].instantiate()
		var here_layer: int = int(body.collision_layer)
		var here_mask: int = int(body.collision_mask)
		body.free()
		eq(here_layer, RUSHERS_BIT, "%s is on the rushers layer" % name)
		if layer == -1:
			layer = here_layer
		# EVERY ENEMY COLLIDES WITH THE SAME THINGS. The consistency the report
		# asked for, stated as a claim rather than left to three scene files that
		# happen to agree today.
		for wanted in [["world", WORLD_BIT], ["players", PLAYERS_BIT],
				["stones", STONES_BIT], ["balls", BALLS_BIT], ["its own kind", RUSHERS_BIT]]:
			check(here_mask & int(wanted[1]) != 0,
				"%s collides with %s (mask %d)" % [name, str(wanted[0]), here_mask])

	# AND THE OTHER END OF EACH PAIR.
	for name in enemies:
		_pair(name, enemies[name], "player", PlayerScene)
		_pair(name, enemies[name], "plinko ball", BallScene)
	# Enemies against each other, which is the same scene twice for a turret and a
	# skirmisher standing next to one another.
	_pair("skirmisher", SkirmisherScene, "turret", TurretScene)

# --- And it actually blocks ----------------------------------------------------

func _physics_process(_delta: float) -> void:
	if done or walker == null or world.tick < 150:
		return
	done = true

	var blocker_z: float = blocker.global_position.z
	var walked: float = start_z - walker.global_position.z
	print("[enemy collision] walker moved %.2f m, stopped at z %.2f, enemy at %.2f"
		% [walked, walker.global_position.z, blocker_z])

	# THE CONTROL: the rig really drives the body. Without this, "it did not get
	# past" is equally well explained by a player who never moved.
	check(walked > 1.0,
		"the player really walked (%.2f m) -- otherwise 'it was blocked' below is "
			% walked
		+ "a statement about a rig that never moved anybody")

	# A MASK THAT IS SET AND HAS NO EFFECT IS THIS REPO'S MOST REPEATED BUG -- five
	# before this one, the round barrier being the worst, where check(wall != null)
	# was green for the barrier's whole life. So the body is driven at the enemy.
	check(walker.global_position.z > blocker_z,
		"and a player walking into an enemy is STOPPED by it rather than passing "
		+ "through (player z %.2f, enemy z %.2f -- smaller z is further up-bridge)"
			% [walker.global_position.z, blocker_z])
	finish()
