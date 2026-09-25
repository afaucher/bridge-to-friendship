extends "res://scripts/test_support/test_case.gd"

# THE LAYER TABLE IS THE PROJECT'S LAYER TABLE.
#
# `core/layers.gd` names every physics layer so no script has to spell a bit by
# hand. That is only worth anything while it agrees with project.godot's
# `[layer_names]` -- which is what the editor shows and what a scene's .tscn is
# authored against -- so both directions are held here:
#
#   1. EVERY CONSTANT NAMES THE LAYER IT CLAIMS TO. Read back from
#      ProjectSettings, not from a copy of the names in this file.
#   2. EVERY NAMED LAYER HAS A CONSTANT. A layer added to project.godot and not
#      here is a layer somebody will write as `1 << 13`.
#   3. EVERY SCENE THAT CARRIES A LAYER CARRIES THE ONE ITS KIND SHOULD. A .tscn
#      cannot reference a script constant, so this is the only thing that keeps
#      "the rusher is on ENEMIES" true when somebody edits the scene.

const Layers = preload("res://scripts/core/layers.gd")

# The constant for each project layer, by its project name.
const BY_NAME := {
	"world": Layers.WORLD, "players": Layers.PLAYERS, "stones": Layers.STONES,
	"balls": Layers.BALLS, "rushers": Layers.ENEMIES, "hats": Layers.HATS,
	"specials": Layers.SPECIALS, "barrier": Layers.BARRIER,
	"worn_hats": Layers.WORN_HATS, "merchant": Layers.MERCHANT,
	"mode_post": Layers.POSTS, "bus": Layers.BUS, "debris": Layers.DEBRIS,
}

# The layer each scene's root body must be on.
const SCENES := {
	"res://scenes/player.tscn": Layers.PLAYERS,
	"res://scenes/rusher.tscn": Layers.ENEMIES,
	"res://scenes/zombie.tscn": Layers.ENEMIES,
	"res://scenes/skirmisher.tscn": Layers.ENEMIES,
	"res://scenes/turret.tscn": Layers.ENEMIES,
	"res://scenes/plinko_ball.tscn": Layers.BALLS,
	"res://scenes/stone.tscn": Layers.STONES,
	"res://scenes/hat.tscn": Layers.HATS,
	"res://scenes/special.tscn": Layers.SPECIALS,
	"res://scenes/grenade.tscn": Layers.SPECIALS,
	"res://scenes/mine.tscn": Layers.SPECIALS,
	"res://scenes/shooter.tscn": Layers.WORLD,
}

func setup(_main) -> void:
	var named := 0
	for bit in range(1, 33):
		var project_name: String = Layers.name_of(bit)
		if project_name == "":
			continue
		named += 1
		check(BY_NAME.has(project_name),
			"project layer %d (%s) has a constant in core/layers.gd" % [bit, project_name])
		if BY_NAME.has(project_name):
			eq(int(BY_NAME[project_name]), 1 << (bit - 1),
				"and `%s` is bit %d" % [project_name, bit])
	eq(named, BY_NAME.size(), "every constant here names a layer the project has")

	for path in SCENES:
		var packed := load(path) as PackedScene
		if not check(packed != null, "%s loads" % path):
			continue
		var node := packed.instantiate()
		var body := node as CollisionObject3D
		if check(body != null, "%s is a physics body" % path):
			eq(body.collision_layer, int(SCENES[path]), "%s is on its layer" % path)
		node.free()

	# THE ONE LAYER THAT LOOKS WRONG AND IS NOT. The player's mask must NOT see
	# the swallow, or its shell would stop a body reaching the core it drains in.
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as CollisionObject3D
	eq(player.collision_mask & Layers.SWALLOW, 0, "a player passes through a swallow's shell")
	check(player.collision_mask & Layers.ENEMIES != 0, "while enemies stay solid to them")
	player.free()
	finish()
