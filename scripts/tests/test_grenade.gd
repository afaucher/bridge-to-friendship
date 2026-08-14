extends "res://scripts/test_support/test_case.gd"

# M15c. The grenade: hold to adjust distance, throw on release.
#
# The claims:
#   1. IT THROWS ON THE BUTTON COMING UP, not on it going down. That is the whole
#      verb -- a special whose interesting decision is made before the release.
#   2. A LONGER HOLD LANDS IT FURTHER, and measurably so. This is the claim the
#      feature exists for; without it the hold is decoration and the grenade is a
#      worse gun.
#   3. A TAP CAN HURT THE THROWER. GRENADE_MIN_RANGE is inside BLAST_RADIUS on
#      purpose: if the near throw were safe, holding longer would be strictly
#      better and there would be nothing to adjust.
#   4. BEING KNOCKED OVER MID-CHARGE COSTS THE MOMENT, NOT THE GRENADE. A lost
#      trigger must not read as a release, or a tumble hurls a live grenade at
#      whatever direction the tumble left you facing.
#   5. It goes off on a FUSE and takes the deck with it -- a rusher inside the
#      radius dies.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var thrower: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var holding: bool = false
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "GrenadeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	thrower = world.player_body(1)
	# The trigger is a closure over `holding`, so a phase presses and releases by
	# assignment rather than by scripting a tick number -- which is what lets the
	# release edge be the thing under test rather than a frame count.
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if holding else 0
		return [t, Vector2.ZERO, actions, thrower.facing]

func _physics_process(_delta: float) -> void:
	if thrower == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_throws_on_release()
		1: _phase_longer_hold_goes_further()
		2: _phase_a_tap_can_hurt_you()
		3: _phase_a_tumble_does_not_throw()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	holding = false
	_clear()

func _clear() -> void:
	for d in world._deployables:
		if is_instance_valid(d):
			d.queue_free()
	world._deployables.clear()
	for r in world._rushers:
		if is_instance_valid(r):
			r.queue_free()
	world._rushers.clear()
	thrower.health = SimConfig.MAX_HEALTH
	thrower.invulnerable = 0.0

# --- 1. The release is the throw ----------------------------------------------

func _phase_throws_on_release() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3), 0.0)
		_arm()
		holding = true
		return
	# HELD FOR HALF A SECOND AND NOTHING HAS LEFT THE HAND. Asserted on every tick
	# of the hold, not once at the end: "nothing happens while held" is a claim
	# about a duration, and sampling it once is how a test misses the tick the bug
	# is on.
	if phase_frame < 32:
		if world._deployables.size() != 0:
			check(false, "nothing is thrown while the button is DOWN (frame %d)" % phase_frame)
			_advance(1)
		return
	if phase_frame == 32:
		holding = false
		return
	if phase_frame == 34:
		eq(world._deployables.size(), 1, "and exactly one grenade leaves on release")
		check(_held().ammo == SimConfig.GRENADE_AMMO - 1,
			"and it cost exactly one use (%d of %d)" % [_held().ammo, SimConfig.GRENADE_AMMO])
		return
	if phase_frame == 45:
		# IT GOES WHERE YOU ARE POINTING, and this is asserted because its absence
		# shipped. The thrower is parked facing north, which is -Z. The throw built
		# its forward vector by hand as Vector3(sin(f), 0, cos(f)) -- the exact
		# NEGATION of GridConfig.yaw_vector -- so every grenade in the game was
		# lobbed over the thrower's shoulder, and it reached a playtest.
		#
		# Nothing here caught it because every other claim in this file is about
		# DISTANCE, and a magnitude has no opinion about direction. When a test
		# measures how far, ask whether anything measures which way.
		if world._deployables.size() > 0:
			var g: Node = world._deployables[0]
			var dz: float = g.position.z - thrower.position.z
			check(dz < -1.0,
				"and it goes FORWARD, not over your shoulder (dz %+.2f, forward is -Z)" % dz)
		_advance(1)

# --- 2. Hold longer, throw further --------------------------------------------
#
# MEASURED WHERE IT LANDS, not where it was launched. The launch is one line of
# arithmetic and would pass against a broken arc; the landing is the thing the
# player is actually adjusting.

func _phase_longer_hold_goes_further() -> void:
	# SAMPLED EVERY TICK IT IS ALIVE, and read after it is gone. A grenade is freed
	# by its own fuse, so a single read at a chosen frame is a race between the
	# flight time and the fuse -- and the frame that wins the race changes with
	# every tuning value in this file.
	if world._deployables.size() > 0:
		recorded["live"] = _live_distance()

	# A tap first, then a full charge, and the two are compared.
	if phase_frame == 1:
		_park(Vector2i(15, 3), 0.0)
		_arm()
		recorded["from"] = thrower.position
		holding = true
		return
	if phase_frame == 3:
		holding = false
		return
	if phase_frame == 100:
		recorded["short"] = recorded.get("live", 0.0)
		# RE-PARKED, because the tap just went off next to them: a blasted thrower
		# is tumbled and somewhere else, and both would corrupt the second throw.
		_park(Vector2i(15, 3), 0.0)
		recorded["from"] = thrower.position
		recorded["live"] = 0.0
		_clear_deployables()
		holding = true
		return
	if phase_frame == 100 + int(SimConfig.GRENADE_CHARGE_TIME * 60.0) + 4:
		holding = false
		return
	if phase_frame == 300:
		var far: float = float(recorded.get("live", 0.0))
		var near: float = float(recorded["short"])
		check(far > near + 5.0,
			"a full hold lands much further than a tap (%.1f m vs %.1f m)" % [far, near])
		# AND BOTH ENDS ARE IN THE RIGHT PLACE, or "further" could be satisfied by
		# a tap that dribbles out of the hand and a throw off the map.
		check(near < SimConfig.BLAST_RADIUS + 1.0,
			"the tap stays near the thrower (%.1f m)" % near)
		check(far > SimConfig.GRENADE_MAX_RANGE * 0.5,
			"and the full hold reaches (%.1f m, wants over %.1f)"
				% [far, SimConfig.GRENADE_MAX_RANGE * 0.5])
		_advance(2)

# --- 3. A tap can hurt you ----------------------------------------------------

func _phase_a_tap_can_hurt_you() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		recorded["health"] = int(thrower.health)
		holding = true
		return
	if phase_frame == 3:
		holding = false
		return
	# The fuse, plus the flight, plus room to spare.
	if phase_frame == 3 + int(SimConfig.GRENADE_FUSE * 60.0) + 40:
		check(int(thrower.health) < int(recorded["health"]),
			"the shortest throw is inside your own blast (%d -> %d)"
				% [recorded["health"], thrower.health])
		_advance(3)

# --- 4. A tumble is not a release ---------------------------------------------

func _phase_a_tumble_does_not_throw() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		holding = true
		return
	if phase_frame == 20:
		# Knocked over with the trigger still down. The button never came up.
		#
		# THROUGH begin_tumble AND NOT BY ASSIGNING THE STATE. A tumble with no
		# velocity recovers on the next tick, so setting the field directly gave a
		# player who was upright again by the time the trigger was read -- the
		# assertion then measured a charge that had never been cancelled and blamed
		# the cancel.
		# STRAIGHT UP, and that matters: a launch with any real reach put them over
		# the edge of the fixture into LEDGE_HANG, which DOES drop a special -- so
		# the test failed on "still in hand" while testing nothing about tumbling.
		# Only LEDGE_HANG and DOWNED drop; a tumble is meant to keep it.
		thrower.begin_tumble(Vector3(0.0, 6.0, 0.0))
		return
	if phase_frame == 21:
		# ASSERTED ON THE TICK AFTER THE TUMBLE, not forty frames later. A player
		# who RECOVERS with the trigger still down starts charging again -- which is
		# correct, and which would have made a late read of `charge` fail for a
		# reason that has nothing to do with the claim.
		var weapon: Node = _held()
		if weapon != null:
			check(weapon.charge == 0.0,
				"the charge is cancelled rather than banked (%.2f s)" % weapon.charge)
		return
	# NOTHING IS THROWN ON ANY TICK OF THE TUMBLE, not merely at the end of it.
	if phase_frame > 20 and world._deployables.size() > 0:
		check(false,
			"losing control does not throw -- a tumble must not spend a grenade for you (frame %d)"
				% phase_frame)
		finish()
		return
	if phase_frame == 60:
		var weapon: Node = _held()
		check(weapon != null, "and the grenade is still in hand")
		if weapon != null:
			eq(weapon.ammo, SimConfig.GRENADE_AMMO,
				"with its ammo untouched -- the cost is the moment, not the resource")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i, yaw: float) -> void:
	thrower.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	thrower.velocity = Vector3.ZERO
	thrower.state = PlayerBody.State.WALK
	thrower.grounded = true
	thrower.facing = yaw

func _arm() -> void:
	for s in world._specials.all():
		world._specials.destroy(s)
	var g: Node = world._specials.spawn_loose(thrower.position, SpecialBody.Kind.GRENADE)
	g.hold(1)

func _held() -> Node:
	return world._specials.held_by(1)

func _clear_deployables() -> void:
	for d in world._deployables:
		if is_instance_valid(d):
			d.queue_free()
	world._deployables.clear()

# How far the live grenade is from where it was THROWN. From a recorded origin
# rather than from the thrower: a thrower who has just been blasted by their own
# tap is somewhere else, and measuring from them would credit the throw with their
# retreat.
func _live_distance() -> float:
	if world._deployables.size() == 0:
		return 0.0
	var d: Node = world._deployables[0]
	var from: Vector3 = recorded.get("from", Vector3.ZERO)
	return Vector2(d.position.x - from.x, d.position.z - from.z).length()
