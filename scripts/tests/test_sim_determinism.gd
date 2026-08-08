extends "res://scripts/test_support/test_case.gd"

# The integrator produces the same result from the same inputs, and a
# reconciliation replay of N ticks inside ONE frame lands where N frames landed.
#
# That second property is the one the whole prediction scheme rests on, and it is
# not obvious: move_and_slide() takes its delta from the physics frame, so
# replaying several ticks in a single frame only reproduces the original run
# because a sim tick is defined to BE a physics tick. If that equality ever
# breaks — someone changes physics_ticks_per_second, or calls step() off the
# physics thread — clients would correct forever and the cause would be invisible
# from the symptom. This test is the tripwire.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerScene = preload("res://scenes/player.tscn")

const SCRIPT := [
	[40, Vector2(0.0, -1.0), 0],
	[1, Vector2(0.0, -1.0), SimConfig.ACTION_SHOVE],
	[40, Vector2(1.0, 0.0), 0],
	[30, Vector2(0.0, 0.0), 0],
]
const TOTAL_TICKS := 111

var level: Node = null
var body_a: CharacterBody3D = null
var body_b: CharacterBody3D = null
var trace_a: Array = []
var frame: int = 0

# The two bodies live 20 m apart on the gym's flat, uniform ground and are
# compared by DISPLACEMENT from their own start rather than by absolute
# position. Sharing a spawn point made them collide with each other -- players
# collide with players, so two bodies at one spot shove each other apart and the
# "divergence" being measured was the test rig, not the integrator.
# Both lanes must be geometrically IDENTICAL, not merely separate. The first
# version put one body at the origin and the other 20 m east; the scripted dash
# then drove body A into one of the gym's stones and body B into open floor, and
# the "divergence" being measured was the scenery. Clear of every stone (which
# sit at x 0 and +/-8, z -6 and -12) and clear of the ground's edges.
const START_A := Vector3(-20.0, 1.5, 10.0)
const START_B := Vector3(20.0, 1.5, 10.0)

func setup(main) -> void:
	timeout_seconds = 20.0
	# A real level, so the run involves actual floor contact rather than a body
	# integrating in a vacuum.
	level = (load("res://scenes/gym.tscn") as PackedScene).instantiate()
	main.add_child(level)

	body_a = _make_body(main, "DetA", START_A)
	body_b = _make_body(main, "DetB", START_B)

func _make_body(parent: Node, name: String, position: Vector3) -> CharacterBody3D:
	var body: CharacterBody3D = PlayerScene.instantiate()
	body.name = name
	body.position = position
	parent.add_child(body)
	return body

func _input_at(t: int) -> Array:
	var remaining: int = t
	for entry in SCRIPT:
		var duration: int = int(entry[0])
		if remaining <= duration:
			return [entry[1], int(entry[2])]
		remaining -= duration
	return [Vector2.ZERO, 0]

func _physics_process(_delta: float) -> void:
	frame += 1

	# Pass 1: step body A one tick per frame, recording DISPLACEMENT from its
	# own start (the two bodies stand 20 m apart, so absolute positions are not
	# comparable; the gym floor is flat and uniform, so displacements are).
	if frame <= TOTAL_TICKS:
		var inp: Array = _input_at(frame)
		body_a.step(inp[0], inp[1])
		trace_a.append(body_a.global_position - START_A)
		return

	# Pass 2: replay the identical inputs into body B, all of them inside this
	# single frame -- exactly what a client does when it rewinds and replays
	# unacknowledged input after a correction. Body B has never been stepped, so
	# it is already in the same initial condition body A started from.
	var trace_b: Array = []
	for t in range(1, TOTAL_TICKS + 1):
		var inp: Array = _input_at(t)
		body_b.step(inp[0], inp[1])
		trace_b.append(body_b.global_position - START_B)

	eq(trace_b.size(), trace_a.size(), "both passes ran the same number of ticks")

	var worst: float = 0.0
	var worst_tick: int = -1
	for i in trace_a.size():
		var d: float = (trace_a[i] as Vector3).distance_to(trace_b[i])
		if d > worst:
			worst = d
			worst_tick = i + 1
	# Not bit-exact: CLAUDE.md records that Godot's physics is not
	# bit-deterministic run to run (contact solver and float ordering), and two
	# bodies resolving against the same floor can differ in the last bits. 1 mm
	# over 111 ticks is far below anything a player or a correction threshold
	# could notice, and far above float noise.
	check(worst < 0.001,
		"a single-frame replay reproduces the per-frame run (worst divergence %.6f m at tick %d)"
			% [worst, worst_tick])

	# And the run actually did something, so the comparison is not two
	# identical piles of nothing.
	var travelled: float = (trace_a[trace_a.size() - 1] as Vector3).distance_to(trace_a[0])
	check(travelled > 3.0, "the scripted run moved the body (%.2f m)" % travelled)

	finish()
