extends RefCounted

# Every special in the world, and the rules about who is holding one.
#
# THE SECOND CLIENT OF THE CARRIED-ITEM CHANNEL M8.5 BUILT, which is what that
# milestone said it was for: carried, contested, droppable state belonging to a
# player and not part of their body. Deliberately a sibling of hat_pool.gd rather
# than a generalisation of it -- the two share a shape but not a rule. Hats stack
# and pop on a tumble; a special is one slot and survives one.
#
# See implementation_plans/m12_machine_gun.md.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const SpecialScene = preload("res://scenes/special.tscn")

# The body's own radius, so "within pickup radius" is measured from the edge of a
# player rather than from their centre line.
const PLAYER_HALF_WIDTH := 0.4

# How close counts as a dead heat. Same value and same argument as
# HatPool.TIE_EPSILON: two players symmetric about a pickup are never EXACTLY
# equidistant once a physics tick has moved them, so a tie-break written on float
# equality never fires and every "tie" is settled by rounding noise.
const TIE_EPSILON := 0.05

var _specials: Array = []
var _root: Node3D = null

# Host-assigned and monotonic. See special_body.special_id for why this is not an
# index.
var _next_id: int = 0

func attach(root: Node3D) -> void:
	_root = root

func count() -> int:
	return _specials.size()

func all() -> Array:
	return _specials

func by_id(id: int) -> Node:
	for s in _specials:
		if is_instance_valid(s) and s.special_id == id:
			return s
	return null

# What this peer is holding, or null. THE ONE SLOT, expressed as a lookup rather
# than as a field on the player: the player owns no item state at all, which is
# what keeps every item out of capture_state() by construction instead of by
# discipline.
func held_by(peer: int) -> Node:
	for s in _specials:
		if is_instance_valid(s) and s.mode == SpecialBody.Mode.HELD and s.owner_peer == peer:
			return s
	return null

# --- Host: creating and destroying --------------------------------------------

func spawn_loose(at: Vector3, kind: int = SpecialBody.Kind.MACHINE_GUN,
		ammo: int = -1, authored: bool = false) -> Node:
	var s: Node3D = SpecialScene.instantiate()
	_next_id += 1
	s.special_id = _next_id
	s.kind = kind
	s.authored = authored
	s.ammo = ammo if ammo >= 0 else _full_ammo(kind)
	s.name = "Special_%d" % s.special_id
	_root.add_child(s)
	_specials.append(s)
	s.apply_kind_look()
	s.place_loose(at)
	return s

# A special this machine has been TOLD about rather than created. Clients only:
# the id comes from the host, so it must not touch _next_id.
func adopt(id: int, kind: int) -> Node:
	var s: Node3D = SpecialScene.instantiate()
	s.special_id = id
	s.kind = kind
	s.name = "Special_%d" % id
	_root.add_child(s)
	_specials.append(s)
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

static func _base_ammo(kind: int) -> int:
	match kind:
		SpecialBody.Kind.MACHINE_GUN:
			return SimConfig.MG_AMMO
		SpecialBody.Kind.GRENADE:
			return SimConfig.GRENADE_AMMO
		SpecialBody.Kind.MINE:
			return SimConfig.MINE_AMMO
		SpecialBody.Kind.SHIELD:
			return SimConfig.SHIELD_AMMO
		SpecialBody.Kind.ROCKET:
			return SimConfig.ROCKET_AMMO
		SpecialBody.Kind.LEGS:
			return SimConfig.LEGS_AMMO
		SpecialBody.Kind.SHOTGUN:
			return SimConfig.SHOTGUN_AMMO
		SpecialBody.Kind.RIFLE:
			return SimConfig.RIFLE_AMMO
		SpecialBody.Kind.HEAVY:
			return SimConfig.HEAVY_AMMO
	return 0

func destroy(s: Node) -> void:
	var index: int = _specials.find(s)
	if index >= 0:
		_specials.remove_at(index)
	if is_instance_valid(s):
		s.queue_free()

func clear() -> void:
	for s in _specials:
		if is_instance_valid(s):
			s.queue_free()
	_specials.clear()

# --- Host: the per-tick pass --------------------------------------------------

# Age the dropped specials, remove the ones that left the world, and keep the
# loose population inside its cap.
func step(trailing_z: float) -> void:
	for i in range(_specials.size() - 1, -1, -1):
		var s: Node = _specials[i]
		if not is_instance_valid(s):
			_specials.remove_at(i)
			continue
		if s.mode == SpecialBody.Mode.HELD:
			continue
		s.step()
		# Off the bottom of the world, or behind the streaming window. FALLING
		# DESTROYS IT, exactly as it destroys hats: leaving a free weapon at the
		# spot that just killed you would rescue the one failure the design does
		# not rescue.
		if s.is_gone() or s.position.z > trailing_z:
			_specials.remove_at(i)
			s.queue_free()

	# THE CAP BOUNDS LITTER, NOT THE LEVEL. Authored pickups are excluded, because
	# an author who places twelve gets twelve -- the alternative, measured
	# 2026-08-14, is that the twelfth silently deletes the FIRST, and the first is
	# the rack beside the spawn. Nothing errors and nothing logs; the specials are
	# simply not there.
	#
	# Authored ones are still culled by the streaming window a few lines above, so
	# walking a long bridge does not accumulate them forever.
	var loose: Array = []
	for s in _specials:
		if is_instance_valid(s) and s.mode != SpecialBody.Mode.HELD and not s.authored:
			loose.append(s)
	# Oldest first: ids are monotonic, so a lower id is an older special.
	loose.sort_custom(func(a, b): return a.special_id < b.special_id)
	while loose.size() > SimConfig.SPECIAL_MAX_LOOSE:
		destroy(loose.pop_front())

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
	var peers: Array = players.keys().duplicate()
	peers.sort()

	# Tracked WITHIN the pass. A player who took one special this tick must not
	# also take the next one along -- otherwise walking down a line of pickups
	# swaps through all of them and leaves a trail of dropped weapons, which is
	# the one-slot rule doing the opposite of what it is for.
	var taken: Dictionary = {}

	for s in _specials:
		if not is_instance_valid(s) or not s.is_collectable():
			continue

		var winner: int = 0
		var best: float = INF
		for peer_key in peers:
			var peer: int = int(peer_key)
			if taken.has(peer):
				continue
			var body: Node = players[peer]
			if not can_carry.call(peer, body):
				continue
			var d: float = body.position.distance_to(s.position)
			if d > SimConfig.SPECIAL_PICKUP_RADIUS + PLAYER_HALF_WIDTH:
				continue
			# MEANINGFULLY nearer to win. Inside TIE_EPSILON the two are the same
			# distance as far as the rule is concerned, so the peer already held
			# keeps it -- and `peers` is ascending, so that is the lower id.
			if d < best - TIE_EPSILON:
				best = d
				winner = peer

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
