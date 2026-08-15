extends "res://scripts/test_support/test_case.gd"

# M16 Step 2 and 3: the round state machine, and the barriers that enforce it.
#
# THE SEQUENCE IS ASSERTED BEFORE ANYTHING CAN BE SEEN, which is why this step
# came before the wall in the plan. A state machine debugged through geometry is
# a state machine debugged twice.
#
# The claims:
#   1. LOBBY until EVERY player is on the strip. One player standing on it does
#      not open the round -- that is the entire gesture the barrier exists for.
#   2. The check is POLLED. A player who steps on, steps off, and steps on again
#      still opens it; this project lost a day to a readiness check that only ran
#      in the handler that fired once (CLAUDE.md).
#   3. THE ROUND CLOCK PASSING FIVE MINUTES DOES NOTHING AT ALL. Five minutes is
#      an authoring budget, not a mechanism -- the half of the gate that says
#      something is IMPOSSIBLE, and the one that stops a cap being added later by
#      accident.
#   4. First over the line starts the 30 s close, and ANYONE who gets over during
#      it is recorded -- asserted on every tick of the window, not at its end.
#   5. At expiry the stragglers are in the lobby and the board distinguishes them.
#   6. The barriers stand where the corridor says: a front wall while the party
#      is held, no front wall during the round, and a rear wall behind them the
#      moment they cross.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")

# The fixture's two strips.
const FIRST_GATE := 2
const SECOND_GATE := 10

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var closing_ticks: int = 0

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "RoundWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_gate.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	_park(a, 3, 0)
	_park(b, 6, 0)

func _park(body: CharacterBody3D, x: int, row: int) -> void:
	body.position = world.grid.cell_surface_world(Vector2i(x, row)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

func machine():
	return world.round_machine

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_lobby_holds()
		1: _phase_all_together_opens_it()
		2: _phase_the_clock_is_powerless()
		3: _phase_first_over_starts_the_close()
		4: _phase_the_window_records_arrivals()
		5: _phase_the_board()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1 and 2. The lobby holds until everyone is on the strip ------------------

func _phase_lobby_holds() -> void:
	if phase_frame == 2:
		eq(machine().state, RoundMachine.State.LOBBY, "a session opens in the lobby")
		eq(machine().target_row, FIRST_GATE,
			"heading for the first strip, taken from the GRID rather than computed")
		eq(machine().rear_row, -1,
			"with nothing behind them yet -- -1, never a plausible guess")

		# THE BARRIER IS UP, AHEAD OF THEM.
		check(world._front_wall != null, "and a barrier stands ahead of the party")
		check(world._rear_wall == null, "with nothing behind, because they came from nowhere")

		# AND THE PLAYERS CAN ACTUALLY SEE IT. Asserted as the MASK, because the
		# first version of this wall sat on a layer nothing masked: it existed,
		# replicated, drew, and stopped nothing at all -- and the "a barrier
		# stands ahead" check above passed the whole time. Five bugs in this
		# project have now been one wrong bit here.
		check(world._front_wall.collision_layer & a.collision_mask != 0,
			"on a layer the players actually mask (wall %d, player mask %d)"
				% [world._front_wall.collision_layer, a.collision_mask])

		# THE PLAYER IS TOLD WHAT TO DO, not where they are. "LOBBY" is a fact
		# they can see out of the window; "everyone onto the checker" is the only
		# thing on any screen in this game that says how to start a round.
		var waiting: Dictionary = HudModel.round_entry(world)
		check(bool(waiting["waiting"]), "the model says the lobby is waiting on the party")
		check(float(waiting["countdown"]) < 0.0,
			"with no countdown -- a timer that is always there is not read")
		return
	if phase_frame == 4:
		# WALK INTO IT AND STAY PUT. The half of the gate that says something is
		# IMPOSSIBLE, and the half the first draft skipped -- "a wall exists" is
		# satisfied just as well by a wall made of nothing.
		#
		# Measured over several ticks rather than one: a body that squeezes
		# through takes a few frames to do it, and a single sample taken on the
		# tick of contact would miss exactly that.
		_park(a, 3, FIRST_GATE)
		a.velocity = Vector3(0.0, 0.0, -SimConfig.WALK_SPEED * 3.0)
		return
	if phase_frame > 4 and phase_frame < 8:
		# Held against it under power, so this is not measuring a body that simply
		# stopped moving.
		a.velocity.z = -SimConfig.WALK_SPEED * 3.0
		return
	if phase_frame == 8:
		var row: int = world.grid.cell_of_world(a.position).y
		check(row <= FIRST_GATE,
			"a player driven into the barrier does NOT cross it (row %d, strip %d)"
				% [row, FIRST_GATE])
		return
	if phase_frame == 10:
		eq(machine().state, RoundMachine.State.LOBBY,
			"ONE player on the strip does not open the round -- that is the whole "
			+ "gesture the barrier exists for")

		# POLLED, NOT HANDLED. Step off and on again: a check that only ran on the
		# tick somebody arrived would have spent its one chance by now.
		_park(a, 3, 0)
		return
	if phase_frame == 14:
		_park(a, 3, FIRST_GATE)
		return
	if phase_frame == 18:
		eq(machine().state, RoundMachine.State.LOBBY, "still held with one of two on it")
		_advance(1)

# --- 3. Everyone together opens it -------------------------------------------

func _phase_all_together_opens_it() -> void:
	if phase_frame == 2:
		_park(b, 6, FIRST_GATE)
		return
	if phase_frame < 6:
		return
	eq(machine().state, RoundMachine.State.RUNNING,
		"the LAST player arriving opens the round")
	eq(machine().rear_row, FIRST_GATE, "the strip they crossed is now behind them")
	eq(machine().target_row, SECOND_GATE, "and the next one is the target")

	# THE WALL FLIPPED. No front wall during a round -- the section is the thing
	# you are meant to cross -- and a rear one where they came through.
	check(world._front_wall == null, "the barrier ahead of them is gone")
	check(world._rear_wall != null, "and one has appeared behind them")
	_advance(2)

# --- 4. The clock measures and never fires -----------------------------------

func _phase_the_clock_is_powerless() -> void:
	if phase_frame == 2:
		# Well past the five-minute target, and past any plausible cap somebody
		# might add later without reading the plan.
		machine().round_clock = RoundMachine.TARGET_SECONDS * 3.0
		return
	if phase_frame < 30:
		return
	eq(machine().state, RoundMachine.State.RUNNING,
		"a round FIFTEEN MINUTES long is still a round -- five minutes is an "
		+ "authoring budget, and nothing in the machine reads the clock")
	check(machine().round_clock > RoundMachine.TARGET_SECONDS,
		"and the clock really is past it (%.0f s), so this is not a vacuous pass"
			% machine().round_clock)
	_advance(3)

# --- 5. First over the line starts the close ---------------------------------

func _phase_first_over_starts_the_close() -> void:
	if phase_frame == 2:
		_park(a, 3, SECOND_GATE)
		return
	if phase_frame < 6:
		return
	eq(machine().state, RoundMachine.State.CLOSING,
		"the FIRST player over the next strip starts the close")
	near(machine().close_timer, RoundMachine.CLOSE_SECONDS, 0.2,
		"with the whole 30 s to run")
	check(machine().reached.has(1), "and they are recorded as having made it")
	check(not machine().reached.has(2), "while the one still out there is not")
	check(world._front_wall != null,
		"a barrier holds them out of the lobby until the clock runs down")
	closing_ticks = 0
	_advance(4)

# --- 6. Every tick of the window ---------------------------------------------

func _phase_the_window_records_arrivals() -> void:
	closing_ticks += 1

	# ASSERTED ON EVERY TICK, not at the end. A phase that samples one frame
	# cannot see a bug seven frames later -- the 2026-08-13 rusher bug was exactly
	# this shape and was green for the whole life of the defect.
	if machine().state == RoundMachine.State.CLOSING:
		if not machine().reached.has(1):
			check(false, "a player who made it stopped counting mid-window (tick %d)"
				% closing_ticks)
			finish()
			return
		if world._front_wall == null:
			check(false, "the barrier dropped early, at tick %d of the window"
				% closing_ticks)
			finish()
			return

	# Two thirds of the way through, the straggler makes it over.
	if closing_ticks == int(RoundMachine.CLOSE_SECONDS * 60.0 * 0.66):
		_park(b, 6, SECOND_GATE)
		return
	if closing_ticks == int(RoundMachine.CLOSE_SECONDS * 60.0 * 0.66) + 6:
		check(machine().reached.has(2),
			"somebody arriving DURING the window is recorded, not just the first")
		# And back off the strip again before it expires, to prove the record is
		# what was DONE rather than where the body ended up.
		_park(b, 6, SECOND_GATE - 3)
		return
	if machine().state == RoundMachine.State.CLOSING:
		return

	eq(machine().state, RoundMachine.State.SCORING, "the window closes into the board")
	check(machine().reached.has(2),
		"and somebody who touched the strip and walked back off STILL counts -- "
		+ "made-it is recorded when it happens, never re-derived from where a body is")
	_advance(5)

# --- 7. The board, and back to the lobby -------------------------------------

func _phase_the_board() -> void:
	if phase_frame == 2:
		eq(machine().board.size(), 2, "the board has a row per player")

		# AND THE HUD REALLY DRAWS IT. The model is a pure function and is where
		# the design lives, but a view script the gate never instantiates ships
		# having never run once (CLAUDE.md) -- and this one is built from a
		# freshly-added panel that nothing else touches.
		var model: Dictionary = HudModel.build(world)
		var entry: Dictionary = model.get("round", {})
		check(not entry.is_empty(), "the HUD model carries the round")
		eq(int(entry["state"]), RoundMachine.State.SCORING, "in the scoring state")
		eq(entry["board"].size(), 2, "with the board attached for the panel to draw")
		check(float(entry["elapsed"]) > 0.0,
			"and the round clock, which is shown and decides nothing (%.0f s)"
				% entry["elapsed"])
		# Both made it and neither has a hat, so the tie-break decides -- and it
		# has to be the same on every machine, or two clients show a different
		# round.
		eq(int(machine().board[0]["peer"]), 1, "ranked stably by peer on a tie")
		check(bool(machine().board[0]["made_it"]), "with both marked as having lived")
		return
	if machine().state != RoundMachine.State.LOBBY:
		return
	eq(machine().round_index, 1, "and the board gives way to the next lobby")
	eq(machine().rear_row, SECOND_GATE, "which is up-bridge of the strip just crossed")
	check(world._rear_wall != null, "with the barrier behind them")
	finish()
