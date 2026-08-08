extends "res://scripts/test_support/test_case.gd"

# Exercises the player body against a real level, driving it through the same
# step(move, actions) call the host runs and the client predicts with. A test
# that instead set `velocity` directly would pass while the actual movement code
# was broken.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

const REST_Y := 0.9        # capsule half-height; gym ground top sits at y = 0
const SETTLE_TICKS := 60   # 1s at 60Hz -- a 1.5m fall lands in ~0.35s

var player: CharacterBody3D = null
var frame: int = 0
var start_z: float = 0.0

func setup(main) -> void:
	timeout_seconds = 20.0
	var level: Node = (load("res://scenes/gym.tscn") as PackedScene).instantiate()
	main.add_child(level)

	player = PlayerScene.instantiate()
	player.name = "TestPlayer"
	player.position = Vector3(0.0, 1.5, 0.0)
	main.add_child(player)

	eq(player.state, PlayerBody.State.WALK, "a fresh player starts in WALK")

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	frame += 1

	var move := Vector2.ZERO
	var actions := 0

	if frame <= SETTLE_TICKS:
		pass                                   # phase 1: fall and settle
	elif frame <= SETTLE_TICKS + 60:
		move = Vector2(0.0, -1.0)              # phase 2: hold forward for 1s
	elif frame <= SETTLE_TICKS + 90:
		pass                                   # phase 3: release
	elif frame == SETTLE_TICKS + 91:
		actions = SimConfig.ACTION_JUMP        # phase 4: one-tick jump edge

	player.step(move, actions)

	if frame == SETTLE_TICKS:
		near(player.global_position.y, REST_Y, 0.05, "player falls and rests on the ground")
		check(player.is_on_floor(), "player reports standing on the floor")
		start_z = player.global_position.z

	elif frame == SETTLE_TICKS + 60:
		var travelled: float = start_z - player.global_position.z
		# 1s at 6 m/s minus acceleration ramp-up. Asserting a floor rather than
		# an exact distance: the number moves whenever WALK_SPEED is tuned, and a
		# test that has to be edited for every tuning pass gets edited without
		# being read.
		check(travelled > 4.0,
			"holding forward for 1s moves the player at least 4m (moved %.2f)" % travelled)
		near(player.global_position.y, REST_Y, 0.05, "the player stays grounded while walking")

	elif frame == SETTLE_TICKS + 90:
		near(player.velocity.x, 0.0, 0.01, "horizontal velocity decays to zero on release")
		near(player.velocity.z, 0.0, 0.01, "forward velocity decays to zero on release")

	elif frame == SETTLE_TICKS + 100:
		check(player.global_position.y > REST_Y + 0.2,
			"jumping leaves the ground (y = %.2f)" % player.global_position.y)
		# The jump bit was set for exactly one tick. If it were level-triggered
		# the player would still be climbing, which is the bug that a
		# reconciliation replay would otherwise reproduce every tick.
		check(player.velocity.y < SimConfig.JUMP_VELOCITY,
			"the jump was a single edge, not a sustained thrust")
		finish()
