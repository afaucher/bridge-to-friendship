extends "res://scripts/test_support/test_case.gd"

# WHAT A DEATH COSTS, AND WHETHER IT IS PAID ONCE OR EVERY TIME.
#
# Cutting a body into 32 cells and lathing an ArrayMesh for each is real work, and
# it happens in the middle of a fight. corpse.gd caches the result per kind, so
# the intent is that the FIRST death of a kind pays for it and every later one is
# just nodes -- but "the intent is" is not a measurement, and a cache key is
# exactly the kind of thing that silently stops matching.
#
# TWO CLAIMS, AND THE SECOND IS THE ONE THAT ROTS:
#
#   1. The build is warm before anything dies. GameWorld.start() primes it, so no
#      death is ever the first one.
#   2. A second corpse of the same kind does NOT rebuild. Asserted as a TIME
#      RATIO rather than a duration, because a duration is a property of the
#      machine the gate happens to be running on -- CLAUDE.md's rule about never
#      asserting a value the code does not control.
#
# The numbers are printed either way. A cost that has quietly tripled is worth
# seeing even on a run where nothing failed.

const Corpse = preload("res://scripts/sim/corpse.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

func setup(main) -> void:
	var root := Node3D.new()
	main.add_child(root)

	# COLD, deliberately: empty the cache so the first build is really a first
	# build. A test that measured a cache warmed by an earlier phase would report
	# the cheap number twice and call it evidence.
	Corpse._built.clear()

	var cold: Dictionary = {}
	# EVERY KIND THAT LEAVES A CORPSE, ASKED OF THE ONE LIST OF THEM. Written out
	# as three kinds by hand, this test failed the day a turret learned to shatter
	# -- talking about a count rather than about cost.
	for kind_id in Corpse.SCENES.keys():
		var started: int = Time.get_ticks_usec()
		var built: Dictionary = Corpse._build(kind_id, SimConfig.CORPSE_FRAGMENTS)
		var took: int = Time.get_ticks_usec() - started
		cold[kind_id] = took
		check(not built.is_empty(), "kind %d builds" % kind_id)
		print("[CORPSE COST] kind %d cold build %.2f ms (%d pieces)"
			% [kind_id, took / 1000.0, SimConfig.CORPSE_FRAGMENTS])

	# A SECOND BUILD OF THE SAME THING MUST BE FREE. Not "fast" -- a cache hit is
	# a dictionary lookup, so the ratio against a cold build is enormous and any
	# threshold in between separates the two cleanly on any machine.
	for kind_id in Corpse.SCENES.keys():
		var started: int = Time.get_ticks_usec()
		for _i in range(50):
			Corpse._build(kind_id, SimConfig.CORPSE_FRAGMENTS)
		var warm: float = float(Time.get_ticks_usec() - started) / 50.0
		print("[CORPSE COST] kind %d warm build %.4f ms" % [kind_id, warm / 1000.0])
		check(warm < float(cold[kind_id]) * 0.05,
			"kind %d: a second corpse of a kind reuses the cut -- cold %.0f us, warm %.1f us"
				% [kind_id, cold[kind_id], warm])

	# AND THE PER-CORPSE COST, which is what a fight actually pays: 32 rigid
	# bodies, each with a mesh instance and a collision shape. Printed rather than
	# asserted -- it is a node-creation cost on whatever box is running, and the
	# thing worth watching is that it is not doing the CUT again.
	var spawn_started: int = Time.get_ticks_usec()
	var made: Array = []
	for i in range(10):
		var c: Node3D = Corpse.spawn(root, Corpse.Kind.RUSHER,
			Vector3(float(i) * 3.0, 1.0, 0.0), Vector3.ZERO, false, 1 + i)
		if c != null:
			made.append(c)
	var per: float = float(Time.get_ticks_usec() - spawn_started) / 10.0
	eq(made.size(), 10, "ten corpses spawned")
	print("[CORPSE COST] spawn %.2f ms per corpse (%d bodies each)"
		% [per / 1000.0, SimConfig.CORPSE_FRAGMENTS])

	# THE WARM-UP IS THE POINT OF ALL OF THE ABOVE. A world that has started must
	# already hold every kind, or the first rusher to die does the cold build
	# during a fight.
	Corpse._built.clear()
	var world: Node3D = world_under_test(Node3D.new())
	world.name = "CostWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	# A RELATIONSHIP, NOT A LITERAL: as many built entries as there are kinds that
	# can leave a corpse. The literal 3 broke the day the turret joined them.
	eq(Corpse._built.size(), Corpse.SCENES.size(),
		"starting a world primes every corpse kind, so no death is ever the first one")

	finish()
