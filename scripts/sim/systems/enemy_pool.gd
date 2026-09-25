extends "res://scripts/sim/world/entity_pool.gd"

# WHAT EVERY ENEMY POOL ASKS OF THE WORLD. Rushers, zombies and gunners each had
# their own copy of "who can I see", "is this player out of play", "has somebody
# walked near my trigger" and "I am done, leave a pile" -- the rusher's and the
# zombie's targeting were one loop, and the gunner's differed only in the height
# of the eye.
#
# HOST ONLY. A client's pool is a mirror filled by `apply_snapshot`; it never
# steps, targets or wakes anything, and `step()` is only called on the host.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const PlayerBody = preload("res://scripts/sim/actors/player/player_body.gd")
const Hit = preload("res://scripts/sim/combat/hit.gd")

# SOMEBODY THIS ENEMY IGNORES. Hanging off a lip, downed, or being carried back
# by the drone: waking or chasing a player with no verbs left is a punishment
# with no decision in it, and a hit on them is one nobody could have avoided.
func out_of_play(peer: int, body: Node) -> bool:
	return body.is_awaiting_rescue() or world._returning.has(peer)

# THE NEAREST PLAYER THIS BODY CAN SEE, from `eye` above its origin, or null.
#
# SIGHT IS THE WHOLE AI. Nothing here pathfinds: a rusher walks the straight line
# to what it can see, a gunner shoots at it, and a player who gets something
# solid in between has answered them. Deck, parapets and pillars block sight;
# players do not (hiding behind a friend would make the friend a shield, which is
# a mechanic this game has not decided to have).
func nearest_visible(from_body: Node, eye: float = 0.0) -> Node:
	var best: Node = null
	var best_distance := INF
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		var body: Node = world.players[peer]
		if out_of_play(peer, body):
			continue
		var d: float = body.position.distance_to(from_body.position)
		if d >= best_distance:
			continue
		if not world._clear_line(from_body.global_position + Vector3(0.0, eye, 0.0),
				body.global_position):
			continue
		best_distance = d
		best = body
	return best

# A PLAYER WALKED NEAR ONE OF `cells`, AND SAW IT: wake it. Mounds and graves.
#
# PROXIMITY AND SIGHT, not a collision: a trigger has no collider (a lump you can
# bump into is a wall), and the sight test is the same one that gates the chase
# -- otherwise a player walking past the far side of a pillar spends the trigger
# on an enemy that rises with nobody to run at. `take` consumes the cell and
# answers whether it was still there; `wake` does the rest. At most one per tick.
func wake_near(cells: Array, surface: Callable, radius: float, take: Callable,
		wake: Callable) -> void:
	for cell in cells:
		var at: Vector3 = surface.call(cell)
		for peer_key in world.players.keys():
			var body: Node = world.players[int(peer_key)]
			if out_of_play(int(peer_key), body):
				continue
			if body.position.distance_to(at) > radius:
				continue
			if not world._clear_line(world.to_global(at), body.global_position):
				continue
			if take.call(cell):
				wake.call(cell, at)
			break

# DONE: off the list, and offered a corpse. Every exit goes through here -- shot,
# burrowed, fallen, or spent on a body -- so every death is offered the same
# choice about leaving a pile.
func retire(body: Node) -> void:
	forget(body)
	world._retire_enemy(body, body.corpse_kind())

# Walk the pool once: drop the freed, retire the spent, step the rest.
func _step_each(step_one: Callable) -> void:
	for i in range(items.size() - 1, -1, -1):
		var body = items[i]
		if not is_instance_valid(body):
			items.remove_at(i)
			continue
		step_one.call(body)
