extends "res://scripts/test_support/test_case.gd"

# PLAYTEST 2026-08-16: "the shield doesn't block shots very well."
#
# It did not block them at all, and test_shield was green the whole time.
#
# WHY THAT TEST COULD NOT SEE IT: it builds its own Hit and hands it straight to
# receive_hit, with a source six metres away. That is what a bullet OUGHT to look
# like, so the shield's arithmetic was correct and correctly tested. What was
# never exercised is the line that CONSTRUCTS the hit -- and it passed the impact
# POINT as `hit.from`, which for a round is the surface of the body it just hit,
# about 40 cm from the middle. That is inside SHIELD_MIN_BLOCK_DISTANCE, so every
# round in the game was unblockable at every angle, always.
#
# THE LESSON IS THE SHAPE, NOT THE ARITHMETIC: a test that hand-builds the input
# to the thing it is testing has not tested the caller, and the caller is where
# "where did this come from" gets decided. So this test fires a REAL round from a
# REAL muzzle and lets the sweep resolve it.
#
# The claims:
#   1. A round fired at the front of a raised shield is refused: no damage, no
#      knockback.
#   2. The same round from behind is not, so flanking is still the answer.
#   3. A POINT-BLANK round is refused too. The proximity rule that made this bug
#      lethal is about BLASTS -- its own comment says so -- and a shooter who
#      takes one step forward must not beat the answer to shooters.
#   4. A blast at the feet still gets through, which is the rule that proximity
#      clause actually exists for.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var holder: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var raising: bool = false
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "ShieldRoundWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	holder = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if raising else 0
		return [t, Vector2.ZERO, actions, holder.facing]

func _physics_process(_delta: float) -> void:
	if holder == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_front(6.0, 0.0, 1, "at range")
		1: _phase_behind()
		# TWO CASES, ONE PER HALF OF THE FIX, and they are here because the first
		# draft had neither: with both halves reverted separately the test still
		# passed, because EITHER ONE saves a square-on shot from six metres. A pair
		# of changes that a test cannot tell apart is a pair where one of them is
		# unproven.
		#
		# GRAZING gates the origin half: a round fired dead ahead but 35 cm off
		# centre strikes the front-left of the cylinder, and the bearing FROM THAT
		# POINT is about 60 degrees off north -- outside a 110-degree arc. From the
		# muzzle it is about 3 degrees.
		2: _phase_front(6.0, 0.35, 3, "grazing the shoulder")
		# POINT BLANK gates the proximity half: 0.9 m is INSIDE
		# SHIELD_MIN_BLOCK_DISTANCE even measured honestly from the muzzle.
		3: _phase_front(0.9, 0.0, 4, "point blank")
		4: _phase_blast_still_gets_through()
		5: _phase_spikes_get_through()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	raising = false
	holder.shielding = false
	holder.health = SimConfig.MAX_HEALTH
	holder.invulnerable = 0.0

func _park() -> void:
	holder.position = world.grid.cell_surface_world(Vector2i(15, 5)) + Vector3(0.0, 1.0, 0.0)
	holder.velocity = Vector3.ZERO
	holder.state = PlayerBody.State.WALK
	holder.facing = 0.0          # yaw 0 is north, which is -Z
	holder.grounded = true

func _arm() -> void:
	var weapon: Node = world._specials.spawn_loose(holder.position + Vector3(0.0, 0.5, 0.0),
		SpecialBody.Kind.SHIELD)
	weapon.hold(1)

# TICKS TO WAIT FOR A ROUND TO CROSS `distance`, plus a margin. DERIVED, because
# the fixed 20 here broke the day MG_BULLET_SPEED fell to 10 on 2026-08-22: six
# metres is 36 ticks at that speed and the window closed at 20.
#
# NOTE WHICH HALF OF THE FILE NOTICED. Only the BEHIND phase failed, because it
# is the only one asserting that damage DOES happen -- 'a shielded round does no
# damage' is satisfied just as well by a round that has not arrived yet, so the
# three front phases went on passing while testing nothing at all. That is
# CLAUDE.md's rule about rejection oracles in a new costume: the live assertion is
# the one that counts the thing HAPPENING.
func _after_flight(distance: float) -> int:
	return int(distance / (SimConfig.MG_BULLET_SPEED * SimConfig.TICK_DELTA)) + 20

# A round fired from a muzzle `distance` metres dead ahead, aimed back at the
# holder. Through _spawn_round and the sweep, deliberately: the whole bug lived
# between those two and a hand-built Hit walks straight past it.
func _fire_from_ahead(distance: float, lateral: float) -> void:
	var muzzle: Vector3 = holder.position + Vector3(lateral, 0.0, -distance)
	world._spawn_round(world.to_global(muzzle), Vector3(0.0, 0.0, 1.0), 0, RID())

# --- 1 and 3. The front, near and far -----------------------------------------

func _phase_front(distance: float, lateral: float, next: int, label: String) -> void:
	if phase_frame == 1:
		_park()
		_arm()
		raising = true
		return
	if phase_frame == 20:
		check(holder.shielding, "the shield is up (%s)" % label)
		recorded["health"] = int(holder.health)
		recorded["at"] = holder.position
		_fire_from_ahead(distance, lateral)
		return
	if phase_frame == 20 + _after_flight(distance):
		eq(int(holder.health), int(recorded["health"]),
			"a round fired %s into the front of a raised shield does no damage "
				% label
			+ "-- it was doing full damage from every angle until 2026-08-16, "
			+ "because the hit carried its IMPACT POINT where its ORIGIN belonged")
		var moved: float = Vector2(holder.position.x - recorded["at"].x,
			holder.position.z - recorded["at"].z).length()
		check(moved < 0.35, "and no knockback either (%.2f m) -- displacement IS "
			% moved + "the threat this refuses")
		_advance(next)

# --- 2. And it is still flankable ---------------------------------------------

func _phase_behind() -> void:
	if phase_frame == 1:
		_park()
		_arm()
		raising = true
		return
	if phase_frame == 20:
		recorded["health"] = int(holder.health)
		var muzzle: Vector3 = holder.position + Vector3(0.0, 0.0, 6.0)
		world._spawn_round(world.to_global(muzzle), Vector3(0.0, 0.0, -1.0), 0, RID())
		return
	if phase_frame == 20 + _after_flight(6.0):
		check(int(holder.health) < int(recorded["health"]),
			"the same round from BEHIND still hurts (%d -> %d) -- a shield that "
				% [recorded["health"], holder.health]
			+ "worked in every direction would be invulnerability, and flanking "
			+ "is what it is meant to cost")
		_advance(2)

# --- 4. The rule the proximity clause exists for ------------------------------

func _phase_blast_still_gets_through() -> void:
	if phase_frame == 1:
		_park()
		_arm()
		raising = true
		return
	if phase_frame == 20:
		check(holder.shielding, "the shield is up before the blast")
		recorded["health"] = int(holder.health)
		# Under the feet, inside SHIELD_MIN_BLOCK_DISTANCE. Scoping that clause to
		# EXPLOSIVE is half of this fix, so the half it was written for has to be
		# asserted in the same run or the next person will widen it back.
		world.blast_at(holder.position, SimConfig.BLAST_RADIUS)
		return
	if phase_frame == 40:
		check(int(holder.health) < int(recorded["health"]),
			"a blast at your feet still gets through (%d -> %d) -- it has no "
				% [recorded["health"], holder.health]
			+ "direction to be in, and a mine is how you answer somebody who has "
			+ "decided to stop moving")
		# THROUGH _advance, not by hand. Setting the phase directly skipped the
		# health and invulnerability reset, so the next phase measured a holder
		# still inside the blast's HIT_GRACE and read "no damage" as a pass.
		_advance(5)

# --- 5. Nor does it stop the floor --------------------------------------------

func _phase_spikes_get_through() -> void:
	if phase_frame == 1:
		_park()
		_arm()
		raising = true
		return
	if phase_frame == 20:
		check(holder.shielding, "the shield is up before the spikes come out")
		recorded["health"] = int(holder.health)
		# A CRUSH from well OUTSIDE the proximity distance and dead ahead, which
		# is the case a distance-based rule lets through. Spikes come up through
		# the ground: there is no direction to hold a slab against.
		var hit = Hit.new()
		hit.kind = Hit.Kind.CRUSH
		hit.amount = 1
		hit.from = holder.position + Vector3(0.0, 0.0, -2.5)
		holder.receive_hit(hit)
		return
	if phase_frame == 40:
		check(int(holder.health) < int(recorded["health"]),
			"a shield does not stop the floor (%d -> %d) -- spikes come UP through "
				% [recorded["health"], holder.health]
			+ "the ground you are standing on, so there is nothing to face")
		finish()
