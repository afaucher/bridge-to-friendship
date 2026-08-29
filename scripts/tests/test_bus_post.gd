extends "res://scripts/test_support/test_case.gd"

# THE BUS POST: DASH IT AND A BUS TURNS UP.
#
# The answer to "the race track needs a way to get additional buses if you lose
# them", and it is a PLACE rather than a rule. An earlier draft kept a bus per
# player alive and replaced them silently; it was written and taken out, because
# a vehicle that reappears on its own has no cost -- driving into the void stops
# being a mistake and the party never decides whether the walk back is worth it.
#
# The claims:
#   1. EVERY LEVEL WITH BUSES IN IT HAS ONE, just inside the entrance. It was at
#      the MIDDLE first, which minimises the worst-case walk back and pessimises
#      the case that happens every time: nothing hands out a bus automatically,
#      so arriving without one is how every bus level starts. Reported from play
#      as having to walk a way to find it.
#   2. IT STANDS ON SOLID GROUND WITH NOTHING ELSE ON IT -- the middle ROW of a
#      serpentine is usually a link and of a circuit is the infield, so the row
#      is a starting point rather than an answer.
#   3. DASHING IT BUILDS A BUS, through the same dash dispatch the merchant and
#      the mode selector use. Driven by the real contact, not by calling the
#      handler: a control that only works when you call its function is a control
#      whose WIRING has never been tested.
#   4. ONE DASH IS ONE BUS. A dash sweeps several times against the same body and
#      `move_and_slide` reports each contact, so without a cooldown a single dash
#      makes a heap of them -- on one cell, which is the coincident-bodies trap.
#   5. AND NOT IN A MODE WITH NO BUSES. The post is terrain; the pool is a mode
#      declaration, and terrain must not be able to overrule it.

const GameMode = preload("res://scripts/sim/game_mode.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const WIDTH := 21
const SEEDS := 20

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	test_mode = GameMode.BLANK
	world = Node3D.new()
	world.name = "PostWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.run_modes = [GameMode.BLANK]

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)
	_every_bus_level_has_one()
	_a_dash_builds_a_bus()
	_one_dash_is_one_bus()
	_not_where_the_mode_has_no_buses()
	_the_sign_is_not_hidden_behind_its_own_post()
	finish()

# --- 1 and 2. Where they are ---------------------------------------------------

func _every_bus_level_has_one() -> void:
	var kinds := {
		"blank zone": func(sv): return SegmentGen.blank_zone(WIDTH, sv, sv % 5),
		"bus route": func(sv): return SegmentGen.bus_track(WIDTH, sv, sv % 5),
		"race circuit": func(sv): return SegmentGen.race_loop(WIDTH, sv, sv % 5),
	}
	for label in kinds:
		var missing := 0
		var off_ground := 0
		var worst := 0.0
		for sv in SEEDS:
			var seg = kinds[label].call(sv)
			var found := Vector2i(-1, -1)
			for z in seg.length:
				for x in seg.width:
					if seg.content_at(x, z) == GridConfig.Content.BUS_POST:
						found = Vector2i(x, z)
			if found.x < 0:
				missing += 1
				continue
			if not seg.is_solid(found.x, found.y):
				off_ground += 1
			# HOW FAR IN, IN ROWS rather than as a fraction of the section. A
			# fraction lets the post drift further from the door on a longer level
			# while the number stays the same, and "how far do I walk" is a
			# distance.
			#
			# This replaced a fraction-from-the-middle, and the replacement did not
			# apply the first time -- it was the one edit in the batch I did not
			# assert on. The print then said "rows" while the maths still said
			# fraction, `int(0.46)` rendered as 0, and the new bound passed over a
			# number that meant something else entirely.
			worst = maxf(worst, float(found.y))
		print("[post] %s: %d of %d missing, %d off the ground, furthest in %d rows"
			% [label, missing, SEEDS, off_ground, int(worst)])
		eq(missing, 0,
			"every %s carries a bus post (%d of %d without) -- a level with a bus "
				% [label, missing, SEEDS]
			+ "in it and no way to fetch another is a level with nothing in it "
			+ "the moment somebody drives into the void")
		eq(off_ground, 0,
			"and it stands on solid ground (%d over a hole) -- the middle ROW of a "
				% off_ground
			+ "serpentine is usually a link and of a circuit is the infield, so "
			+ "the row is where the search STARTS")
		check(worst <= SegmentGen.BUS_POST_ROW + 4,
			"and within a few rows of the entrance (furthest %d, want %d or less) "
				% [int(worst), SegmentGen.BUS_POST_ROW + 4]
			+ "-- a party arrives at a bus level with no bus, so the walk to the "
			+ "first one is not a rare cost, it is what starting the mode IS. The "
			+ "slack is the search stepping past ground the row happens not to "
			+ "have, which on a circuit is the infield")

# --- 3 and 4. Dashing it -------------------------------------------------------

func _a_post() -> Node:
	var posts: Array = world.grid.bus_posts()
	return posts[0] if posts.size() > 0 else null

func _plant_a_post() -> Node:
	# test_flat has no post of its own, so one is put down through the grid's own
	# spawner -- the same call the builder makes for a `!` glyph.
	world.grid._spawn_bus_post(Vector2i(7, 6))
	return _a_post()

func _a_dash_builds_a_bus() -> void:
	var post: Node = _plant_a_post()
	if not check(post != null, "there is a post to dash"):
		return
	world._clear_buses()
	# THROUGH THE REAL DASH DISPATCH, which is what makes this a test of the
	# WIRING rather than of `_hail_bus`. `resolve_shove_contact` is the function
	# the shove sweep calls when a dashing body meets something.
	world.resolve_shove_contact(world.player_body(1), post, 0.0)
	print("[post] one dash produced %d buses" % world._buses.size())
	eq(world._buses.size(), 1,
		"dashing the post builds a bus (%d) -- reached through the same contact "
			% world._buses.size()
		+ "dispatch as the merchant and the mode selector, so the duck it answers "
		+ "is the wiring under test")

func _one_dash_is_one_bus() -> void:
	var post: Node = _a_post()
	if post == null:
		return
	world._clear_buses()
	post.ready_at = 0
	# A DASH IS NOT ONE EVENT. The sweep reports contact against the same body
	# several times, so this is what a single dash really looks like.
	for i in 5:
		world.resolve_shove_contact(world.player_body(1), post, 0.0)
	print("[post] five contacts from one dash produced %d buses"
		% world._buses.size())
	eq(world._buses.size(), 1,
		"five contacts in one tick still produce one bus (%d) -- without the "
			% world._buses.size()
		+ "cooldown a dash makes a heap of them, on one cell, which is the "
		+ "coincident-bodies trap as well as the wrong number")

	# AND IT COMES BACK. A cooldown that never expired would be a post you may
	# use once per run, which is not a way to get a bus back.
	post.ready_at = 0
	world.resolve_shove_contact(world.player_body(1), post, 0.0)
	eq(world._buses.size(), 2,
		"and once the cooldown is up it hands out another (%d)"
			% world._buses.size())

# --- 6. You can actually see it ------------------------------------------------
#
# THE POST WAS IN FRONT OF THE SIGN. Both posts had the plate at z = 0, the same
# as the pole, so the pole stood proud of it and ran down the middle of its face.
# Reported twice as "facing the wrong way", which is what a sign you cannot read
# the middle of looks like -- and it is not an orientation fault at all, so no
# amount of rotating would have touched it.
#
# ASSERTED AS AN OCCLUSION, not as a coordinate. "The plate is at z = 0.19" is a
# restatement of the code; "nothing of the post stands between the plate and the
# camera" is the property, and it stays true if the post gets fatter.
func _the_sign_is_not_hidden_behind_its_own_post() -> void:
	var post: Node = _a_post()
	if not check(post != null, "there is a post to look at"):
		return
	var plate: MeshInstance3D = post.get_node_or_null("Plate")
	var pole: MeshInstance3D = post.get_node_or_null("Post")
	if not check(plate != null and pole != null, "it has a plate and a pole"):
		return
	# FRONT IS +Z: the party walks up-bridge toward -Z and the camera sits behind
	# them, so +Z is the only side anybody ever sees.
	var plate_front: float = plate.position.z 		+ (plate.mesh as BoxMesh).size.z * 0.5
	var pole_front: float = pole.position.z + (pole.mesh as BoxMesh).size.z * 0.5
	var plate_back: float = plate.position.z - (plate.mesh as BoxMesh).size.z * 0.5
	print("[post] plate spans z %.2f..%.2f, pole reaches %.2f"
		% [plate_back, plate_front, pole_front])
	check(plate_back >= pole_front - 0.01,
		"the plate is IN FRONT of the pole (%.2f vs %.2f) rather than skewered by "
			% [plate_back, pole_front]
		+ "it -- a pole standing proud of its own sign is a stripe down the middle "
		+ "of the only face anybody sees")

	# AND THE DEVICE IS ON THE PLATE'S FRONT, for the same reason one step in. A
	# bus on the back is a sign for nobody, and it has the same bounding box.
	var bus: MeshInstance3D = plate.get_node_or_null("Bus")
	if not check(bus != null, "the sign has a bus on it"):
		return
	check(bus.position.z > 0.0,
		"and the bus is on the FRONT of the plate (%.3f) -- a device on the back "
			% bus.position.z
		+ "has the same bounding box as one on the front, which is why this asks "
		+ "about the sign rather than about whether it exists")

# --- 5. The mode still decides -------------------------------------------------

func _not_where_the_mode_has_no_buses() -> void:
	var post: Node = _a_post()
	if post == null:
		return
	world._clear_buses()
	post.ready_at = 0
	world.run_modes = [GameMode.BASE]
	world.resolve_shove_contact(world.player_body(1), post, 0.0)
	print("[post] on the ordinary bridge a dash produced %d buses"
		% world._buses.size())
	eq(world._buses.size(), 0,
		"a post on a mode that does not run buses hands out nothing (%d) -- the "
			% world._buses.size()
		+ "post is TERRAIN and the pool is a mode declaration, and terrain must "
		+ "not be able to overrule the table. This is the direction the subsystem "
		+ "x mode grid is for: not a pool running where it should not, but a "
		+ "piece of ground offering something the mode switched off")
	world.run_modes = [GameMode.BLANK]
