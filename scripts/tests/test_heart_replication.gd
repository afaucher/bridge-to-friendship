extends "res://scripts/test_support/test_case.gd"

# A HEART THAT IS EATEN IS EATEN ON EVERY MACHINE.
#
# Reported from a multiplayer playtest: "client doesn't see health disappear
# after pickup". A heart is built from the SEGMENT, so every machine draws one
# from the seed -- and nothing ever told the others it had gone. The host ate it,
# healed the player, and left a heart drawn on every other screen that could
# never be picked up again.
#
# Mounds and shooters already get told; hearts were the one destructible piece of
# authored scenery that did not. Two worlds here rather than a network, which is
# the cheaper way to make the same claim: the layout the host would SEND is
# applied to a second grid, and the question is whether that is enough to make
# them agree.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var host: Node3D = null
var client: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	# TWO WORLDS SHARE ONE PHYSICS SPACE, so they are offset by a kilometre --
	# CLAUDE.md's note, and the reason the harness has always done this.
	host = _world(main, "HeartHost", Vector3.ZERO)
	client = _world(main, "HeartClient", Vector3(1000.0, 0.0, 0.0))

func _world(main: Node, name: String, at: Vector3) -> Node3D:
	var w := Node3D.new()
	w.name = name
	w.set_script(GameWorldScript)
	main.add_child(w)
	w.position = at
	w.segment_paths = ["res://segments/test_stats.seg"]
	w.start(true, 1, false)
	return w

func _physics_process(_delta: float) -> void:
	if done or host == null or host.tick < 3:
		return
	done = true

	var before: int = host.grid.heart_count()
	check(before > 0, "the fixture really carries a heart (%d)" % before)
	eq(client.grid.heart_count(), before,
		"and both machines built it from the same seed, which is the whole reason "
		+ "nobody noticed: they agree until one of them eats it")

	# THE HOST EATS IT, by standing on it -- the real path, not by calling the
	# remover directly.
	var at: Vector3 = host.grid.cell_surface_world(Vector2i(7, 6))
	check(host.grid.try_take_heart(at), "the host takes the heart")
	eq(host.grid.heart_count(), before - 1, "and it is gone there")

	# WITHOUT THE MESSAGE THE CLIENT STILL HAS IT. This is the reported bug stated
	# as a measurement, and it is what the layout below has to fix.
	eq(client.grid.heart_count(), before,
		"the client still draws it until it is TOLD -- a heart is built from the "
		+ "segment, so nothing else would ever remove it")

	# AND THE MESSAGE IS ENOUGH. This is exactly the payload _sync_taken_hearts
	# carries, applied the way the RPC applies it.
	client.grid.apply_taken_hearts(host.grid.taken_heart_layout())
	eq(client.grid.heart_count(), before - 1,
		"once told which cell went, the client agrees")

	# IDEMPOTENT, because the layout is the WHOLE set and it is resent on every
	# pickup and again on join -- so a client applies the same cell repeatedly and
	# a late joiner applies all of them at once.
	client.grid.apply_taken_hearts(host.grid.taken_heart_layout())
	eq(client.grid.heart_count(), before - 1,
		"and applying the same layout twice takes nothing extra")
	finish()
