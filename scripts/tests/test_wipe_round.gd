extends "res://scripts/test_support/test_case.gd"

# A WIPE MUST NOT ADVANCE THE ROUND, because it carries the party BACKWARDS.
#
# Reported, as a sequence: "spawn in the lobby / switch to the race track / cross
# the ready line and jump off an edge / get the loss screen / respawn in the
# lobby / try to switch the game mode again, sign changes but the game doesn't."
#
# `_enter_lobby` re-derives `rear_row` and `target_row` from where the party
# actually ended up -- it says so at length, and that fix was itself a playtest
# report -- and then increments `round_index` two lines away. On every round that
# ends by being CROSSED the two agree and there is nothing to see. On a round that
# ends in a WIPE they come apart by exactly one: the party is put back in the
# lobby they started from, the rows follow them, the counter does not.
#
# Measured before the fix: the party standing on row 2 of segment 0 -- the FIRST
# lobby -- with `round_index` reading 1. Every later choice was then written into
# the plan for round 1, and `_rebuild_corridor_ahead` keeps every segment through
# round 1's lobby, which is all the ground the party is about to walk through. So
# the sign moved and the map could not, and it never recovered, because the
# counter stayed one ahead for the rest of the run.
#
# THE CLAIM IS ABOUT THE MAP, NOT ABOUT THE PLAN. `run_modes` changing is what a
# test would naturally reach for and it is one layer short of the report: the
# player is looking at the ground. A race circuit carries LAP GATES and nothing
# else does, so "are there still gates in front of me" is the same question the
# player was asking, answered by the grid.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

const A := 41

var world: Node3D = null
var body: CharacterBody3D = null
var done := false
var phase := 0
var _at := 0
var _gates_before := 0

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "WipeRoundWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = 2024
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	body = world.players[A]

func _row() -> int:
	return world.grid.cell_of_world(body.global_position).y

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match phase:
		0: _pick_the_race()
		1: _cross_the_line()
		2: _jump_off()
		3: _wait_for_the_loss_screen()
		4: _switch_again()

# --- The reported sequence -----------------------------------------------------

func _pick_the_race() -> void:
	var post = world.grid.mode_posts()[0] if world.grid.mode_posts().size() > 0 else null
	if not check(post != null, "there is a selector to dash"):
		done = true
		finish()
		return
	while world.selected_mode != GameMode.RACE:
		world._select_next_mode(post)
	world._extend_run()
	_gates_before = world.grid.lap_gate_count()
	print("[wiperound] picked the race: round %d, %d lap gates on the run"
		% [world.round_index(), _gates_before])
	if not check(_gates_before > 0,
			"the map really became a race track -- lap gates are the thing only a "
			+ "circuit has, and the whole test reads the map through them"):
		done = true
		finish()
		return
	phase = 1

func _cross_the_line() -> void:
	# ONTO THE BAND, NOT PAST IT. A solo party dropped beyond the gate crosses AND
	# satisfies the closing rule on the same tick, so the entire round flashes by
	# and the machine is in SCORING before anything can be observed.
	var target: int = int(world.round_machine.target_row)
	if target < 0:
		return
	if int(world.round_machine.state) == RoundMachine.State.LOBBY:
		body.global_position = world.grid.cell_surface_world(
			Vector2i(world.grid.width / 2, target)) + Vector3(0.0, 1.0, 0.0)
		return
	if int(world.round_machine.state) != RoundMachine.State.RUNNING:
		return
	phase = 2

func _jump_off() -> void:
	body.global_position = Vector3(0.0, SimConfig.FALL_KILL_Y - 2.0,
		body.global_position.z)
	phase = 3
	_at = world.tick

func _wait_for_the_loss_screen() -> void:
	if int(world.round_machine.state) != RoundMachine.State.LOBBY:
		if world.tick > _at + 3000:
			fail("the round never came back to a lobby after the wipe")
			done = true
			finish()
		return

	# --- 1. The counter agrees with the ground ---------------------------------
	var stood: int = world.grid.round_of_row(_row())
	print("[wiperound] back in a lobby on row %d (segment %d, round %d); "
			% [_row(), world.grid.segment_index_of_row(_row()), stood]
		+ "round_index says %d" % world.round_index())
	eq(world.round_index(), stood,
		"the round the machine thinks the party is in (%d) is the round they are "
			% world.round_index()
		+ "STANDING in (%d) -- `rear_row` and `target_row` beside it are re-derived "
			% stood
		+ "from where bodies ended up, and a counter incremented two lines away "
		+ "disagrees with them by exactly one round on a wipe")
	phase = 4
	_at = world.tick

# --- 2. AND THE MAP FOLLOWS THE SIGN ---------------------------------------------

func _switch_again() -> void:
	if world.tick < _at + 10:
		return
	var post = world.grid.mode_posts()[0] if world.grid.mode_posts().size() > 0 else null
	if not check(post != null, "the selector is still there"):
		done = true
		finish()
		return
	while world.selected_mode == GameMode.RACE:
		world._select_next_mode(post)
	world._extend_run()
	var gates_after: int = world.grid.lap_gate_count()
	print("[wiperound] switched to %s: sign says %s, ground has %d lap gates (was %d)"
		% [GameMode.name_of(world.selected_mode),
			GameMode.name_of(world.next_mode_showing()), gates_after, _gates_before])

	eq(world.mode_for_round(world.round_index()), world.selected_mode,
		"the round the party is about to play is the one on the sign (%s vs %s)"
			% [GameMode.name_of(world.mode_for_round(world.round_index())),
				GameMode.name_of(world.selected_mode)])
	# THE ONE THE PLAYER WAS LOOKING AT. Not `run_modes`, which is the plan: a
	# plan that changed while the ground did not is precisely what got reported.
	eq(gates_after, 0,
		"and the GROUND stopped being a race track -- %d lap gates left after "
			% gates_after
		+ "switching away from it. This is the report in its own words: the sign "
		+ "changed and the map did not, because the choice was being written into "
		+ "a round the party was not in while the rebuild kept every segment they "
		+ "were about to walk through")
	done = true
	finish()
