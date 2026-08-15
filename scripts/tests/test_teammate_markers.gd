extends "res://scripts/test_support/test_case.gd"

# The dorito. Asked for on 2026-08-13, asked for AGAIN on 2026-08-14 because it
# had not been built, and reshaped on 2026-08-15 after seeing it in play.
#
# The claims:
#   1. A FRIEND YOU CAN SEE GETS NOTHING -- and as of 2026-08-15 that includes a
#      DOWNED one. They already carry a flashing bar over their head in this same
#      red on this same clock; an arrow on top of it is one warning drawn twice,
#      and twice is how a warning stops being read. This is the assertion that
#      changed: the previous version demanded a permanent red triangle on every
#      downed player on screen.
#   2. A FRIEND OFF THE SIDE GETS AN EDGE MARKER POINTING AT THEM, in GREEN and
#      not flashing. Where somebody is is information; it is not a summons.
#   3. A FRIEND BEHIND THE CAMERA POINTS THE RIGHT WAY. This is the case that goes
#      wrong on its own: unproject_position MIRRORS a point behind the lens, so
#      the naive version puts the arrow on exactly the wrong side.
#   4. A FRIEND WHO NEEDS HELP, OFF SCREEN, ALTERNATES RED AND WHITE -- and both
#      halves are asserted. A marker that never changed would pass "it is red"
#      perfectly, and the flash is the entire difference between "over there" and
#      "come now".
#   5. IT NEVER BLINKS OUT. The old one did, so half the time the thing being
#      pointed at was not on screen at all, and which half you catch is luck.
#      Asserted as alpha: both phases are opaque.
#
# THE COLOURS ARE ASSERTED AGAINST crisis_flash's CONSTANTS, never against
# literals -- that shared file is the whole point of the change, and a literal
# here would let the arrow and the bar drift apart again while staying green.
#
# The maths is a pure function precisely so this test can exist: `_draw` output
# cannot be read back, so a version that decided placement inside it would be
# untestable.

const Markers = preload("res://scripts/ui/teammate_markers.gd")
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

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

	# --- 1. On screen: nothing, in trouble or not ----------------------------
	check(Markers.place(centre, false, SCREEN, false, 0.0).is_empty(),
		"a healthy friend you can already see gets no marker -- clutter is how a "
		+ "real one gets ignored")

	# THE ONE THAT CHANGED. A downed friend in shot used to get a permanent red
	# triangle over them, on top of the bar over their head that is already
	# flashing this same red. One fact, one marking.
	check(Markers.place(centre, false, SCREEN, true, 0.0).is_empty(),
		"and NEITHER does a downed one -- their own bar is already saying it")

	# --- 2. Off to the side: an edge marker, green and steady ----------------
	var side: Dictionary = Markers.place(
		Vector2(SCREEN.x + 400.0, centre.y), false, SCREEN, false, 0.0)
	check(not side.is_empty(), "a friend off the side of the screen gets one")
	if not side.is_empty():
		var pos: Vector2 = side["pos"]
		check(pos.x > centre.x,
			"pinned to the RIGHT half, the side they are on (x %.0f)" % pos.x)
		check(pos.x <= SCREEN.x and pos.y >= 0.0 and pos.y <= SCREEN.y,
			"and inside the frame rather than half off it (%.0f, %.0f)" % [pos.x, pos.y])
		check(absf(wrapf(float(side["angle"]), -PI, PI)) < PI * 0.5,
			"with the triangle pointing at them (%.2f rad)" % side["angle"])
		eq(side["colour"], CrisisFlash.FRIEND, "in GREEN -- this is information")

		# AND IT DOES NOT MOVE. Sampled at four points across a full cycle: if a
		# healthy friend's marker flashed too, the flash would stop meaning
		# anything, which is the whole reason there are two colours.
		for step in 4:
			eq(Markers.place(Vector2(SCREEN.x + 400.0, centre.y), false, SCREEN,
					false, CrisisFlash.PERIOD * float(step) * 0.3)["colour"],
				CrisisFlash.FRIEND, "and it stays green all the way round the cycle")

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
		check(float(behind["pos"].x) > centre.x,
			"and it points to the RIGHT -- the mirrored projection is flipped back "
			+ "(x %.0f of %.0f)" % [behind["pos"].x, SCREEN.x])

	# --- 4 and 5. Off screen and in trouble: red to white, never to nothing --
	var far := Vector2(SCREEN.x + 400.0, centre.y)
	var lit: Dictionary = Markers.place(far, false, SCREEN, true, 0.0)
	check(not lit.is_empty(), "a friend who needs help, off screen, is marked")
	eq(lit["colour"], CrisisFlash.RED, "in the crisis red at the start of the cycle")

	# THE SAME RED THE BAR OVER THEIR HEAD USES. Not a matching literal -- the
	# same constant, which is what stops the two drifting apart later while this
	# test stays green.
	eq(CrisisFlash.RED, PlayerBody.BAR_RESCUE_FILL,
		"and it is the SAME red as the countdown bar over that player's head")

	var pale: Dictionary = Markers.place(far, false, SCREEN, true,
		CrisisFlash.PERIOD * 0.75)
	eq(float(pale["colour"].r), 1.0, "white on the other half of the cycle: red")
	eq(float(pale["colour"].g), 1.0, "green")
	eq(float(pale["colour"].b), 1.0, "and blue all at full -- it really alternates")

	# NEVER TO NOTHING. The old marker blinked out entirely, which means half the
	# time the thing you are being told to look at is not on screen.
	check(float(lit["colour"].a) > 0.99 and float(pale["colour"].a) > 0.99,
		"and it is opaque in BOTH phases -- it alternates, it does not blink out")

	eq(Markers.place(far, false, SCREEN, true, CrisisFlash.PERIOD * 1.1)["colour"],
		CrisisFlash.RED, "and it is red again on the next cycle")

	finish()
