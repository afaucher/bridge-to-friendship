extends "res://scripts/test_support/test_case.gd"

# M16 Step 7: the loop, on a REAL ASSEMBLED RUN.
#
# test_round_machine drives the machine on a two-strip fixture, which proves the
# sequence. This proves the thing a player actually gets: a run built from the
# pool is lobby, section, lobby, section -- with the strips in the right places,
# the corridor moving up one each time, and a SECOND section that is not the
# first.
#
# THE SECOND LAP IS THE POINT. A slot with exactly one occupant proves nothing
# about a slot: this repo shipped plinko with balls ghosting through each other
# because every test used a single ball, and the whole reason the section is
# named rather than appended is that players will one day choose it. One lap
# would pass against an implementation that can only ever do one.
#
# It is also the end-to-end check that the AUTHORED lobby works -- that its two
# strips land where the format says, that the party spawns inside it rather than
# on a strip, and that the run extends by whole segments rather than by however
# far somebody walked.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const RUN_SEED := 20260815

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var laps: int = 0
var first_target: int = -1

func setup(main) -> void:
	timeout_seconds = 120.0

	# THE PLAN ITSELF, before a single body exists. A pure function, so it is
	# asserted as one.
	var plan: Array = SegmentPool.plan(RUN_SEED, 6)
	eq(plan.size(), 6, "a six-slot plan has six segments")
	eq(String(plan[0]), SegmentPool.LOBBY, "a run OPENS on a lobby")
	eq(String(plan[2]), SegmentPool.LOBBY, "and every other slot is one")
	eq(String(plan[4]), SegmentPool.LOBBY, "all the way up")
	check(String(plan[1]) != SegmentPool.LOBBY, "with a section between them")
	check(String(plan[3]) != SegmentPool.LOBBY, "and another after that")

	world = Node3D.new()
	world.name = "LoopWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func machine():
	return world.round_machine

func _park_both(row: int) -> void:
	a.position = world.grid.cell_surface_world(Vector2i(5, row)) + Vector3(0.0, 1.0, 0.0)
	b.position = world.grid.cell_surface_world(Vector2i(9, row)) + Vector3(0.0, 1.0, 0.0)
	a.velocity = Vector3.ZERO
	b.velocity = Vector3.ZERO

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_spawned_in_a_lobby()
		1: _phase_walk_a_lap()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- Spawned in a lobby, with a strip at each end -----------------------------

func _phase_spawned_in_a_lobby() -> void:
	if phase_frame < 3:
		return
	var grid: Node = world.grid
	check(grid.gate_rows.size() >= 2,
		"an assembled run has boundaries in it (%d)" % grid.gate_rows.size())

	# The lobby's own two strips: one at its first row, one at its last. The party
	# spawns BETWEEN them, which is what makes the first corridor exist at all.
	var spawn_row: int = grid.cell_of_world(a.position).y
	check(not grid.is_gate_row(spawn_row),
		"the party spawns in the lobby, not standing on a boundary (row %d)" % spawn_row)
	eq(machine().state, RoundMachine.State.LOBBY, "and the session opens in the lobby")
	check(machine().target_row > spawn_row,
		"with the lobby's exit strip ahead of them (row %d)" % machine().target_row)
	first_target = machine().target_row
	_advance(1)

# --- Two full laps ------------------------------------------------------------

func _phase_walk_a_lap() -> void:
	# AN UNCONDITIONAL HEARTBEAT, on a path no game state can gate. The first run
	# of this timed out with nothing in the log at all, which is indistinguishable
	# between "stuck in one state" and "never got here" -- CLAUDE.md has the rule
	# and the first draft did not follow it.
	if phase_frame % 60 == 0:
		print("[loop] t=%d state=%s rear=%d target=%d rows=%d a=%d b=%d" % [
			world.tick, machine().state_name(), machine().rear_row,
			machine().target_row, world.grid.total_length(),
			world.grid.cell_of_world(a.position).y,
			world.grid.cell_of_world(b.position).y])

	# The party is teleported rather than walked: this is a test of the LOOP, and
	# a real walk of two sections is a minute of wall clock spent re-proving that
	# walking works.
	if machine().state == RoundMachine.State.LOBBY and phase_frame > 4:
		if machine().target_row < 0:
			return
		_park_both(machine().target_row)
		phase_frame = 0
		return
	if machine().state == RoundMachine.State.RUNNING and phase_frame > 4:
		check(world._front_wall == null, "no barrier ahead during a round")
		if machine().target_row < 0:
			# The next lobby has not been appended yet. Nothing to do but let the
			# run extend -- and NOT crossing is the correct behaviour meanwhile.
			return
		_park_both(machine().target_row)
		phase_frame = 0
		return
	# SKIP THE WAITS, ONCE EACH. The 30 s window and the 10 s board are asserted
	# tick-by-tick in test_round_machine; re-proving them here would cost 40
	# seconds a lap.
	#
	# `> 0.1` and not an unconditional assignment, which is what the first draft
	# did: writing the timer every frame meant it could never reach zero, and the
	# run sat in CLOSING for the whole 120 s timeout. The heartbeat above is what
	# turned that from "it hangs" into one line of log.
	if machine().state == RoundMachine.State.CLOSING 			or machine().state == RoundMachine.State.SCORING:
		if machine().close_timer > 0.1:
			machine().close_timer = 0.05
		return

	if machine().round_index <= laps:
		return
	laps = machine().round_index
	print("[loop] lap %d complete: rear %d, next target %d, %d segments"
		% [laps, machine().rear_row, machine().target_row, world.grid.segment_count()])

	if laps < 2:
		phase_frame = 0
		return

	# TWO LAPS, and the second corridor is not the first.
	eq(laps, 2, "the run went round twice")
	check(machine().rear_row > first_target,
		"the corridor moved up the bridge each lap (rear %d, first target %d)"
			% [machine().rear_row, first_target])
	check(world.grid.segment_count() >= 4,
		"and the run really grew, lobby and section (%d segments)"
			% world.grid.segment_count())
	eq(world.wipes, 0, "with nobody wiped along the way")
	finish()
