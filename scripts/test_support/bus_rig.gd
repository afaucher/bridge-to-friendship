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
	# THROUGH THE DASH, so every test that wants a bus is also one more run over
	# the wiring that produces one.
	world.resolve_shove_contact(world.player_body(world.players.keys()[0]), post, 0.0)
	return world._buses[world._buses.size() - 1] if world._buses.size() > 0 else null
