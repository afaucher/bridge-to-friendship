extends "res://scripts/test_support/test_case.gd"

# DASHES ARE A RESOURCE: three of them, one back every five seconds.
#
# TWO LIMITS, AND THEY ARE NOT THE SAME LIMIT. SHOVE_COOLDOWN bounds the RATE --
# you cannot spend three in a third of a second -- and the charges bound the
# TOTAL. Both are kept: without charges the dash was free and infinite, which made
# it the answer to a rusher, to a gap, and to any mistake; without the cooldown,
# three charges would just be one dash three times as long.
#
# EVERYTHING HERE IS DRIVEN BY THE INPUT BIT, never by poking the counter. The
# counter existing is not the feature -- the feature is that pressing the button a
# fourth time does nothing.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PEER := 3

var world: Node3D = null
var body: CharacterBody3D = null
var phase := 0
var phase_frame := 0
var dashes_seen := 0
var was_dashing := false

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "DashChargeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_stats.seg"]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	_hold(false)

func _hold(dashing: bool) -> void:
	var bits: int = SimConfig.ACTION_SHOVE if dashing else 0
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.make(t, Vector2(0.0, -1.0), bits)

# PINNED IN PLACE, and this is the whole reason the first version of this test was
# worthless. A dash covers 5.6 m and the fixture is 28 m long, so the body ran OFF
# THE END after three of them and caught the ledge -- and three is also the charge
# limit, so the test reported exactly the right number for entirely the wrong
# reason and passed against a build with the charge gate deleted.
#
# CLAUDE.md already carries "a rig that holds a movement input walks the player
# off the map". It cost a day when a hat stack was dropped sixteen metres away by
# a LEDGE_HANG nobody was looking at, and it cost this test its meaning until the
# two builds were run side by side and printed identical numbers.
func _pin() -> void:
	body.position = world.grid.cell_surface_world(Vector2i(7, 6)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

# Counted the way GameWorld counts one: the rising edge of the SHOVE state. The
# input is held down the whole time, so this is what says how many actually fired.
func _watch() -> void:
	var now: bool = int(body.state) == PlayerBody.State.SHOVE
	if now and not was_dashing:
		dashes_seen += 1
	was_dashing = now

func _physics_process(_delta: float) -> void:
	if body == null:
		return
	phase_frame += 1
	_watch()
	match phase:
		0: _phase_spend_them_all()
		1: _phase_wait_for_one_back()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- Three, and then nothing ----------------------------------------------------

func _phase_spend_them_all() -> void:
	if phase_frame == 1:
		eq(body.dash_charges, SimConfig.DASH_CHARGES,
			"a player starts with a full hand of dashes")
		_hold(true)
		return
	# LONG ENOUGH FOR MANY MORE THAN THREE. The cooldown is 0.35 s, so two seconds
	# of holding the button is room for five or six -- which is the point: the
	# limit under test is the CHARGES, and a window that only fits three would
	# pass against a build with no charges at all.
	_pin()
	if phase_frame < 130:
		return
	print("[dash] seen=%d charges=%d refill=%.2f state=%d"
		% [dashes_seen, body.dash_charges, body.dash_refill, body.state])
	var room: int = int(2.0 / SimConfig.SHOVE_COOLDOWN)
	check(room > SimConfig.DASH_CHARGES,
		"the window fits %d dashes at the cooldown, which is more than the %d "
			% [room, SimConfig.DASH_CHARGES]
		+ "charges -- so stopping at three is the charges doing it and not the "
		+ "clock running out")
	eq(dashes_seen, SimConfig.DASH_CHARGES,
		"holding the dash button spends exactly %d and then stops"
			% SimConfig.DASH_CHARGES)
	eq(body.dash_charges, 0, "and the hand is empty")
	check(body.dash_refill > 0.0,
		"with a charge already on its way back -- the clock starts when you SPEND, "
		+ "not when you run dry, so pacing yourself is not punished")
	_hold(false)
	_advance(1)

# --- One back, after five seconds ------------------------------------------------

func _phase_wait_for_one_back() -> void:
	_pin()
	var refill_ticks: int = int(SimConfig.DASH_REFILL_SECONDS / SimConfig.TICK_DELTA)
	# HALFWAY: still empty. Without this, "it came back" is satisfied by a charge
	# that returned instantly, which is what a refill timer that never started
	# would look like.
	if phase_frame == refill_ticks / 2:
		eq(body.dash_charges, 0,
			"halfway through the refill the hand is still empty (%.1f s in)"
				% (float(phase_frame) * SimConfig.TICK_DELTA))
		return
	if phase_frame < refill_ticks + 10:
		return
	eq(body.dash_charges, 1,
		"and after %.0f s exactly ONE is back, not the whole hand"
			% SimConfig.DASH_REFILL_SECONDS)

	# AND THE KNOB REALLY MOVES THE CAP. Read live rather than stored, so turning
	# it down mid-round takes charges away instead of leaving somebody holding
	# nine.
	DebugSettings.set_value("dash_charges", 1)
	eq(body.max_dashes(), 1, "the debug knob sets the cap")
	DebugSettings.set_value("dash_charges", SimConfig.DASH_CHARGES)
	eq(body.max_dashes(), SimConfig.DASH_CHARGES, "and puts it back")
	finish()
