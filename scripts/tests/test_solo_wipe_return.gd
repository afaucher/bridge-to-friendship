extends "res://scripts/test_support/test_case.gd"

# A SOLO WIPE MUST PUT THE PLAYER BACK IN A LOBBY.
#
# From a playtest: "it says you lost, but you don't spawn in a lobby -- the
# lobby/non-lobby gets flipped." Reported for single player, which is exactly
# where it would show: a wipe is EVERY player waiting on the drone, and with one
# player that is one death rather than a coordinated disaster.
#
# THE CLAIM IS ABOUT THE SEGMENT THE BODY IS STANDING IN, not about a row number.
# "Back in the lobby" is a statement about the place, and a row is only evidence
# for it -- the run is assembled, so which rows are lobby is a property of the
# plan rather than something this test should hardcode.
#
# It is also a claim about the STATE agreeing with the place. The round machine
# calls the lobby a corridor between two strips, so a party standing outside that
# corridor while the machine says LOBBY is the reported symptom in the machine's
# own terms.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const RUN_SEED := 20260816

var world: Node3D = null
var solo: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var round_started := false

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "SoloWipeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	# ONE PLAYER. The report says single player, and a wipe is every player out --
	# so a party of two would need both down on the same tick and the bug would
	# look intermittent.
	world._spawn_player(1, 0)
	solo = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

# Which segment of the assembled run a world row belongs to, and whether that
# segment is a lobby. Asked of the GRID rather than computed from the plan: the
# run is built lazily and the rows a lobby occupies are whatever was appended.
func _in_lobby(row: int) -> bool:
	var i: int = world.grid.segment_index_of_row(row)
	if i < 0 or i >= world.grid._segments.size():
		return false
	var seg = world.grid._segments[i]["data"]
	return seg.tags.has("lobby")

func _row_of(body: Node) -> int:
	return world.grid.cell_of_world(body.position).y

func _physics_process(_delta: float) -> void:
	if solo == null:
		return
	phase_frame += 1
	match phase:
		0: _phase_start_the_round()
		1: _phase_die()
		2: _phase_wait_for_lobby()

# Walk onto the exit strip so the round actually begins. A wipe out of LOBBY is
# not the reported case and would not exercise the corridor at all.
func _phase_start_the_round() -> void:
	if world.round_machine.state == RoundMachine.State.RUNNING:
		round_started = true
		phase = 1
		phase_frame = 0
		return
	if phase_frame > 3000:
		check(false, "the round never started -- the rig never got the party over "
			+ "the first strip (row %d, target %d), so nothing below is about a wipe"
				% [_row_of(solo), world.round_machine.target_row])
		finish()
		return
	# Straight up-bridge until the machine crosses.
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(0.0, -1.0), 0)

# Then die. Straight to the terminal state the wipe rule actually reads: a player
# waiting on the drone has already spent their hang and their bleed-out, and
# nothing else counts.
func _phase_die() -> void:
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	if phase_frame < 5:
		return
	# SET ONCE, THEN LET IT PLAY OUT. The first version of this rig re-armed
	# `_returning` every frame it found it empty -- but a wipe CLEARS it, so the
	# rig wiped the party on every tick forever and the run hung with no failing
	# assertion. Exactly the shape CLAUDE.md warns about: a hang is very often the
	# rig, and a probe that keeps poking the thing it is measuring is measuring
	# itself.
	world._returning[1] = 3.0
	phase = 2
	phase_frame = 0

func _phase_wait_for_lobby() -> void:
	# SCORING then LOBBY. The board is the "you lost" the report names; the claim
	# is about where the body is once the machine says the lobby is open again.
	if world.round_machine.state != RoundMachine.State.LOBBY:
		if phase_frame > 4000:
			check(false, "the machine never returned to LOBBY after a solo wipe "
				+ "(stuck in %s)" % world.round_machine.state_name())
			finish()
		return

	check(round_started, "the round had really started before the wipe")
	print("[solo wipe] back at row %d, corridor %d..%d, state %s"
		% [_row_of(solo), world.round_machine.rear_row,
			world.round_machine.target_row, world.round_machine.state_name()])

	# NOT `wipes > 0`, and this was the first thing the rig got wrong about the
	# game. A solo death never reaches `_check_wipe`: the round machine sees
	# everyone out and goes to SCORING, `_settle_round_transition` puts the
	# straggler back and ERASES `_returning` doing it, so by the time `_check_wipe`
	# runs there is nobody returning and the counter never moves. The round is
	# still lost and still scored -- `wipes` just is not the instrument for it.
	var row: int = _row_of(solo)
	check(_in_lobby(row),
		"a wiped solo player stands in a LOBBY segment: ended at row %d, which is "
			% row
		+ "in segment %d of the run and that segment is not a lobby. This is the "
			% world.grid.segment_index_of_row(row)
		+ "playtest report -- the board says you lost and the place says otherwise")

	# AND THE MACHINE AGREES WITH THE PLACE. The lobby is the corridor between
	# `rear_row` and `target_row`; a body outside it while the state says LOBBY is
	# the same bug stated in the machine's own terms, and it is the half that
	# breaks the NEXT round rather than this one -- a target strip five sections
	# away means the whole next section is played in the lobby state.
	var rear: int = world.round_machine.rear_row
	var target: int = world.round_machine.target_row
	check(row >= rear and row <= target,
		"and inside the corridor the machine calls the lobby: at row %d with "
			% row
		+ "rear %d and target %d" % [rear, target])
	# AND THE STRIP THEY MUST CROSS IS THE ONE AT THE END OF THE LOBBY THEY ARE
	# STANDING IN. This is the assertion that actually catches the report, and the
	# first version of it did not: it asked whether `target_row` was a lobby row,
	# which is true of the NEXT lobby's entry band as well and so was true of the
	# broken build. Same segment or nothing.
	eq(world.grid.segment_index_of_row(target), world.grid.segment_index_of_row(row),
		"the strip to cross is this lobby's own exit: player in segment %d at row "
			% world.grid.segment_index_of_row(row)
		+ "%d, target strip at row %d in segment %d. A target in a LATER segment "
			% [row, target, world.grid.segment_index_of_row(target)]
		+ "means the whole next section is played in the LOBBY state -- which is "
		+ "the playtest report, and it stays flipped for the rest of the run")
	finish()
