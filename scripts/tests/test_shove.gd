extends "res://scripts/test_support/test_case.gd"

# MVP criterion B3: the shove resolves legibly.
#
#   - a dash into a stone moves it EXACTLY one cell when the destination is
#     clear, and ZERO cells when it is blocked
#   - a dash into a player transfers momentum along the dash axis
#   - a dash off the deck leaves the bridge
#   - the dash cannot be steered once committed
#
# The one-cell rule is the reason the integrator is ours. A rigid-body solver
# would slide the stone a variable distance depending on approach angle and
# contact ordering; "did the stone move a cell?" has to be answerable at a glance
# from across the bridge.
#
# The world runs its own host tick; the test only supplies input, through the
# same per-peer hook a keyboard would feed.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var shover: CharacterBody3D = null
var target: CharacterBody3D = null

var stone_cell := Vector2i.ZERO
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

# Set by the phase code each tick and read by the input hook. Actions are
# cleared every tick, so a press is exactly one tick wide -- which is what an
# edge-triggered action means.
var p1_move: Vector2 = Vector2.ZERO
var p1_actions: int = 0

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "ShoveWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)

	# Pick a stone whose north neighbour is open deck, rather than assuming the
	# first one is pushable -- test_flat's leading pillar sits right against a
	# hole band, and a push into it is a different case (tested below).
	var stones: Array = world.grid.all_stones()
	var found := false
	for stone in stones:
		var ahead: Vector2i = stone.cell + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH]
		if world.grid.is_solid(ahead) and world.grid.stone_at(ahead) == null:
			stone_cell = stone.cell
			found = true
			break
	if not check(found, "the segment has a stone with clear deck ahead of it"):
		finish()
		return

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	shover = world.player_body(1)
	target = world.player_body(2)

	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, p1_move, p1_actions)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	_place_behind_stone()
	target.position = shover.position + Vector3(40.0, 0.0, 0.0)   # parked, out of the way

func _place_behind_stone() -> void:
	# One cell SOUTH of the stone (down the bridge), so a dash NORTH runs
	# straight into it. cell_surface_world, not cell_surface: the bridge is
	# pitched, so grid-local and world coordinates are different things.
	var behind: Vector2i = stone_cell + GridConfig.DIR_CELLS[GridConfig.DIR_SOUTH]
	var start: Vector3 = world.grid.cell_surface_world(behind)
	shover.position = start + Vector3(0.0, 1.0, 0.0)
	shover.velocity = Vector3.ZERO
	shover.state = PlayerBody.State.WALK
	shover.shove_cooldown = 0.0

func _physics_process(_delta: float) -> void:
	if shover == null or world.tick == 0:
		return
	phase_frame += 1
	p1_actions = 0

	match phase:
		0: _phase_push_stone()
		1: _phase_blocked_and_hole()
		2: _phase_shove_player()
		3: _phase_dash_off_edge()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 1. A dash into a stone moves it exactly one cell -------------------------

func _phase_push_stone() -> void:
	if phase_frame < 30:
		return                       # let the shover settle onto the deck
	if phase_frame == 30:
		p1_move = Vector2(0.0, -1.0)
		p1_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 31:
		eq(shover.state, PlayerBody.State.SHOVE, "pressing shove enters the SHOVE state")
		eq(shover.shove_dir, GridConfig.DIR_NORTH, "and locks to the compass axis that was held")
		# Steering input during a dash must do nothing at all.
		p1_move = Vector2(1.0, 0.0)
		return

	p1_move = Vector2(1.0, 0.0)

	if phase_frame == 120:
		var moved_to: Vector2i = stone_cell + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH]
		check(world.grid.stone_at(moved_to) != null,
			"the stone moved exactly one cell north")
		eq(world.grid.stone_at(stone_cell), null, "and is no longer in its old cell")
		eq(shover.state, PlayerBody.State.WALK, "the dash ended on contact")
		if world.grid.stone_at(moved_to) != null:
			stone_cell = moved_to
		p1_move = Vector2.ZERO
		_advance(1)

# --- 2. Blocked pushes move nothing; a push into a hole drops the stone -------

func _phase_blocked_and_hole() -> void:
	if phase_frame == 1:
		# Occupy the destination so the next push has nowhere to go.
		world.grid._spawn_stone(stone_cell + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH])
		return
	if phase_frame == 2:
		eq(world.grid.try_push(stone_cell, GridConfig.DIR_NORTH), world.grid.PushResult.BLOCKED,
			"a push into an occupied cell is refused")
		check(world.grid.stone_at(stone_cell) != null, "and the stone stays put")

		# A stone placed right at the lip of test_flat's hole band, pushed in.
		# This is the reward for rearranging the bridge -- and it only works
		# because interior holes carry no parapet.
		var lip := Vector2i(10, 5)
		var into_hole: Vector2i = lip + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH]
		check(not world.grid.is_solid(into_hole), "the fixture has a hole beyond the lip")
		world.grid._spawn_stone(lip)
		var before: int = world.grid.stone_count()
		eq(world.grid.try_push(lip, GridConfig.DIR_NORTH), world.grid.PushResult.FELL,
			"a push into a hole makes the stone fall")
		eq(world.grid.stone_count(), before - 1, "and it leaves the cell map")
		_advance(2)

# --- 3. A dash into a player transfers momentum -------------------------------

func _phase_shove_player() -> void:
	if phase_frame == 1:
		var here: Vector3 = world.grid.cell_surface_world(Vector2i(4, 4))
		shover.position = here + Vector3(0.0, 1.0, 0.0)
		shover.velocity = Vector3.ZERO
		shover.state = PlayerBody.State.WALK
		shover.shove_cooldown = 0.0
		# Just over a cell east, in the path of an eastward dash.
		target.position = here + Vector3(GridConfig.CELL_SIZE * 1.2, 1.0, 0.0)
		target.velocity = Vector3.ZERO
		return
	if phase_frame == 40:
		recorded["target_x"] = target.position.x
		p1_move = Vector2(1.0, 0.0)
		p1_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 140:
		var pushed: float = target.position.x - float(recorded["target_x"])
		check(pushed > 1.0,
			"a dash into a player launches them along the dash axis (%.2f m east)" % pushed)
		eq(shover.state, PlayerBody.State.WALK, "and the shover's dash ends on the hit")
		_advance(3)

# --- 4. A dash through a missing parapet goes over the side -------------------

func _phase_dash_off_edge() -> void:
	if phase_frame == 1:
		# test_flat suppresses the parapet at x 0-3 on rows 4 and 5, so a dash
		# west from the outer column has nothing to stop it.
		var edge: Vector3 = world.grid.cell_surface_world(Vector2i(0, 4))
		shover.position = edge + Vector3(0.0, 1.0, 0.0)
		shover.velocity = Vector3.ZERO
		shover.state = PlayerBody.State.WALK
		shover.shove_cooldown = 0.0
		return
	if phase_frame == 40:
		recorded["edge_y"] = shover.position.y
		p1_move = Vector2(-1.0, 0.0)
		p1_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 200:
		var fell: float = float(recorded["edge_y"]) - shover.position.y
		check(fell > 2.0,
			"a dash through a missing parapet goes over the side (fell %.2f m)" % fell)
		finish()
