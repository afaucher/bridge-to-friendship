extends RefCounted

# THE SHOVE (M4): a committed dash along the direction you were pointing at the
# press, and the other end of it -- what arriving momentum does to the body it
# hits. A shove into a climb carries you up it; anywhere else it tumbles you.
#
# Part of PlayerBody. It holds no state of its own: `shove_yaw` and
# `shove_cooldown` stay on the body because they ride capture_state().

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

func begin(move: Vector2, aim: float) -> void:
	# A shove commits to the direction you were POINTING at the instant of the
	# press, and to nothing afterwards. The commitment is the design (see
	# step() below); what changed with free aim is only that the committed
	# direction is now any angle rather than one of four.
	body.shove_yaw = body._aim_yaw(move, aim)
	body.facing = body.shove_yaw
	body.state = State.SHOVE
	body.state_timer = 0.0
	var axis: Vector3 = GridConfig.yaw_vector(body.shove_yaw)
	body.velocity.x = axis.x * SimConfig.SHOVE_SPEED
	body.velocity.z = axis.z * SimConfig.SHOVE_SPEED

func step() -> void:
	var dt := SimConfig.TICK_DELTA

	# The dash holds its speed along its axis and cannot be steered, slowed or
	# cancelled. Gravity still applies, so a dash off the deck is a dash off the
	# deck -- that commitment is where the comedy lives, and it is also why the
	# client does not predict this state: there is no input to mispredict.
	var axis: Vector3 = GridConfig.yaw_vector(body.shove_yaw)
	body.velocity.x = axis.x * SimConfig.SHOVE_SPEED
	body.velocity.z = axis.z * SimConfig.SHOVE_SPEED
	if body.grounded:
		body.velocity.y = -SimConfig.FLOOR_STICK
	else:
		body.velocity.y -= SimConfig.GRAVITY * dt

	body.move_and_slide()
	body.grounded = body.is_on_floor()

	var hit_something := false
	for i in body.get_slide_collision_count():
		var collision: KinematicCollision3D = body.get_slide_collision(i)
		# Only side-on contacts count. Running along the floor is not "hitting
		# something", and neither is clipping a ceiling.
		if absf(collision.get_normal().y) > 0.7:
			continue
		hit_something = true
		if body.world != null:
			body.world.resolve_shove_contact(body, collision.get_collider(), body.shove_yaw)

	if hit_something or body.state_timer >= SimConfig.SHOVE_DURATION:
		end()

func end() -> void:
	if body.state != State.SHOVE:
		return
	body.state = State.WALK
	body.state_timer = 0.0
	body.shove_cooldown = SimConfig.SHOVE_COOLDOWN
	body.velocity.x = 0.0
	body.velocity.z = 0.0

# Momentum arriving from someone else's dash. Called by the world, which owns
# the transfer rules.
func receive(yaw: float) -> void:
	if body.state == State.DOWNED or body.state == State.LEDGE_HANG:
		return
	var axis: Vector3 = GridConfig.yaw_vector(yaw)

	# A BOOST UP A SLOPE IS NOT A SHOVE OFF A BRIDGE, and the same impulse cannot
	# serve both. Reported as "we implemented dashing into players to knock them
	# up a steep rise but it was janky": measured, it CLEARS the ramp 25 times out
	# of 26 -- the unreliability was never the problem. The problem is that it
	# arrives as a TUMBLE, so the player who has just been helped up loses control
	# at the top and goes wherever the bridge sends them.
	#
	# That is exactly right when somebody dashes you into open air, which is where
	# the comedy lives and stays. It is exactly wrong for the one move the design
	# calls a co-op gate (MVP A4), and it gets worse the moment a section REQUIRES
	# two players: a climb you cannot land is a climb you cannot rely on.
	#
	# So the shove asks what it is pushing you INTO. Up a ramp, you keep control
	# and get carried; anywhere else, you tumble as before.
	if boosted_up_a_ramp(axis):
		body.state = State.WALK
		body.state_timer = 0.0
		body.grounded = false
		body.velocity = Vector3(
			axis.x * SimConfig.BOOST_CARRY_SPEED,
			SimConfig.BOOST_LIFT,
			axis.z * SimConfig.BOOST_CARRY_SPEED)
		return

	# A dash arrives at 56 m/s. That is not a nudge -- it TUMBLES you, which is
	# where the comedy lives: the shoved player loses control and goes wherever
	# the bridge sends them.
	body.begin_tumble(Vector3(
		axis.x * SimConfig.SHOVE_TRANSFER_SPEED,
		SimConfig.SHOVE_TRANSFER_LIFT,
		axis.z * SimConfig.SHOVE_TRANSFER_SPEED))

# Is the shove pushing this body INTO a climb? Asked of the cell ahead along the
# shove axis rather than the one underfoot: at the foot of a ramp you are still
# standing on flat deck, which is precisely where a boost is asked for.
func boosted_up_a_ramp(axis: Vector3) -> bool:
	if body.world == null or body.world.grid == null:
		return false
	var grid: Node = body.world.grid
	var here: Vector2i = grid.cell_of_world(body.position)
	for cells in [1.0, 2.0]:
		var ahead: Vector2i = grid.cell_of_world(body.position + axis * (GridConfig.CELL_SIZE * cells))
		if ahead == here:
			continue
		if not grid.is_solid(ahead):
			return false          # being shoved at a hole is a shove, not a boost
		if grid.kind_at(ahead) == GridConfig.Kind.RAMP:
			return true
		if grid.height_at(ahead) > grid.height_at(here):
			return true           # a step up counts too, even a bare one
		return false
	return false
