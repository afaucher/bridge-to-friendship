extends Control

# WHERE YOUR FRIENDS ARE WHEN YOU CANNOT SEE THEM.
#
# Two things, asked for in the 2026-08-13 playtest and again on 2026-08-14:
#
#   THE DORITO -- a triangle pinned to the edge of the screen, pointing at a
#   teammate who is off it.
#   THE DOWNED FLASH -- a downed friend is marked whether or not they are on
#   screen, and it pulses, because a static marker in a busy frame is wallpaper.
#
# IT MATTERS MORE THAN IT DID A ROUND AGO. Everything M15 added pulls the party
# apart: a shield anchors somebody in place, a mine asks a player to hang back, a
# skirmisher is answered by closing and a turret by taking cover. Knowing where a
# downed friend is stops being a convenience the moment the group has reasons to
# spread out.
#
# THE MATHS IS A PURE FUNCTION AND THE DRAWING IS NOT. `markers_for` takes a
# camera and returns what to draw; `_draw` renders it and decides nothing. That is
# what lets the gate assert any of this -- the output of `_draw` cannot be read
# back, so a version that decided placement inside it would be untestable, and
# CLAUDE.md's rule is that a view script the gate never exercises ships having
# never run.

# How far inside the edge a marker sits, so it is never half off the screen.
const EDGE_INSET := 34.0

# Below this from an edge, a teammate counts as off screen. A little inside the
# real border: somebody one pixel inside the frame is somebody you have already
# lost track of.
const EDGE_MARGIN := 48.0

const TRIANGLE_SIZE := 15.0

# A full flash cycle. Fast enough to catch the eye, slow enough not to strobe.
const FLASH_PERIOD := 0.7

const COLOR_DOWNED := Color(1.0, 0.35, 0.25, 1.0)
const COLOR_FRIEND := Color(0.72, 0.80, 0.95, 0.85)

var entries: Array = []
var camera: Camera3D = null
var age: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func refresh(list: Array, cam: Camera3D, delta: float) -> void:
	entries = list
	camera = cam
	age += delta
	queue_redraw()

# --- The decision ------------------------------------------------------------

# Returns one descriptor per marker that should be drawn. An entry needs `at`
# (Vector3, world) and `downed` (bool).
#
# `age` drives the flash and is passed in rather than read from a clock, so a test
# can ask for a specific point in the cycle instead of waiting for one.
# TWO FUNCTIONS, AND THE SPLIT IS WHAT MAKES THIS TESTABLE.
#
# `markers_for` does the part that needs a real camera and a real viewport;
# `place` does the part this project actually decided -- where a marker goes, which
# way it points, and whether it is lit.
#
# THE HEADLESS VIEWPORT IS 64x64. Measured 2026-08-14: a friend dead ahead projects
# to (32, 32), which is correct and also inside EDGE_MARGIN of every edge at once,
# so under `--headless` every teammate in the world reads as off screen. A test
# that went through a camera could therefore only ever assert nonsense. `place`
# takes an already-projected point and an explicit screen size, so the gate can
# hand it 1280x720 and mean it.
static func markers_for(list: Array, cam: Camera3D, age_seconds: float) -> Array:
	var out: Array = []
	if cam == null:
		return out
	var viewport := cam.get_viewport()
	if viewport == null:
		return out
	var screen: Vector2 = viewport.get_visible_rect().size
	for entry in list:
		var at: Vector3 = entry.get("at", Vector3.ZERO)
		var marker: Dictionary = place(
			cam.unproject_position(at), cam.is_position_behind(at), screen,
			bool(entry.get("downed", false)), age_seconds)
		if marker.is_empty():
			continue
		marker["peer"] = int(entry.get("peer", 0))
		out.append(marker)
	return out

# Where one marker goes. Empty means "draw nothing", which is the answer for a
# healthy friend you can already see.
static func place(point: Vector2, behind: bool, screen: Vector2, downed: bool,
		age_seconds: float) -> Dictionary:
	var centre: Vector2 = screen * 0.5

	# BEHIND THE CAMERA IS THE CASE THAT GOES WRONG ON ITS OWN. unproject_position
	# on a point behind the lens returns a MIRRORED projection -- it reads as being
	# on the opposite side of the screen, so a friend standing behind your right
	# shoulder gets an arrow pointing left. Flipping about the centre puts it back.
	if behind:
		point = centre + (centre - point)

	var off: bool = behind 		or point.x < EDGE_MARGIN or point.x > screen.x - EDGE_MARGIN 		or point.y < EDGE_MARGIN or point.y > screen.y - EDGE_MARGIN

	# A healthy friend you can already see needs no furniture on the screen.
	if not off and not downed:
		return {}

	var dir: Vector2 = point - centre
	if dir.length_squared() < 0.0001:
		dir = Vector2.UP
	dir = dir.normalized()

	var pos: Vector2 = point
	if off:
		# Pinned to the edge, on the ray toward where they actually are.
		var half: Vector2 = centre - Vector2(EDGE_INSET, EDGE_INSET)
		var scale_x: float = half.x / absf(dir.x) if absf(dir.x) > 0.0001 else INF
		var scale_y: float = half.y / absf(dir.y) if absf(dir.y) > 0.0001 else INF
		pos = centre + dir * minf(scale_x, scale_y)

	return {
		"pos": pos,
		# Points AWAY from the middle when off screen -- at the friend. A downed
		# friend already on screen gets an arrow pointing down at them instead.
		"angle": dir.angle() if off else PI * 0.5,
		"offscreen": off,
		"downed": downed,
		# ONLY A DOWNED MARKER BLINKS. An off-screen friend who is fine is
		# information; a downed one is a summons, and the difference has to be
		# visible without reading anything.
		"shown": (not downed) or flash_on(age_seconds),
	}

static func flash_on(age_seconds: float) -> bool:
	return fmod(age_seconds, FLASH_PERIOD) < FLASH_PERIOD * 0.5

# --- The drawing --------------------------------------------------------------

func _draw() -> void:
	for marker in markers_for(entries, camera, age):
		if not bool(marker["shown"]):
			continue
		var colour: Color = COLOR_DOWNED if bool(marker["downed"]) else COLOR_FRIEND
		_triangle(marker["pos"], float(marker["angle"]), colour)

func _triangle(at: Vector2, angle: float, colour: Color) -> void:
	var points := PackedVector2Array([
		Vector2(TRIANGLE_SIZE, 0.0),
		Vector2(-TRIANGLE_SIZE * 0.7, TRIANGLE_SIZE * 0.7),
		Vector2(-TRIANGLE_SIZE * 0.7, -TRIANGLE_SIZE * 0.7),
	])
	var turned := PackedVector2Array()
	for p in points:
		turned.append(at + p.rotated(angle))
	draw_colored_polygon(turned, colour)
