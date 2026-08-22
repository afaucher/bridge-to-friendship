extends "res://scripts/test_support/test_case.gd"

# Alertness: the telegraph a gunner never had, and what it does with nobody to
# shoot at.
#
# BEFORE THIS, `fire_timer` STARTED AT ZERO. A gunner picked the nearest player it
# could see and fired on the tick it acquired them, so stepping out from behind a
# pillar at 8 m was an instant round with no window to answer it. Every other
# hazard in the game announces itself first -- hazards.md calls the rusher's rise
# *the* telegraph and plinko's balls are slow on purpose -- and these were the
# exception.
#
# The claims:
#   1. IT IS SILENT FOR THE WHOLE WAKE, asserted on every tick of it rather than
#      sampled once. CLAUDE.md has the scar from a phase that checked one frame
#      and missed a bug seven frames later; where the claim is "X is safe FOR A
#      DURATION", every tick of the duration is the claim.
#   2. AND THEN IT FIRES. The other half, and the one carrying the design: an
#      enemy that never shoots passes claim 1 perfectly.
#   3. THE WAKE IS ROLLED PER ENEMY. Asserted as a property a fixed interval
#      CANNOT produce -- several gunners waking at DIFFERENT times -- rather than
#      as a tuned spread. With one constant they would all be identical.
#   4. LOSING THE TARGET MAKES IT PATROL, and "patrol" is asserted as movement.
#      It used to stand still forever, and standing still satisfies any assertion
#      about not falling off.
#   5. IT KNOWS THE GRID, so it does not patrol into a hole. Both halves again:
#      it must MOVE and it must not fall, because a body that never moved would
#      pass the second half on its own.
#   6. A BRIEF SIGHT BREAK IS NOT A RESET. Without this, bobbing in and out of
#      cover would re-buy the whole wake window every time and cover would be an
#      infinite stall.
#
# TAKING THE TARGET AWAY, two ways, and the difference is worth knowing before
# copying either. Hiding the player behind a pillar is the realistic route and is
# no good here: a gunner that patrols out from behind that cover re-acquires
# halfway through and the measurement becomes about luck. That cover blocks sight
# at all is already gated by test_gunners phase 4.
#   * Downing the player (phase 4) is a real "no target" -- `_nearest_visible_
#     player` skips anyone awaiting rescue -- and it has a FUSE on it. A solo
#     party entirely in `_returning` is a wipe, and `_restart_at_checkpoint` frees
#     every gunner in the world, so a phase using it must finish inside that
#     window and must clear `_returning` after itself.
#   * Removing the player from the roster (phase 5) has no fuse, which is what a
#     fifteen-second patrol needs. It also makes `_trailing_edge_z` infinite, so
#     the leash cannot cull the subject either.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GunnerBody = preload("res://scripts/sim/gunner_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "AlertWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# The flat fixture, with nothing else moving in it -- CLAUDE.md's note about
	# measuring on the playtest map, where live hazards tumble the subject and every
	# one of those reads as the thing under test misbehaving.
	world.segment_paths = ["res://segments/test_flat.seg"]
	# NO SPREAD, and this is not tidying -- it is the difference between a gate and
	# a coin flip. MG_SPREAD_DEG is 10, which at a skirmisher's own 12 m band is a
	# cone 4.2 m wide against a body 0.8 m wide: under one shot in five lands, so
	# "an awake gunner hurts you" measured over three shots is a 45% assertion.
	# Measured, the round that made this phase fail first time was 2 m wide of a
	# stationary player. The claim here is that it FIRES, not that its spread was
	# lucky, so the spread comes out -- the same isolation as turret_arc_deg in
	# test_gunners.
	DebugSettings.set_value("mg_spread_deg", 0.0)
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	victim = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_silent_then_fires()
		1: _phase_each_wakes_on_its_own_clock()
		2: _phase_lost_target_patrols()
		3: _phase_patrol_stays_on_the_deck()
		4: _phase_a_glance_away_is_not_a_reset()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	recorded.clear()
	_clear()

func _clear() -> void:
	for g in world._gunners:
		if is_instance_valid(g):
			g.queue_free()
	world._gunners.clear()
	for b in world._bullets:
		if is_instance_valid(b):
			b.queue_free()
	world._bullets.clear()
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	victim.state = PlayerBody.State.WALK
	# AND THE RESCUE BOOKKEEPING, or a phase that downed the player leaves peer 1
	# in `_returning` and the NEXT phase wipes on its first tick -- which frees
	# every gunner in the world and reads as a gunner that fell off the bridge.
	world._returning.clear()
	if not world.players.has(1):
		world.players[1] = victim

# --- 1 + 2. Silent through the wake, and then not ------------------------------

func _phase_silent_then_fires() -> void:
	if phase_frame == 1:
		# Along a row rather than down the bridge: 6 cells is 12 m, inside the dead
		# zone of its band (11 to 17 m), so it holds still -- a gunner walking
		# during the measurement would be changing the range as well as its
		# alertness. NOT 7 cells: that is 14 m, SKIRMISHER_RANGE exactly, and the
		# drop onto the deck leaves the 3D distance a hair OUTSIDE the range test,
		# so the first run of this phase measured a gunner that was awake and had
		# nothing to shoot at.
		_park(Vector2i(5, 10))
		recorded["id"] = _spawn(Vector2i(11, 10)).gunner_id
		recorded["health"] = int(victim.health)
		recorded["woke_at"] = 0
		return
	if _lost():
		return
	var g: Node = _tracked()

	# EVERY TICK OF THE WAKE, not a sample of it.
	if not g.is_engaged():
		if int(victim.health) < int(recorded["health"]):
			check(false, "a waking gunner fired at tick %d (alert %.2f)" % [phase_frame, g.alert])
			_advance(1)
		return

	if int(recorded["woke_at"]) == 0:
		recorded["woke_at"] = phase_frame
		check(int(victim.health) == int(recorded["health"]),
			"a gunner is silent for the whole wake (%d ticks, %.2f s)"
				% [phase_frame, phase_frame * SimConfig.TICK_DELTA])
		var took: float = phase_frame * SimConfig.TICK_DELTA
		check(took >= SimConfig.GUNNER_WAKE_MIN - 0.05 and took <= SimConfig.GUNNER_WAKE_MAX + 0.05,
			"and the wake is inside the rolled interval (%.2f s, wants %.1f-%.1f)"
				% [took, SimConfig.GUNNER_WAKE_MIN, SimConfig.GUNNER_WAKE_MAX])
		return

	# ...AND THEN IT SHOOTS. The half that carries the design: everything above is
	# also true of a gunner that has simply stopped working.
	if phase_frame > int(recorded["woke_at"]) + 240:
		check(int(victim.health) < int(recorded["health"]),
			"but an awake one does fire (%d -> %d)" % [recorded["health"], victim.health])
		_advance(1)

# --- 3. Each one rolls its own wake --------------------------------------------
#
# THE ASSERTION IS "NOT ALL THE SAME", which a single constant cannot satisfy --
# CLAUDE.md's note that an arithmetic impossibility beats a tuned threshold. A
# spread of "at least N distinct values" would be a number somebody picked; two
# gunners waking on different ticks is a proof that the roll is per enemy.

func _phase_each_wakes_on_its_own_clock() -> void:
	if phase_frame == 1:
		# Fanned out from one point, so no sight line passes through another
		# gunner, and spaced so no two are ever coincident -- two bodies in one
		# place is the through-the-floor trap.
		#
		# AHEAD OF THE PLAYER, not behind. `_process_gunners` culls anything more
		# than LEASH_HARD behind the rearmost player, so the obvious arrangement --
		# player up-bridge looking back at a line of gunners -- deletes them
		# mid-measurement, which reads as a gunner that never woke.
		_park(Vector2i(15, 11))
		recorded["ids"] = []
		recorded["woke"] = {}
		for x in [4, 9, 14, 19, 24]:
			recorded["ids"].append(_spawn(Vector2i(x, 9)).gunner_id)
		return
	var woke: Dictionary = recorded["woke"]
	for id in recorded["ids"]:
		var g: Node = world._gunner_by_id(int(id))
		if g != null and g.is_engaged() and not woke.has(id):
			woke[id] = phase_frame
	if phase_frame < int(SimConfig.GUNNER_WAKE_MAX / SimConfig.TICK_DELTA) + 30:
		return

	eq(woke.size(), int(recorded["ids"].size()), "every gunner woke")
	var ticks: Array = woke.values()
	var distinct := {}
	for t in ticks:
		distinct[t] = true
	check(distinct.size() > 1,
		"and not all on the same tick -- the wake is rolled per enemy (%s)" % [ticks])
	for t in ticks:
		var took: float = float(t) * SimConfig.TICK_DELTA
		check(took >= SimConfig.GUNNER_WAKE_MIN - 0.05 and took <= SimConfig.GUNNER_WAKE_MAX + 0.05,
			"and every roll is inside the interval (%.2f s)" % took)
	_advance(2)

# --- 4. With the target gone, it patrols ---------------------------------------

func _phase_lost_target_patrols() -> void:
	if phase_frame == 1:
		_park(Vector2i(5, 10))
		recorded["id"] = _spawn(Vector2i(11, 10)).gunner_id
		return
	if _lost():
		return
	var g: Node = _tracked()

	# Wait until it is properly engaged, then take the target away.
	if not recorded.has("dropped"):
		if g.is_engaged():
			victim.state = PlayerBody.State.DOWNED
			recorded["dropped"] = phase_frame
		return

	# It forgets. GUNNER_FORGET_SECONDS from full alert, plus a margin.
	var since: int = phase_frame - int(recorded["dropped"])
	var forget_ticks: int = int(SimConfig.GUNNER_FORGET_SECONDS / SimConfig.TICK_DELTA)
	if since < forget_ticks + 30:
		return
	if not recorded.has("rested"):
		eq(snappedf(g.alert, 0.01), 0.0,
			"a gunner with nobody in sight goes back to sleep")
		recorded["rested"] = true
		recorded["at"] = g.position
		recorded["far"] = 0.0
		return

	# ...AND THEN IT WALKS. It used to stand exactly where it was, forever.
	recorded["far"] = maxf(float(recorded["far"]), g.position.distance_to(recorded["at"]))
	if since > forget_ticks + 30 + 420:
		check(float(recorded["far"]) > 1.0,
			"and then patrols rather than standing there (%.1f m)" % recorded["far"])
		_advance(3)

# --- 5. It knows the grid ------------------------------------------------------
#
# test_flat has a hole run across columns 4..21 of row 6. A gunner posted at row 9
# can roll a patrol point on the far side of it, and the straight line to that
# point crosses the hole -- which is exactly the walk that has to stop at the lip.

func _phase_patrol_stays_on_the_deck() -> void:
	if phase_frame == 1:
		# Far across the deck but on the SAME row: distance is what makes this a
		# patrol rather than an engagement, and staying level keeps the gunner
		# inside the leash that culls anything left behind the party.
		_park(Vector2i(28, 10))
		# NOBODY TO SEE, FOR FIFTEEN SECONDS. Not by downing the player, which is
		# how phase 4 does it: a solo party entirely in `_returning` wipes to the
		# checkpoint, and `_restart_at_checkpoint` frees every gunner in the world.
		# That is correct game behaviour and fatal to a long patrol measurement, so
		# here the target simply is not in the roster -- which also makes
		# `_trailing_edge_z` infinite, taking the leash out of the picture too.
		# _clear() puts the player back.
		world.players.erase(1)
		var g: Node = _spawn(Vector2i(7, 9))
		recorded["id"] = g.gunner_id
		recorded["far"] = 0.0
		return
	if phase_frame == 30:
		if _lost(): return
		# Recorded once it has LANDED. A gunner is spawned a metre up and drops onto
		# the deck; "where it started" taken on the frame it was created is a point
		# in mid-air, and the drop then reads as the fall being asserted against.
		recorded["at"] = _tracked().position
		return
	if phase_frame < 30:
		return
	if _lost():
		check(false, "the patrolling gunner fell off the bridge")
		return
	var g: Node = _tracked()
	recorded["far"] = maxf(float(recorded["far"]), g.position.distance_to(recorded["at"]))

	# MEASURED AGAINST THE DECK UNDER IT, NOT AGAINST WHERE IT STARTED. The bridge
	# is pitched BRIDGE_PITCH_DEG, so a gunner patrolling four rows up-bridge gains
	# half a metre of world Y for doing exactly the right thing -- and the first
	# version of this check read that as a fall and failed against correct code.
	# Comparing world Y across different Z on this bridge is the recurring trap.
	var cell: Vector2i = world.grid.cell_of_world(g.position)
	if not world.grid.is_solid(cell):
		check(false, "a patrolling gunner stepped over the hole field (cell %s)" % cell)
		_advance(4)
		return
	var fell: float = world.grid.cell_surface_world(cell).y - g.position.y
	if fell > 0.6:
		check(false, "a patrolling gunner sank through the deck (%.2f m below cell %s)"
			% [fell, cell])
		_advance(4)
		return
	if phase_frame == 900:
		check(true, "a gunner patrols for 15 s beside a hole field without falling in")
		# AND THE INSTRUMENT CAN FAIL: a body that never moved would satisfy the
		# claim above on its own.
		check(float(recorded["far"]) > 1.0,
			"and it really was walking around while it did (%.1f m)" % recorded["far"])
		_advance(4)

# --- 6. A glance away is not a reset -------------------------------------------

func _phase_a_glance_away_is_not_a_reset() -> void:
	if phase_frame == 1:
		_park(Vector2i(5, 10))
		recorded["id"] = _spawn(Vector2i(11, 10)).gunner_id
		return
	if _lost():
		return
	var g: Node = _tracked()

	# Half a second into the wake, look away for half a second.
	if not recorded.has("hid"):
		if g.alert > 0.2:
			recorded["before"] = g.alert
			victim.state = PlayerBody.State.DOWNED
			recorded["hid"] = phase_frame
		return
	if phase_frame - int(recorded["hid"]) < 30:
		return
	if not recorded.has("shown"):
		victim.state = PlayerBody.State.WALK
		var before: float = float(recorded["before"])
		check(g.alert > 0.0,
			"half a second out of sight does not reset the wake (%.2f -> %.2f)"
				% [before, g.alert])
		# The rise is at most GUNNER_WAKE_MAX seconds end to end and the fall is
		# GUNNER_FORGET_SECONDS, so half a second of each is 0.25 gained against
		# 0.125 lost. The asymmetry IS the memory.
		check(before - g.alert < 0.2,
			"and costs it far less than the same time would have earned (%.3f lost)"
				% (before - g.alert))
		recorded["shown"] = true
		return
	if g.is_engaged():
		DebugSettings.set_value("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	victim.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.state = PlayerBody.State.WALK
	victim.grounded = true

func _spawn(cell: Vector2i) -> Node:
	return world._spawn_gunner(
		world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0),
		GunnerBody.Kind.SKIRMISHER)

func _tracked() -> Node:
	return world._gunner_by_id(int(recorded.get("id", 0)))

func _lost() -> bool:
	if _tracked() != null:
		return false
	check(false, "the gunner under test is gone before it was measured")
	_advance(phase + 1)
	return true
