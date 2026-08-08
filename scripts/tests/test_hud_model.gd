extends "res://scripts/test_support/test_case.gd"

# MVP criterion D5, the half a headless gate can actually reach.
#
# The HUD's Control tree cannot be asserted in a run that renders nothing, so
# every DECISION it makes lives in hud_model.gd instead and is checked here: which
# countdown applies to which state, how full each bar is, which slots are live,
# who counts as a friend and where they are. The nodes in hud.gd draw this and
# decide nothing, which is what makes "untested view" an acceptable trade.
#
# The assertion this test exists for is the LEDGE_HANG/DOWNED pair. They are the
# same machinery on purpose (see SimConfig) but they run on four different
# durations -- 8s and 15s to bleed out, 0.8s and 1.5s to be pulled out -- so one
# field means four different things depending on state, and getting that wrong
# produces a bar that is plausibly wrong rather than obviously broken.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null

func setup(main) -> void:
	world = Node3D.new()
	world.name = "HudModelWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)

	_check_shape()
	_check_slots()
	_check_grace_and_health()
	_check_bearing()
	_check_downed()
	_check_hanging()
	_check_no_world()
	finish()

func _own() -> Dictionary:
	return HudModel.build(world)["own"]

func _friends() -> Array:
	return HudModel.build(world)["friends"]

# --- A walking player has nothing to report -----------------------------------

func _check_shape() -> void:
	var model: Dictionary = HudModel.build(world)
	check(bool(model["active"]), "a world with a local avatar produces a live model")

	var own: Dictionary = model["own"]
	eq(int(own["peer"]), 1, "'own' describes the local peer")
	eq(int(own["health"]), SimConfig.MAX_HEALTH, "a player starts at full health")
	eq(str(own["state_label"]), "", "a walking player gets no state banner")

	# NO_BAR, not 0.0. Zero would mean "this bar applies and is empty", which on
	# screen is a bleed-out about to expire -- a crisis reported for a player who
	# is simply walking around.
	eq(own["bleed_out"], HudModel.NO_BAR, "and no bleed-out bar")
	eq(own["rescue"], HudModel.NO_BAR, "and no rescue bar")
	check(not bool(own["needs_help"]), "and is not asking for help")

	var friends: Array = model["friends"]
	eq(friends.size(), 1, "the other player is one friend row")
	eq(int(friends[0]["peer"]), 2, "and it is the other peer, not us")

# --- Three slots, one of them live --------------------------------------------

func _check_slots() -> void:
	var slots: Array = _own()["slots"]
	eq(slots.size(), 3, "three action slots, per D5")
	eq(str(slots[0]["id"]), "push", "push first")
	check(bool(slots[0]["filled"]), "push is live")
	check(bool(slots[0]["ready"]), "and ready when the dash is off cooldown")
	# Empty is a STATE, not an absence: the view draws these deliberately blank
	# rather than omitting them, so the layout does not move when M4 and M12 land.
	check(not bool(slots[1]["filled"]), "rope is empty until M4")
	check(not bool(slots[2]["filled"]), "special is empty until M12")

	a.shove_cooldown = SimConfig.SHOVE_COOLDOWN * 0.5
	slots = _own()["slots"]
	check(not bool(slots[0]["ready"]), "a cooling dash is not ready")
	near(float(slots[0]["cooldown"]), 0.5, 0.02, "and reports how much is left")
	a.shove_cooldown = 0.0

# --- Health, and the grace window that is currently unknowable -----------------

func _check_grace_and_health() -> void:
	a.health = 3
	a.invulnerable = SimConfig.HIT_GRACE * 0.5
	var own: Dictionary = _own()
	eq(int(own["health"]), 3, "health is reported as taken")
	eq(int(own["max_health"]), SimConfig.MAX_HEALTH, "against the real maximum")
	near(float(own["grace"]), 0.5, 0.02, "and the grace window is visible at all (B7)")

	a.invulnerable = 0.0
	near(float(_own()["grace"]), 0.0, 0.001, "expiring back to nothing")
	a.health = SimConfig.MAX_HEALTH

# --- Where a friend is, since they are routinely off screen --------------------

func _check_bearing() -> void:
	a.position = Vector3.ZERO

	# NORTH is up the bridge, which is -Z.
	b.position = Vector3(0.0, 0.0, -10.0)
	var friend: Dictionary = _friends()[0]
	near(float(friend["distance"]), 10.0, 0.01, "distance to a friend up-bridge")
	near(float(friend["bearing"]), 0.0, 0.001, "who bears due north")
	eq(Hud.compass_point(float(friend["bearing"])), "N", "and reads as N")

	b.position = Vector3(10.0, 0.0, 0.0)
	friend = _friends()[0]
	near(float(friend["bearing"]), PI * 0.5, 0.001, "bearing runs clockwise from north")
	eq(Hud.compass_point(float(friend["bearing"])), "E", "so +X is E")

	b.position = Vector3(-7.07, 0.0, -7.07)
	eq(Hud.compass_point(float(_friends()[0]["bearing"])), "NW", "and the diagonals resolve")

	b.position = Vector3(0.0, 0.0, 4.0)
	eq(Hud.compass_point(float(_friends()[0]["bearing"])), "S", "behind you is S")

# --- DOWNED: 15s to bleed out, 1.5s to be revived -----------------------------

func _check_downed() -> void:
	b.begin_downed()
	var friend: Dictionary = _friends()[0]
	check(bool(friend["needs_help"]), "a downed friend is asking for help")
	eq(str(friend["state_label"]), "DOWN", "and says so")
	near(float(friend["bleed_out"]), 1.0, 0.001, "with the whole countdown still to run")
	near(float(friend["rescue"]), 0.0, 0.001, "and nobody helping yet")

	b.state_timer = SimConfig.DOWNED_SECONDS * 0.25
	near(float(_friends()[0]["bleed_out"]), 0.75, 0.01,
		"the bar EMPTIES as the countdown runs down")

	b.rescue_progress = SimConfig.REVIVE_SECONDS * 0.5
	near(float(_friends()[0]["rescue"]), 0.5, 0.01, "a revive in progress is half done")

	# Past the end, clamped rather than overflowing into a bar drawn off its own
	# background.
	b.state_timer = SimConfig.DOWNED_SECONDS * 2.0
	near(float(_friends()[0]["bleed_out"]), 0.0, 0.001, "and never goes negative")

# --- LEDGE_HANG: the same fields, different durations -------------------------

func _check_hanging() -> void:
	b.state = PlayerBody.State.LEDGE_HANG
	b.state_timer = SimConfig.LEDGE_HANG_SECONDS * 0.5
	b.rescue_progress = SimConfig.LEDGE_HAUL_SECONDS * 0.5

	var friend: Dictionary = _friends()[0]
	eq(str(friend["state_label"]), "HANGING", "a hanging friend reads differently to a downed one")
	near(float(friend["bleed_out"]), 0.5, 0.01,
		"and bleeds out against LEDGE_HANG_SECONDS, not DOWNED_SECONDS")
	near(float(friend["rescue"]), 0.5, 0.01,
		"and hauls against LEDGE_HAUL_SECONDS, not REVIVE_SECONDS")

	# The proof that the two states are not sharing one duration: the same
	# state_timer means different things, because the timers differ by ~2x.
	b.state_timer = SimConfig.LEDGE_HANG_SECONDS
	near(float(_friends()[0]["bleed_out"]), 0.0, 0.001, "a full hang is spent")
	b.state = PlayerBody.State.DOWNED
	check(float(_friends()[0]["bleed_out"]) > 0.4,
		"while the SAME timer is barely half a downed player's countdown")

# --- Nothing to draw is a state, not a crash ----------------------------------

func _check_no_world() -> void:
	check(not bool(HudModel.build(null)["active"]), "no world draws nothing")

	world.stop()
	check(not bool(HudModel.build(world)["active"]), "a stopped world draws nothing")
	world.running = true

	# A client is told about avatars by a reliable RPC that has not necessarily
	# arrived yet. Not an error -- there is simply nothing to draw.
	world._despawn_player(1)
	check(not bool(HudModel.build(world)["active"]),
		"and a world that has not yet been told about the local avatar draws nothing")
