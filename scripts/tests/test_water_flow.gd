extends "res://scripts/test_support/test_case.gd"

# WATER RUNS SOMEWHERE, AND CARRIES YOU WITH IT.
#
# Water was an ordinary deck slab 0.4 m lower than its neighbours and nothing in
# the game read it. M27 phase 2 makes it a crossing with a direction.
#
# WHICH WAY IT RUNS IS A PROPERTY OF THE CHANNEL. Every water cell touching
# somewhere the deck stops is an OUTLET; a multi-source flood from all of them
# gives each cell its distance to the nearest one, and the flow is downhill on
# that field. So:
#
#   - a channel with one open end runs that way, everywhere;
#   - a channel open at BOTH rails has a watershed down the middle, and cells
#     flow to whichever rail is nearer;
#   - a landlocked pond has no outlets, so no sources, so no flow at all. That
#     falls out rather than being a clause, and it is why playtest_bridge's pond
#     is still a pond.
#
# THE FIELD IS ORDER-INDEPENDENT, which is the whole reason for computing a
# distance rather than walking outward and remembering a parent. A shortest
# distance does not depend on visit order, so two machines agree without anything
# crossing the wire. The version this replaced picked a direction for a two-ended
# channel off the run seed.
#
# AND THE SPEED TAPERS TO ZERO AT THE DIVIDE. Not a nicety: without it the two
# cells either side shove at full strength in opposite directions and a body
# straddling them jitters between them. Tapering makes the divide calm BY
# CONSTRUCTION rather than by a special case -- the same lesson as the deck
# profile, where a rate cap turned out not to be a gradient.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

const A := 41

# From test_channel.seg: one-outlet rows and two-outlet rows.
const ONE_WAY_ROW := 5
const SPLIT_ROW := 10
const POND_ROW := 13

var world: Node3D = null
var body: CharacterBody3D = null
var done := false
var phase := 0
var _at := 0
var _move := Vector2.ZERO
var _from := Vector3.ZERO

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "FlowWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_channel.seg"]
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.make(t, _move, 0)
	body = world.players[A]

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match phase:
		0: _the_field_has_the_right_shape()
		1: _stand_still_in_the_current()
		2: _carried()
		3: _walk_upstream()
		4: _headway()
		5: _fall_off_the_waterfall()
		6: _no_hold_on_a_waterfall()
		7: _fall_off_the_deck()
		8: _but_a_deck_lip_still_catches()

# --- 1. The shape of the field ----------------------------------------------------

func _the_field_has_the_right_shape() -> void:
	var grid = world.grid

	# --- one open end: everything runs the same way ------------------------
	var left: Vector3 = grid.water_flow_at(Vector2i(5, ONE_WAY_ROW))
	var right: Vector3 = grid.water_flow_at(Vector2i(19, ONE_WAY_ROW))
	print("[flow] one-outlet row: at x5 %s, at x19 %s" % [left, right])
	check(left.x > 0.5 and right.x > 0.5,
		"a channel with one open end runs that way along its whole length "
		+ "(x5 %.2f, x19 %.2f) -- there is nowhere else for it to go"
			% [left.x, right.x])
	check(grid.water_speed_at(Vector2i(19, ONE_WAY_ROW))
			> grid.water_speed_at(Vector2i(5, ONE_WAY_ROW)),
		"and it runs faster the nearer the fall (%.2f at the lip against %.2f at "
			% [grid.water_speed_at(Vector2i(19, ONE_WAY_ROW)),
				grid.water_speed_at(Vector2i(5, ONE_WAY_ROW))]
		+ "the closed end) -- a current picks up as it approaches the drop")

	# --- two open ends: a watershed ----------------------------------------
	var near_left: Vector3 = grid.water_flow_at(Vector2i(2, SPLIT_ROW))
	var near_right: Vector3 = grid.water_flow_at(Vector2i(18, SPLIT_ROW))
	print("[flow] two-outlet row: at x2 %s, at x18 %s, middle speed %.2f"
		% [near_left, near_right, grid.water_speed_at(Vector2i(10, SPLIT_ROW))])
	check(near_left.x < -0.5,
		"open at both rails, the left side runs LEFT (%.2f)" % near_left.x)
	check(near_right.x > 0.5,
		"and the right side runs RIGHT (%.2f) -- each cell to whichever rail is "
			% near_right.x
		+ "nearer, which is what makes where you ENTER the decision")
	check(grid.water_speed_at(Vector2i(10, SPLIT_ROW)) < 0.2,
		"and the divide between them is calm (%.2f) -- without the taper the two "
			% grid.water_speed_at(Vector2i(10, SPLIT_ROW))
		+ "cells either side shove at full strength in opposite directions and a "
		+ "body across them jitters")

	# --- and a pond does nothing -------------------------------------------
	_a_landlocked_pond_does_not_flow()

	body.global_position = world.grid.cell_surface_world(Vector2i(8, ONE_WAY_ROW)) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT + 0.1, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	phase = 1
	_at = world.tick

# THE ENCLOSED POND IN THIS SAME FIXTURE, rows 13-14. It used to be borrowed from
# playtest_bridge, and that map's pond has since become a channel -- which is
# exactly why a claim about ABSENCE has to be made on ground built to have
# nothing rather than on ground that merely happened not to have it yet.
func _a_landlocked_pond_does_not_flow() -> void:
	var flowing := 0
	var water := 0
	for x in range(7, 12):
		for z in [POND_ROW, POND_ROW + 1]:
			var cell := Vector2i(x, z)
			if world.grid.kind_at(cell) != GridConfig.Kind.WATER:
				continue
			water += 1
			if world.grid.water_flow_at(cell) != Vector3.ZERO:
				flowing += 1
	print("[flow] the enclosed pond: %d water cells, %d of them flowing"
		% [water, flowing])
	check(water > 0, "the pond is really there to check (%d cells)" % water)
	eq(flowing, 0,
		"a landlocked pond does not flow (%d of %d cells) -- no outlet means no "
			% [flowing, water]
		+ "source, and a puddle that shoves you is not water, it is ice")

# --- 2. Standing still is not standing still --------------------------------------

func _stand_still_in_the_current() -> void:
	if world.tick < _at + 20:
		return
	_from = body.global_position
	_move = Vector2.ZERO
	phase = 2
	_at = world.tick

func _carried() -> void:
	if world.tick < _at + 60:
		return
	var drift: float = body.global_position.x - _from.x
	print("[flow] one second of standing still carried the body %.2f m" % drift)
	check(drift > 0.8,
		"standing still in the current carries you downstream (%.2f m in a "
			% drift
		+ "second) -- water that leaves a stationary body alone is scenery")
	# BACK TO THE SAME CELL for the upstream run, so the two measurements are of
	# the same water rather than of two places in it.
	body.global_position = world.grid.cell_surface_world(Vector2i(8, ONE_WAY_ROW)) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT + 0.1, 0.0)
	body.velocity = Vector3.ZERO
	phase = 3
	_at = world.tick

# --- 3. Upstream is possible, and worse ------------------------------------------

func _walk_upstream() -> void:
	if world.tick < _at + 20:
		return
	_from = body.global_position
	_move = Vector2(-1.0, 0.0)      # against a current running +x
	phase = 4
	_at = world.tick

func _headway() -> void:
	if world.tick < _at + 60:
		return
	_move = Vector2.ZERO
	var gained: float = _from.x - body.global_position.x
	var on_deck: float = SimConfig.WALK_SPEED
	print("[flow] a second of walking upstream gained %.2f m, against %.2f on deck"
		% [gained, on_deck])
	check(gained > 0.5,
		"upstream is possible (%.2f m in a second) -- water you cannot make "
			% gained
		+ "headway against is a wall, and a wall is not a current")
	check(gained < on_deck * 0.8,
		"and visibly worse than deck (%.2f against %.2f) -- if the push does not "
			% [gained, on_deck]
		+ "cost anything measurable it is not doing anything")
	phase = 5
	_at = world.tick

# --- 4. YOU CANNOT HOLD ON TO A WATERFALL -----------------------------------------
#
# The lip of a fall is solid deck like any other, so a body carried over it would
# catch the ledge and dangle -- the current throws you off and then the thing
# that threw you rescues you, which is exactly backwards.
#
# BOTH HALVES, because a guard that switched ledge-catching off everywhere would
# satisfy the first one perfectly. The same body has to still catch an ordinary
# deck edge, or all that has been tested is that the feature can be deleted.
#
# DROPPED JUST OFF THE EDGE AT WALKING PACE, not carried there by the current: a
# body that arrives on the current arrives at whatever speed the current gave it,
# and LEDGE_CATCH_MAX_SPEED would then be doing the refusing instead of the rule
# under test.

func _place_beside(cell: Vector2i, outward: Vector3) -> void:
	body.global_position = world.grid.cell_surface_world(cell) 		+ outward * (GridConfig.CELL_SIZE * 0.75) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT - 0.35, 0.0)
	body.velocity = Vector3(0.0, -1.0, 0.0)
	body.state = PlayerBody.State.WALK
	body.ledge_cooldown = 0.0
	body.grounded = false

func _fall_off_the_waterfall() -> void:
	# The right rail of the one-outlet channel: the cell the water leaves by.
	_place_beside(Vector2i(20, ONE_WAY_ROW), Vector3(1.0, 0.0, 0.0))
	phase = 6
	_at = world.tick

func _no_hold_on_a_waterfall() -> void:
	if world.tick < _at + 20:
		return
	print("[flow] dropped past the waterfall lip: state %d, y %.2f"
		% [int(body.state), body.global_position.y])
	check(int(body.state) != PlayerBody.State.LEDGE_HANG,
		"a body going over a waterfall does not catch its lip -- the current "
		+ "throws you off, and dangling from the thing that threw you is a rescue "
		+ "the fall was never supposed to have")
	phase = 7
	_at = world.tick

func _fall_off_the_deck() -> void:
	# The same drop, one row away, where the edge is ordinary deck.
	_place_beside(Vector2i(20, ONE_WAY_ROW + 3), Vector3(1.0, 0.0, 0.0))
	phase = 8
	_at = world.tick

func _but_a_deck_lip_still_catches() -> void:
	if world.tick < _at + 20:
		return
	print("[flow] dropped past an ordinary deck lip: state %d, y %.2f"
		% [int(body.state), body.global_position.y])
	check(int(body.state) == PlayerBody.State.LEDGE_HANG,
		"but an ordinary deck edge still catches (state %d) -- the rule is about "
			% int(body.state)
		+ "WATER, and a guard that refused every lip would pass the claim above "
		+ "just as well")
	done = true
	finish()
