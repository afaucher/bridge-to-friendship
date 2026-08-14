extends "res://scripts/test_support/test_case.gd"

# The first DESTRUCTIBLE hazard. See design_ideas/hazards.md.
#
# The claims worth defending, in the order they matter:
#
#   1. A mound wakes on proximity and is SPENT -- one rusher per mound, ever.
#   2. The rise is a TELEGRAPH: for its whole duration the thing cannot touch
#      you. That is the entire fairness argument for the hazard.
#   3. It runs at you, faster than a walk. Not "it moved" -- faster than you can
#      stroll, or it is not a decision.
#   4. LINE OF SIGHT gates both the wake and the chase. Get something solid
#      between you and it and it cannot come for you -- which is what makes the
#      burrow timer an answer rather than a formality.
#   5. Contact tumbles you, costs a hit point, and EXPENDS the rusher.
#   6. A dashing player deflects it instead, and takes nothing.
#   7. It burrows after RUSHER_LIFETIME. The floor under a weaponless player.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const RusherBody = preload("res://scripts/sim/rusher_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "RusherWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)

	check(world.grid.mound_count() >= 4,
		"the playtest map authors mounds (%d)" % world.grid.mound_count())

	world._spawn_player(1, 0)
	victim = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, recorded.get("move", Vector2.ZERO), int(recorded.get("actions", 0)))

	# Park well clear so nothing wakes before its phase asks it to.
	_park(Vector2i(7, 1))

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_wake_and_telegraph()
		1: _phase_chases_faster_than_a_walk()
		2: _phase_line_of_sight()
		3: _phase_contact_tumbles_and_spends()
		4: _phase_dash_deflects()
		5: _phase_burrows()
		6: _phase_speed_knob()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 1 & 2. Waking, and the rise that cannot hurt you -------------------------

func _phase_wake_and_telegraph() -> void:
	if phase_frame == 1:
		recorded["mounds_before"] = world.grid.mound_count()
		# TWO CELLS from the first mound (5,5) -- inside the 3-cell trigger, far
		# enough that the rusher has not reached us by the time the rise ends.
		# Standing ON it was the first version and it made the phase untestable:
		# the thing surfaced under our feet and the contact rule fired on the
		# same tick the rise finished, so what got measured was the hit.
		_park(Vector2i(3, 5))
		return
	if phase_frame == 3:
		eq(world.rusher_count(), 1, "walking up to a mound wakes exactly one rusher")
		eq(world.grid.mound_count(), int(recorded["mounds_before"]) - 1,
			"and the mound is spent")
		if world.rusher_count() > 0:
			recorded["id"] = world._rushers[0].rusher_id
		return

	# Through the WHOLE rise, taking nothing. Checked every tick rather than once
	# at the end: a single sample at the far edge would pass even if the thing had
	# hit us at tick two.
	if phase_frame > 3 and phase_frame < int(SimConfig.RUSHER_RISE_SECONDS * 60.0):
		var rusher: Node = _tracked()
		if not is_instance_valid(rusher):
			check(false, "the rusher vanished during its own rise")
			_advance(1)
			return
		if rusher.state != RusherBody.State.RISE:
			check(false, "the rise ended early at frame %d" % phase_frame)
			_advance(1)
			return
		if victim.health != SimConfig.MAX_HEALTH:
			check(false, "a RISING rusher hurt the player -- the telegraph is a lie")
			_advance(1)
			return
		return

	# Four ticks past the end of the rise: long enough to have switched state,
	# far short of the ~15 ticks it needs to cross the gap.
	if phase_frame == int(SimConfig.RUSHER_RISE_SECONDS * 60.0) + 4:
		check(victim.health == SimConfig.MAX_HEALTH,
			"a rising rusher cannot touch you for the whole telegraph")
		var rusher: Node = _tracked()
		if is_instance_valid(rusher):
			eq(rusher.state, RusherBody.State.CHASE, "and then it comes for you")
		else:
			check(false, "the rusher was gone before it ever chased")
		# The mound two cells further along must NOT have woken from the same
		# visit -- the trigger is a radius, not the whole row.
		eq(world.rusher_count(), 1, "one mound, one rusher")
		_advance(1)

# --- 3. It runs at you, faster than a walk ------------------------------------

func _phase_chases_faster_than_a_walk() -> void:
	if phase_frame == 1:
		_isolate()
		# COLUMN 6 is the open lane through the whole arena: the pillar rows
		# alternate between x 1,4,7,10,13 and x 2,5,8,11, so 6 carries neither.
		# Every phase below that wants an unobstructed run uses it.
		_park(Vector2i(6, 22))
		recorded["id"] = _place_rusher_id(Vector2i(6, 27))
		return
	if phase_frame == 20:
		if _lost_subject(): return
		recorded["gap"] = float(_tracked().position.distance_to(victim.position))
		return
	if phase_frame == 50:
		if _lost_subject(): return
		var rusher: Node = _tracked()
		var closed: float = float(recorded["gap"]) - rusher.position.distance_to(victim.position)
		# HALF A SECOND OF CLOSING, compared against what a WALK would cover in
		# the same time. "It moved" is not the claim -- the claim is that you
		# cannot stroll away from it, and only this comparison says that.
		var walk_would: float = SimConfig.WALK_SPEED * 0.5
		check(closed > walk_would,
			"a rusher closes faster than a player walks (%.2f m vs %.2f m in 0.5 s)"
				% [closed, walk_would])
		_advance(2)

# --- 4. Line of sight ---------------------------------------------------------
#
# The A/B that makes this assertion mean something: the SAME rusher, the SAME
# player, the SAME positions -- one pillar moved. If it closed the gap either way
# the sight test would be decorative.
func _phase_line_of_sight() -> void:
	if phase_frame == 1:
		_isolate()
		# COLUMN 7 carries a pillar on row 23 and none on 21 or 26, so a rusher at
		# z26 and a player at z21 stand in clear cells with solid stone between
		# them. Ten metres apart -- the SAME distance the clear-lane half below
		# uses, so the two numbers are comparable.
		_park(Vector2i(7, 21))
		recorded["id"] = _place_rusher_id(Vector2i(7, 26))
		return
	if phase_frame == 10:
		if _lost_subject(): return
		recorded["blocked_gap"] = float(_tracked().position.distance_to(victim.position))
		var rusher: Node = _tracked()
		rusher.state = RusherBody.State.CHASE
		rusher.state_timer = 0.0
		return
	if phase_frame == 60:
		if _lost_subject(): return
		var rusher: Node = _tracked()
		var closed: float = float(recorded["blocked_gap"]) - rusher.position.distance_to(victim.position)
		eq(rusher.target_peer, 0, "a rusher with a pillar in the way has no target")
		check(closed < 0.5,
			"and does not close on a player it cannot see (%.2f m)" % closed)
		recorded["blocked_closed"] = closed

		# THE OTHER HALF, and it is the one carrying the claim. Same distance, same
		# states, one column across -- into the open lane. Without it, the
		# assertion above passes just as happily on a rusher that never moves at
		# all, which is the shape of gate CLAUDE.md calls half a gate.
		_isolate()
		_park(Vector2i(6, 21))
		recorded["id"] = _place_rusher_id(Vector2i(6, 26))
		return
	if phase_frame == 70:
		if _lost_subject(): return
		recorded["clear_gap"] = float(_tracked().position.distance_to(victim.position))
		var rusher: Node = _tracked()
		rusher.state = RusherBody.State.CHASE
		rusher.state_timer = 0.0
		return
	# 45 ticks of chasing, and deliberately NOT more: from ten metres it reaches
	# contact at about tick 60, kills itself on the hit, and the measurement then
	# has no subject left. The first version sampled at 120 and reported only that
	# the rusher had vanished.
	if phase_frame == 115:
		if _lost_subject(): return
		var rusher: Node = _tracked()
		var closed: float = float(recorded["clear_gap"]) - rusher.position.distance_to(victim.position)
		eq(rusher.target_peer, 1, "down a clear lane it has one")
		check(closed > float(recorded["blocked_closed"]) + 3.0,
			"and closes on a player it CAN see (%.2f m vs %.2f m blocked)"
				% [closed, recorded["blocked_closed"]])
		_advance(3)

# --- 5. Contact tumbles you, and the rusher is spent --------------------------

func _phase_contact_tumbles_and_spends() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(6, 22))
		# Placed right next to the player and already chasing, so the outcome
		# under test is the contact and not the walk up to it.
		_place_rusher(Vector2i(6, 23))
		return
	if phase_frame == 30:
		eq(victim.health, SimConfig.MAX_HEALTH - SimConfig.RUSHER_DAMAGE,
			"a rusher that reaches you costs a hit point")
		eq(victim.state, PlayerBody.State.TUMBLE, "and tumbles you")
		# EXPENDING ITSELF is what stops one rusher chain-tumbling somebody who is
		# already out of control and has no way to answer.
		eq(world.rusher_count(), 0, "and is spent by the hit")
		_advance(4)

# --- 6. A dashing player deflects it ------------------------------------------

func _phase_dash_deflects() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(6, 22))
		return
	if phase_frame == 10:
		# A HAT STACK, because the playtest report was about hats. Health is a
		# number in a struct; a spilled stack is the thing a player actually
		# notices losing, and it is dropped by entering TUMBLE rather than by
		# taking damage -- so it is a second, independent witness to the same
		# event and it fails even if the damage rule ever changes.
		for i in 3:
			var hat: Node = world._hats.spawn_loose(victim.position)
			world._wear_hat(hat.hat_id, 1, i)
		recorded["hats"] = world.hats_worn_by(1).size()
		check(int(recorded["hats"]) == 3, "the player is wearing a stack to lose")
		return
	if phase_frame == 20:
		# Two cells UP-bridge (grid +z is world -z), which is the way a
		# move of (0, -1) dashes -- so the player runs straight into it.
		var rusher: Node = _place_rusher(Vector2i(6, 24))
		recorded["id"] = rusher.rusher_id
		recorded["rusher_z"] = rusher.position.z
		recorded["move"] = Vector2(0.0, -1.0)      # up-bridge, into it
		recorded["actions"] = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 21:
		recorded["actions"] = 0                    # a press is one tick wide
		return

	# LET GO ONCE THE PLAYER HAS WALKED PAST IT. The dash carries them through the
	# rusher and the stick is still held, so the frames either side of 60 are the
	# ones that matter: the player is on foot, out of dash cooldown, and passing
	# within a metre of the thing they just deflected. That is precisely where the
	# old behaviour tumbled them.
	#
	# Releasing here is not tidiness -- holding forward for the full two seconds
	# walks the player sixteen metres off the end of the deck into a LEDGE_HANG,
	# which drops the hat stack for reasons that have nothing to do with a rusher
	# and reads as this assertion failing. CLAUDE.md: measure on a fixture with
	# nothing else moving in it.
	if phase_frame == 70:
		recorded["move"] = Vector2.ZERO
		return
	if phase_frame == 30:
		var rusher: Node = _tracked()
		check(is_instance_valid(rusher) and world.rusher_count() == 1,
			"a dash does NOT kill a rusher -- that is the weapons' job")
		if is_instance_valid(rusher):
			eq(rusher.state, RusherBody.State.STAGGER, "it is staggered")
			check(rusher.position.z < float(recorded["rusher_z"]) - 0.3,
				"and knocked back along the dash axis (%.2f -> %.2f)"
					% [recorded["rusher_z"], rusher.position.z])
		eq(victim.health, SimConfig.MAX_HEALTH, "and the dashing player takes nothing")
		check(victim.state != PlayerBody.State.TUMBLE, "and is not tumbled")
		return

	# THE STAGGER IS A BREATHER, AND THE ASSERTION ABOVE COULD NOT SEE IT.
	#
	# Everything up to frame 30 was already true when a deflected rusher was still
	# lethal: the dash is six ticks and the tumble landed on frame 37, so this
	# phase sampled seven frames early and passed for the whole life of the bug.
	# The player kept walking into the thing they had just deflected, could not
	# dash again (SHOVE_COOLDOWN outlasts the contact), and was tumbled by it.
	#
	# So hold the stick down and stay until the stagger ENDS. This is CLAUDE.md's
	# "test the half that says something is POSSIBLE": the half saying a dash
	# cannot kill was gated, the half saying a dash SAVES YOU was not.
	#
	# THE WINDOW IS READ OFF THE RUSHER, NOT COUNTED IN FRAMES. A dash re-deflects
	# on every one of its six ticks and each one resets state_timer, so the stagger
	# ends at some frame this phase does not know. A hard-coded count either stops
	# early (and tests nothing) or runs past the end into a rusher that has
	# legitimately got back up and re-acquired -- which is the design working, and
	# would read as this assertion failing.
	if phase_frame > 30:
		var rusher: Node = _tracked()
		var still_staggered: bool = rusher != null \
			and int(rusher.state) == RusherBody.State.STAGGER

		# Checked EVERY tick, not once at the end: a tumble is transient
		# (TUMBLE_MIN_SECONDS, then back to WALK), so a single late sample would
		# miss it entirely and report a clean run over a player who was floored.
		if victim.state == PlayerBody.State.TUMBLE:
			check(false,
				"a deflected rusher tumbled the player who deflected it, %d frames in"
					% [phase_frame - 30])
			_advance(5)
			return

		if still_staggered and phase_frame < 400:
			return

		eq(victim.health, SimConfig.MAX_HEALTH,
			"and costs no health for the whole stagger it bought")
		eq(world.hats_worn_by(1).size(), int(recorded["hats"]),
			"and the hat stack survives the exchange")
		_advance(5)

# --- 7. It burrows, so a weaponless player is never stranded -------------------

func _phase_burrows() -> void:
	if phase_frame == 1:
		_isolate()
		# Out of reach: this measures the LIFETIME, not how long it took to walk
		# somewhere. It must expire on its own clock with nobody to chase.
		_park(Vector2i(7, 1))
		var rusher: Node = _place_rusher(Vector2i(6, 25))
		# Aged to just short of the limit, so the phase costs a fraction of a
		# second rather than ten of them -- the clock is what is under test, and
		# it is the same clock either way.
		rusher.age = SimConfig.RUSHER_LIFETIME - 0.5
		return
	if phase_frame == 10:
		eq(world.rusher_count(), 1, "still there just before its time is up")
		return
	if phase_frame == 60:
		eq(world.rusher_count(), 0,
			"a rusher nobody could fight burrows back down on its own")
		_advance(6)

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	victim.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.state = PlayerBody.State.WALK
	victim.grounded = true
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	victim.shove_cooldown = 0.0
	recorded["move"] = Vector2.ZERO
	recorded["actions"] = 0

# Clear the board: no rushers, no balls, and the shooters silenced so a stray
# ball cannot take a damage assertion for a ride.
func _isolate() -> void:
	for rusher in world._rushers:
		if is_instance_valid(rusher):
			rusher.queue_free()
	world._rushers.clear()
	for ball in world._balls:
		if is_instance_valid(ball):
			ball.queue_free()
	world._balls.clear()
	world.grid.shooter_cells.clear()
	# And every remaining mound, so no phase below can be derailed by waking one
	# it did not ask for.
	for cell in world.grid.mound_cells():
		world.grid.take_mound(cell)

# The rusher this phase is watching, by ID rather than by reference.
#
# NOT a stored node. Assigning a freed object to a typed `var x: Node` raises
# BEFORE is_instance_valid() gets a chance to say no -- and a raise inside
# _physics_process aborts the rest of the function silently, so the phase stops
# advancing and the whole test presents as a 90-second timeout with no clue in
# it. A rusher is a thing that dies on contact, so this is not a corner case.
# Returns null once it is gone, which every caller can handle.
func _tracked() -> Node:
	return world._rusher_by_id(int(recorded.get("id", 0)))

# A phase whose rusher has died has lost its subject. Say so, name the phase, and
# move on -- rather than raising on a null and aborting the frame, which is how
# this presented as a bare timeout twice.
func _lost_subject() -> bool:
	if _tracked() != null:
		return false
	check(false, "phase %d lost its rusher at frame %d" % [phase, phase_frame])
	_advance(phase + 1)
	return true

func _place_rusher_id(cell: Vector2i) -> int:
	return int(_place_rusher(cell).rusher_id)

# A rusher already up and running, for the phases that are not about the rise.
#
# THE POSITION MUST BE SET AFTER the state, not before. begin_rise() parks the
# body a full RUSHER_HEIGHT BELOW the deck -- that is what it emerges from -- and
# only _step_rise lifts it back out. Forcing CHASE straight afterwards skips the
# lift, so the first version of this helper left every rusher underneath the
# bridge, quietly falling. Six assertions failed and every one of them looked
# like a different bug in the rusher.
func _place_rusher(cell: Vector2i) -> Node:
	var at: Vector3 = world.grid.cell_surface_world(cell) \
		+ Vector3(0.0, SimConfig.RUSHER_HEIGHT * 0.5, 0.0)
	var rusher: Node = world._spawn_rusher(at)
	rusher.state = RusherBody.State.CHASE
	rusher.state_timer = 0.0
	rusher.position = at
	rusher.velocity = Vector3.ZERO
	rusher.grounded = true
	return rusher

# --- 7. The speed knob actually reaches the rusher -----------------------------
#
# Added 2026-08-14 with the debug console's rusher_speed_pct. The knob is a
# percentage of RUSHER_SPEED, and the failure it exists to catch is the silent
# one: a knob that replicates perfectly, shows the right number in the panel, and
# is read by nothing. Only measuring TRAVEL can tell those apart.

func _phase_speed_knob() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(6, 22))
		DebugSettings.set_value("rusher_speed_pct", 100.0)
		recorded["id"] = _place_rusher_id(Vector2i(6, 27))
		return
	if phase_frame == 20:
		if _lost_subject(): return
		recorded["from"] = _tracked().position
		return
	if phase_frame == 50:
		if _lost_subject(): return
		recorded["full"] = float(_tracked().position.distance_to(recorded["from"]))
		# Same rusher would be ideal, but it is closing on the player and would
		# reach them; a fresh one on the same lane is the honest comparison.
		_isolate()
		_park(Vector2i(6, 22))
		DebugSettings.set_value("rusher_speed_pct", 25.0)
		recorded["id"] = _place_rusher_id(Vector2i(6, 27))
		return
	if phase_frame == 70:
		if _lost_subject(): return
		recorded["from"] = _tracked().position
		return
	if phase_frame == 100:
		if _lost_subject(): return
		var quarter: float = float(_tracked().position.distance_to(recorded["from"]))
		var full: float = float(recorded["full"])
		# A QUARTER, within a generous margin -- the point is that the knob is read
		# at all, not that the arithmetic is exact under a physics sweep.
		check(quarter < full * 0.5,
			"at 25%% a rusher covers far less ground (%.2f m against %.2f m)"
				% [quarter, full])
		check(quarter > 0.05, "but is still moving, rather than switched off (%.2f m)" % quarter)
		DebugSettings.set_value("rusher_speed_pct", 100.0)
		finish()
