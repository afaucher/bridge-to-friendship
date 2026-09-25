extends "res://scripts/sim/systems/enemy_pool.gd"

# RUSHERS: what only the host may do about them. Deciding when a mound wakes, who
# each rusher is chasing, and what a hit costs. The walk itself is rusher_body.gd;
# a client is told the results and invents none of them.

const RusherScene = preload("res://scenes/rusher.tscn")

func _init() -> void:
	pool_name = "rushers"
	section_name = "rushers"
	root_name = "Rushers"
	node_prefix = "Rusher"

func _instantiate() -> Node:
	return RusherScene.instantiate()

func spawn(at: Vector3) -> Node:
	var rusher: Node = add(_instantiate())
	rusher.begin_rise(at)
	return rusher

func host_tick() -> void:
	_wake_mounds()
	_step_each(_step_rusher)

func _step_rusher(rusher: Node) -> void:
	# Target chosen HERE, per tick, because it is a host decision. Re-picked
	# rather than locked on: a rusher that kept chasing someone who has since been
	# carried off by a drone is a rusher chasing a corpse.
	#
	# A rusher that can see nobody simply STANDS THERE. It does not wander or
	# guess: guessing needs a search behaviour, which is the pathfinding this
	# design bought its way out of -- and it pairs with the burrow timer: get
	# something solid between you and it, and outliving it is a plan.
	var target: Node = nearest_visible(rusher)
	rusher.target_peer = int(target.peer_id) if target != null else 0
	rusher.step(target.position if target != null else Vector3.ZERO, target != null)
	if rusher.is_spent():
		retire(rusher)
		return
	_resolve_contact(rusher)

# A player within RUSHER_TRIGGER_RADIUS wakes the mound they are standing near.
func _wake_mounds() -> void:
	if world.grid == null or items.size() >= SimConfig.RUSHER_MAX:
		return
	# A COPY of the keys: take_mound() erases from the dictionary being iterated.
	wake_near(world.grid.mound_cells(), world.grid.mound_surface_world,
		SimConfig.RUSHER_TRIGGER_RADIUS, world.grid.take_mound, _wake_mound)

func _wake_mound(cell: Vector2i, at: Vector3) -> void:
	spawn(at)
	# A mound changes state exactly ONCE in its life, so this is a discrete event
	# and goes reliably -- unlike the rusher itself, which rides the unreliable
	# per-tick snapshot. Losing this packet would leave a client drawing a lump
	# that is not there, forever, and nothing later would correct it.
	if world.networked:
		world._mound_taken.rpc(cell.x, cell.y)

# What a rusher does when it reaches somebody -- and what a dashing player does to
# it. Resolved here, by proximity, for the same reason ball hits are: the outcome
# is a game rule, not a physics response, and it has to be decided once.
func _resolve_contact(rusher: Node) -> void:
	if not rusher.is_in_play():
		return
	for peer_key in world.players.keys():
		var body: Node = world.players[int(peer_key)]
		if out_of_play(int(peer_key), body):
			continue
		if body.position.distance_to(rusher.position) > SimConfig.RUSHER_HIT_RADIUS + PlayerBody.HALF_HEIGHT:
			continue

		# A DASHING PLAYER WINS THE EXCHANGE. Checked before the hit, so the two
		# can never both happen -- and it is the free answer available to
		# everyone, which is what keeps a weaponless player from being stranded.
		if body.state == PlayerBody.State.SHOVE:
			rusher.deflect(GridConfig.yaw_vector(body.shove_yaw))
			return

		# ALREADY DEFLECTED, SO IT CANNOT COLLECT ON THE COUNTER IT LOST. `continue`
		# rather than `return`: this rusher is harmless to THIS player, but another
		# player may still be mid-dash and entitled to bat it further.
		#
		# Without this the dash was a counter that lost. See rusher_body's
		# is_dangerous(): the dash is six ticks, the stagger it buys is a hundred
		# and twenty, and the player spent the counter, walked into the thing they
		# had just deflected, and was tumbled by it with the cooldown still running.
		if not rusher.is_dangerous():
			continue

		# Otherwise it reaches you: tumble, one hit point, and it is SPENT.
		# Expending itself is the whole reason a single rusher cannot chain-tumble
		# someone who is already out of control and has no way to answer.
		var along := Vector3(rusher.velocity.x, 0.0, rusher.velocity.z)
		if along.length_squared() < 0.0001:
			along = (body.position - rusher.position)
			along.y = 0.0
		if along.length_squared() < 0.0001:
			along = Vector3(0.0, 0.0, 1.0)
		along = along.normalized()

		body.receive_hit(Hit.make(Hit.Kind.IMPACT, SimConfig.RUSHER_DAMAGE,
			rusher.position, SimConfig.RUSHER_KNOCKBACK, SimConfig.RUSHER_KNOCKBACK_LIFT))
		kill(rusher)
		return

# SPENT ON A BODY -- the fourth way a rusher leaves the world, and for a while it
# went out through a side door (`queue_free` directly) and so left nothing behind,
# on the one death that happens at arm's length from a player who is looking
# straight at it. `kill()` first, because `killed` already means "this ended in an
# EVENT rather than by expiring".
#
# AND IT POPS RATHER THAN CRUMPLING. The burst point is its OWN centre, so the
# pieces go outward in every direction rather than being sprayed one way; and it
# goes through `_note_death_burst` so a contact death takes the same route as an
# explosive one -- built scattered, told to clients by the same RPC.
func kill(rusher: Node) -> void:
	forget(rusher)
	if not is_instance_valid(rusher):
		return
	rusher.kill()
	world._note_death_burst(rusher, rusher.position)
	world._retire_enemy(rusher, rusher.corpse_kind())
