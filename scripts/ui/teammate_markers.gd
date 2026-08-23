extends Control

# WHERE YOUR FRIENDS ARE WHEN YOU CANNOT SEE THEM.
#
# Two things, asked for in the 2026-08-13 playtest and again on 2026-08-14:
#
#   THE DORITO -- a triangle pinned to the edge of the screen, pointing at a
#   teammate who is off it.
#   THE DOWNED FLASH -- a friend who needs help alternates red and white, because
#   a static marker in a busy frame is wallpaper.
#
# THREE RULES, ALL OF THEM ABOUT NOT SPENDING ATTENTION TWICE (2026-08-15):
#
#   NOTHING IS DRAWN FOR SOMEBODY YOU CAN SEE. Not even a downed one -- they
#   already have a flashing bar over their head, in this same red, on this same
#   rhythm. A triangle stacked on top of that is the same warning twice, and the
#   earlier version drew one, permanently, on every downed player on screen.
#   GREEN IS "THERE", RED IS "COME". A friend out of shot is information and does
#   not move; a friend who needs help is a summons and does. If both flashed,
#   neither would mean anything.
#   RED TO WHITE, NEVER TO NOTHING. It used to blink out, so half the time the
#   thing you were being pointed at was not on screen -- and which half you catch
#   is luck.
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

# THE FLASH IS NOT DEFINED HERE. Colour, rhythm and clock all come from
# crisis_flash.gd, which the bar over a downed player's head reads as well -- so
# the arrow and the bar are one signal rather than two that resemble each other.
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")

var entries: Array = []
var camera: Camera3D = null
var age: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

# THE SAME CLOCK THE BARS USE, not an accumulated delta. Two accumulators started
# at different moments give two rhythms, and a screen with two rhythms on it reads
# as broken rather than as urgent.
func refresh(list: Array, cam: Camera3D) -> void:
	entries = list
	camera = cam
	age = CrisisFlash.now()
	queue_redraw()

# --- The decision ------------------------------------------------------------

# Returns one descriptor per marker that should be drawn. An entry needs `at`
# (Vector3, world) and `downed` (bool).
#
# `age_seconds` drives the flash and is passed in rather than read from a clock,
# so a test can ask for a specific point in the cycle instead of waiting for one.
# TWO FUNCTIONS, AND THE SPLIT IS WHAT MAKES THIS TESTABLE.
#
# `markers_for` does the part that needs a real camera and a real viewport;
# `place` does the part this project actually decided -- whether a marker exists at
# all, where it goes, which way it points, and what colour it is.
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
			bool(entry.get("downed", false)), age_seconds,
			bool(entry.get("calling_at", false)))
		if marker.is_empty():
			continue
		marker["peer"] = int(entry.get("peer", 0))
		out.append(marker)
	return out

# Where one marker goes. Empty means "draw nothing", which is now the answer for
# ANY friend you can already see -- healthy or not.
# HOW MUCH BIGGER A CALLING FRIEND'S MARKER IS. Large enough to be the thing you
# notice in a row of markers, not so large it stops reading as the same object --
# the marker still has to say WHERE, and a blob has no point.
const CALL_SCALE := 1.9

static func place(point: Vector2, behind: bool, screen: Vector2, downed: bool,
		age_seconds: float, calling: bool = false) -> Dictionary:
	var centre: Vector2 = screen * 0.5

	# BEHIND THE CAMERA IS THE CASE THAT GOES WRONG ON ITS OWN. unproject_position
	# on a point behind the lens returns a MIRRORED projection -- it reads as being
	# on the opposite side of the screen, so a friend standing behind your right
	# shoulder gets an arrow pointing left. Flipping about the centre puts it back.
	if behind:
		point = centre + (centre - point)

	var off: bool = behind 		or point.x < EDGE_MARGIN or point.x > screen.x - EDGE_MARGIN 		or point.y < EDGE_MARGIN or point.y > screen.y - EDGE_MARGIN

	# ON SCREEN IS ON SCREEN. A marker exists to point at something you cannot
	# see; once you can see them it is clutter, and clutter is how the marker
	# that matters gets ignored. A downed friend in shot is not unmarked -- the
	# bar over their head is flashing the same red on the same clock.
	if not off:
		return {}

	var dir: Vector2 = point - centre
	if dir.length_squared() < 0.0001:
		dir = Vector2.UP
	dir = dir.normalized()

	# Pinned to the edge, on the ray toward where they actually are.
	var half: Vector2 = centre - Vector2(EDGE_INSET, EDGE_INSET)
	var scale_x: float = half.x / absf(dir.x) if absf(dir.x) > 0.0001 else INF
	var scale_y: float = half.y / absf(dir.y) if absf(dir.y) > 0.0001 else INF

	return {
		"pos": centre + dir * minf(scale_x, scale_y),
		# Points AWAY from the middle -- at the friend.
		"angle": dir.angle(),
		"downed": downed,
		# THE COLOUR IS PART OF THE DECISION, not of the drawing, so the gate can
		# assert it. Steady green for a friend who is merely elsewhere; red
		# alternating to white for one who needs somebody to come.
		"colour": CrisisFlash.alternate(CrisisFlash.RED, age_seconds) if downed 			else CrisisFlash.FRIEND,
		# SIZE IS PART OF THE DECISION, like the colour above and for the same
		# reason: the gate can assert it, and _draw is left with nothing to decide.
		#
		# IT FLASHES rather than simply being big. A marker that grew and stayed
		# grown would be read once and then become the new normal; alternating on
		# the crisis clock is what makes it keep asking. Same clock the downed
		# colour uses, so a friend who is both does one thing rather than two.
		"size": TRIANGLE_SIZE * (CALL_SCALE if calling and CrisisFlash.on(age_seconds) 			else 1.0),
	}

# --- The drawing --------------------------------------------------------------

func _draw() -> void:
	for marker in markers_for(entries, camera, age):
		_triangle(marker["pos"], float(marker["angle"]), marker["colour"],
			float(marker.get("size", TRIANGLE_SIZE)))

func _triangle(at: Vector2, angle: float, colour: Color, size: float) -> void:
	var points := PackedVector2Array([
		Vector2(size, 0.0),
		Vector2(-size * 0.7, size * 0.7),
		Vector2(-size * 0.7, -size * 0.7),
	])
	var turned := PackedVector2Array()
	for p in points:
		turned.append(at + p.rotated(angle))
	draw_colored_polygon(turned, colour)
