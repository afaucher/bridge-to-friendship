extends "res://scripts/test_support/test_case.gd"

# EVERYONE IS IN THE LOBBY WHEN THE LOBBY OPENS.
#
# From a playtest, three players, two over the line and one behind:
#
#   the scores popped up and looked accurate
#   when they went away, one guy was still OUTSIDE the lobby's south wall, in the
#   play area from the last round
#   once he crossed that south wall, the round STARTED and the timer started
#
# The second symptom is the diagnostic one. A round begins when the party crosses
# the strip AHEAD of them -- the lobby's exit -- so a round that began on the
# strip BEHIND them means `target_row` was pointing at the lobby's ENTRY band. The
# corridor was one boundary out, and the party was outside it.
#
# test_straggler_return already covers where a straggler is PUT, and passes: it
# asserts at SCORING, which is the moment they are moved. What nothing covered is
# the ten seconds after -- `_enter_lobby` re-deriving the corridor from where the
# party actually is, which is a different question with a different answer if
# anybody is somewhere unexpected.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const RUN_SEED := 20260817

# Godot's own shape, not 1 and 2 -- the straggler lane maths was wrong for a year
# because every test used small ids.
const PEER_A := 512338291
const PEER_B := 774120655
const PEER_C := 193884027

var world: Node3D = null
var frames: int = 0
var phase: int = 0
var phase_frame: int = 0
var scored := false

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "RegroupWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	for peer in [PEER_A, PEER_B, PEER_C]:
		world._spawn_player(peer, [PEER_A, PEER_B, PEER_C].find(peer))
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func machine():
	return world.round_machine

func _park(peer: int, x: int, row: int) -> void:
	var body: Node = world.player_body(peer)
	body.position = world.grid.cell_surface_world(Vector2i(x, row)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

func _row_of(peer: int) -> int:
	return world.grid.cell_of_world(world.player_body(peer).position).y

func _in_lobby(row: int) -> bool:
	return world.grid.is_lobby_row(row)

func _physics_process(_delta: float) -> void:
	if world.tick == 0:
		return
	frames += 1
	phase_frame += 1
	match phase:
		0: _phase_open_the_round()
		1: _phase_two_cross_one_does_not()
		2: _phase_wait_for_the_lobby()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# Everyone onto the first lobby's exit strip, which is what opens a round.
func _phase_open_the_round() -> void:
	if machine().state == RoundMachine.State.RUNNING:
		_advance(1)
		return
	if machine().target_row < 0 or phase_frame < 4:
		return
	_park(PEER_A, 4, machine().target_row)
	_park(PEER_B, 7, machine().target_row)
	_park(PEER_C, 10, machine().target_row)
	if phase_frame > 900:
		check(false, "the round never opened")
		finish()

# THE REPORTED SITUATION. Two cross the far strip; the third is left in the middle
# of the section and never gets there, so the close timer has to expire.
func _phase_two_cross_one_does_not() -> void:
	if machine().target_row < 0:
		return
	if machine().state == RoundMachine.State.RUNNING and phase_frame > 4:
		_park(PEER_A, 5, machine().target_row)
		_park(PEER_B, 9, machine().target_row)
		return
	if machine().state == RoundMachine.State.CLOSING:
		# Straight to the end of the window rather than sitting through 30 s.
		machine().close_timer = minf(machine().close_timer, 0.05)
		return
	if machine().state == RoundMachine.State.SCORING:
		scored = true
		print("[regroup] SCORING rear=%d target=%d rows=%d/%d/%d"
			% [machine().rear_row, machine().target_row,
				_row_of(PEER_A), _row_of(PEER_B), _row_of(PEER_C)])
		_advance(2)

func _phase_wait_for_the_lobby() -> void:
	if machine().state != RoundMachine.State.LOBBY:
		if phase_frame > 4000:
			check(false, "never reached LOBBY (stuck in %s)" % machine().state_name())
			finish()
		return

	var rear: int = machine().rear_row
	var target: int = machine().target_row
	print("[regroup] LOBBY rear=%d target=%d rows=%d/%d/%d"
		% [rear, target, _row_of(PEER_A), _row_of(PEER_B), _row_of(PEER_C)])

	check(scored, "the round really went through the scoreboard first")

	# EVERY PLAYER IS IN A LOBBY. The straggler most of all -- they are the one the
	# transition has to move, and the one the report found still standing in the
	# section they lost.
	for peer in [PEER_A, PEER_B, PEER_C]:
		var row: int = _row_of(peer)
		check(_in_lobby(row),
			"peer %d is in a LOBBY segment when the lobby opens (row %d) -- the "
				% [peer, row]
			+ "report was 'one guy was still outside the lobby's south wall, in "
			+ "the play area from the last round'")

	# AND THE STRIP TO CROSS IS AHEAD OF THEM, NOT BEHIND. This is the assertion
	# that names the reported symptom: the round started when he crossed the SOUTH
	# wall, which can only happen if `target_row` is the strip the party came in
	# through rather than the one they leave by.
	for peer in [PEER_A, PEER_B, PEER_C]:
		check(_row_of(peer) >= rear,
			"peer %d is inside the corridor the machine calls the lobby (row %d, "
				% [peer, _row_of(peer)]
			+ "rear %d) -- a player BEHIND the rear strip starts the next round by "
				% rear
			+ "walking forwards into the lobby, which is the reported bug")
		check(_row_of(peer) < target,
			"and short of the strip that starts the next round (row %d, target %d)"
				% [_row_of(peer), target])

	# PAST THE DOORWAY, NOT STANDING IN IT. This is the assertion that names the
	# change: the transition used to move only the players who did NOT cross, on
	# the reasoning that anybody who crossed was already where they should be. They
	# were on the STRIP -- the lobby's doorway rather than its floor -- so the party
	# ended a round spread across a boundary at the exact moment every rule about
	# the next one is derived from where they are standing.
	var band_end: int = world.grid.gate_band_end(rear)
	for peer in [PEER_A, PEER_B, PEER_C]:
		check(_row_of(peer) > band_end,
			"peer %d is on the lobby FLOOR, past the entry band (row %d, band ends "
				% [peer, _row_of(peer)]
			+ "at %d) -- including the ones who crossed under their own power, "
				% band_end
			+ "because 'everyone is in the lobby' is the property the next round "
			+ "is built on")
	finish()
