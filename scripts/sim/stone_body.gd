extends CharacterBody3D

# A pillar stone. Rearranging the bridge is a verb: a dashing player shoves a
# stone into the next cell, or through a hole, where it falls away.
#
# THE STONE SNAPS TO CELLS; THE PLAYER DOES NOT. A dash ends wherever it ends,
# but "did the stone move a cell?" has to be answerable at a glance from across
# the bridge -- so the push is a discrete, designed outcome and the slide between
# cells is presentation. That split is the whole reason the integrator is ours
# and not a rigid-body solver's; see design_ideas/physics_and_authority.md.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

enum Mode { SETTLED, SLIDING, FALLING }

var cell: Vector2i = Vector2i.ZERO
var mode: int = Mode.SETTLED

# Where a slide is heading, in local space. Only meaningful while SLIDING.
var target: Vector3 = Vector3.ZERO

# How far this body moved during its own last step -- what a rider inherits.
var motion_delta: Vector3 = Vector3.ZERO

func step() -> void:
	var before := position
	match mode:
		Mode.SLIDING:
			_step_slide()
		Mode.FALLING:
			velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
			move_and_slide()
		_:
			velocity = Vector3.ZERO
	motion_delta = position - before

func _step_slide() -> void:
	var to_target := target - position
	var step_length := SimConfig.STONE_PUSH_SPEED * SimConfig.TICK_DELTA
	if to_target.length() <= step_length:
		# Land exactly on the cell centre. Creeping to within a few millimetres
		# and calling it arrived is how a grid stops being a grid.
		position = target
		velocity = Vector3.ZERO
		mode = Mode.SETTLED
		return
	velocity = to_target.normalized() * SimConfig.STONE_PUSH_SPEED
	move_and_slide()

# Begin sliding to a new cell. The grid has already decided this is legal and
# has already recorded the stone as being there -- authority is the grid's, not
# the body's.
func slide_to(new_cell: Vector2i, world_target: Vector3) -> void:
	cell = new_cell
	target = world_target
	mode = Mode.SLIDING

# Pushed into a hole. The grid has already dropped it from the cell map; this is
# only the falling away.
func start_falling(direction: Vector3) -> void:
	mode = Mode.FALLING
	velocity = direction * SimConfig.STONE_PUSH_SPEED

func is_gone() -> bool:
	return mode == Mode.FALLING and position.y < SimConfig.FALL_KILL_Y

# Riders inherit a carrier's motion; see player_body.ride().
func ride(delta: Vector3) -> void:
	if delta != Vector3.ZERO:
		position += delta

func capture_state() -> Array:
	return [position, cell, mode, target]

func apply_state(s: Array) -> void:
	position = s[0]
	cell = s[1]
	mode = int(s[2])
	target = s[3]
