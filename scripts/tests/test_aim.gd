extends "res://scripts/test_support/test_case.gd"

# Free aim: facing is a continuous angle, decided by the mouse or the right
# stick, and the dash goes wherever it points.
#
# The claims worth defending:
#
#   1. The yaw convention is Godot's own, and round-trips. Everything else here
#      is built on that being true, so it is asserted first and directly.
#   2. Facing is INDEPENDENT of movement -- you strafe one way while pointing
#      another. That is the whole revision in one assertion.
#   3. A dash goes to the AIM, at any angle, and NOT to the nearest cardinal.
#      Asserted with an angle that is nowhere near one, so a leftover snap could
#      not pass it.
#   4. With no aiming device the dash still follows the feet, which is what a
#      keyboard-only player and every older test expect.
#   5. A dash with nothing held at all still fires, along the last facing. A verb
#      that silently refuses reads as a dropped input, and this one spends a
#      cooldown either way.
#   6. Where the free angle meets the CELL GRID: an off-axis dash into a stone
#      still moves it exactly one cell, in the nearest cardinal. There is no
#      20-degree cell to push it into.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Deliberately not near a quarter turn: 40 degrees west of north is 5 degrees off
# the halfway line between north and west, so a snap to EITHER neighbour would
# miss it by a wide margin and the tolerance never has to be argued about.
const OFF_AXIS := deg_to_rad(40.0)

var world: Node3D = null
var walker: CharacterBody3D = null
var stone_cell := Vector2i.ZERO
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

var p_move: Vector2 = Vector2.ZERO
var p_actions: int = 0
var p_aim: float = PlayerInput.AIM_NONE

func setup(main) -> void:
	timeout_seconds = 40.0
	_test_yaw_convention()

	world = Node3D.new()
	world.name = "AimWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)

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
	walker = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, p_move, p_actions, p_aim)

# --- 1. The convention ---------------------------------------------------------
#
# Pure functions, so asserted directly rather than inferred from a body's motion.
# Everything below depends on these, and a sign error here would show up as some
# unrelated thing being mysteriously mirrored.
func _test_yaw_convention() -> void:
	near(GridConfig.yaw_vector(0.0).z, -1.0, 0.001, "yaw 0 points north, which is -Z")
	near(GridConfig.yaw_vector(-PI * 0.5).x, 1.0, 0.001, "and -90 degrees points east, +X")
	near(GridConfig.yaw_vector(0.0).length(), 1.0, 0.001, "a yaw vector is a unit vector")

	# The round trip, at an angle chosen to be nowhere near a quarter turn.
	var v := GridConfig.yaw_vector(OFF_AXIS)
	near(GridConfig.yaw_of_vector(v), OFF_AXIS, 0.001, "yaw -> vector -> yaw is the identity")

	# And the snap the cell grid needs, at all four quarter turns plus one that
	# has to round.
	eq(GridConfig.yaw_to_direction(0.0), GridConfig.DIR_NORTH, "yaw 0 snaps to north")
	eq(GridConfig.yaw_to_direction(-PI * 0.5), GridConfig.DIR_EAST, "-90 snaps to east")
	eq(GridConfig.yaw_to_direction(PI), GridConfig.DIR_SOUTH, "180 snaps to south")
	eq(GridConfig.yaw_to_direction(PI * 0.5), GridConfig.DIR_WEST, "+90 snaps to west")
	eq(GridConfig.yaw_to_direction(OFF_AXIS), GridConfig.DIR_NORTH,
		"40 degrees west of north still snaps to north, not to west")

func _physics_process(_delta: float) -> void:
	if walker == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_facing_is_independent()
		1: _phase_dash_follows_aim()
		2: _phase_no_aim_follows_feet()
		3: _phase_dash_with_nothing_held()
		4: _phase_off_axis_push_is_still_one_cell()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 2. Facing is independent of movement -------------------------------------

func _phase_facing_is_independent() -> void:
	if phase_frame == 1:
		# Walking EAST, pointing 40 degrees west of north. Under the old scheme
		# these could not disagree: facing was derived from the movement stick.
		p_move = Vector2(1.0, 0.0)
		p_aim = OFF_AXIS
		return
	if phase_frame == 20:
		near(walker.facing, OFF_AXIS, 0.001,
			"facing follows the AIM, not the direction of travel")
		check(walker.velocity.x > 1.0,
			"and the player is genuinely walking the other way (%.2f m/s east)" % walker.velocity.x)

		# Snappy: a new aim is taken up the same tick, with no turn rate to lag
		# behind it. Set it here, read it on the very next frame.
		p_aim = -OFF_AXIS
		return
	if phase_frame == 21:
		near(walker.facing, -OFF_AXIS, 0.001,
			"and a new aim is taken up IMMEDIATELY -- no easing, no turn rate")
		_advance(1)

# --- 3. The dash goes where you point -----------------------------------------

func _phase_dash_follows_aim() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 9))
		return
	if phase_frame == 20:
		# Aiming off-axis while holding a movement direction that is not merely
		# different but OPPOSITE, so "it used the movement" and "it used the aim"
		# cannot both look the same.
		p_move = Vector2(0.0, 1.0)          # south
		p_aim = OFF_AXIS                    # 40 degrees west of north
		p_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 21:
		p_actions = 0
		near(walker.shove_yaw, OFF_AXIS, 0.001, "the dash committed to the AIM, not the movement")
		eq(walker.state, PlayerBody.State.SHOVE, "and it is running")

		# The velocity really points there -- not just the bookkeeping field.
		var want := GridConfig.yaw_vector(OFF_AXIS)
		var got := Vector3(walker.velocity.x, 0.0, walker.velocity.z).normalized()
		near(got.angle_to(want), 0.0, 0.02,
			"and the body is actually moving that way (%.1f degrees off)"
				% rad_to_deg(got.angle_to(want)))

		# THE POINT OF THE REVISION, stated as a negative: this is not a cardinal.
		# A leftover snap would have produced exactly north or exactly west.
		var nearest: float = round(walker.shove_yaw / (PI * 0.5)) * PI * 0.5
		check(absf(walker.shove_yaw - nearest) > deg_to_rad(5.0),
			"and it is NOT snapped to a compass axis (%.1f degrees off the nearest)"
				% rad_to_deg(absf(walker.shove_yaw - nearest)))
		_advance(2)

# --- 4. No aiming device: the dash follows the feet ---------------------------

func _phase_no_aim_follows_feet() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 9))
		return
	if phase_frame == 20:
		p_move = Vector2(1.0, 0.0)          # east
		p_aim = PlayerInput.AIM_NONE        # keyboard only, nothing pointing
		p_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 21:
		p_actions = 0
		near(walker.shove_yaw, -PI * 0.5, 0.001,
			"with no aiming device the dash follows the feet -- east")
		_advance(3)

# --- 5. Nothing held at all: it still fires -----------------------------------

func _phase_dash_with_nothing_held() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 9))
		walker.facing = OFF_AXIS            # left pointing somewhere from before
		return
	if phase_frame == 20:
		p_move = Vector2.ZERO
		p_aim = PlayerInput.AIM_NONE
		p_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 21:
		p_actions = 0
		eq(walker.state, PlayerBody.State.SHOVE,
			"a dash with nothing held still fires rather than silently refusing")
		near(walker.shove_yaw, OFF_AXIS, 0.001, "along the way the player was already facing")
		_advance(4)

# --- 6. The cell grid is still the cell grid ----------------------------------
#
# The one place the two systems have to meet. A stone moves exactly ONE CELL, and
# a cell has four neighbours however you were pointing when you hit it -- so an
# off-axis dash has to resolve to a cardinal at the moment of contact, and the
# push has to stay legible from across the bridge.
func _phase_off_axis_push_is_still_one_cell() -> void:
	if phase_frame == 1:
		# Squarely south of the stone, aimed 40 degrees off north at it. The
		# approach is off-axis; the answer must not be.
		var at: Vector3 = world.grid.cell_surface_world(
			stone_cell + GridConfig.DIR_CELLS[GridConfig.DIR_SOUTH])
		walker.position = at + Vector3(0.0, 1.0, 0.0)
		walker.velocity = Vector3.ZERO
		walker.state = PlayerBody.State.WALK
		walker.grounded = true
		walker.shove_cooldown = 0.0
		p_move = Vector2.ZERO
		p_actions = 0
		p_aim = PlayerInput.AIM_NONE
		return
	if phase_frame == 30:
		p_aim = OFF_AXIS
		p_actions = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 31:
		p_actions = 0
		return
	if phase_frame == 120:
		var moved_to: Vector2i = stone_cell + GridConfig.DIR_CELLS[GridConfig.DIR_NORTH]
		check(world.grid.stone_at(moved_to) != null,
			"an off-axis dash still pushes a stone exactly one cell, in the nearest cardinal")
		eq(world.grid.stone_at(stone_cell), null, "and it left the cell it was in")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	walker.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	walker.velocity = Vector3.ZERO
	walker.state = PlayerBody.State.WALK
	walker.grounded = true
	walker.shove_cooldown = 0.0
	p_move = Vector2.ZERO
	p_actions = 0
	p_aim = PlayerInput.AIM_NONE
