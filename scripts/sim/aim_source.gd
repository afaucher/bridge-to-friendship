extends RefCounted

# Where the player is pointing, from whichever device they last touched.
#
# THE FACING IS ABSOLUTE, NEVER INTEGRATED. Both devices name a direction
# outright -- the cursor is at a place on the deck, the right stick is held at an
# angle -- so the answer is read, not accumulated. That is what "snappy and locked
# in" has to mean mechanically: there is no turn rate to lag behind the input, no
# smoothing to overshoot, and no drift to accumulate. Point, and you are pointing.
#
# A turn-rate version was never written and should not be: on a fixed camera the
# cursor IS the aim, and any interpolation between the current facing and the
# cursor shows up as the character lagging the pointer, which reads as input lag
# even when the input is arriving perfectly.
#
# THE DEVICE IS CHOSEN BY LAST USE, not by a setting. Someone on a pad who nudges
# the mouse should not have their aim yanked across the deck, and someone on a
# mouse should not have it stolen by a resting stick. Whichever one MOVED most
# recently owns the aim until the other one moves.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# No device has ever been touched, so there is no aim to report and the body
# should fall back to the way it is moving. NOT an angle: every real angle is a
# valid facing, so the "none" case cannot be a number in the same range.
const NONE := INF

enum Device { NONE, MOUSE, PAD }

var _device: int = Device.NONE
var _yaw: float = 0.0
var _last_mouse: Vector2 = Vector2.ZERO
var _has_mouse_sample: bool = false

# How far the mouse must move to claim the aim back from a gamepad. A few pixels
# of desk vibration is not a decision.
const MOUSE_CLAIM_PIXELS := 3.0

# HOW FAR OUT A PAD'S VIRTUAL CURSOR SITS (M20).
#
# A stick gives an angle and no place, so `point` mode would have nothing to aim
# at on a pad. Alien Swarm's answer is a cursor locked to a circle around the
# character, adjustable by cvar, and this takes the same one -- so the pad
# resolves to a POINT exactly as the mouse does and nothing downstream has to know
# which device it came from.
#
# Six metres is inside MG_RANGE and roughly where a rusher becomes a problem. It
# is a starting value: the assist is what makes a fixed radius playable, because
# the ray only has to pass NEAR an enemy rather than through it.
const PAD_CURSOR_RANGE := 6.0

# How far above and below the virtual cursor to look for ground. A pad points at
# a bearing, so the height has to come from the terrain under that bearing --
# generous enough to find a deck two units up or a pit below.
const PAD_GROUND_PROBE := 12.0

# The last point the cursor resolved to in the world, or AIM_POINT_NONE.
var _point: Vector3 = Vector3.INF

# WHERE the player is pointing, as a place. `poll` answers which WAY, and the two
# are deliberately separate calls over the same cursor: the bearing is what the
# body faces and has shipped for months, and the point is new and optional. A
# single call returning both would have made the control path carry the new code.
func point() -> Vector3:
	return _point

# Returns the yaw the player is pointing, or NONE.
#
# `camera` and `from` are needed for the mouse: a cursor is a point on the SCREEN
# and the answer wanted is a direction on the DECK, so the ray has to be cast and
# met with the plane the player is standing on. That is why this cannot live in
# PlayerInput.sample() with the rest of the input -- sampling is static and knows
# about neither.
# Resolve the cursor to a world POSITION. Called beside poll(), never instead of
# it -- see the note on `point()`.
#
# THE MOUSE RAY GOES INTO THE WORLD, not onto a plane. A plane at the player's
# height is what `_yaw_to_cursor` uses and is exactly right for a bearing; it is
# exactly wrong for a point, because it would put every aim at the player's own
# height and reintroduce the level-shot problem this feature exists to solve.
#
# FALLING BACK TO THAT PLANE when the ray hits nothing is deliberate: pointing at
# the sky past the end of the bridge should aim somewhere sensible rather than
# nowhere.
func resolve_point(camera: Camera3D, from: Vector3) -> Vector3:
	_point = Vector3.INF
	if camera == null:
		return _point
	var space: PhysicsDirectSpaceState3D = camera.get_world_3d().direct_space_state
	if _device == Device.PAD:
		_point = _pad_point(space, from)
		return _point
	_point = _mouse_point(camera, from)
	return _point

# WHERE THE CURSOR IS POINTING, AND THERE IS EXACTLY ONE ANSWER TO THAT.
#
# It used to be two. `resolve_point` cast a ray at the world and `_yaw_to_cursor`
# intersected a horizontal plane through the player, so `point` mode named the
# thing under the cursor while `level` mode named a spot on the floor behind it.
# They agree for anything standing at your own height and disagree by more the
# higher it is.
#
# WHAT THAT COST, reported from play 2026-08-25: "if you point at an elevated
# enemy your cursor doesn't select them -- only when you point at different spots
# near them, and I can't quite figure out what the correlation is." The camera is
# pitched 45 degrees, so tan is 1 and a target `h` metres up puts the plane point
# `h` metres BEYOND it along the camera's view direction. The bearing error is
# therefore height times how far off the camera's axis the target sits: an enemy
# directly up-bridge is displaced radially and still aims true, one off to the
# side is displaced sideways and misses. At the watchpost -- 2.45 m up, 7.4 m out
# -- that is up to 18 degrees, which puts the level ray 2.4 m wide of a turret the
# assist only reaches within 0.6 m of. Hence "spots near them" working: those are
# the places where the floor under the cursor really does line up with the enemy.
#
# So this is the one function, and both callers ask it. Two implementations of one
# fact is the trap CLAUDE.md records from the ladder face, where the copies also
# "never changed and disagreed anyway" -- they were never the same arithmetic.
func _mouse_point(camera: Camera3D, from: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = camera.get_world_3d().direct_space_state
	var mouse := camera.get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var hit := _cast(space, origin, origin + direction * 200.0)
	if not hit.is_empty():
		return hit["position"]
	# NOTHING UNDER THE CURSOR -- pointing at the sky, or off the end of the
	# bridge. The plane through the player is the honest fallback: it is the only
	# height that means anything when there is no surface to name.
	var plane := Plane(Vector3.UP, from.y)
	var flat = plane.intersects_ray(origin, direction)
	return flat if flat != null else Vector3.INF

# A pad has no cursor, so one is invented on a circle around the player and then
# dropped onto whatever is under it -- which is what gives a stick a height.
func _pad_point(space: PhysicsDirectSpaceState3D, from: Vector3) -> Vector3:
	var flat: Vector3 = from + GridConfig.yaw_vector(_yaw) * PAD_CURSOR_RANGE
	var hit := _cast(space, flat + Vector3(0.0, PAD_GROUND_PROBE, 0.0),
		flat - Vector3(0.0, PAD_GROUND_PROBE, 0.0))
	return hit["position"] if not hit.is_empty() else flat

# WORLD AND ENEMIES, NOT PLAYERS. Aiming through a teammate has to be possible or
# the party becomes cover for the enemy; aiming at the deck and at the things
# standing on it is the whole point. Layers 1 (world) and 5 (rushers).
func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = (1 << 0) | (1 << 4)
	query.collide_with_areas = false
	return space.intersect_ray(query)

func poll(camera: Camera3D, from: Vector3) -> float:
	var pad := Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down")
	if pad.length_squared() > 0.0:
		# Past the deadzone, so this is a deliberate hold. The stick's ANGLE is
		# the answer and its magnitude is discarded: pushing the stick further
		# does not point you harder.
		_device = Device.PAD
		_yaw = GridConfig.yaw_of(pad)
		return _yaw

	var mouse := _mouse_moved()
	if mouse != NONE and camera != null:
		var aimed := _yaw_to_cursor(camera, from)
		if aimed != NONE:
			_device = Device.MOUSE
			_yaw = aimed
			return _yaw

	# Nothing moved. HOLD, do not recentre -- a released stick means "keep
	# pointing where I left you", and a still mouse means the same.
	if _device == Device.MOUSE and camera != null:
		# The mouse is still but the PLAYER is not: walking past a stationary
		# cursor has to keep the character pointed at it, or the aim slides off
		# the moment you move.
		var aimed := _yaw_to_cursor(camera, from)
		if aimed != NONE:
			_yaw = aimed
		return _yaw
	if _device == Device.NONE:
		return NONE
	return _yaw

# Has the mouse moved far enough to claim the aim? Returns NONE when it has not.
func _mouse_moved() -> float:
	var pos := Vector2.ZERO
	var viewport := Engine.get_main_loop()
	if viewport is SceneTree and (viewport as SceneTree).root != null:
		pos = (viewport as SceneTree).root.get_mouse_position()
	if not _has_mouse_sample:
		_has_mouse_sample = true
		_last_mouse = pos
		# The FIRST sample is not a movement. Without this a gamepad player has
		# the aim taken off them on the very first frame by a cursor that has
		# simply always been somewhere.
		return NONE
	if pos.distance_to(_last_mouse) < MOUSE_CLAIM_PIXELS:
		return NONE
	_last_mouse = pos
	return 0.0

# The bearing to whatever the cursor is on.
#
# ASKED OF `_mouse_point`, WHICH IS THE FIX. This used to intersect a horizontal
# plane through the player itself -- a second, quieter answer to the question
# `resolve_point` was already answering by raycast -- so `level` mode aimed at the
# floor behind an elevated enemy rather than at the enemy. See _mouse_point for
# the measurement and for why the failure looked uncorrelated from inside the game.
#
# The plane still decides it when the ray hits nothing, and it is still the plane
# through the PLAYER rather than y = 0: the bridge climbs in layers, so a fixed
# plane would put the aim metres off up-bridge and the error would grow the
# further the party climbed -- the worst shape an aiming bug can have.
func _yaw_to_cursor(camera: Camera3D, from: Vector3) -> float:
	var hit: Vector3 = _mouse_point(camera, from)
	if not is_finite(hit.x):
		# Looking along the plane, or away from it. Keep the last answer rather
		# than snapping somewhere arbitrary.
		return NONE
	var offset: Vector3 = hit - from
	if Vector2(offset.x, offset.z).length_squared() < 0.0001:
		# Cursor exactly on the player: there is no direction to report.
		return NONE
	return GridConfig.yaw_of_vector(offset)
