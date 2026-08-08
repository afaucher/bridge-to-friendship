extends "res://scripts/test_support/test_case.gd"

# Exercises the player body against the REAL main-scene ground, driving it
# through `input_override` -- the same branch of _physics_process the keyboard
# takes, one input source further up. A test that instead set `velocity`
# directly would pass while the actual movement code was broken.

const REST_Y := 0.9        # capsule half-height; ground top sits at y = 0
const SETTLE_FRAMES := 120 # 2s at 60Hz -- a 3m fall lands in ~0.8s

var main_node: Node3D = null
var player: CharacterBody3D = null
var frame: int = 0
var landed_y: float = 0.0
var start_z: float = 0.0

func setup(main) -> void:
	main_node = main
	var scene := load("res://scenes/player.tscn") as PackedScene
	player = scene.instantiate()
	player.name = "TestPlayer"
	player.position = Vector3(0.0, 3.0, 0.0)
	main_node.get_node("Players").add_child(player)

	# No session: the avatar must simulate locally rather than wait for a state
	# packet that will never come.
	check(player.has_control(), "a player simulates locally when there is no session")

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	frame += 1

	if frame == SETTLE_FRAMES:
		# Phase 1: gravity and the floor.
		landed_y = player.global_position.y
		near(landed_y, REST_Y, 0.05, "player falls and rests on the ground")
		check(player.is_on_floor(), "player reports standing on the floor")
		start_z = player.global_position.z
		# Phase 2: hold "forward". -Z is forward in Godot.
		player.input_override_active = true
		player.input_override = Vector2(0.0, -1.0)

	elif frame == SETTLE_FRAMES + 60:
		var travelled := start_z - player.global_position.z
		check(travelled > 3.0,
			"holding forward for 1s moves the player at least 3m (moved %.2f)" % travelled)
		near(player.global_position.y, REST_Y, 0.05, "the player stays on the ground while walking")

		# Phase 3: release, and confirm it stops rather than coasting.
		player.input_override = Vector2.ZERO

	elif frame == SETTLE_FRAMES + 90:
		near(player.velocity.x, 0.0, 0.01, "horizontal velocity decays to zero on release")
		near(player.velocity.z, 0.0, 0.01, "forward velocity decays to zero on release")

		# Phase 4: jump leaves the floor.
		player.jump_override = true

	elif frame == SETTLE_FRAMES + 100:
		check(player.global_position.y > REST_Y + 0.2,
			"jumping leaves the ground (y = %.2f)" % player.global_position.y)
		finish()
