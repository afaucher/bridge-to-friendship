extends RefCounted

# PUTTING A BUS IN A TEST WORLD, the way the game does.
#
# NOTHING BUILDS A BUS AUTOMATICALLY ANY MORE. It comes from dashing a post and
# from nowhere else, so a test that wants one has to ask for one -- and the
# honest way to ask is through the same post and the same dash the player uses,
# not by reaching for the constructor.
#
# THAT IS WORTH A SHARED HELPER RATHER THAN FIVE COPIES. Five test files need a
# bus in order to test something else about it, and five hand-rolled spawns is
# five places to quietly drift away from what the game does -- which is the trap
# where a test builds its own input and stops covering the caller.
#
# `test_bus_post` deliberately does NOT use this: it is the file about the post
# itself, so it drives the parts separately and asserts on each.

static func spawn(world: Node, cell: Vector2i = Vector2i(7, 6)) -> Node:
	if world.grid == null:
		return null
	var post = world.grid.bus_posts()[0] if world.grid.bus_posts().size() > 0 else null
	if post == null:
		world.grid._spawn_bus_post(cell)
		post = world.grid.bus_posts()[0]
	post.ready_at = 0
	# STOOD NEXT TO IT AND PRESSED E, which is what hailing a bus IS now. It used
	# to be a dash, and the dash dispatched on the collider -- so a test could hand
	# `resolve_shove_contact` the post from anywhere in the world and get a bus.
	# The new path is decided by DISTANCE, so a rig that does not move the body
	# reaches nothing, and that is the rig being honest rather than being awkward.
	var peer: int = int(world.players.keys()[0])
	var body: Node = world.player_body(peer)
	var was: Vector3 = body.global_position
	body.global_position = post.global_position + Vector3(1.0, 1.0, 0.0)
	world._use(peer, body)
	# PUT BACK. Several callers spawn a bus as setup for a claim about something
	# else entirely and would not expect their body to have moved across the level.
	body.global_position = was
	return world._buses[world._buses.size() - 1] if world._buses.size() > 0 else null
