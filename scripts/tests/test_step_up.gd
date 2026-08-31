extends "res://scripts/test_support/test_case.gd"

# A BOUNDED STEP-UP: OUT OF THE WATER, AND NOT OVER A WALL.
#
# Reported: "you can't step out of water so you get stuck."
#
# Water is an ordinary deck slab whose top is 0.4 m BELOW its cell's nominal
# height, so walking in is a drop and walking out is a vertical wall -- and this
# game has no mantle, which is why ramps, ladders, bouncers and lifts exist.
# `SegmentValidator` does not know: water and deck share a grid height, so the
# rise reads as 0 and the flood certifies a route nobody can walk. That is the
# second time an oracle here has modelled a movement the player does not have.
#
# Measured before the fix, on playtest_bridge's pond: two seconds of walking
# straight at the shore moved the body 0.001 m upward and left it in the water.
#
# THE FIX IS A STEP BOUNDED UNDER ONE HEIGHT UNIT, and the bound is the whole
# safety argument. Heights are hex digits times HEIGHT_UNIT of 1.0 m, one
# character per cell, so the smallest rise a level can express is a whole metre.
# A step above the 0.4 m water lip and below 1.0 m is therefore invisible to
# every authored level BY CONSTRUCTION -- and `SegmentValidator` needs no change,
# because it already believes water is crossable and the step makes that true.
#
# THE BOUND IS BRACKETED FROM BOTH SIDES, because a rule with one half tested is
# a rule half-shipped:
#
#   1. A body walks out of the pond in the map the report came from.
#   2. It climbs a ledge UNDER the bound, on a purpose-built rig.
#   3. It does NOT climb a ledge at one full height unit. Without this the
#      traversal rewrite -- every ramp and ladder in the game made optional --
#      ships silently, and claims 1 and 2 pass just as well.
#
# CLAIMS 2 AND 3 ARE BUILT, NOT FOUND, and that is not laziness about fixtures.
# A bare one-unit step between two deck cells is exactly what `SegmentValidator`
# refuses, so NO level in the game contains one to test against -- the rule being
# asserted here is the reason its own fixture cannot exist. A box on flat ground
# isolates the bound from level content entirely, and asks the same apparatus a
# question either side of it.
#
# THE RIG IS BUILT FROM GRID COORDINATES, never from a hard-coded height. The
# bridge is pitched about 4 degrees and stacks segments by height, so "the deck
# is at y = 0" is true nowhere; the first version of this test put its ledge at
# y = 0 and measured a body falling off the world.
#
# AND THE APPROACH IS MEASURED EVERY TIME, so no claim can be satisfied by a body
# that never reached the wall it was supposed to meet.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

const A := 41

var world: Node3D = null
var body: CharacterBody3D = null
var done := false
var phase := 0
var _at := 0
var _move := Vector2.ZERO
var _from := Vector3.ZERO
var _water: Vector2i = Vector2i(-1, -1)
var _shore: Vector2i = Vector2i(-1, -1)
var _ledge: StaticBody3D = null
var _high := 0.0
var _stand: Vector2i = Vector2i(-1, -1)
# THE PEAK, NOT THE FINISH. A body that climbs a ledge, crosses it and steps down
# the far side is back at its starting height by the end of the window -- so a
# claim sampled at the end reads "did not climb" for a body that plainly did.
# Found by A/B: at a step of 1.6 the body cleared a one-unit wall, walked 10.65 m
# over it, and the refusal claim stayed green.
var _peak := -9999.0
var _far := 0.0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "StepUpWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# THE MAP THE REPORT CAME FROM. Its pond is the only water in the game, and
	# the rig for claims 2 and 3 is built on its own flat ground -- test_flat is
	# 30 cells wide against this one's 21, so a run cannot hold both.
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.make(t, _move, 0)
	body = world.players[A]

# The pond, and a deck cell beside it to walk out onto -- found rather than
# hard-coded, so moving the pond in the .seg does not silently make this a test
# of some other cell.
func _find_the_pond() -> bool:
	var seg = world.grid.segment_data(0)
	if seg == null:
		return false
	for z in seg.length:
		for x in seg.width:
			if seg.kind_at(x, z) != GridConfig.Kind.WATER:
				continue
			for dir in 4:
				var n: Vector2i = Vector2i(x, z) + GridConfig.DIR_CELLS[dir]
				if n.x < 0 or n.x >= seg.width or n.y < 0 or n.y >= seg.length:
					continue
				if seg.kind_at(n.x, n.y) != GridConfig.Kind.DECK:
					continue
				if seg.height_at(n.x, n.y) != seg.height_at(x, z):
					continue     # a real cliff, not a shore
				_water = Vector2i(x, z)
				_shore = n
				return true
	return false

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match phase:
		0: _stand_in_the_water()
		1: _walk_at_the_shore()
		2: _set_up_the_low_ledge()
		3: _walk_at_the_ledge()
		4: _a_low_ledge_is_climbed()
		5: _walk_at_the_ledge()
		6: _a_full_unit_is_not()

# --- 0. THE BOUND ITSELF ----------------------------------------------------------
#
# The three claims below measure a body. This one measures the CONSTANT, and it
# is the reason the audit that went with this change came out empty.
#
# A step strictly under HEIGHT_UNIT cannot be reached by any arrangement of the
# height grid, because heights are whole units. So the only things it makes
# newly climbable are sub-cell colliders -- and the sweep of those found nothing
# in the player's mask under 0.45 m except water: the bus is on layer 2048 and
# the player mask is 1687, so players never touch it at all; the merchant is
# 1.6 m, the posts 1.9 m, cover 1.1 m.
#
# THAT CONCLUSION IS ONLY TRUE WHILE THE BOUND HOLDS, and a constant is one edit
# from not holding. Asserted here so raising it past a height unit fails loudly
# rather than quietly turning every ramp and ladder in the game into decoration.
func _the_bound_is_the_safety_argument() -> void:
	print("[stepup] the step is %.2f m, between the water lip 0.40 and HEIGHT_UNIT %.2f"
		% [SimConfig.STEP_UP_HEIGHT, GridConfig.HEIGHT_UNIT])
	check(SimConfig.STEP_UP_HEIGHT < GridConfig.HEIGHT_UNIT,
		"the step (%.2f) is under one height unit (%.2f) -- above it, every rise "
			% [SimConfig.STEP_UP_HEIGHT, GridConfig.HEIGHT_UNIT]
		+ "an authored level can express becomes walkable and the whole climb "
		+ "vocabulary is decoration")
	check(SimConfig.STEP_UP_HEIGHT > 0.4,
		"and over the 0.4 m a water cell sits below its nominal height (%.2f), "
			% SimConfig.STEP_UP_HEIGHT
		+ "which is the lip this exists to clear")

# --- 1. Out of the pond ----------------------------------------------------------

func _stand_in_the_water() -> void:
	if not check(_find_the_pond(), "playtest_bridge still has a pond with a shore"):
		done = true
		finish()
		return
	_the_bound_is_the_safety_argument()
	print("[stepup] the pond is at %s, the shore beside it at %s" % [_water, _shore])
	body.global_position = world.grid.cell_surface_world(_water) + Vector3(0.0, 0.6, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	phase = 1
	_at = world.tick

func _walk_at_the_shore() -> void:
	# Settle onto the water before anything is measured, or the first ticks of the
	# walk are a fall.
	if world.tick < _at + 30:
		return
	if world.tick == _at + 30:
		_from = body.global_position
		var away: Vector3 = world.grid.cell_surface_world(_shore) - _from
		_move = Vector2(away.x, away.z).normalized()
		print("[stepup] in the water at y %.3f, walking at the shore" % _from.y)
		return

	# STOPPED THE MOMENT IT ARRIVES, not after a fixed window. The first version
	# held the stick for two seconds, and the body climbed out and kept going --
	# two cells past the shore and down the bridge beyond it, so a working fix
	# measured as a body 1.4 m LOWER than it started. A rig that holds a movement
	# input walks the player off the map; this one lets go on arrival.
	var here: Vector2i = world.grid.cell_of_world(body.global_position)
	if here != _water or world.tick > _at + 150:
		_move = Vector2.ZERO
		var lip: float = world.grid.cell_surface_world(_shore).y
		print("[stepup] after %d ticks: cell %s at y %.3f (from %.3f, shore top %.3f)"
			% [world.tick - _at - 30, here, body.global_position.y, _from.y, lip])
		check(body.global_position.y > _from.y + 0.2,
			"the body climbed out of the water (%.3f from %.3f) -- a 0.4 m lip "
				% [body.global_position.y, _from.y]
			+ "with no mantle is a wall, and the pond was a trap you walked into "
			+ "once and stayed in")
		eq(here, _shore,
			"and it is standing on the shore cell (%s, wanted %s) rather than "
				% [here, _shore]
			+ "having gone somewhere else entirely")
		phase = 2
		_at = world.tick

# --- 2 and 3. A LEDGE EITHER SIDE OF THE BOUND ------------------------------------

# Flat ground well clear of the pond: the second segment, which is test_flat.
# SEARCHED, NOT ASSUMED. The first version picked the middle column six rows in
# and got a hole -- the second segment is not obliged to be solid anywhere in
# particular, and a rig built on nothing measures a body falling.
func _flat_cell() -> Vector2i:
	var seg = world.grid.segment_data(0)
	if seg == null:
		return Vector2i(-1, -1)
	for z in range(2, seg.length - 5):
		for x in seg.width:
			var cell := Vector2i(x, z)
			# A CLEAR RUN, not a clear cell. The walk is three cells long, so a
			# hole or a step part-way along is a body that falls or stops before
			# it reaches the box -- and either would satisfy claim 3 by missing.
			var clear := true
			for ahead in 5:
				var c := Vector2i(x, z + ahead)
				if seg.kind_at(c.x, c.y) != GridConfig.Kind.DECK 						or seg.height_at(c.x, c.y) != seg.height_at(cell.x, cell.y) 						or seg.content_at(c.x, c.y) != GridConfig.Content.NONE:
					clear = false
					break
			if clear:
				return cell
	return Vector2i(-1, -1)

# A box whose TOP FACE sits `high` above the deck of the cell in front of the
# body -- built from the grid's own surface, because the bridge is pitched and
# stacked and there is no height in this world that can be assumed.
func _build_ledge(high: float) -> void:
	_clear_ledge()
	_high = high
	var here: Vector3 = world.grid.cell_surface_world(_stand)
	var ledge := StaticBody3D.new()
	ledge.name = "Ledge"
	ledge.collision_layer = 1        # world, like the deck it stands on
	ledge.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# DEEP ENOUGH TO LAND ON, and buried below so the sides are the only faces a
	# body can meet: a slab floating at exactly the step height would let the
	# probe's downward leg pass under it.
	box.size = Vector3(12.0, high + 2.0, 6.0)
	shape.shape = box
	ledge.add_child(shape)
	world.add_child(ledge)
	ledge.global_position = here + Vector3(0.0, high - (high + 2.0) * 0.5,
		-GridConfig.CELL_SIZE * 2.5)
	_ledge = ledge

func _clear_ledge() -> void:
	if _ledge != null and is_instance_valid(_ledge):
		_ledge.queue_free()
	_ledge = null

func _set_up_the_low_ledge() -> void:
	_stand = _flat_cell()
	if not check(world.grid.is_solid(_stand),
			"there is flat ground at %s to build the rig on" % _stand):
		done = true
		finish()
		return
	_build_ledge(SimConfig.STEP_UP_HEIGHT - 0.05)
	body.global_position = world.grid.cell_surface_world(_stand) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT + 0.1, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	phase = 3
	_at = world.tick

func _walk_at_the_ledge() -> void:
	if world.tick < _at + 20:
		return
	if world.tick == _at + 20:
		_from = body.global_position
		_peak = body.global_position.y
		_far = 0.0
		_move = Vector2(0.0, -1.0)      # straight up-bridge, at the box
		return
	_peak = maxf(_peak, body.global_position.y)
	_far = maxf(_far, _from.z - body.global_position.z)
	if world.tick < _at + 120:
		return
	phase += 1

func _a_low_ledge_is_climbed() -> void:
	_move = Vector2.ZERO
	print("[stepup] a %.2f m ledge: peaked %.3f above the start, travelled %.2f m"
		% [_high, _peak - _from.y, _far])
	check(_peak > _from.y + _high * 0.5,
		"a ledge under the bound is climbed (%.3f up at its peak, the top face is "
			% (_peak - _from.y)
		+ "%.2f up) -- which is the whole of what a step-up is for" % _high)
	check(_far > GridConfig.CELL_SIZE,
		"and the body went FORWARD onto it (%.2f m) rather than merely rising -- "
			% _far
		+ "a climb that gains height without gaining ground is not a step")

	_build_ledge(GridConfig.HEIGHT_UNIT)
	body.global_position = world.grid.cell_surface_world(_stand) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT + 0.1, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	phase = 5
	_at = world.tick

func _a_full_unit_is_not() -> void:
	_move = Vector2.ZERO
	print("[stepup] a %.2f m ledge: peaked %.3f above the start, travelled %.2f m"
		% [_high, _peak - _from.y, _far])
	check(_far > 1.0,
		"the body really walked into the wall (%.2f m travelled) -- one that never "
			% _far
		+ "arrived would satisfy the refusal below by missing")
	check(_peak < _from.y + GridConfig.HEIGHT_UNIT * 0.5,
		"and a full height unit is still a wall (%.3f at its highest) -- the step "
			% (_peak - _from.y)
		+ "bounded under HEIGHT_UNIT precisely so no authored rise can reach it, "
		+ "and every ramp, ladder, bouncer and lift in the game depends on that")
	_clear_ledge()
	done = true
	finish()
