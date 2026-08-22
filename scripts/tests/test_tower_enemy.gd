extends "res://scripts/test_support/test_case.gd"

# M23 PHASES 4 AND 5: HIGH GROUND WITH SOMETHING ON IT, AND YOU CAN ANSWER IT.
#
# The milestone's third ask was "we can build towers with enemies on top", and
# the reason it was sequenced LAST is one asymmetry: a gunner aims at its target's
# full 3D position (`game_world.gd`, `_spawn_round` from `gunner.muzzle()` toward
# `target.global_position`), while a player under the old `level` aim mode fired
# flat from the muzzle whatever the cursor said. So a turret three units up could
# shoot you and you could not shoot back -- the hazard-with-no-counter shape
# CLAUDE.md warns about, and the reason phase 0 had to land first.
#
# THIS IS THE TEST THAT SAYS THE ASYMMETRY IS GONE. It is not about aim
# arithmetic -- `test_point_aim` already covers direction and pitch -- it is
# about a round leaving a real gun at a real target on a real tower and ARRIVING.
# The distinction matters: this project has shipped a shield whose maths was
# perfect and which blocked nothing, because the test built its own input rather
# than taking the one the caller passes.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const Bullet = preload("res://scripts/sim/bullet.gd")

const MAP := "res://segments/test_watchpost.seg"
const PEER := 918447201

# The tower top, from the fixture: three units up at column 7, row 6.
const POST_COL := 7
const POST_ROW := 6
# On the deck, four rows short of it -- a real engagement distance rather than
# standing underneath, which would flatter the shot.
const STAND_COL := 7
const STAND_ROW := 2

var world: Node3D = null
var body: CharacterBody3D = null
var weapon: Node = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "WatchpostWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = [MAP]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	body.position = world.grid.cell_surface_world(Vector2i(STAND_COL, STAND_ROW)) \
		+ Vector3(0.0, 1.2, 0.0)
	body.facing = 0.0
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < 6:
		return
	done = true
	_test_the_pieces_are_towers()
	_test_a_round_reaches_the_top()
	finish()

# --- Phase 4: the library holds more than one kind of climb --------------------

func _test_the_pieces_are_towers() -> void:
	var watch = SegmentData.from_file("res://segments/piece_watchpost.seg")
	var bunker = SegmentData.from_file("res://segments/piece_bunker.seg")
	check(watch.is_valid(), "the watchpost parses (%s)" % str(watch.errors))
	check(bunker.is_valid(), "the bunker parses (%s)" % str(bunker.errors))
	check(SegmentValidator.validate(watch).is_empty(),
		"and validates -- a tower with no way up is marooned deck (%s)"
			% str(SegmentValidator.validate(watch)))
	check(SegmentValidator.validate(bunker).is_empty(),
		"and so does the bunker (%s)" % str(SegmentValidator.validate(bunker)))

	# THE ASCENDER IS THE AXIS BETWEEN THEM, which is the whole reason the library
	# holds two rather than one tuned in between. A ladder is a commitment you
	# cannot fight during; a ramp is walkable the moment you reach it.
	var has_ladder := false
	var tallest := 0
	for z in watch.length:
		for x in watch.width:
			if watch.content_at(x, z) == GridConfig.Content.LADDER:
				has_ladder = true
			tallest = maxi(tallest, watch.height_at(x, z))
	check(has_ladder, "the watchpost is climbed by a LADDER")
	check(tallest >= 3,
		"and is genuinely tall (%d units) -- a ladder is what makes a tall post "
			% tallest
		+ "fit in a patch at all, because a ramp spends a row per unit")

	var ramps := 0
	var bunker_tall := 0
	for z in bunker.length:
		for x in bunker.width:
			if bunker.kind_at(x, z) == GridConfig.Kind.RAMP:
				ramps += 1
			bunker_tall = maxi(bunker_tall, bunker.height_at(x, z))
	check(ramps >= 2,
		"while the bunker has TWO ramps (%d) -- one makes high ground a dead end "
			% ramps
		+ "you back out of, two make it a route with a decision at each end")
	check(bunker_tall < tallest,
		"and is the lower of the two (%d against %d): high ground you take in a "
			% [bunker_tall, tallest]
		+ "stride, and so can anything else")

	# AND SOMETHING IS ON THE TALL ONE. A tower nothing occupies is scenery.
	var armed := false
	for z in watch.length:
		for x in watch.width:
			if watch.content_at(x, z) == GridConfig.Content.TURRET:
				armed = true
	check(armed, "and the watchpost carries a turret, which is phase 5's whole ask")

# --- Phase 5: and a round from the deck actually gets there --------------------

func _test_a_round_reaches_the_top() -> void:
	var post: Vector3 = world.grid.cell_surface_world(Vector2i(POST_COL, POST_ROW))
	var target: Vector3 = post + Vector3(0.0, 0.25, 0.0)   # a gunner's muzzle height

	for s in world._specials.all():
		world._specials.destroy(s)
	weapon = world._specials.spawn_loose(body.position, SpecialBody.Kind.RIFLE)
	weapon.hold(PEER)
	weapon.fire_timer = 0.0
	world._pose_held_special(weapon, body)

	# AIMED THE WAY THE GAME AIMS IT. `aim_point` is what a client resolves from
	# the cursor and puts on the wire, and `aim_direction` is what the shot is
	# built from -- so this is the caller's input, not one invented here.
	body.aim_point = target
	var dir: Vector3 = world.aim_direction(body, weapon)
	var muzzle: Vector3 = world._muzzle_of(weapon, body)
	var rise: float = target.y - muzzle.y
	print("[tower] post %.2f m above the muzzle, %.2f m away; shot leaves at y %.3f"
		% [rise, Vector2(target.x - muzzle.x, target.z - muzzle.z).length(), dir.y])

	check(rise > 1.5,
		"the turret really is above the shooter (%.2f m) -- a tower measured from "
			% rise
		+ "underneath would flatter every number here")
	check(dir.y > 0.05,
		"and the shot leaves the barrel TILTED UP (y %.3f). Under `level` this is "
			% dir.y
		+ "0 by construction and the round passes under the post forever, which "
		+ "is why phase 0 had to land before a tower could carry anything")

	# THE ROUND ARRIVES. Direction is not the claim -- a shot that points at the
	# post and drops under it is exactly as useless, and MG_BULLET_DROP is real.
	# Walked along the ray at the speed the round travels.
	var travel: float = muzzle.distance_to(target)
	var closest: float = INF
	var step: float = SimConfig.TICK_DELTA * SimConfig.MG_BULLET_SPEED
	var at: Vector3 = muzzle
	var flown := 0.0
	var drop := 0.0
	while flown < travel * 1.6:
		at = muzzle + dir * flown + Vector3(0.0, -drop, 0.0)
		closest = minf(closest, at.distance_to(target))
		flown += step
		# ASKED OF THE ROUND, integrated over the flight so far. This used to be its
		# own copy -- `MG_BULLET_DROP * 9.8`, against a GRAVITY of 24 -- so the model
		# fell at 40% of the real rate, and it would not have noticed the drop being
		# put behind a toggle at all.
		var t: float = flown / SimConfig.MG_BULLET_SPEED
		drop = 0.5 * Bullet.drop_accel() * t * t
	print("[tower] closest approach to the turret over the flight: %.3f m (drop %.3f m)"
		% [closest, drop])
	check(closest < 1.0,
		"and passes within a metre of the turret (%.2f m) -- which is the claim "
			% closest
		+ "that matters: a direction with pitch in it is not a hit, and a round "
		+ "that aims at a post and falls under it is exactly as useless")
