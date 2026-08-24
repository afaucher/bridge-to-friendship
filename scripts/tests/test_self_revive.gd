extends "res://scripts/test_support/test_case.gd"

# THE SELF-REVIVE MINIGAME. A marker sweeps a bar; press USE inside the window and
# you get up, miss and time comes off the countdown you are trying to beat.
#
# IT IS A RISK, NOT A SLOWER CERTAINTY, and every claim here is really about that.
# A self-revive that were merely slower than a teammate haul would still be
# strictly better than waiting, and a party would stop coming for each other. The
# cost is paid out of the thing you are short of, which is why the penalty lands
# on `state_timer` and not on a cooldown somewhere.
#
# The claims:
#   1. A HIT GETS YOU UP, from downed and from a hang, and the hang case has to
#      really put the body on the deck rather than merely change a word.
#   2. A MISS COSTS TIME, off the very countdown being raced.
#   3. A MISS CAN KILL YOU. The bet has to be losable or it is not a bet -- press
#      with less left than the penalty and the state ends on that tick.
#   4. IT DOES NOTHING WHILE SOMEBODY IS HELPING. Specified, and it is also what
#      keeps the two routes from competing: a player who gambles at the moment a
#      teammate arrives must not be killed BY the arrival.
#   5. THE BUTTON CANNOT BE LEANED ON. The bit repeats under packet loss and
#      reconciliation replay, and one press must not spend several attempts.
#   6. THE WINDOW DOES NOT MOVE ONCE THE CRISIS HAS STARTED, including across the
#      miss penalty -- which is the trap that decided the design. Derive the seed
#      from `state_timer` and a miss relocates the one window, handing back a
#      second chance out of the punishment for using the first.
#   7. IT IS ONE WINDOW, IN THE MIDDLE OF THE COUNTDOWN, AND IT IS THIN. Not at
#      the start (no time to see it coming), not at the end (indistinguishable
#      from no chance at all), and 0.25 s either way -- a DURATION, so the two
#      countdowns are equally hard and only the drawn line differs.
#   8. THE LINE IS DRAWN WHERE THE EDGE WILL BE. The bar IS the marker, so the
#      claim is that mark and countdown coincide at the winning moment.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

var world: Node3D = null
var body: CharacterBody3D = null
var mate: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "ReviveWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	body = world.player_body(1)
	mate = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	# THE TEAMMATE IS PARKED SIXTY METRES AWAY AND STAYS THERE except in the one
	# phase that wants them. The spawn ring is inside REVIVE_RADIUS (2.5 m), so the
	# first version of this file had a helper standing over the body in EVERY phase
	# -- which makes the whole minigame inert, and every assertion about it failed
	# talking about something else. Worse, the phase that asserts inertness would
	# have passed for entirely the wrong reason.
	_park_mate_away()

# EVERY PHASE STARTS FROM THE SAME STATE, and the cooldown is the reason this is
# a function rather than three lines at the top of setup(). It is 0.35 s -- 21
# ticks -- and it SURVIVES a phase, so the successful press in one phase silently
# blocked the first press of the next. Three assertions failed talking about
# penalties and countdowns, and one PASSED for the wrong reason (a held key that
# spent no attempts because it was never allowed one). CLAUDE.md: isolate every
# sample, not once at setup.
func _reset(target: Node) -> void:
	target.self_revive_cooldown = 0.0
	world._returning.erase(1)
	_park_mate_away()

func _park_mate_away() -> void:
	mate.position = body.position + Vector3(60.0, 0.0, 0.0)
	mate.velocity = Vector3.ZERO

func _physics_process(_delta: float) -> void:
	if body == null or world.tick < 2 or done:
		return
	done = true
	set_physics_process(false)
	# THE WORLD IS DRIVEN BY HAND FROM HERE. Two real frames have run so the spawn
	# has settled; after this every tick is one this file asked for, which is what
	# lets a phase place the countdown on an exact value and read the consequence
	# of exactly one press. Left on the engine's clock, the world would take a
	# further tick after each phase and the "cost of one attempt" assertions would
	# be measuring an unknown number of them.
	world.set_physics_process(false)

	_the_window_is_fixed_for_the_crisis()
	_one_thin_window_in_the_middle()
	_a_hit_gets_you_up()
	_a_miss_costs_time()
	_a_miss_can_kill_you()
	_a_helper_makes_it_inert()
	_it_cannot_be_leaned_on()
	_the_bar_says_when_it_is_live()
	finish()

# --- 6. The window is fixed for the crisis ------------------------------------

func _the_window_is_fixed_for_the_crisis() -> void:
	_reset(body)
	body.begin_downed()
	var gate: float = body.self_revive_gate()

	# ACROSS A MISS, which is the case the stored seed exists for. The obvious
	# implementation reconstructs the entry tick from `state_timer` and needs no new
	# field -- and a miss ADDS to state_timer, so the derived tick moves, the hash
	# changes, and the one window silently relocates. That is a second chance handed
	# out by the punishment for using the first.
	body.state_timer = _nearest_miss(body, 0.5)
	_press(1)
	_tick()
	near(body.self_revive_gate(), gate, 0.0001,
		"a miss does not move the window (%.3f -> %.3f) -- with one window, a "
			% [gate, body.self_revive_gate()]
		+ "window that re-rolls on failure is a second chance out of the penalty")

	# ...and across a whole world tick, which is where a randf() would come apart:
	# the player would be judged against a window they were never shown.
	for _i in 5:
		_tick()
	near(body.self_revive_gate(), gate, 0.0001, "nor does the passage of time")

	# A NEW CRISIS GETS A NEW WINDOW, or it is a fixed puzzle a player memorises
	# once and the gamble stops being one.
	var seen: Dictionary = {}
	for i in 12:
		body.revive()
		world.tick += 37 * (i + 1)
		body.begin_downed()
		seen[snappedf(body.self_revive_gate(), 0.01)] = true
	print("[revive] 12 crises produced %d distinct windows" % seen.size())
	check(seen.size() >= 4,
		"and a new crisis rolls a new one (%d distinct in 12) -- a window in the "
			% seen.size() + "same place every time is memorised once")

	# TWO PLAYERS DOWNED ON THE SAME TICK ARE NOT SOLVING THE SAME PUZZLE. A party
	# wiped by one blast would otherwise all be pressing together.
	body.revive()
	body.begin_downed()
	mate.begin_downed()
	check(absf(mate.self_revive_gate() - body.self_revive_gate()) > 0.01,
		"and two players downed on the same tick get different windows (%.2f vs "
			% body.self_revive_gate() + "%.2f) -- the peer is mixed into the hash"
			% mate.self_revive_gate())
	mate.revive()

# --- 7. One thin window, in the middle ----------------------------------------

func _one_thin_window_in_the_middle() -> void:
	_reset(body)
	body.begin_downed()

	# HOW MUCH OF THE COUNTDOWN IS A WIN. Both halves, because half a gate is not a
	# gate: a window nobody can hit satisfies "not free" perfectly well.
	var hits: int = 0
	var samples: int = 0
	var t: float = 0.0
	while t < SimConfig.DOWNED_SECONDS:
		body.state_timer = t
		samples += 1
		if body.self_revive_hit():
			hits += 1
		t += SimConfig.TICK_DELTA
	print("[revive] %d of %d ticks of a %.0f s countdown are a win (%.2f s)"
		% [hits, samples, SimConfig.DOWNED_SECONDS, float(hits) * SimConfig.TICK_DELTA])
	check(hits > 0,
		"the window is reachable at all -- a rule that cannot be satisfied is a "
		+ "wall, and this project has certified one of those before")
	near(float(hits) * SimConfig.TICK_DELTA, SimConfig.SELF_REVIVE_WINDOW_SECONDS, 0.05,
		"and it is %.2f s wide, the stated duration -- a window measured as a "
			% SimConfig.SELF_REVIVE_WINDOW_SECONDS
		+ "FRACTION would be twice as generous on the shorter of the two countdowns")

	# ONE WINDOW, NOT A SERIES. The count of separate runs of winning ticks is the
	# claim; a repeating gate would show several.
	var runs: int = 0
	var was := false
	t = 0.0
	while t < SimConfig.DOWNED_SECONDS:
		body.state_timer = t
		var now: bool = body.self_revive_hit()
		if now and not was:
			runs += 1
		was = now
		t += SimConfig.TICK_DELTA
	eq(runs, 1, "and there is exactly ONE of them in the whole countdown")

	# ...IN THE MIDDLE. Never so early there is no time to see it coming, never so
	# late it cannot be told apart from having no chance at all.
	var gate: float = body.self_revive_gate()
	check(gate >= SimConfig.DOWNED_SECONDS * SimConfig.SELF_REVIVE_EARLIEST - 0.01
			and gate <= SimConfig.DOWNED_SECONDS * SimConfig.SELF_REVIVE_LATEST + 0.01,
		"and it sits between %.0f%% and %.0f%% of the way through (at %.2f s)"
			% [SimConfig.SELF_REVIVE_EARLIEST * 100.0,
				SimConfig.SELF_REVIVE_LATEST * 100.0, gate])

	# THE SAME DURATION ON A HANG, which is the point of measuring the window in
	# seconds rather than in bar-widths: the hang bar drains nearly twice as fast,
	# so an equal FRACTION would be an easier press there and a different game.
	_hang(body)
	hits = 0
	t = 0.0
	while t < SimConfig.LEDGE_HANG_SECONDS:
		body.state_timer = t
		if body.self_revive_hit():
			hits += 1
		t += SimConfig.TICK_DELTA
	near(float(hits) * SimConfig.TICK_DELTA, SimConfig.SELF_REVIVE_WINDOW_SECONDS, 0.05,
		"a hang gets the same %.2f s -- identical difficulty, drawn twice as wide "
			% SimConfig.SELF_REVIVE_WINDOW_SECONDS
		+ "because that bar is moving twice as fast")
	body.revive()

# --- 1. A hit gets you up -----------------------------------------------------

func _a_hit_gets_you_up() -> void:
	_reset(body)
	body.begin_downed()
	_press_at(1, body, _a_hit_moment(body))
	eq(int(body.state), int(PlayerBody.State.WALK),
		"pressing inside the window gets a downed player back on their feet")
	check(int(world.stats_of(1).get("self_revives", 0)) > 0,
		"and it is counted where it happened -- not as `rescued`, which is about "
		+ "somebody coming for you, and the point of this is that nobody did")

	# THE HANG, WHICH IS THE HALF THAT CAN LIE. `mantle()` moves the body onto the
	# deck; a version that only set the state would pass an assertion about
	# State.WALK while leaving the player hanging in the air.
	var before: Vector3 = body.position
	_hang(body)
	_press_at(1, body, _a_hit_moment(body))
	eq(int(body.state), int(PlayerBody.State.WALK), "and it hauls you off a ledge")
	check(body.position.distance_to(before) < 30.0
			and body.position.y > SimConfig.FALL_KILL_Y,
		"with the body actually moved onto the deck (%.2f, %.2f, %.2f) rather than "
			% [body.position.x, body.position.y, body.position.z]
		+ "the state word changed under a body still in the air")

# --- 2. A miss costs time -----------------------------------------------------

func _a_miss_costs_time() -> void:
	_reset(body)
	body.begin_downed()
	var at: float = _a_miss_moment(body)
	body.state_timer = at
	var before: float = body.rescue_seconds_left()
	_press(1)
	_tick()
	var after: float = body.rescue_seconds_left()
	print("[revive] a miss: %.2f s left -> %.2f s" % [before, after])
	eq(int(body.state), int(PlayerBody.State.DOWNED), "a miss leaves you down")
	check(before - after >= SimConfig.SELF_REVIVE_PENALTY - 0.1,
		"and takes %.1f s off the countdown you are racing (%.2f -> %.2f) -- the "
			% [SimConfig.SELF_REVIVE_PENALTY, before, after]
		+ "cost has to come out of the thing you are short of, or the gamble is free")

# --- 3. And it can kill you ---------------------------------------------------

func _a_miss_can_kill_you() -> void:
	_reset(body)
	# THE BET HAS TO BE LOSABLE. With less left than the penalty, a miss ends the
	# state on that very tick -- the countdown check runs immediately after the
	# attempt, which is the whole reason the penalty is applied to `state_timer`
	# rather than to a clock of its own.
	body.revive()
	body.begin_downed()
	body.state_timer = SimConfig.DOWNED_SECONDS - SimConfig.SELF_REVIVE_PENALTY * 0.5
	body.state_timer = _nearest_miss(body, body.state_timer)
	_press(1)
	_tick()
	check(int(body.state) != int(PlayerBody.State.DOWNED) or world._returning.has(1),
		"a miss with less left than the penalty ends it there and then -- state %d, "
			% int(body.state) + "returning %s" % str(world._returning.has(1)))
	world._returning.erase(1)
	body.revive()

# --- 4. Inert while somebody is helping ---------------------------------------

func _a_helper_makes_it_inert() -> void:
	_reset(body)
	body.begin_downed()
	mate.state = PlayerBody.State.WALK
	mate.position = body.position + Vector3(0.6, 0.0, 0.0)
	body.state_timer = _nearest_miss(body, 2.0)
	var before: float = body.state_timer

	# A MISS, WITH A TEAMMATE STANDING ON THEM. Not merely "the success is ignored"
	# -- the whole attempt is, penalty included. Being killed by the arrival of a
	# rescue is being punished for being rescued.
	_press(1)
	_tick()
	near(body.state_timer, before + SimConfig.TICK_DELTA, 0.02,
		"a miss costs nothing while a teammate is hauling you -- the clock advanced "
		+ "by one tick and no penalty (%.3f -> %.3f)" % [before, body.state_timer])

	# ...and the winning press is inert too, so the bar cannot be used to jump the
	# queue ahead of the rescue that is already under way.
	body.state_timer = _a_hit_moment(body)
	_press(1)
	_tick()
	eq(int(body.state), int(PlayerBody.State.DOWNED),
		"and a HIT does nothing either -- being helped is one route, not a faster "
		+ "start on the other")

	_park_mate_away()
	body.revive()

# --- 5. It cannot be leaned on ------------------------------------------------

func _it_cannot_be_leaned_on() -> void:
	_reset(body)
	body.begin_downed()
	body.state_timer = _nearest_miss(body, 1.0)
	var before: float = body.state_timer

	# THE BIT EVERY TICK, which is what a reconciliation replay and a redundant
	# input packet both look like. Without the cooldown this is one press spending
	# an attempt every tick, and the player is dead inside a second through no
	# decision of their own.
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2.ZERO, SimConfig.ACTION_USE)
	for _i in 10:
		_tick()
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	var spent: float = body.state_timer - before - 10.0 * SimConfig.TICK_DELTA
	var attempts: int = int(round(spent / SimConfig.SELF_REVIVE_PENALTY))
	print("[revive] ten ticks of a held key spent %d attempts" % attempts)
	eq(attempts, 1,
		"ten ticks of a held bit spend exactly one attempt (%d) -- ONE, not zero: "
			% attempts
		+ "a phase that starts under a stale cooldown passes this while measuring "
		+ "nothing. The bit repeats under packet loss and replay, and the penalty "
		+ "here is somebody's life")
	body.revive()

# --- The readout --------------------------------------------------------------

func _the_bar_says_when_it_is_live() -> void:
	_reset(body)
	# HIDDEN IS A STATEMENT. The bar is absent exactly when a press would do
	# nothing, so it never promises something the game will refuse.
	body.revive()
	check(HudModel.build(world, 1)["own"].get("self_revive", {}).is_empty(),
		"a player on their feet has no self-revive bar")
	body.begin_downed()
	var live: Dictionary = HudModel.build(world, 1)["own"].get("self_revive", {})
	check(not live.is_empty(), "a downed player has one")

	# THE LINE IS WHERE THE COUNTDOWN EDGE WILL BE AT THE WINNING MOMENT, and that
	# is the whole claim now that the bar IS the marker. Put the countdown exactly
	# on the gate and the two numbers have to coincide -- if they do not, the player
	# is being told to press at a place the rule does not agree with, which is
	# unfalsifiable from inside the game and reads as "it does not work".
	body.state_timer = body.self_revive_gate()
	var mark: float = float(HudModel.build(world, 1)["own"]["self_revive"]["line"])
	var edge: float = float(body.status_bar()["fraction"])
	near(mark, edge, 0.002,
		"the line sits exactly where the countdown edge is at the winning moment "
		+ "(line %.4f, edge %.4f)" % [mark, edge])
	check(body.self_revive_hit(), "...which is a winning moment")

	mate.position = body.position + Vector3(0.6, 0.0, 0.0)
	check(HudModel.build(world, 1)["own"].get("self_revive", {}).is_empty(),
		"and it goes away while a teammate is hauling you -- a bar still sweeping "
		+ "over an inert button is the HUD promising what the game will refuse")
	_park_mate_away()
	body.revive()

# --- helpers ------------------------------------------------------------------

# A `state_timer` the countdown edge crosses the line at. SEARCHED, NOT COMPUTED:
# `self_revive_gate()` is the rule, and reading it here to build the input would
# make every assertion below a tautology about one expression. Sampling the same
# predicate the host asks is the honest version, and it is also how a player finds
# it -- by watching the bar.
func _a_hit_moment(target: Node) -> float:
	var t: float = 0.0
	while t < target.rescue_total():
		target.state_timer = t
		if target.self_revive_hit():
			return t
		t += SimConfig.TICK_DELTA
	return 0.0

func _a_miss_moment(target: Node) -> float:
	return _nearest_miss(target, 0.0)

# THE NEAREST NON-WINNING MOMENT AT OR AFTER `from`. With one window in the middle
# of the countdown, almost every moment is a miss -- but a phase that parks the
# clock at an arbitrary number and calls it a miss would eventually park it on the
# window and fail for a reason that has nothing to do with what it is testing.
func _nearest_miss(target: Node, from: float) -> float:
	var t: float = from
	while t < target.rescue_total():
		target.state_timer = t
		if not target.self_revive_hit():
			return t
		t += SimConfig.TICK_DELTA
	return from

func _tick() -> void:
	world._physics_process(SimConfig.TICK_DELTA)

func _press(peer: int) -> void:
	world.scripted_inputs[peer] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2.ZERO, SimConfig.ACTION_USE)

func _press_at(peer: int, target: Node, at: float) -> void:
	target.state_timer = at
	target.self_revive_cooldown = 0.0
	_press(peer)
	_tick()
	world.scripted_inputs[peer] = func(t: int) -> Array:
		return PlayerInput.empty(t)

# A REAL LEDGE, NOT MERELY THE WORD. `mantle()` refuses unless the cell in
# `hang_dir` is solid, so setting the state on a body parked wherever it happened
# to be leaves a hang nobody can ever climb out of -- which is what the first
# version of this did, and it failed saying "it does not haul you off a ledge"
# about a rig with no ledge in it.
#
# SEARCHED RATHER THAN HARDCODED. A fixed cell index is a claim about the fixture
# that goes stale the day the fixture changes, and this file would then fail
# talking about the mantle again.
func _hang(target: Node) -> void:
	var base: Vector2i = world.grid.cell_of_world(target.position)
	for step in range(0, 10):
		var cell: Vector2i = base + Vector2i(0, step)
		if world.grid.is_solid(cell + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH]):
			target.position = world.grid.cell_surface_world(cell) 				+ Vector3(0.0, -0.9, 0.0)
			break
	target.hang_dir = GridConfig.DIR_NORTH
	target.state = PlayerBody.State.LEDGE_HANG
	target.state_timer = 0.0
	target.self_revive_cooldown = 0.0
