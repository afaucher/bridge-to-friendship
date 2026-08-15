extends "res://scripts/test_support/test_case.gd"

# The dorito, and the downed flash. Asked for on 2026-08-13, asked for AGAIN on
# 2026-08-14 because it had not been built.
#
# The claims:
#   1. A HEALTHY FRIEND YOU CAN SEE GETS NOTHING. Furniture on the screen for
#      something already visible is noise, and noise is how a real marker gets
#      ignored.
#   2. A FRIEND OFF THE SIDE GETS AN EDGE MARKER POINTING AT THEM. Pinned inside
#      the frame, on the ray toward where they really are.
#   3. A FRIEND BEHIND THE CAMERA POINTS THE RIGHT WAY. This is the case that goes
#      wrong on its own: unproject_position MIRRORS a point behind the lens, so
#      the naive version puts the arrow on exactly the wrong side.
#   4. A DOWNED FRIEND IS MARKED EVEN ON SCREEN, and it FLASHES -- shown for half
#      the cycle and hidden for the other half. A static marker in a busy frame is
#      wallpaper.
#
# The maths is a pure function precisely so this test can exist: `_draw` output
# cannot be read back, so a version that decided placement inside it would be
# untestable.

const Markers = preload("res://scripts/ui/teammate_markers.gd")

# A REAL SCREEN, NOT THE ONE HEADLESS HAS. Measured 2026-08-14: the headless
# viewport is 64x64, so a friend dead ahead projects to (32, 32) -- correct, and
# also inside EDGE_MARGIN (48) of all four edges at once. Every teammate in the
# world reads as off screen there. So the placement maths is tested against an
# explicit size with hand-made points, and the camera is left out of it: the
# projection is Godot's, the placement is ours, and only one of those is worth a
# gate.
const SCREEN := Vector2(1280.0, 720.0)

func setup(_main) -> void:
	timeout_seconds = 20.0
	var centre := SCREEN * 0.5

	# --- 1. Straight ahead and healthy: nothing ------------------------------
	check(Markers.place(centre, false, SCREEN, false, 0.0).is_empty(),
		"a healthy friend you can already see gets no marker -- clutter is how a "
		+ "real one gets ignored")

	# --- 2. Off to the side: an edge marker pointing at them -----------------
	var side: Dictionary = Markers.place(
		Vector2(SCREEN.x + 400.0, centre.y), false, SCREEN, false, 0.0)
	check(not side.is_empty(), "a friend off the side of the screen gets one")
	if not side.is_empty():
		check(bool(side["offscreen"]), "flagged as off screen")
		var pos: Vector2 = side["pos"]
		check(pos.x > centre.x,
			"pinned to the RIGHT half, the side they are on (x %.0f)" % pos.x)
		check(pos.x <= SCREEN.x and pos.y >= 0.0 and pos.y <= SCREEN.y,
			"and inside the frame rather than half off it (%.0f, %.0f)" % [pos.x, pos.y])
		check(absf(wrapf(float(side["angle"]), -PI, PI)) < PI * 0.5,
			"with the triangle pointing at them (%.2f rad)" % side["angle"])
		check(bool(side["shown"]), "and a healthy friend's marker does not blink")

	# --- 3. Behind the camera: the mirrored-projection trap ------------------
	#
	# THIS IS THE CASE THAT GOES WRONG ON ITS OWN, so it is asserted by SIGN.
	# A friend behind your right shoulder projects to the LEFT of centre, because
	# unproject_position mirrors anything behind the lens. Without the flip the
	# arrow points a player away from the friend they are looking for -- which is
	# worse than no arrow, because they will believe it.
	var behind: Dictionary = Markers.place(
		Vector2(centre.x - 300.0, centre.y), true, SCREEN, false, 0.0)
	check(not behind.is_empty(), "a friend behind you still gets a marker")
	if not behind.is_empty():
		check(bool(behind["offscreen"]), "counted as off screen")
		check(float(behind["pos"].x) > centre.x,
			"and it points to the RIGHT -- the mirrored projection is flipped back "
			+ "(x %.0f of %.0f)" % [behind["pos"].x, SCREEN.x])

	# --- 4. Downed: marked on screen, and flashing ---------------------------
	var lit: Dictionary = Markers.place(centre, false, SCREEN, true, 0.0)
	check(not lit.is_empty(), "a DOWNED friend is marked even when you can see them")
	if not lit.is_empty():
		check(not bool(lit["offscreen"]), "not treated as off screen")
		check(bool(lit["downed"]), "and flagged as downed")
		check(bool(lit["shown"]), "lit at the start of the flash cycle")

	# BOTH HALVES OF THE CYCLE. A marker that is always on would pass "lit"
	# perfectly, and a flash nobody can see is the whole thing this exists to avoid.
	var dark: Dictionary = Markers.place(centre, false, SCREEN, true,
		Markers.FLASH_PERIOD * 0.75)
	check(not bool(dark["shown"]),
		"and dark on the other half of the cycle -- it really blinks")
	var again: Dictionary = Markers.place(centre, false, SCREEN, true,
		Markers.FLASH_PERIOD * 1.1)
	check(bool(again["shown"]), "and lit again on the next cycle")

	finish()
