extends RefCounted

# WHAT A POOL OF CARRIED THINGS IS: a list of items under a root, handed out by
# id, culled behind the party and capped when loose, and claimed by whoever is
# nearest. HatPool and SpecialPool were each other's copy -- the same attach,
# count, all, by_id, destroy, clear, step and nearest-wins pickup, down to the
# same two constants -- and differed only in what a claim MEANS (a hat stacks, a
# special replaces) and which loose ones are exempt from the cap.
#
# Items here are CarriedItem subclasses: `id`, `mode`, `owner_peer`, `step()`,
# `is_gone()`, `is_collectable()`.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const CarriedItem = preload("res://scripts/sim/items/carried_item.gd")

# A player's body is this wide either side of its centre: a pickup radius is
# measured from the body's edge, not its middle.
const PLAYER_HALF_WIDTH := 0.4

# HOW CLOSE COUNTS AS A DEAD HEAT.
#
# Without this the tie-break is dead code. Ascending peer id breaks a tie, and
# ties are not rare -- they are what two players symmetric about a pickup
# produce. But two bodies that started symmetric are never EXACTLY equidistant
# once a physics tick has moved them, so a tie-break written on float equality
# would never fire once, and the winner of every "tie" would be decided by
# rounding noise instead of by a stated rule.
#
# 5 cm against a 70 cm pickup radius: wide enough that genuine symmetry lands
# inside it, narrow enough that a player who is actually nearer still wins.
const TIE_EPSILON := 0.05

var _items: Array = []
var _root: Node3D = null
var _next_id: int = 0

func attach(root: Node3D) -> void:
	_root = root

func count() -> int:
	return _items.size()

# THE LIVE ARRAY, NOT A COPY -- deliberately, because the snapshot builders walk
# it every tick and a per-tick duplicate is a cost for nothing.
#
# SO ANY LOOP THAT DESTROYS MUST `.duplicate()` FIRST. `destroy` calls
# `remove_at` on this array, and removing while iterating skips the next
# element -- which is a sweep that quietly clears half of what it was asked to.
# That shipped three times as "the items are all placed in the sky"; see
# GameWorld._discard_level_entities_past.
func all() -> Array:
	return _items

func by_id(id: int) -> Node:
	for item in _items:
		if is_instance_valid(item) and int(item.id) == id:
			return item
	return null

func destroy(item: Node) -> void:
	var index: int = _items.find(item)
	if index >= 0:
		_items.remove_at(index)
	if is_instance_valid(item):
		item.queue_free()

func clear() -> void:
	for item in _items:
		if is_instance_valid(item):
			item.queue_free()
	_items.clear()

# Into the pool under a fresh id -- or `id`, for one a client is told about.
# NAMED AFTER THE ADD (CLAUDE.md 2026-08-22: a name set before add_child is
# discarded when a sibling already has it).
func _add(item: Node, prefix: String, id: int = -1) -> Node:
	if id < 0:
		_next_id += 1
		id = _next_id
	item.id = id
	_root.add_child(item)
	item.name = "%s_%d" % [prefix, id]
	_items.append(item)
	return item

# --- Subclass hooks -----------------------------------------------------------

func _max_loose() -> int:
	return 0

# A loose item that the cap may not remove (a special the LEVEL placed).
func _cap_exempt(_item: Node) -> bool:
	return false

# --- Per tick -----------------------------------------------------------------

# Every item not being carried steps, falls out of the world, or is culled once
# the party has left it behind -- and then the OLDEST loose ones go past the cap.
# Oldest by id (ids are monotonic), so every machine removes the same one.
#
# THE CULL IS NOT OPTIONAL. An endless run scattering items leaks bodies forever;
# the oldest loose one goes first, so the debris behind the party clears rather
# than the thing somebody is walking toward.
func step(trailing_z: float) -> void:
	for i in range(_items.size() - 1, -1, -1):
		var item: Node = _items[i]
		if not is_instance_valid(item):
			_items.remove_at(i)
			continue
		if int(item.mode) == CarriedItem.MODE_CARRIED:
			continue
		item.step()
		if item.is_gone() or item.position.z > trailing_z:
			_items.remove_at(i)
			item.queue_free()
	var loose: Array = []
	for item in _items:
		if is_instance_valid(item) and int(item.mode) != CarriedItem.MODE_CARRIED \
				and not _cap_exempt(item):
			loose.append(item)
	loose.sort_custom(func(a, b): return int(a.id) < int(b.id))
	while loose.size() > _max_loose():
		destroy(loose.pop_front())

# THE NEAREST ELIGIBLE PLAYER WITHIN `radius` OF `item`, or 0.
#
# PEERS IN ID ORDER and a TIE_EPSILON margin, so two machines that see the same
# positions to within float noise hand the item to the same player -- the host
# decides, but a client's HUD and a replay must not argue about it.
func nearest_claimant(item: Node, players: Dictionary, peers: Array, radius: float,
		eligible: Callable) -> int:
	var winner: int = 0
	var best: float = INF
	for peer_key in peers:
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if not eligible.call(peer, body):
			continue
		var d: float = body.position.distance_to(item.position)
		if d > radius + PLAYER_HALF_WIDTH:
			continue
		# MEANINGFULLY nearer to win. Inside TIE_EPSILON the two are the same
		# distance as far as the rule is concerned, so the peer already held
		# keeps it -- and `peers` is ascending, so that is the lower id.
		if d < best - TIE_EPSILON:
			best = d
			winner = peer
	return winner

static func sorted_peers(players: Dictionary) -> Array:
	var peers: Array = players.keys().duplicate()
	peers.sort()
	return peers
