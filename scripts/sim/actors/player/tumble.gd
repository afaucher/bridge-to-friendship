extends RefCounted

# THE TUMBLE (M5): a chaotic pinwheeling bounce that KEEPS its momentum rather
# than sliding to a stop -- displacement is the threat on a bridge full of holes,
# not the damage -- and the ramp launch that turns hitting a ramp at speed into
# air. Entered from a hit, a shove that connects, or letting go of a ledge.
#
# Part of PlayerBody. It holds no state of its own: every value it changes rides
# capture_state(), which is what keeps a client's replay of a tumble exact.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

func step() -> void:
	var dt := SimConfig.TICK_DELTA
	body.velocity.y -= SimConfig.GRAVITY * dt

	# Ground friction only. Airborne, the body keeps everything it was given --
	# that is what makes a tumble carry you somewhere you did not want to go.
	if body.grounded:
		var horizontal := Vector3(body.velocity.x, 0.0, body.velocity.z)
		horizontal = horizontal.move_toward(Vector3.ZERO, SimConfig.TUMBLE_FRICTION * dt * horizontal.length())
		body.velocity.x = horizontal.x
		body.velocity.z = horizontal.z

	# What the body was doing when it arrived. move_and_slide is about to remove
	# the into-surface part of it, and both the ramp launch and any honest
	# reading of an impact need the value from before that.
	var approach: Vector3 = body.velocity
	body.move_and_slide()
	body.grounded = body.is_on_floor()

	# BOUNCE off whatever it hits, rather than stopping dead against it. A
	# tumbling player ricocheting off a parapet and back into the pillar field is
	# the whole point; sliding to a halt at the first wall is not a threat.
	#
	# THIS ALSO SCRUBS SPEED EVERY TICK WHILE GROUNDED, and that is DELIBERATE --
	# do not "fix" it. A resting body reports a floor contact each tick, so this
	# applies the restitution repeatedly and a tumble settles quickly once it is
	# down. The plinko ball had the identical pattern and it was a bug there,
	# because a ball has to keep rolling; here it is the behaviour, and it was
	# kept after playtest (2026-08-08) in preference to the "correct" version.
	# Consistency with the ball is not worth a tumble that feels worse.
	for i in body.get_slide_collision_count():
		var normal: Vector3 = body.get_slide_collision(i).get_normal()
		# A steep ramp THROWS a thrown body up itself, rather than bouncing it
		# back down. Checked before the bounce, because bouncing is what used to
		# happen and it is why a shove up a ramp went nowhere.
		#
		# Judged on the APPROACH velocity, not the current one: move_and_slide has
		# already removed the into-surface component, so reading it back says the
		# body was barely moving toward a wall it just hit at 11 m/s.
		if try_ramp_launch(normal, approach):
			break
		if body.velocity.dot(normal) < 0.0:
			body.velocity = body.velocity.bounce(normal) * SimConfig.TUMBLE_BOUNCE

	var slow_enough: bool = body.velocity.length() < SimConfig.TUMBLE_RECOVER_SPEED
	if body.state_timer >= SimConfig.TUMBLE_MAX_SECONDS \
			or (body.state_timer >= SimConfig.TUMBLE_MIN_SECONDS and body.grounded and slow_enough):
		end()

# A ramp too steep to walk, hit with momentum, throws you UP it.
#
# This is the co-op gate working rather than merely existing: the negative half
# ("a lone player cannot walk up") is worthless on its own, because a wall nobody
# can climb passes it too. This is the half that makes a steep ramp a gate
# instead of a dead end -- "they tie each other together, one pushes the other up
# the ramp", from the original brief.
#
# Called only from TUMBLE, never from SHOVE. See RAMP_LAUNCH_MIN_SPEED.
func try_ramp_launch(normal: Vector3, approach: Vector3) -> bool:
	# Moving into it, not sliding back down it.
	if approach.dot(normal) >= 0.0:
		return false
	if approach.length() < SimConfig.RAMP_LAUNCH_MIN_SPEED:
		return false

	# Steep enough to be a ramp rather than a floor, shallow enough to be a ramp
	# rather than a wall. A parapet must still stop you dead.
	var incline: float = rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
	if incline <= SimConfig.MAX_WALK_ANGLE_DEG or incline >= SimConfig.RAMP_LAUNCH_MAX_ANGLE_DEG:
		return false

	# Up the slope: world up, with the part pointing out of the surface removed.
	var up_slope: Vector3 = (Vector3.UP - normal * normal.y)
	if up_slope.length_squared() < 0.0001:
		return false
	# REDIRECTED, not projected. Projecting onto the slope costs a cosine of
	# speed, which is most of the energy needed to clear the climb.
	body.velocity = up_slope.normalized() * SimConfig.RAMP_LAUNCH_SPEED
	return true

func begin(launch: Vector3) -> void:
	if body.state == State.DOWNED or body.state == State.LEDGE_HANG:
		return
	body.state = State.TUMBLE
	body.state_timer = 0.0
	body.velocity = launch
	body.grounded = false
	body._pop_hats()

func end() -> void:
	body.state = State.WALK
	body.state_timer = 0.0
	body.velocity.x = 0.0
	body.velocity.z = 0.0
