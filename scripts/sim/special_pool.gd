extends "res://scripts/sim/items/item_pool.gd"

# Every special in the world, and the rules about who is holding one.
#
# THE SECOND CLIENT OF THE CARRIED-ITEM CHANNEL M8.5 BUILT, which is what that
# milestone said it was for: carried, contested, droppable state belonging to a
# player and not part of their body. Deliberately a sibling of hat_pool.gd rather
# than a generalisation of it -- the two share a shape but not a rule. Hats stack
# and pop on a tumble; a special is one slot and survives one.
#
# See implementation_plans/m12_machine_gun.md.

const SpecialBody = preload("res://scripts/sim/special_body.gd")
const WeaponDefs = preload("res://scripts/sim/items/weapon_defs.gd")
const SpecialScene = preload("res://scenes/special.tscn")

# The list, the lookup, the cull and the nearest-wins rule are ItemPool's; so are
# PLAYER_HALF_WIDTH and TIE_EPSILON. What is left here is what a SPECIAL means:
# one slot, a swap, and a magazine.

func _max_loose() -> int:
	return SimConfig.SPECIAL_MAX_LOOSE

# THE CAP BOUNDS LITTER, NOT THE LEVEL. Authored pickups are excluded, because an
# author who places twelve gets twelve -- the alternative, measured 2026-08-14, is
# that the twelfth silently deletes the FIRST, and the first is the rack beside
# the spawn. Nothing errors and nothing logs; the specials are simply not there.
# Authored ones are still culled by the streaming window, so walking a long
# bridge does not accumulate them forever.
func _cap_exempt(item: Node) -> bool:
	return bool(item.authored)

# What this peer is holding, or null. THE ONE SLOT, expressed as a lookup rather
# than as a field on the player: the player owns no item state at all, which is
# what keeps every item out of capture_state() by construction instead of by
# discipline.
func held_by(peer: int) -> Node:
	for s in _items:
		if is_instance_valid(s) and s.mode == SpecialBody.Mode.HELD and s.owner_peer == peer:
			return s
	return null

# --- Host: creating and destroying --------------------------------------------

func spawn_loose(at: Vector3, kind: int = SpecialBody.Kind.MACHINE_GUN,
		ammo: int = -1, authored: bool = false) -> Node:
	var s: Node3D = SpecialScene.instantiate()
	s.kind = kind
	s.authored = authored
	s.ammo = ammo if ammo >= 0 else _full_ammo(kind)
	_add(s, "Special")
	s.apply_kind_look()
	s.place_loose(at)
	return s

# A special this machine has been TOLD about rather than created. Clients only:
# the id comes from the host, so it must not touch _next_id.
func adopt(id: int, kind: int) -> Node:
	var s: Node3D = SpecialScene.instantiate()
	s.kind = kind
	_add(s, "Special", id)
	s.apply_kind_look()
	return s

# HOW LOADED A SPECIAL ARRIVES. The one place ammo is granted, which is why the
# multiplier goes here rather than at six constants: a knob applied per-weapon is
# a knob somebody forgets to apply to the seventh weapon.
static func _full_ammo(kind: int) -> int:
	return _scaled(_base_ammo(kind))

# A MULTIPLIER, NOT SIX SLIDERS. What a playtest is answering is "do specials run
# out too fast", which is one question about the whole economy -- and the RATIO
# between a rocket's two shots and a machine gun's twenty is a design decision
# somebody made, not something a playtest should be able to scramble by accident.
#
# NEVER BELOW ONE. A special is DESTROYED on the tick its ammo hits zero, so a
# multiplier that rounded a two-shot rocket to nothing would produce a pickup that
# vanishes as you touch it -- and the player would report it as the pickup being
# broken, with no reason to suspect a debug knob.
static func _scaled(base: int) -> int:
	if base <= 0:
		return 0
	return maxi(1, int(round(float(base) * DebugSettings.tuned("ammo_multiplier", 1.0))))

# WHAT A FRESH ONE OF THESE CARRIES. Public because the bus tops a rider's weapon
# up to it every tick -- see GameWorld._process_buses, where "unlimited while
# aboard" and "you leave with a full one" are the same line rather than two rules.
static func full_ammo(kind: int) -> int:
	return _scaled(_base_ammo(kind))

static func _base_ammo(kind: int) -> int:
	return WeaponDefs.base_ammo(kind)

# --- Host: the per-tick pass --------------------------------------------------

# WHO PICKS UP WHAT.
#
# RESOLVED IN ITS OWN PASS, AFTER EVERY BODY HAS STEPPED, for the reason
# HatPool.resolve_pickups states in full: GameWorld._carry_order() sorts by who is
# standing on whom, so deciding contests inside the step loop would let a carried
# player systematically win or lose races depending on whose head they were on.
#
# ONE SLOT, AND THEREFORE A SWAP RATHER THAN A REFUSAL. Walking over a second
# special while holding one takes the new one and drops the old one where you
# stand, with whatever ammo it had left. A refusal would make the slot an upgrade
# path you can never regret; a swap makes leaving a full gun behind a decision.
#
# Returns [[special, peer, replaced_or_null], ...] so the caller can announce them
# reliably. Deciding and announcing are separate on purpose.
func resolve_pickups(players: Dictionary, can_carry: Callable) -> Array:
	var claimed: Array = []
	var peers: Array = sorted_peers(players)

	# Tracked WITHIN the pass. A player who took one special this tick must not
	# also take the next one along -- otherwise walking down a line of pickups
	# swaps through all of them and leaves a trail of dropped weapons, which is
	# the one-slot rule doing the opposite of what it is for.
	var taken: Dictionary = {}

	for s in _items:
		if not is_instance_valid(s) or not s.is_collectable():
			continue
		var eligible := func(peer: int, body: Node) -> bool:
			return not taken.has(peer) and can_carry.call(peer, body)
		var winner: int = nearest_claimant(s, players, peers, SimConfig.SPECIAL_PICKUP_RADIUS, eligible)
		if winner != 0:
			claimed.append([s, winner, held_by(winner)])
			taken[winner] = true
	return claimed

# Where a swapped-out special lands. A SMALL FIXED OFFSET, never the holder's
# exact position: two bodies at identical coordinates depenetrate into a
# degenerate normal and fall through the floor -- CLAUDE.md's oldest trap, and a
# drop happens at precisely the moment another body is standing there.
func drop_offset(body: Node) -> Vector3:
	var facing: float = float(body.facing) if "facing" in body else 0.0
	var away := Vector3(sin(facing), 0.0, cos(facing))
	return body.position + away * 0.8 + Vector3(0.0, 0.4, 0.0)
