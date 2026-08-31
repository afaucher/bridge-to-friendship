extends "res://scripts/test_support/test_case.gd"

# AN ABSOLUTE DISTANCE, NOT A MULTIPLE OF `USE_REACH`.
#
# It was `USE_REACH * 3.0`, and the A/B caught it: widening the constant to 9999
# moved the test with it, so the out-of-range claim went on passing against a
# control with no range at all. A test that scales its own input by the thing it
# is measuring cannot fail.
const FAR_AWAY := 40.0

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
	_pressing_e_builds_a_bus()
	_one_press_is_one_bus()
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

# THE VERB IS `E` NOW, NOT A DASH.
#
# Reported: "it is really easy to miss them and dash off a cliff." A dash is
# 56 m/s over 5.6 m and a bus post sits mid-track beside the void, so the only
# way to ask for a bus was a committed lunge past the thing you were aiming at.
#
# AND THE TEST GOT HARDER IN A USEFUL WAY. The dash dispatched on the COLLIDER,
# so a test could hand `resolve_shove_contact` a post from anywhere in the world
# and get a bus -- distance was never part of the question. `_use` decides by
# proximity, so a body that is not actually standing there reaches nothing.
func _pressing_e_builds_a_bus() -> void:
	var post: Node = _plant_a_post()
	if not check(post != null, "there is a post to use"):
		return
	world._clear_buses()
	# THROUGH THE REAL USE PATH, which is what makes this a test of the WIRING
	# rather than of `_hail_bus`. `_use` is the function one press of E runs.
	_stand_at(post)
	world._use(1, world.player_body(1))
	print("[post] one press produced %d buses" % world._buses.size())
	eq(world._buses.size(), 1,
		"pressing E at the post builds a bus (%d) -- reached through the same "
			% world._buses.size()
		+ "proximity dispatch as the merchant and the mode selector, so the duck "
		+ "it answers is the wiring under test")

	# AND OUT OF RANGE IT DOES NOTHING, which the dash version could not ask at
	# all: a claim that a press works is only half a control if standing somewhere
	# else works too.
	world._clear_buses()
	post.ready_at = 0
	world.player_body(1).global_position = post.global_position \
		+ Vector3(FAR_AWAY, 1.0, 0.0)
	world._use(1, world.player_body(1))
	eq(world._buses.size(), 0,
		"and standing well away from it does not (%d) -- the interaction is a "
			% world._buses.size()
		+ "place you stand, which is the whole of what changed")

# Beside it, within reach, at deck height.
func _stand_at(post: Node) -> void:
	world.player_body(1).global_position = post.global_position + Vector3(1.0, 1.0, 0.0)

func _one_press_is_one_bus() -> void:
	var post: Node = _a_post()
	if post == null:
		return
	world._clear_buses()
	post.ready_at = 0
	_stand_at(post)
	# THE COOLDOWN STILL EARNS ITS KEEP, for a different reason than it used to.
	# It existed because a dash is not one event -- the sweep reports contact
	# against the same body several times. E is edge-triggered, so that particular
	# repeat is gone; a HELD key still is not, and neither is standing at the post
	# tapping it. Five presses in a row is what that looks like.
	for i in 5:
		world._use(1, world.player_body(1))
	print("[post] five presses in a row produced %d buses" % world._buses.size())
	eq(world._buses.size(), 1,
		"five presses in a row still produce one bus (%d) -- without the cooldown "
			% world._buses.size()
		+ "they make a heap of them on one cell, which is the coincident-bodies "
		+ "trap as well as the wrong number")

	# AND IT COMES BACK. A cooldown that never expired would be a post you may
	# use once per run, which is not a way to get a bus back.
	post.ready_at = 0
	_stand_at(post)
	world._use(1, world.player_body(1))
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
	_stand_at(post)
	world._use(1, world.player_body(1))
	print("[post] on the ordinary bridge a press produced %d buses"
		% world._buses.size())
	eq(world._buses.size(), 0,
		"a post on a mode that does not run buses hands out nothing (%d) -- the "
			% world._buses.size()
		+ "post is TERRAIN and the pool is a mode declaration, and terrain must "
		+ "not be able to overrule the table. This is the direction the subsystem "
		+ "x mode grid is for: not a pool running where it should not, but a "
		+ "piece of ground offering something the mode switched off")
	world.run_modes = [GameMode.BLANK]
