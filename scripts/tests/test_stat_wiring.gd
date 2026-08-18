extends "res://scripts/test_support/test_case.gd"

# EVERY COUNTER IS DRIVEN THROUGH THE LINE THAT REALLY INCREMENTS IT.
#
# This file exists because of a playtest report -- "enemy damage and kills were
# both zero when they shouldn't have been" -- and what it exposed was not one bug
# but a HOLE IN THE METHOD. Those two counters were unreachable code, and every
# assertion about them was that they equal ZERO, so nothing noticed.
#
# An audit of the rest found the same gap under eight of sixteen stats: six with
# no non-zero assertion anywhere, plus `dashes` and `hats_worn`, whose only
# non-zero assertions came from calling `_bump` DIRECTLY -- which tests the
# counter and not the wiring, and is exactly the shape that hid the first one.
#
# So nothing here pokes `_bump`. Each stat is produced the way the game produces
# it: walk to move, dash to dash, take the heart, revive a teammate, lose a tower.
# A counter that cannot be made to move by playing is a counter that does not work.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const A := 41
const B := 57

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase := 0
var phase_frame := 0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "StatWiringWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_stats.seg"]
	world.start(true, 1, false)
	world._spawn_player(A, 0)
	world._spawn_player(B, 1)
	a = world.player_body(A)
	b = world.player_body(B)
	# `time_alive` and `distance` are only counted while a round is RUNNING --
	# otherwise they measure the lobby, and the badge goes to whoever stood around
	# longest between rounds. So the fixture has to be in a round.
	world.round_machine.state = RoundMachine.State.RUNNING
	world.clear_round_stats()
	_hold(A, Vector2.ZERO, 0)
	_hold(B, Vector2.ZERO, 0)

func _hold(peer: int, move: Vector2, actions: int) -> void:
	world.scripted_inputs[peer] = func(t: int) -> Array:
		return PlayerInput.make(t, move, actions)

func _stat(peer: int, key: String) -> int:
	return int(world.stats_of(peer).get(key, 0))

func _physics_process(_delta: float) -> void:
	if a == null:
		return
	phase_frame += 1
	match phase:
		0: _phase_walk_and_dash()
		1: _phase_heart()
		2: _phase_hats()
		3: _phase_rescue()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- Walking, dashing, staying alive -------------------------------------------

func _phase_walk_and_dash() -> void:
	if phase_frame == 1:
		_hold(A, Vector2(0.0, -1.0), SimConfig.ACTION_SHOVE)
		return
	if phase_frame < 40:
		return
	# STICK RELEASED once the moment being measured has passed: a rig that holds a
	# direction for two seconds walks the player off the map, which CLAUDE.md has
	# a note about and this file has no reason to repeat.
	_hold(A, Vector2.ZERO, 0)

	check(_stat(A, "dashes") > 0,
		"a dash driven by the INPUT is counted (%d) -- the counter watches the "
			% _stat(A, "dashes")
		+ "body's SHOVE state on the host, and the only previous non-zero claim "
		+ "about it called _bump directly, which is not the same test")
	check(_stat(A, "distance") > 0,
		"and walking moves the distance counter (%d cm)" % _stat(A, "distance"))
	check(_stat(A, "time_alive") > 0,
		"and a player who is up and in a running round banks time (%d ticks)"
			% _stat(A, "time_alive"))
	_advance(1)

# --- Healing --------------------------------------------------------------------

func _phase_heart() -> void:
	if phase_frame == 1:
		a.health = 1
		# Onto the heart the fixture carries. Hearts are taken by PROXIMITY at
		# grid.try_take_heart, which is the line `healed` is counted at.
		a.position = world.grid.cell_surface_world(Vector2i(7, 6)) + Vector3(0.0, 1.0, 0.0)
		return
	if phase_frame < 12:
		return
	check(_stat(A, "healed") > 0,
		"taking a heart counts healing (%d) -- counted where the heart is "
			% _stat(A, "healed")
		+ "consumed, so a heart that was not there cannot score")
	_advance(2)

# --- Wearing and losing a tower --------------------------------------------------

func _phase_hats() -> void:
	if phase_frame == 1:
		for i in 3:
			var hat: Node = world._hats.spawn_loose(a.global_position + Vector3(0.0, 1.0, 0.0))
			hat.wear(A, i)
		return
	if phase_frame < 8:
		return
	if phase_frame == 8:
		check(_stat(A, "hats_worn") >= 3,
			"the tallest tower is polled from the worn stack (%d of 3)"
				% _stat(A, "hats_worn"))
		# THE REAL LOSS PATH, not a _bump: this is what a fall and a drone return
		# call.
		world.destroy_worn_hats(A)
		return
	check(_stat(A, "hats_lost") >= 3,
		"and losing that tower counts every hat in it (%d)" % _stat(A, "hats_lost"))
	_advance(3)

# --- Rescue, on both ends ---------------------------------------------------------

func _phase_rescue() -> void:
	if phase_frame == 1:
		b.begin_downed()
		# Close enough to help, far enough not to be coincident -- two bodies in
		# one place depenetrate through the floor.
		a.position = b.position + Vector3(1.0, 0.0, 0.0)
		return
	# REVIVE_SECONDS of standing there, which is what _tick_revive counts.
	if phase_frame < int(SimConfig.REVIVE_SECONDS / SimConfig.TICK_DELTA) + 30:
		a.position = b.position + Vector3(1.0, 0.0, 0.0)
		return

	check(_stat(A, "rescues") > 0,
		"the RESCUER is credited (%d) -- counted at the line that revives "
			% _stat(A, "rescues")
		+ "somebody, so it cannot land on the person who was saved")
	check(_stat(B, "rescued") > 0,
		"and the person who was saved is credited separately (%d)"
			% _stat(B, "rescued"))
	eq(_stat(B, "rescues"), 0, "the downed player did not rescue anybody")
	finish()
