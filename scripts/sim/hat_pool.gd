extends RefCounted

# Every hat in the world, and the rules about who gets one.
#
# THE REAL DELIVERABLE OF M8.5 IS THE CARRIED-ITEM CHANNEL, not hats. A hat is
# carried, contested, droppable state that belongs to a player and is NOT part of
# their body -- and the game had no such channel. Player state is capture_state()
# (per-tick, predicted, reconciled); world state is grid cells and stone bodies.
# This is neither, and hearts and specials are its second and third clients.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const HatScene = preload("res://scenes/hat.tscn")

# The body's own radius, so "within pickup radius" is measured from the edge of a
# player rather than from their centre line.
const PLAYER_HALF_WIDTH := 0.4

# HOW CLOSE COUNTS AS A DEAD HEAT.
#
# Without this the tie-break is dead code. The plan says ascending peer id breaks
# a tie and that ties are not rare -- they are what two players symmetric about a
# hat produce. But two bodies that started symmetric are never EXACTLY equidistant
# once a physics tick has moved them, so a tie-break written on float equality
# would never fire once, and the winner of every "tie" would be decided by
# rounding noise instead of by a stated rule.
#
# 5 cm against a 70 cm pickup radius: wide enough that genuine symmetry lands
# inside it, narrow enough that a player who is actually nearer still wins.
const TIE_EPSILON := 0.05

var _hats: Array = []
var _root: Node3D = null

# Host-assigned and monotonic. See hat_body.hat_id for why this is not an index.
var _next_id: int = 0

func attach(root: Node3D) -> void:
	_root = root

func count() -> int:
	return _hats.size()

func all() -> Array:
	return _hats

func by_id(id: int) -> Node:
	for hat in _hats:
		if is_instance_valid(hat) and hat.hat_id == id:
			return hat
	return null

func worn_by(peer: int) -> Array:
	var out: Array = []
	for hat in _hats:
		if is_instance_valid(hat) and hat.mode == HatBody.Mode.WORN and hat.owner_peer == peer:
			out.append(hat)
	out.sort_custom(func(a, b): return a.stack_index < b.stack_index)
	return out

# --- Host: creating and destroying --------------------------------------------

# RANDOM STYLE, DETERMINISTIC SHAPE, and the two are not in tension.
#
# The id is rolled here so the same authored cell turns up a tiny pillbox one run
# and an enormous floppy thing the next -- the surprise is the point. What must
# never be random is the SHAPE for a given id: that is a pure function (see
# hat_style.gd), the id travels on the wire, and so every machine draws the same
# hat and a stolen one stays the hat it was.
#
# Host only. A client never invents a hat; it is told the id and the style.
func spawn_loose(at: Vector3, style: int = -1) -> Node:
	var hat: Node3D = HatScene.instantiate()
	_next_id += 1
	hat.hat_id = _next_id
	if style < 0:
		style = randi()
	hat.style_id = style
	hat.name = "Hat_%d" % hat.hat_id
	_root.add_child(hat)
	_hats.append(hat)
	hat.place_loose(at)
	return hat

# A hat this machine has been TOLD about rather than created. Clients only: the
# id comes from the host, so it must not touch _next_id.
func adopt(id: int, style: int) -> Node:
	var hat: Node3D = HatScene.instantiate()
	hat.hat_id = id
	hat.style_id = style
	hat.name = "Hat_%d" % id
	_root.add_child(hat)
	_hats.append(hat)
	return hat

func destroy(hat: Node) -> void:
	var index: int = _hats.find(hat)
	if index >= 0:
		_hats.remove_at(index)
	if is_instance_valid(hat):
		hat.queue_free()

func clear() -> void:
	for hat in _hats:
		if is_instance_valid(hat):
			hat.queue_free()
	_hats.clear()

# --- Host: the per-tick pass --------------------------------------------------

# Age the flying hats, drop the ones that left the world, and keep the loose
# population inside its cap.
#
# THE CULL IS NOT OPTIONAL. An endless run scattering hats leaks bodies forever;
# the oldest loose hat goes first, so the debris behind the party clears rather
# than the hat somebody is walking toward.
func step(trailing_z: float) -> void:
	for i in range(_hats.size() - 1, -1, -1):
		var hat: Node = _hats[i]
		if not is_instance_valid(hat):
			_hats.remove_at(i)
			continue
		if hat.mode == HatBody.Mode.WORN:
			continue
		hat.step()
		# Off the bottom of the world, or behind the streaming window.
		if hat.is_gone() or hat.position.z > trailing_z:
			_hats.remove_at(i)
			hat.queue_free()

	var loose: Array = []
	for hat in _hats:
		if is_instance_valid(hat) and hat.mode != HatBody.Mode.WORN:
			loose.append(hat)
	# Oldest first: ids are monotonic, so a lower id is an older hat.
	loose.sort_custom(func(a, b): return a.hat_id < b.hat_id)
	while loose.size() > SimConfig.HAT_MAX_LOOSE:
		destroy(loose.pop_front())

# WHO GETS THE HAT, and this is the part the plan warns about.
#
# RESOLVED IN ITS OWN PASS, AFTER EVERY BODY HAS STEPPED -- never inline in the
# step loop. GameWorld._carry_order() is a topological sort over who is standing
# on whom, so the order players step in CHANGES with the stack. Deciding contests
# inside that loop would mean a player being carried systematically wins or loses
# hat races depending on who they happened to be standing on: an
# ordering-dependent gameplay outcome hiding inside a function written for an
# entirely different reason.
#
# EXCLUSIVITY IS THE B8 SHAPE: two players reaching one hat, exactly one gets it.
# Nearest wins; ASCENDING PEER ID BREAKS THE TIE, and the tie is not rare -- it is
# what happens when two players are symmetric about a hat, which is precisely the
# situation a race produces.
#
# Returns the pickups it decided, as [[hat, peer], ...], so the caller can send
# them reliably. Deciding and announcing are separate on purpose.
func resolve_pickups(players: Dictionary, can_carry: Callable, worn_count: Callable) -> Array:
	var claimed: Array = []
	var peers: Array = players.keys().duplicate()
	peers.sort()

	# Counted WITHIN the pass, not read fresh per hat. A dash down a line of loose
	# hats collects several in one tick -- which is one of the better moments this
	# milestone can produce, and is exactly why the cap has to be tracked here
	# rather than trusted to a count that only updates once the pickups are
	# applied.
	var taken: Dictionary = {}
	for peer_key in peers:
		taken[int(peer_key)] = int(worn_count.call(int(peer_key)))

	for hat in _hats:
		if not is_instance_valid(hat) or not hat.is_collectable():
			continue

		var winner: int = 0
		var best: float = INF
		for peer_key in peers:
			var peer: int = int(peer_key)
			var body: Node = players[peer]
			if not can_carry.call(peer, body):
				continue
			if int(taken[peer]) >= SimConfig.HAT_MAX_STACK:
				continue
			var d: float = body.position.distance_to(hat.position)
			if d > SimConfig.HAT_PICKUP_RADIUS + PLAYER_HALF_WIDTH:
				continue
			# MEANINGFULLY nearer to win. Inside TIE_EPSILON the two are the same
			# distance as far as the rule is concerned, so the peer already held
			# keeps it -- and `peers` is ascending, so that is the lower id.
			if d < best - TIE_EPSILON:
				best = d
				winner = peer

		if winner != 0:
			claimed.append([hat, winner, int(taken[winner])])
			taken[winner] = int(taken[winner]) + 1
	return claimed
