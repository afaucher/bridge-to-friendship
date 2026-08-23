extends "res://scripts/test_support/test_case.gd"

# A CLIENT'S ROUND CLOCKS RUN. Reported from play 2026-08-23: "the lobby closing
# countdown doesn't update for remote players -- it stays at 30s for the whole
# period."
#
# It did. `RoundMachine.step()` is called from `_host_tick` and nowhere else,
# which is correct for everything in it that DECIDES something -- a client must
# never promote a corridor or open a scoreboard. But the countdown is not a
# decision, it is a number on a screen, and a client was handed 30.0 by
# `_round_sync` at the moment CLOSING began and then showed it unchanged for
# thirty seconds.
#
# THE FIX WAS WRITTEN DOWN AND NEVER BUILT. `_on_round_state_changed` says: "a
# client ticking its own copy down between those is right to within a frame, and
# the frame it is wrong by is a number on a screen rather than anything the sim
# reads." Nothing ticked it.
#
# The claims:
#   1. A CLIENT'S COUNTDOWN FALLS. The reported bug, asserted on a world that is
#      not the host.
#   2. AND ITS TWIN RISES. `round_clock` was frozen on a client too and nobody
#      reported it, because a clock counting UP from zero looks plausible while it
#      is wrong. Fixing only the one that was noticed would have left it.
#   3. A CLIENT STILL DECIDES NOTHING. This is the claim that keeps the fix from
#      being a bug: the clocks move, the STATE does not, and a countdown reaching
#      zero on a client must not open the scoreboard by itself.
#   4. HOST AND CLIENT USE THE SAME ARITHMETIC. Asserted by running both for the
#      same number of ticks and comparing, because two copies of one fact is what
#      this project keeps paying for.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const SECOND := 60

var client: Node3D = null
var started := false

func setup(main) -> void:
	timeout_seconds = 40.0
	# A CLIENT-SHAPED WORLD WITH NO NETWORK. `start(is_host, peer, networked)` --
	# false, so `_client_tick` is what runs, which is the path under test. The
	# socket is not needed: the bug is that nothing on this side advanced a number,
	# and a real peer would only make the fixture slower and flakier.
	client = Node3D.new()
	client.name = "ClientWorld"
	client.set_script(GameWorldScript)
	main.add_child(client)
	client.segment_paths = ["res://segments/test_flat.seg"]
	client.start(false, 2, false)
	client._spawn_player(2, 0)
	client.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if client.tick < 2 or started:
		return
	started = true
	set_physics_process(false)

	_countdown_falls()
	_round_clock_rises()
	_a_client_decides_nothing()
	_host_and_client_agree()
	finish()

# --- 1. The reported bug ------------------------------------------------------

func _countdown_falls() -> void:
	var m = client.round_machine
	m.state = RoundMachine.State.CLOSING
	m.close_timer = RoundMachine.CLOSE_SECONDS
	var before: float = m.close_timer
	_run(SECOND)
	print("[clocks] client countdown %.2f -> %.2f over 1 s" % [before, m.close_timer])
	near(m.close_timer, before - 1.0, 0.05,
		"a client's closing countdown falls in real time -- it sat at %.0f for the "
			% before + "whole window before 2026-08-23")

# --- 2. The twin nobody reported ----------------------------------------------

func _round_clock_rises() -> void:
	var m = client.round_machine
	m.state = RoundMachine.State.RUNNING
	m.round_clock = 0.0
	_run(SECOND)
	print("[clocks] client round clock 0.00 -> %.2f over 1 s" % m.round_clock)
	near(m.round_clock, 1.0, 0.05,
		"and the round timer runs too (%.2f s) -- it was frozen in the same way "
			% m.round_clock
		+ "and went unreported, because a clock counting UP from zero looks "
		+ "plausible while it is wrong")

# --- 3. ...and still decides nothing ------------------------------------------
#
# THE CLAIM THAT KEEPS THE FIX FROM BEING A BUG. A client advancing clocks must
# not become a client running the round: `_step_scoring` opens the lobby when the
# timer hits zero, and if that ran here two machines would disagree about which
# round they are in.

func _a_client_decides_nothing() -> void:
	var m = client.round_machine
	m.state = RoundMachine.State.SCORING
	m.close_timer = 0.5
	m.round_index = 7
	_run(SECOND * 2)          # twice as long as the timer it is counting down
	eq(int(m.close_timer * 100.0), 0, "the client's timer reaches zero")
	eq(int(m.state), RoundMachine.State.SCORING,
		"and the state does NOT move -- a client that ran _step_scoring would open "
		+ "the next lobby on its own and disagree with the host about the round")
	eq(m.round_index, 7, "nor the round index")

# --- 4. One arithmetic, both sides --------------------------------------------

func _host_and_client_agree() -> void:
	# The host reaches the same function through step(); this compares the numbers
	# rather than the call path, which is the thing that has to stay true.
	var mine = RoundMachine.new()
	mine.state = RoundMachine.State.CLOSING
	mine.close_timer = RoundMachine.CLOSE_SECONDS
	mine.round_clock = 0.0
	for _i in SECOND:
		mine.advance_clocks()

	var theirs = client.round_machine
	theirs.state = RoundMachine.State.CLOSING
	theirs.close_timer = RoundMachine.CLOSE_SECONDS
	theirs.round_clock = 0.0
	_run(SECOND)

	near(theirs.close_timer, mine.close_timer, 0.001,
		"host and client count the same countdown down at the same rate")
	near(theirs.round_clock, mine.round_clock, 0.001,
		"and the same clock up -- two copies of one arithmetic is what this "
		+ "project keeps paying for")

# --- helpers ------------------------------------------------------------------

# Ticks the world the way the game does, so what is under test is the real
# `_client_tick` path rather than a call to `advance_clocks` this file made.
func _run(ticks: int) -> void:
	for _i in ticks:
		client._physics_process(SimConfig.TICK_DELTA)
