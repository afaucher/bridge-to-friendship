extends "res://scripts/test_support/test_case.gd"

# M15b. The two enemies that shoot.
#
# TWO TYPES OVER A SHARED BASE -- skirmisher_body.gd and turret_body.gd. They
# share how a round leaves a barrel and disagree about everything else, which is
# what phases 3 and 5 are for.
#
# The claims:
#   1. A skirmisher HOLDS A BAND. Too far and it closes, too near and it backs
#      off. That is what makes it an enemy with a POSITION it wants rather than a
#      target it runs at, which is the whole reason it is different from a rusher.
#   2. It does not back off the bridge. A body that retreats until it falls is a
#      comedy nobody authored, and it hands the player a free kill for walking
#      forwards.
#   3. A TURRET IGNORES A DASH and dies to a round. **This is the claim carrying
#      the design**: if the free verb answered it, the weapon specials would lose
#      another customer -- which hazards.md warns about twice -- and the turret
#      would be a rusher that cannot walk.
#   4. Both need line of sight to fire. A gun that shoots through a pillar has no
#      counter-play at all, and cover is the entire answer to these.
#   5. A TURRET CANNOT SHOOT OUTSIDE ITS ARC, and both halves are asserted --
#      CLAUDE.md's "half a gate is not a gate": a turret that never fires passes
#      the first half perfectly, so the same target inside the arc must be shown
#      to get hit.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GunnerBody = preload("res://scripts/sim/gunner_body.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "GunnerWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# The flat fixture, with nothing else moving in it. CLAUDE.md's note: measuring
	# on the playtest map means live hazards tumbling the subject, and every one of
	# those reads as the thing under test misbehaving.
	world.segment_paths = ["res://segments/test_flat.seg"]
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
		0: _phase_holds_its_band()
		1: _phase_will_not_back_off_the_edge()
		2: _phase_turret_ignores_a_dash()
		3: _phase_needs_line_of_sight()
		4: _phase_turret_arc()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
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

# --- 1. It holds a band -------------------------------------------------------

func _phase_holds_its_band() -> void:
	if phase_frame == 1:
		# ONE END OF THE FIXTURE TO THE OTHER. test_flat is 12 rows -- 24 m -- so
		# an offset of SKIRMISHER_RANGE * 2 put the gunner off the end of the map,
		# where it fell and was culled. Twenty metres is outside the band and
		# still on the bridge.
		_park(Vector2i(15, 1))
		recorded["id"] = _spawn(Vector2i(15, 11), GunnerBody.Kind.SKIRMISHER).gunner_id
		recorded["start"] = float(_tracked().position.distance_to(victim.position))
		return
	if phase_frame == 150:
		if _lost(): return
		var now: float = float(_tracked().position.distance_to(victim.position))
		check(now < float(recorded["start"]) - 2.0,
			"a skirmisher too far away CLOSES (%.1f m -> %.1f m)" % [recorded["start"], now])
		check(now > SimConfig.SKIRMISHER_RANGE - SimConfig.SKIRMISHER_BAND * 2.0,
			"and stops in its band rather than running into your face (%.1f m, wants %.1f)"
				% [now, SimConfig.SKIRMISHER_RANGE])
		_advance(1)

# --- 2. It will not reverse off the deck --------------------------------------

func _phase_will_not_back_off_the_edge() -> void:
	if phase_frame == 1:
		# Two cells from the up-bridge end of the fixture, with the player right on
		# top of it -- so the only way to restore its band is backwards, off the
		# map.
		_park(Vector2i(15, 10))
		recorded["id"] = _spawn(Vector2i(15, 11), GunnerBody.Kind.SKIRMISHER).gunner_id
		recorded["y"] = _tracked().position.y
		return
	if phase_frame == 120:
		# BY ID, never by holding the node. Assigning a freed object to a typed var
		# raises before is_instance_valid can answer, and the raise silently aborts
		# the rest of the frame -- which is how the first run of this test presented
		# as a timeout rather than a failure.
		var g: Node = _tracked()
		check(g != null, "a skirmisher crowded at the edge is still on the bridge")
		if g != null:
			check(g.position.y > float(recorded["y"]) - 2.0,
				"and has not reversed off it (%.2f m of drop)"
					% (float(recorded["y"]) - g.position.y))
		_advance(2)

# --- 3. A turret ignores a dash and dies to a round ---------------------------

func _phase_turret_ignores_a_dash() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 9))
		recorded["id"] = _spawn(Vector2i(15, 7), GunnerBody.Kind.TURRET).gunner_id
		return
	# RECORDED ONCE IT HAS LANDED, not on the frame it was created. A gunner is
	# spawned a metre above the deck and drops onto it, so "where it was" taken at
	# frame 1 is a point in mid-air — and the assertion three frames later was
	# measuring the last of that fall, passing only because the remaining drop
	# happened to be under the margin. It stopped being under the margin the day an
	# unrelated change upstream moved the timeline by a frame, which is the tell
	# that the sample was never isolated. Same note as CLAUDE.md's ramp sweep.
	if phase_frame == 20:
		if _lost(): return
		recorded["at"] = _tracked().position
		return
	if phase_frame == 24:
		if _lost(): return
		var g: Node = _tracked()
		# A dash arriving, built as the hit a dash actually makes.
		var moved: bool = g.receive_hit(Hit.make(Hit.Kind.IMPACT, 0, victim.position,
			SimConfig.SHOVE_TRANSFER_SPEED, SimConfig.SHOVE_TRANSFER_LIFT))
		check(not moved, "a dash does NOTHING to a turret -- the free verb is not the answer")
		check(g.position.distance_to(recorded["at"]) < 0.1,
			"and it has not been shifted (%.2f m)" % g.position.distance_to(recorded["at"]))

		# ...but a round ends it, which is what makes it a customer for the weapon
		# specials at all.
		check(g.receive_hit(Hit.make(Hit.Kind.BULLET, SimConfig.MG_DAMAGE,
			victim.position, SimConfig.MG_KNOCKBACK, SimConfig.MG_KNOCKBACK_LIFT)),
			"but a round does")
		check(g.is_spent(), "and it is spent")
		_advance(3)

# --- 4. Cover works -----------------------------------------------------------

func _phase_needs_line_of_sight() -> void:
	if phase_frame == 1:
		# The pillar authored at cell (22, 8) in test_flat, with the player on one
		# side and a turret on the other.
		_park(Vector2i(22, 4))
		recorded["id"] = _spawn(Vector2i(22, 11), GunnerBody.Kind.TURRET).gunner_id
		recorded["health"] = int(victim.health)
		return
	if phase_frame == 240:
		eq(int(victim.health), int(recorded["health"]),
			"a gunner cannot shoot through a pillar -- cover is the whole answer to these")
		# AND THE INSTRUMENT IS VALIDATED: step out and it does hurt, so the
		# assertion above is about cover rather than about a gun that never fires.
		_park(Vector2i(18, 4))
		return
	if phase_frame == 600:
		check(int(victim.health) < int(recorded["health"]),
			"but out of cover it does (%d -> %d)" % [recorded["health"], victim.health])
		_advance(4)

# --- 5. The arc ---------------------------------------------------------------
#
# THE REASON A TURRET IS ITS OWN TYPE. An arc is meaningless on something that can
# turn to face you, so this is the claim that could not have been a flag on a
# skirmisher.
#
# BOTH HALVES ARE ASSERTED, because a turret that never fires would pass the
# first one perfectly -- and CLAUDE.md has the scar from exactly that shape.

func _phase_turret_arc() -> void:
	if phase_frame == 1:
		DebugSettings.set_value("turret_arc_deg", 90.0)
		_park(Vector2i(15, 5))
		var g: Node = _spawn(Vector2i(15, 11), GunnerBody.Kind.TURRET)
		recorded["id"] = g.gunner_id
		# Bolted looking the other way. The player is a clear 12 m down an empty
		# lane -- in range, in sight, and squarely behind the gun.
		recorded["toward"] = GridConfig.yaw_of_vector(
			Vector3(victim.position.x - g.position.x, 0.0, victim.position.z - g.position.z))
		g.mount_yaw = float(recorded["toward"]) + PI
		recorded["health"] = int(victim.health)
		return
	if phase_frame == 300:
		if _lost(): return
		eq(int(victim.health), int(recorded["health"]),
			"a turret does not shoot behind itself -- flanking is an answer the geometry gives free")
		# Now swing the MOUNT round, not the player. Same distance, same sight
		# line, same everything: the only thing that changed is the arc.
		_tracked().mount_yaw = float(recorded["toward"])
		return
	if phase_frame == 800:
		check(int(victim.health) < int(recorded["health"]),
			"but the same target inside the arc gets hit (%d -> %d)"
				% [recorded["health"], victim.health])
		DebugSettings.set_value("turret_arc_deg", SimConfig.TURRET_ARC_DEG)
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	victim.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.state = PlayerBody.State.WALK
	victim.grounded = true

func _spawn(cell: Vector2i, kind: int) -> Node:
	return world._spawn_gunner(
		world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0), kind)

func _tracked() -> Node:
	return world._gunner_by_id(int(recorded.get("id", 0)))

func _lost() -> bool:
	if _tracked() != null:
		return false
	check(false, "the gunner under test is gone before it was measured")
	_advance(phase + 1)
	return true
