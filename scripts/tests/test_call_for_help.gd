extends "res://scripts/test_support/test_case.gd"

# CALL FOR HELP. Playtest 2026-08-23: a player should be able to ask for it, and
# it should show on screen, off screen, and in audio.
#
# THREE CHANNELS BECAUSE OF WHERE THE PARTY IS. `sound.md` opens with the reason:
# the camera frames sixty metres, every player has their own screen, and a
# teammate's crisis is invisible to you by construction. So one channel is the
# channel that happens to be pointed the wrong way -- the bar if you are not
# reading the HUD, the marker if you are not watching the edge, the sound if you
# have the volume down.
#
# The claims:
#   1. THE KEY DOES SOMETHING, and only for as long as it should. A call rises on
#      the action bit and expires on its own clock.
#   2. IT IS RATE LIMITED. Holding the button gives one call, not a siren -- the
#      open question this feature was specced with.
#   3. IT REPLICATES. `call_timer` rides capture_state, so a remote client knows
#      by the same route it knows where somebody is standing. Asserted through the
#      real blob rather than by setting the field on both sides.
#   4. THE BAR FLASHES BIGGER -- and both halves, since a bar that is always big
#      is not a signal.
#   5. THE OFFSCREEN MARKER FLASHES BIGGER, same clock, so a player in trouble
#      does ONE thing rather than several at several frequencies.
#   6. IT CAN BE CALLED FROM THE STATES THAT MATTER. Hanging off a ledge is the
#      case the feature is FOR, and a call gated on WALK would be one you cannot
#      make when you need it.
#   7. GOING DOWN CALLS BY ITSELF, at least once, THROUGH the cooldown -- and
#      keeps asking for as long as you are down.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")
const Markers = preload("res://scripts/ui/teammate_markers.gd")
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const SCREEN := Vector2(1280.0, 720.0)

var world: Node3D = null
var caller: CharacterBody3D = null
var mate: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "CallWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	caller = world.player_body(1)
	mate = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if caller == null or world.tick < 2 or done:
		return
	done = true
	set_physics_process(false)

	_it_rises_and_expires()
	_it_is_rate_limited()
	_it_replicates()
	_the_bar_flashes()
	_the_marker_flashes()
	_it_works_where_it_is_needed()
	_going_down_calls_by_itself()
	finish()

# --- 1. The key does something ------------------------------------------------

func _it_rises_and_expires() -> void:
	caller.call_timer = 0.0
	caller.call_cooldown = 0.0
	caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)
	check(caller.call_timer > 0.0, "pressing it starts a call (%.2f s)" % caller.call_timer)
	near(caller.call_timer, SimConfig.CALL_SECONDS, 0.05, "for the stated duration")

	# ...and it ends. A call that never expires is a player permanently flagged as
	# in trouble, which is the same as nobody being flagged.
	for _i in int(SimConfig.CALL_SECONDS / SimConfig.TICK_DELTA) + 4:
		caller.step(Vector2.ZERO, 0)
	eq(snappedf(caller.call_timer, 0.01), 0.0, "and it expires on its own clock")

# --- 2. And it cannot be leaned on --------------------------------------------

func _it_is_rate_limited() -> void:
	caller.call_timer = 0.0
	caller.call_cooldown = 0.0
	caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)
	var first: float = caller.call_timer

	# HELD DOWN. The bit is edge-triggered at the input, but a test that only sent
	# one edge would be asserting the input layer rather than the rule -- so this
	# sends the bit every tick, which is the worst case a lost or replayed packet
	# can produce, and the cooldown is what has to answer it.
	for _i in 60:
		caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)
	check(caller.call_timer < first,
		"a second of holding it does NOT restart the call (%.2f -> %.2f) -- the "
			% [first, caller.call_timer]
		+ "cooldown is what stops a cry for help becoming a siren")

	# And it comes back once the cooldown is spent.
	for _i in int(SimConfig.CALL_COOLDOWN / SimConfig.TICK_DELTA) + 4:
		caller.step(Vector2.ZERO, 0)
	caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)
	check(caller.call_timer > 0.0, "and it can be called again afterwards")

# --- 3. It crosses the wire ---------------------------------------------------

func _it_replicates() -> void:
	caller.call_timer = 0.0
	caller.call_cooldown = 0.0
	caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)

	# THROUGH THE REAL BLOB. capture_state/apply_state is how every other fact
	# about a player crosses, and the point of putting the call there rather than
	# in an RPC is that it cannot arrive by a route the rest of the player does
	# not.
	var blob: Array = caller.capture_state()
	mate.call_timer = 0.0
	mate.apply_state(blob)
	near(mate.call_timer, caller.call_timer, 0.001,
		"a call rides capture_state, so a remote client learns about it by the "
		+ "same route it learns where somebody is standing")

	# AND A BLOB FROM BEFORE THE FEATURE STILL APPLIES. The house pattern, and the
	# thing that makes a tail field safe to add.
	#
	# TRUNCATED TO A NAMED LENGTH, NOT TO `size() - 1`. It was the latter, and it
	# broke the day a LATER tail field was appended (self_revive_seed, 2026-08-23):
	# "drop the last one" silently became "drop the self-revive seed", the call
	# field survived, and the assertion failed claiming the tolerant read was
	# broken. **"The last field" is not "the field I mean"** as soon as somebody
	# adds another -- and every tail-field test in this project is one append away
	# from the same mistake.
	const CALL_AT := 21
	var old: Array = blob.duplicate()
	eq(blob.size() > CALL_AT, true, "call_timer is still a tail field")
	old.resize(CALL_AT)
	mate.call_timer = 0.0
	mate.apply_state(old)
	eq(snappedf(mate.call_timer, 0.01), 0.0,
		"and a snapshot from before the call existed leaves a player not calling "
		+ "rather than aborting the rest of the function")

# --- 4. The bar ---------------------------------------------------------------

func _the_bar_flashes() -> void:
	caller.call_timer = SimConfig.CALL_SECONDS
	var model: Dictionary = HudModel.build(world, 1)
	check(bool(model["own"].get("calling", false)),
		"your own row says you are calling -- pressing a key and seeing nothing "
		+ "is how a player decides it is broken")
	var friends: Array = HudModel.build(world, 2).get("friends", [])
	check(friends.size() > 0, "the caller appears in a friend's list")
	if friends.size() > 0:
		check(bool(friends[0].get("calling", false)),
			"and a FRIEND's row says so too, which is the half that matters")

	# BOTH HALVES. A bar that is always big is not a signal, and this is the
	# assertion that a permanently-flashing HUD would fail.
	caller.call_timer = 0.0
	check(not bool(HudModel.build(world, 1)["own"].get("calling", false)),
		"and a player who is not calling is not flagged")

# --- 5. The marker ------------------------------------------------------------

func _the_marker_flashes() -> void:
	# OFF SCREEN, which is the only case a marker exists for -- `place` returns
	# nothing at all for a friend you can already see.
	var far := Vector2(-400.0, 360.0)
	var quiet: Dictionary = Markers.place(far, false, SCREEN, false, _flash_on(), false)
	var loud: Dictionary = Markers.place(far, false, SCREEN, false, _flash_on(), true)
	check(not quiet.is_empty() and not loud.is_empty(), "both markers are drawn")
	if quiet.is_empty() or loud.is_empty():
		return
	print("[call] marker %.1f px quiet, %.1f px calling"
		% [float(quiet["size"]), float(loud["size"])])
	check(float(loud["size"]) > float(quiet["size"]) * 1.5,
		"a calling friend's marker is markedly bigger (%.1f vs %.1f px)"
			% [float(loud["size"]), float(quiet["size"])])
	# ...AND IT FLASHES rather than staying big. On the off beat it matches the
	# quiet one, which is what makes it keep asking instead of becoming the new
	# normal.
	var off: Dictionary = Markers.place(far, false, SCREEN, false, _flash_off(), true)
	near(float(off["size"]), float(quiet["size"]), 0.01,
		"and on the off beat it is ordinary size again -- a marker that grew and "
		+ "stayed grown is read once")
	# It still points the same way. The size must not move the marker.
	near(float(loud["angle"]), float(quiet["angle"]), 0.001,
		"and it still points at them")

# --- 6. Where it is actually needed -------------------------------------------

func _it_works_where_it_is_needed() -> void:
	caller.call_timer = 0.0
	caller.call_cooldown = 0.0
	caller.state = PlayerBody.State.LEDGE_HANG
	caller.step(Vector2.ZERO, SimConfig.ACTION_CALL)
	check(caller.call_timer > 0.0,
		"you can call while hanging off a ledge -- the states with no other verb "
		+ "are the ones the feature is FOR, and a call gated on WALK would be one "
		+ "you cannot make when you need it")
	caller.state = PlayerBody.State.WALK

# --- 7. And it does not wait to be asked ---------------------------------------

func _going_down_calls_by_itself() -> void:
	# THE COOLDOWN IS FULLY CHARGED, which is the whole claim. A player who called
	# two seconds before being tumbled is the likeliest caller there is -- they
	# already knew they were in trouble -- and under a cooldown that is consulted
	# rather than cleared, they are the one player whose collapse is silent.
	caller.call_timer = 0.0
	caller.call_cooldown = SimConfig.CALL_COOLDOWN
	caller.state = PlayerBody.State.WALK
	caller.begin_downed()
	eq(int(caller.state), int(PlayerBody.State.DOWNED), "the player is down")
	check(caller.call_timer > 0.0,
		"going down calls for help by itself (%.2f s) THROUGH a live cooldown -- "
			% caller.call_timer
		+ "the state where you most need somebody is the one where you are least "
		+ "likely to be composed enough to ask")

	# AND IT KEEPS ASKING. Two and a half seconds of call against fifteen seconds
	# of bleeding out: without the repeat a downed player is loud for a sixth of
	# their timer and silent for the part where somebody is deciding whether to
	# come. Counted as RISES rather than as ticks-with-a-call, because the thing
	# being asserted is that it is re-issued, not that it is held on.
	var calls: int = 1
	var last: float = caller.call_timer
	var quiet: int = 0
	for _i in int(SimConfig.DOWNED_SECONDS / SimConfig.TICK_DELTA):
		caller.step(Vector2.ZERO, 0)
		if caller.call_timer > last:
			calls += 1
		if caller.call_timer <= 0.0:
			quiet += 1
		last = caller.call_timer
	print("[call] %d calls over a %.0f s bleed-out, quiet for %.1f s of it"
		% [calls, SimConfig.DOWNED_SECONDS, float(quiet) * SimConfig.TICK_DELTA])
	check(calls >= 2,
		"and it keeps asking while they are down (%d calls) -- one cry at the "
			% calls
		+ "moment of a tumble is heard by whoever happened to be looking")
	# ...with gaps in it. A call that never stops is an alarm nobody can locate,
	# and it would also make the marker's flash the new normal.
	check(quiet > 0,
		"with silence between them (%.1f s) rather than one continuous siren"
			% (float(quiet) * SimConfig.TICK_DELTA))
	caller.revive()

# A moment when the crisis clock is showing, and one when it is not. Taken from
# the clock itself rather than assumed, so a change to its period cannot make
# this test quietly assert nothing.
func _flash_on() -> float:
	for i in 240:
		var t: float = float(i) * 0.01
		if CrisisFlash.on(t):
			return t
	return 0.0

func _flash_off() -> float:
	for i in 240:
		var t: float = float(i) * 0.01
		if not CrisisFlash.on(t):
			return t
	return 0.0
