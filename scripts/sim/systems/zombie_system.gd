extends "res://scripts/sim/systems/enemy_pool.gd"

# ZOMBIES: the first enemy that arrives as a GROUP. See design_ideas/hazards.md;
# the walk itself is in zombie_body.gd. This is the part only the host may do:
# deciding when a grave opens, how many come out, who each of them is chasing,
# and what a bite costs.

const ZombieScene = preload("res://scenes/zombie.tscn")
const Hash = preload("res://scripts/core/hash.gd")
const Layers = preload("res://scripts/core/layers.gd")

func _init() -> void:
	pool_name = "zombies"
	section_name = "zombies"
	root_name = "Zombies"
	node_prefix = "Zombie"

func _instantiate() -> Node:
	return ZombieScene.instantiate()

func spawn(at: Vector3) -> Node:
	var zombie: Node = add(_instantiate())
	zombie.begin_rise(at)
	return zombie

func host_tick() -> void:
	_wake_graves()
	_step_each(_step_zombie)

func _step_zombie(zombie: Node) -> void:
	# Re-picked per tick, like the rusher's, and it matters MORE here: a pack that
	# locked on at the moment it rose would all chase the same player forever,
	# which is the one arrangement that turns a group into a single enemy with
	# five bodies.
	var target: Node = nearest_visible(zombie)
	zombie.target_peer = int(target.peer_id) if target != null else 0
	zombie.step(target.position if target != null else Vector3.ZERO, target != null)
	if zombie.is_spent():
		retire(zombie)
		return
	_resolve_contact(zombie)

# A player within ZOMBIE_TRIGGER_RADIUS opens the grave they walked near. Same
# shape as the mounds, including the sight test -- a grave spent on a player who
# never saw it is an authored encounter consumed without ever being one, and that
# is worth three to five enemies here rather than one.
func _wake_graves() -> void:
	if world.grid == null:
		return
	# CHECKED AGAINST THE WHOLE PACK, not against one. The cap is a backstop for
	# authored density being wrong, and a grave that opens with two slots left
	# would deliver a pack of two -- which is not the hazard anybody authored. It
	# opens in full or it waits.
	if items.size() + SimConfig.ZOMBIE_PACK_MAX > SimConfig.ZOMBIE_MAX:
		return
	wake_near(world.grid.grave_cells(), world.grid.grave_surface_world,
		SimConfig.ZOMBIE_TRIGGER_RADIUS, world.grid.take_grave, _open_grave)

func _open_grave(cell: Vector2i, at: Vector3) -> void:
	spawn_pack(cell, at)
	# A grave changes state exactly ONCE in its life, so this is a discrete event
	# and goes RELIABLY -- unlike the zombies themselves, which ride the unreliable
	# per-tick snapshot. Losing this packet would leave a client drawing a slab
	# that is not there, forever, with nothing later to correct it.
	if world.networked:
		world._grave_taken.rpc(cell.x, cell.y)

# THE PACK. Three to five bodies from one cell, arranged in a RING.
#
# THE RING IS NOT DECORATION. Two perfectly coincident bodies depenetrate into a
# degenerate normal that drives both of them DOWN through the deck -- measured,
# and in CLAUDE.md as the trap every placement in this game has to answer. This is
# the most concentrated instance of it the project has: five bodies, one cell, one
# tick. ZOMBIE_PACK_RADIUS leaves 1.12 m between neighbours against a body 0.9 m
# across.
#
# The count and the ring's rotation are drawn from the CELL, not from the global
# RNG. A grave is authored terrain, so what comes out of it should be the same
# thing every time that ground is replayed -- and it means a test can name a cell
# and know what it will get.
func spawn_pack(cell: Vector2i, at: Vector3) -> Array:
	var span: int = SimConfig.ZOMBIE_PACK_MAX - SimConfig.ZOMBIE_PACK_MIN + 1
	var roll: int = Hash.mix(cell.x * 73856093 + cell.y * 19349663)
	var count: int = SimConfig.ZOMBIE_PACK_MIN + (roll % span)
	# So two graves side by side do not produce two identically-oriented rings.
	var phase: float = float(Hash.mix(roll + 1) % 3600) * 0.1

	var raised: Array = []
	for i in count:
		var angle: float = deg_to_rad(phase + 360.0 * float(i) / float(count))
		var slot: Vector3 = at + Vector3(sin(angle), 0.0, cos(angle)) * SimConfig.ZOMBIE_PACK_RADIUS
		# THE BACKSTOP, not the rule. The dressing pass and the validator both
		# refuse a grave without deck on all eight sides, so this should never
		# fire on authored or generated ground; it is here because the cost of
		# being wrong is a body falling off the bridge the instant it exists, and
		# because nothing downstream would report that as anything but a pack that
		# turned up short.
		if not _deck_under(slot):
			continue
		raised.append(spawn(slot))
	return raised

# Is there something to stand on beneath this point? A short downward ray against
# the deck only, from head height.
func _deck_under(at: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	if space == null:
		return true
	var from: Vector3 = world.to_global(at)
	var to: Vector3 = from - Vector3(0.0, SimConfig.ZOMBIE_HEIGHT + 1.5, 0.0)
	# The deck only. A pack member standing on another pack member's head is not
	# "there is ground here", and neither is one resting on a stone that a blast
	# is about to remove.
	return not space.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD)).is_empty()

# What a zombie does when it reaches somebody, and what a dashing player does to
# it. Resolved by proximity for the same reason every other contact is: the
# outcome is a game rule, not a physics response, decided in one place and once.
#
# STRUCTURALLY THE RUSHER'S, WITH ONE DIFFERENCE, and the difference is the whole
# enemy: a rusher is SPENT on contact, a zombie RECOILS. See recoil_from() -- with
# five of them, being spent on contact would mean the pack lands five hits and
# deletes itself, and the rule that exists to stop one enemy chain-tumbling a
# helpless player would be protecting nobody.
func _resolve_contact(zombie: Node) -> void:
	if not zombie.is_in_play():
		return
	for peer_key in world.players.keys():
		var body: Node = world.players[int(peer_key)]
		if out_of_play(int(peer_key), body):
			continue
		if body.position.distance_to(zombie.position) > SimConfig.ZOMBIE_HIT_RADIUS + PlayerBody.HALF_HEIGHT:
			continue

		# A DASHING PLAYER WINS THE EXCHANGE, checked before the hit so the two can
		# never both happen. The free answer available to everyone, which is what
		# keeps a weaponless player from being stranded in front of a pack.
		if body.state == PlayerBody.State.SHOVE:
			zombie.deflect(GridConfig.yaw_vector(body.shove_yaw))
			return

		# Already deflected, or still recovering from its last bite, so it cannot
		# collect on a counter it lost. `continue` rather than `return`: this
		# zombie is harmless to THIS player, but another player may still be
		# mid-dash and entitled to bat it further.
		if not zombie.is_dangerous():
			continue

		# A CHANCE OF A TUMBLE, ROLLED PER CONTACT. A rusher always tumbles because
		# it only gets to do it once; a zombie gets to do it repeatedly, and a
		# hazard that reliably takes your control away every time it touches you is
		# one you cannot play out of.
		#
		# Below the roll it is damage and NOTHING ELSE -- receive_hit tumbles on any
		# push at all, so "no tumble" has to mean no knockback. That reads as being
		# bitten rather than run over, which is what it is.
		var tumbles: bool = zombie._draw() < SimConfig.ZOMBIE_TUMBLE_CHANCE
		var push: float = SimConfig.ZOMBIE_KNOCKBACK if tumbles else 0.0
		var lift: float = SimConfig.ZOMBIE_KNOCKBACK_LIFT if tumbles else 0.0
		body.receive_hit(Hit.make(Hit.Kind.IMPACT, SimConfig.ZOMBIE_DAMAGE,
			zombie.position, push, lift))
		# KNOCKED OFF, NOT KILLED. Unconditional -- it happens whether or not the
		# damage landed, because a player inside HIT_GRACE has still been walked
		# into and a zombie that stayed pressed against them would bite again the
		# tick the grace expires, forever.
		zombie.recoil_from(body.position)
		return
