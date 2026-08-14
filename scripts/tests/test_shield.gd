extends "res://scripts/test_support/test_case.gd"

# M15c. The shield: anchors you, and refuses everything from one direction.
#
# The claims:
#   1. IT ANCHORES YOU. Full movement input while it is up moves you nowhere, on
#      EVERY tick it is up -- being unable to leave is the price of not being
#      moved, and it is the only special that takes something away from you.
#   2. IT REFUSES WHAT IS IN FRONT, entirely: no damage AND no knockback. A shield
#      that stopped the damage but not the shove would be worthless in a game
#      whose threat model is being put somewhere you did not choose.
#   3. IT DOES NOTHING ABOUT WHAT IS BEHIND. **This is the claim carrying the
#      design** -- a shield that worked in every direction is just invulnerability,
#      and flanking one is the answer the geometry is supposed to supply.
#   4. IT IS UNBLOCKABLE FROM UNDERFOOT, which is how a mine counters somebody who
#      has decided to stop moving. A blast beneath you has no direction to be in.
#   5. THE LAST CHARGE WORKS. A shield spends its use as it RISES, so a naive
#      "spent means gone" deletes the third deployment in the tick it was raised.

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
var walking := Vector2.ZERO
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "ShieldWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	holder = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if raising else 0
		return [t, walking, actions, holder.facing]

func _physics_process(_delta: float) -> void:
	if holder == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_anchors_you()
		1: _phase_refuses_the_front()
		2: _phase_ignores_the_back()
		3: _phase_underfoot_gets_through()
		4: _phase_the_last_charge_works()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	raising = false
	walking = Vector2.ZERO
	holder.shielding = false
	holder.health = SimConfig.MAX_HEALTH
	holder.invulnerable = 0.0

# --- 1. Anchored --------------------------------------------------------------

func _phase_anchors_you() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		# RUNNING FIRST, and this matters more than it looks. Raising a shield from
		# a standstill is anchored by the early return alone, so a test that starts
		# parked passes even with the velocity zeroing deleted -- found by A/B, and
		# the case it could not see is the only one where that zeroing does
		# anything: raise it mid-stride and you must stop DEAD, not skate on.
		#
		# DOWN-BRIDGE, because test_flat has an authored hole one cell NORTH of
		# here: the first version of this ran into it, caught the ledge, and a
		# LEDGE_HANG drops your special -- so the shield under test had been thrown
		# on the floor before the assertion ran. Nothing in the failure said so.
		walking = Vector2(0.0, 1.0)
		return
	if phase_frame == 30:
		check(holder.velocity.length() > 3.0,
			"the holder is genuinely running before the shield goes up (%.1f m/s)"
				% holder.velocity.length())
		raising = true
		return
	if phase_frame == 33:
		recorded["at"] = holder.position
		return
	# EVERY TICK, not a single late sample: "you cannot move for a duration" is a
	# claim about the duration, and one read at the end cannot see a body that
	# drifted and came back.
	if phase_frame > 33 and phase_frame < 90:
		var moved: float = Vector2(holder.position.x - recorded["at"].x,
			holder.position.z - recorded["at"].z).length()
		if moved > 0.35:
			check(false, "a raised shield anchors you (%.2f m on frame %d)"
				% [moved, phase_frame])
			_advance(1)
		return
	if phase_frame == 90:
		check(holder.shielding, "and it is genuinely up")
		# AND THE INSTRUMENT IS VALIDATED: drop it and the same stick moves you, so
		# the assertion above is about the shield rather than about a rig that
		# never pressed anything.
		raising = false
		return
	if phase_frame == 130:
		var moved: float = Vector2(holder.position.x - recorded["at"].x,
			holder.position.z - recorded["at"].z).length()
		check(moved > 1.0, "and releasing it lets you walk again (%.2f m)" % moved)
		_advance(1)

# --- 2 and 3. The front and the back ------------------------------------------

func _phase_refuses_the_front() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		raising = true
		return
	if phase_frame == 20:
		check(holder.shielding, "the shield is up before anything is thrown at it")
		recorded["health"] = int(holder.health)
		recorded["at"] = holder.position
		# Yaw 0 is north, which is -Z, so a source further along -Z is dead ahead.
		var taken: bool = holder.receive_hit(Hit.make(Hit.Kind.BULLET, 2,
			holder.position + Vector3(0.0, 0.0, -6.0), 12.0, 3.0))
		check(not taken, "and it refuses what is in front of it")
		return
	if phase_frame == 24:
		eq(int(holder.health), int(recorded["health"]), "no damage got through")
		var moved: float = Vector2(holder.position.x - recorded["at"].x,
			holder.position.z - recorded["at"].z).length()
		check(moved < 0.35, "and no knockback either (%.2f m) -- displacement IS the threat"
			% moved)
		_advance(2)

func _phase_ignores_the_back() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		raising = true
		return
	if phase_frame == 20:
		recorded["health"] = int(holder.health)
		# Same shield, same tick, opposite side: +Z is behind a body facing north.
		var taken: bool = holder.receive_hit(Hit.make(Hit.Kind.BULLET, 2,
			holder.position + Vector3(0.0, 0.0, 6.0), 12.0, 3.0))
		check(taken, "but it does nothing about what is behind you -- flanking is the answer")
		return
	if phase_frame == 24:
		check(int(holder.health) < int(recorded["health"]),
			"and that one hurt (%d -> %d)" % [recorded["health"], holder.health])
		_advance(3)

# --- 4. Underfoot -------------------------------------------------------------

func _phase_underfoot_gets_through() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		_arm()
		raising = true
		return
	if phase_frame == 20:
		recorded["health"] = int(holder.health)
		# A blast at the feet, from inside SHIELD_MIN_BLOCK_DISTANCE. There is no
		# direction for it to be in, which is exactly why a mine answers a shield.
		var taken: bool = holder.receive_hit(Hit.make(Hit.Kind.EXPLOSIVE,
			SimConfig.BLAST_DAMAGE, holder.position + Vector3(0.1, -0.8, 0.1),
			SimConfig.BLAST_PUSH, SimConfig.BLAST_LIFT))
		check(taken, "a blast beneath your feet is not in the arc -- a mine is the counter")
		return
	if phase_frame == 24:
		check(int(holder.health) < int(recorded["health"]),
			"and it lands (%d -> %d)" % [recorded["health"], holder.health])
		_advance(4)

# --- 5. The last charge -------------------------------------------------------

func _phase_the_last_charge_works() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5), 0.0)
		# ONE USE LEFT. A shield spends its charge as it RISES, so this is the
		# deployment a naive "spent means gone" destroys in the tick it was raised.
		_arm(1)
		raising = true
		return
	if phase_frame == 20:
		check(holder.shielding, "the LAST charge still raises a shield")
		check(_held() != null, "and the shield survives being spent while it is up")
		recorded["health"] = int(holder.health)
		var taken: bool = holder.receive_hit(Hit.make(Hit.Kind.BULLET, 2,
			holder.position + Vector3(0.0, 0.0, -6.0), 12.0, 3.0))
		check(not taken, "and it still blocks")
		return
	if phase_frame == 40:
		# Released: now it is spent and gone, because an empty special in a one-slot
		# rule is the worst thing you can be carrying.
		raising = false
		return
	if phase_frame == 60:
		check(not holder.shielding, "dropping it ends the shield")
		check(_held() == null, "and a spent shield is gone once it is down")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i, yaw: float) -> void:
	holder.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	holder.velocity = Vector3.ZERO
	holder.state = PlayerBody.State.WALK
	holder.grounded = true
	holder.facing = yaw

func _arm(ammo: int = -1) -> void:
	for s in world._specials.all():
		world._specials.destroy(s)
	var sh: Node = world._specials.spawn_loose(holder.position,
		SpecialBody.Kind.SHIELD, ammo)
	sh.hold(1)

func _held() -> Node:
	return world._specials.held_by(1)
