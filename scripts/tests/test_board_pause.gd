extends "res://scripts/test_support/test_case.gd"

# THE BOARD IS UP, SO THE WORLD STOPS -- BUT THE CLOCK THAT ENDS IT DOES NOT.
#
# Two halves and they pull against each other, which is why both are asserted.
# Freeze too little and a rusher walks onto somebody who is reading their score;
# freeze too much and the countdown never finishes and the board is up forever.
#
# NOT `get_tree().paused`. That would stop the HUD, the countdown and the network
# along with the simulation -- and the countdown is the thing that ends the pause.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PEER := 21

var world: Node3D = null
var body: CharacterBody3D = null
var enemy: Node = null
var frozen_at: Vector3 = Vector3.ZERO
var enemy_at: Vector3 = Vector3.ZERO
var clock_at: float = 0.0
var phase := 0
var phase_frame := 0

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "PauseWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_stats.seg"]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	body.position = world.grid.cell_surface_world(Vector2i(7, 2)) + Vector3(0.0, 1.0, 0.0)
	# WALKING, and holding the stick throughout. A frozen world proved with a
	# player who was standing still anyway proves nothing.
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(0.0, -1.0), 0)
	enemy = preload("res://scenes/skirmisher.tscn").instantiate()
	world.add_child(enemy)
	enemy.global_position = body.global_position + Vector3(3.0, 0.0, -4.0)
	world._gunners.append(enemy)

func _physics_process(_delta: float) -> void:
	phase_frame += 1
	match phase:
		0: _phase_running()
		1: _phase_frozen()

func _phase_frozen_snapshot() -> void:
	frozen_at = body.global_position
	enemy_at = enemy.global_position
	clock_at = world.round_machine.close_timer

# --- The world moves before the board goes up ------------------------------------

func _phase_running() -> void:
	if phase_frame < 30:
		return
	var before: Vector3 = body.global_position
	for _t in 20:
		world._host_tick()
	check(before.distance_to(body.global_position) > 0.5,
		"the world really is running first (%.2f m walked) -- without this, "
			% before.distance_to(body.global_position)
		+ "'nothing moved while paused' is a claim about a rig that never moved "
		+ "anything")

	world.round_machine.state = RoundMachine.State.SCORING
	world.round_machine.close_timer = RoundMachine.SCORE_SECONDS
	_phase_frozen_snapshot()
	phase = 1
	phase_frame = 0

# --- And stops once it is ---------------------------------------------------------

func _phase_frozen() -> void:
	for _t in 30:
		world._host_tick()

	near(body.global_position.x, frozen_at.x, 0.001, "a player does not move")
	near(body.global_position.z, frozen_at.z, 0.001, "on either axis")
	near(body.global_position.y, frozen_at.y, 0.001, "and does not fall")
	# THE STICK IS STILL HELD. The input keeps arriving; what stops is the body
	# acting on it.
	near(enemy.global_position.z, enemy_at.z, 0.001,
		"and an enemy does not walk onto somebody reading their score")

	# BUT THE COUNTDOWN RUNS, or the board never closes and the pause is a hang.
	check(world.round_machine.close_timer < clock_at,
		"while the clock that ENDS the board keeps running (%.2f, was %.2f)"
			% [world.round_machine.close_timer, clock_at])

	# AND IT REALLY ENDS. Not a claim about the timer's direction -- a claim that
	# the state machine gets out.
	for _t in int(RoundMachine.SCORE_SECONDS / SimConfig.TICK_DELTA) + 20:
		world._host_tick()
	eq(world.round_machine.state, RoundMachine.State.LOBBY,
		"and the board gives way to the lobby on its own")
	finish()
