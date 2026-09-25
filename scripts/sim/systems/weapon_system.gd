extends "res://scripts/sim/world/world_system.gd"

# THE SPECIALS AND THE SIDEARM: picking them up and firing them. See
# implementation_plans/m12_machine_gun.md.
#
# WHAT EACH WEAPON IS lives in items/weapon_defs.gd, one row per kind. This file
# is what the rows MEAN: how a trigger kind reads the button, and the three things
# a weapon can do when it goes off -- rounds, a thrown grenade, a laid mine.
#
# HOST ONLY, AND NEVER PREDICTED. A client has no authority to decide that a round
# hit somebody, and there is nothing to gain by guessing -- unlike walking, which
# is predicted precisely because the delay is felt. See physics_and_authority.md:
# committed actions play from host state.
#
# The items themselves stay in `world._specials` (SpecialPool), and rounds and
# deployables in their own pools; this system decides, they hold.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const PlayerBody = preload("res://scripts/sim/actors/player/player_body.gd")
const PlayerInput = preload("res://scripts/sim/actors/player/player_input.gd")
const WeaponDefs = preload("res://scripts/sim/items/weapon_defs.gd")
const Deployable = preload("res://scripts/sim/items/deployable.gd")

const Trigger = WeaponDefs.Trigger

func _init() -> void:
	pool_name = "specials"

func host_tick() -> void:
	var grid = world.grid
	if grid != null:
		for entry in grid.take_authored_special_cells():
			world._specials.spawn_loose(
				grid.cell_surface_world(entry[0]) + Vector3(0.0, 0.4, 0.0), int(entry[1]),
				-1, true)

	world._specials.step(world._trailing_edge_z())
	_resolve_pickups()
	fire_all()

# WHICH STATES MAY PICK ONE UP -- AND FIRE ONE. The same set hats use, and the
# same reason: collecting something mid-tumble removes the cost of the tumble,
# and shooting while tumbling would make a tumble free. A dash may, because a
# dash across a contested pickup is exactly the moment this rule is for.
func can_act(peer: int, body: Node) -> bool:
	if world._returning.has(peer):
		return false
	return body.state == PlayerBody.State.WALK or body.state == PlayerBody.State.SHOVE

func _resolve_pickups() -> void:
	for claim in world._specials.resolve_pickups(world.players, can_act):
		var taken: Node = claim[0]
		var peer: int = int(claim[1])
		var replaced: Node = claim[2]
		# ONE SLOT: the old one leaves the hand before the new one enters it, with
		# whatever ammo it had. Dropped a step in FRONT of the holder rather than
		# underneath them -- two bodies at identical coordinates depenetrate into a
		# degenerate normal and fall through the floor.
		if replaced != null and is_instance_valid(replaced):
			world._drop_special(replaced, world._specials.drop_offset(world.players[peer]))
			if world.networked:
				world._special_dropped.rpc(replaced.special_id, replaced.position)
		world._take_special(taken.special_id, peer)
		# OWNERSHIP GOES RELIABLY, positions ride the unreliable snapshot. Same
		# split as hats: a lost pickup that never applies is a client holding a
		# weapon the host says is on the deck, and nothing re-sends it.
		if world.networked:
			world._take_special.rpc(taken.special_id, peer)

func _trigger_held(peer: int) -> bool:
	var inp: Array = world._current_input.get(peer, PlayerInput.empty(0))
	return (int(inp[PlayerInput.ACTIONS]) & SimConfig.ACTION_SPECIAL_HELD) != 0

# One tick of everybody's trigger.
func fire_all() -> void:
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		var body: Node = world.players[peer]
		var weapon: Node = world._specials.held_by(peer)

		# NOTHING IN THE SLOT MEANS THE SIDEARM, not nothing (M24). A player whose
		# special had run out used to have no verb at all until the next rack; the
		# pistol fills the gap and needs no lifecycle to do it.
		if weapon == null:
			sidearm(peer, body)
			continue

		# AND IT COOLS WHILE A SPECIAL IS OUT. Otherwise a player who emptied a
		# machine gun mid-burst would come back to a pistol still holding the heat
		# of a fight that ended a minute ago.
		body.pistol_heat = maxf(0.0,
			body.pistol_heat - SimConfig.PISTOL_HEAT_DECAY * SimConfig.TICK_DELTA)
		weapon.fire_timer = maxf(0.0, weapon.fire_timer - SimConfig.TICK_DELTA)
		var held: bool = _trigger_held(peer)

		# LOSING CONTROL LOSES THE THROW, and that is not merely bookkeeping. If a
		# lost trigger counted as a RELEASE, being tumbled mid-charge would hurl a
		# grenade at whatever the tumble left you facing -- a special spent, by the
		# game, on your behalf. Cancelling costs the charge and keeps the ammo.
		if not can_act(peer, body):
			weapon.charge = 0.0
			weapon.was_held = false
			continue

		use(peer, body, weapon, held)
		weapon.was_held = held

		# SPENT MEANS GONE. An empty special you keep carrying is the worst possible
		# occupant of a one-slot rule: it does nothing and it stops you picking up
		# the thing that would.
		#
		# CHECKED EVERY TICK RATHER THAN ONLY WHEN A USE WAS SPENT, and NOT while a
		# shield is still up. A shield spends its use the moment it RISES, so
		# destroying on the spend would have deleted the last one in the same tick
		# it was raised -- a third deployment that protected nobody from anything.
		if weapon.is_spent() and not (WeaponDefs.trigger_of(int(weapon.kind)) == Trigger.PRESS
				and body.shielding):
			var id: int = weapon.special_id
			world._specials.destroy(weapon)
			if world.networked:
				world._special_destroyed.rpc(id)

# ONE TICK OF ONE WEAPON'S TRIGGER. Returns whether a use was spent.
func use(peer: int, body: Node, weapon: Node, held: bool) -> bool:
	var kind: int = int(weapon.kind)
	var row: Dictionary = WeaponDefs.def(kind)
	match WeaponDefs.trigger_of(kind):
		Trigger.HOLD:
			# Held down, and every interval one goes off.
			if not held or weapon.fire_timer > 0.0:
				return false
			weapon.fire_timer = WeaponDefs.interval_of(kind)
			weapon.ammo -= 1
			_fire(peer, body, weapon, row)
			return true
		Trigger.RELEASE:
			# HELD TO ADJUST DISTANCE, thrown on release. THE RELEASE EDGE IS DERIVED
			# FROM THE LEVEL BIT rather than sent as its own action, so a throw does
			# not depend on one press packet arriving -- see special_body.was_held.
			if held:
				weapon.charge = minf(weapon.charge + SimConfig.TICK_DELTA,
					SimConfig.GRENADE_CHARGE_TIME)
				return false
			if not weapon.was_held:
				return false
			var fraction: float = weapon.charge_fraction()
			weapon.charge = 0.0
			weapon.ammo -= 1
			throw_grenade(peer, body, fraction)
			return true
		Trigger.PRESS:
			# ONE USE PER DEPLOYMENT, spent when it goes up. There is no timer on the
			# shield: standing still IS the timer. The anchoring itself is decided in
			# PlayerBody._step_walk, because a client replays that function.
			if not held or weapon.was_held:
				return false
			weapon.ammo -= 1
			return true
		Trigger.PASSIVE:
			# THE BODY LAUNCHED; THIS IS THE BILL. Legs are the one special whose
			# effect is NOT applied out here: it is on the player's own vertical
			# velocity and a client predicts that, so the condition lives in the
			# function a replay re-runs and this reads the flag it raised.
			if not body.legs_fired:
				return false
			body.legs_fired = false
			weapon.ammo -= 1
			return true
	return false

func _fire(peer: int, body: Node, weapon: Node, row: Dictionary) -> void:
	match str(row.get("fire", "")):
		"rounds":
			fire_rounds(body, weapon, row)
		"mine":
			place_mine(peer, body)
		"grenade":
			throw_grenade(peer, body, 1.0)

# ROUNDS OUT OF THE BARREL: every gun. `rounds` leave on one pull (a shotgun's
# pellets), each with its own roll in the row's cone.
#
# EVERY ONE IS AIMED THROUGH aim_direction, so every gun gets point aim and the
# assist for free and the cone is applied on top. A weapon that computed its own
# direction would be outside the A/B while looking like it was in it.
func fire_rounds(body: Node, weapon: Node, row: Dictionary) -> void:
	var from: Vector3 = world._muzzle_of(weapon, body)
	var aimed: Vector3 = world.aim_direction(body, weapon)
	var spread: Array = row.get("spread", WeaponDefs.SPREAD_KNOB)
	var rocket: bool = bool(row.get("rocket", false))
	var damage: int = int(row.get("damage", SimConfig.MG_DAMAGE))
	for _i in int(row.get("rounds", 1)):
		# NO SPREAD MEANS NO ROLL, not a zero-degree roll: `_spread` draws from the
		# seeded RNG either way, and a rocket that consumed two draws per shot would
		# shift every random stream behind it.
		var direction: Vector3 = aimed if spread.is_empty() \
			else world._spread(aimed, float(spread[0]), float(spread[1]))
		world._spawn_round(from, direction, int(body.peer_id), body.get_rid(), rocket, damage)

# THE SIDEARM: one accurate shot, or a burst that goes everywhere (M24).
#
# NO AMMO AND NO OBJECT. There is nothing to decrement and nothing to destroy,
# which is why this takes a peer and a body rather than a weapon -- the pistol is
# a property of the player, so the whole item lifecycle has nothing to say about
# it and none of the pickup, drop or spend paths needed a special case.
#
# HEAT IS THE ENTIRE WEAPON. Cold it is a rifle; three rounds into a held trigger
# it is worse than the machine gun. A shot adds more heat than the gap between
# shots can bleed off, so a HELD trigger climbs and a TAPPED one does not.
#
# THE SIGHT AND THE MUZZLE COME FOR FREE, because the sidearm node carries a
# Barrel exactly as a special does -- `_muzzle_of` and `aim_direction` take it
# unchanged, so the round leaves the barrel it is drawn leaving and the laser
# points where it goes.
func sidearm(peer: int, body: Node) -> void:
	body.pistol_timer = maxf(0.0, body.pistol_timer - SimConfig.TICK_DELTA)
	body.pistol_heat = maxf(0.0,
		body.pistol_heat - SimConfig.PISTOL_HEAT_DECAY * SimConfig.TICK_DELTA)
	if not can_act(peer, body):
		return
	if not _trigger_held(peer):
		return
	if body.pistol_timer > 0.0:
		return
	var gun: Node3D = world._sidearm_of(body)
	if gun == null:
		return
	body.pistol_timer = SimConfig.PISTOL_FIRE_INTERVAL
	var spread: float = lerpf(SimConfig.PISTOL_SPREAD_DEG,
		SimConfig.PISTOL_SPREAD_HOT_DEG, clampf(body.pistol_heat, 0.0, 1.0))
	world._spawn_round(world._muzzle_of(gun, body),
		world._spread(world.aim_direction(body, gun), spread, spread),
		int(body.peer_id), body.get_rid(), false, SimConfig.PISTOL_DAMAGE)
	body.pistol_heat = minf(1.0, body.pistol_heat + SimConfig.PISTOL_HEAT_PER_SHOT)

# A BALLISTIC LOB, not a flat shot. Range is set by SPEED at a fixed angle, which
# is what makes "hold longer, throw further" one number; and an arc is what lets a
# grenade clear a parapet a bullet cannot.
#
# The near end of the range is INSIDE the blast on purpose. A tap has to be able
# to hurt you, or holding longer is strictly better and the verb is decoration.
func throw_grenade(peer: int, body: Node, fraction: float) -> void:
	var distance: float = lerpf(SimConfig.GRENADE_MIN_RANGE, SimConfig.GRENADE_MAX_RANGE,
		fraction)
	var angle: float = deg_to_rad(SimConfig.GRENADE_THROW_ANGLE_DEG)
	# THROUGH GridConfig, NOT sin/cos BY HAND. Written out longhand this was the
	# exact NEGATION of yaw_vector, so every grenade in the game was lobbed over
	# the thrower's shoulder (2026-08-14). test_grenade measured DISTANCE, which
	# has no opinion about which way anything went.
	var forward: Vector3 = GridConfig.yaw_vector(body.facing)
	# SOLVED FROM THE RELEASE POINT, NOT FROM LEVEL GROUND. The hand is 1.2 m up
	# and 0.7 m forward, and a grenade launched from a height flies further than
	# `R = v^2 sin(2a)/g` says -- see GRENADE_RELEASE_HEIGHT for what that cost.
	#
	#   0 = h + x tan(a) - g x^2 / (2 v^2 cos^2(a))   ->   v^2 = g x^2 / D
	#
	# where x is the horizontal run still to cover and h the height it falls.
	var run: float = maxf(distance - SimConfig.GRENADE_THROW_FORWARD, 0.5)
	var denom: float = 2.0 * pow(cos(angle), 2.0) \
		* (SimConfig.GRENADE_RELEASE_HEIGHT + run * tan(angle))
	var speed: float = sqrt(SimConfig.GRAVITY * run * run / denom)
	var velocity: Vector3 = forward * speed * cos(angle) + Vector3.UP * speed * sin(angle)
	var feet: float = body.global_position.y - PlayerBody.HALF_HEIGHT
	var release := Vector3(
		body.global_position.x + forward.x * SimConfig.GRENADE_THROW_FORWARD,
		feet + SimConfig.GRENADE_RELEASE_HEIGHT,
		body.global_position.z + forward.z * SimConfig.GRENADE_THROW_FORWARD)
	var d: Node = world._spawn_deployable(Deployable.Kind.GRENADE)
	d.throw_from(release, velocity, peer)

# PLACED AT YOUR FEET. A mine is the one special whose whole verb is spending
# something now to be paid back later, so there is nothing to aim -- the decision
# is WHERE you were standing and WHEN. It uses the machine gun's trigger, down to
# the timer: held lays them on a cadence, a tap lays one.
func place_mine(peer: int, body: Node) -> void:
	var spot: Array = mine_drop_point(body)
	world._spawn_deployable(Deployable.Kind.MINE).place_at(spot[0], peer, bool(spot[1]))

# WHERE A MINE GOES: at your feet, one step in front, sitting ON the deck.
#
# Returns [point, found_ground]. The downward probe is what makes it sit rather
# than drop -- placing at the feet and letting gravity do the rest puts the mine
# wherever the fall ends, which on a ramp or a moving player is not where the
# button was pressed.
func mine_drop_point(body: Node) -> Array:
	var forward: Vector3 = GridConfig.yaw_vector(body.facing)
	var feet: float = body.global_position.y - PlayerBody.HALF_HEIGHT
	var ahead := Vector3(
		body.global_position.x + forward.x * SimConfig.MINE_DROP_FORWARD,
		feet,
		body.global_position.z + forward.z * SimConfig.MINE_DROP_FORWARD)
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	if space != null:
		var from: Vector3 = ahead + Vector3(0.0, 0.5, 0.0)
		var query := PhysicsRayQueryParameters3D.create(from,
			from - Vector3(0.0, SimConfig.MINE_GROUND_PROBE + 0.5, 0.0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			# Its own half-height above the surface, so it rests ON the deck.
			return [Vector3(ahead.x, float(hit["position"].y) + 0.07, ahead.z), true]
	# Nothing under it -- placed over a hole. Left live so it falls away, which
	# costs the use and is the right answer.
	return [ahead, false]
