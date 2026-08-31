extends "res://scripts/test_support/test_case.gd"

# EACH PLAYER'S BEST LAP, ON THE HUD.
#
# THE CLAIM THAT MATTERS IS ABOUT ZERO. A lap of 0 ticks means nobody has
# finished one, and a clock reading "0:00.0" says the exact opposite -- that
# somebody went round instantly. Every mode but the race leaves this at zero for
# every player, so the wrong answer here is not a rare edge case, it is what the
# whole game looks like almost all of the time.
#
# AND THE LABEL IS MEASURED, NOT THE INPUT. This project has shipped a score
# screen in the corner of the display with four correct anchors, because the test
# asserted the anchors and not the layout -- so what is asserted here is the TEXT
# a player would read and whether the node is visible, never the dictionary that
# fed it.
#
# The claims:
#   1. A player with no lap shows nothing at all -- empty text and a hidden node.
#   2. A player with a lap shows it, in a form a human reads: tenths always,
#      minutes only when there are any.
#   3. It is PER PLAYER: your own row and each friend's carry their own time,
#      which is the difference between a scoreboard and a shared clock.
#   4. The HUD really reads it from the world, so the number on screen is the one
#      the lap system recorded rather than a copy that can drift.

const HudModel = preload("res://scripts/ui/hud_model.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudScript = preload("res://scripts/ui/hud.gd")

const A := 41
const B := 57

var world: Node3D = null
var hud: Node = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "LapHudWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world._spawn_player(B, 1)
	for peer in [A, B]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

	# THE REAL HUD, BUILT. Headless does not draw a Control tree but it does
	# BUILD one -- `_ready`, `_process` and every property write really run --
	# which is the whole reason a HUD is testable here at all.
	# A REAL SCREEN. The headless viewport is 64x64 (CLAUDE.md), which makes every
	# position on this HUD nonsense -- measured, the centred round label lands at
	# x = -441 in a 64 px window. Layout is CPU-side and headless really runs it,
	# so the fix is to give it a plausible size rather than to give up on
	# measuring position, which is the half of this report a font size cannot see.
	main.get_window().size = Vector2i(1280, 720)
	hud = HudScript.new()
	hud.name = "LapHud"
	main.add_child(hud)
	hud.world = world

# PHASED, BECAUSE THE HUD REFRESHES FROM `_process` RATHER THAN ON DEMAND. There
# is no `refresh()` to call: it reads the world every frame, which is exactly how
# it behaves in play, so the test writes a number and waits a frame for the
# screen to catch up.
var _phase := 0
var _at := 0

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match _phase:
		0:
			_a_time_reads_like_a_time()
			_it_is_read_at_a_glance_and_not_in_the_panel()
			_nobody_has_a_lap_yet()
			_set_a_lap()
			_phase = 1
			_at = world.tick
		1:
			if world.tick < _at + 3:
				return
			_a_lap_appears_for_the_player_who_drove_it()
			_it_sits_between_the_panel_and_the_round_line()
			_phase = 2
			_at = world.tick
		2:
			if world.tick < _at + 3:
				return
			_and_only_for_that_player()
			done = true
			finish()

# --- 2. The format -------------------------------------------------------------

func _a_time_reads_like_a_time() -> void:
	var per_second: int = int(round(1.0 / SimConfig.TICK_DELTA))
	eq(HudModel.lap_label(0), "",
		"no lap is EMPTY, not a zeroed clock -- `0:00.0` reads as a lap driven "
		+ "instantly, and outside the race that is what every player would show")
	eq(HudModel.lap_label(-3), "", "and a negative one cannot render either")
	var quick: String = HudModel.lap_label(per_second * 18 + per_second / 2)
	print("[hudlap] 18.5 s renders as `%s`, 83 s as `%s`"
		% [quick, HudModel.lap_label(per_second * 83)])
	eq(quick, "18.5s",
		"a sub-minute lap is seconds and tenths (%s) -- a tenth is the unit a "
			% quick
		+ "lap is actually beaten by, so dropping it would make most improvements "
		+ "invisible")
	eq(HudModel.lap_label(per_second * 83), "1:23.0",
		"and a longer one grows a minutes field rather than reading `83.0s`")

# --- 5. IT IS READ AT A GLANCE, WHICH IS A SIZE AND A PLACE -----------------------
#
# Reported: "that counter is WAY too small." It sat beside the player's name
# inside the own panel at 16 px -- the size of a status caption, and the wrong
# KIND of thing to be in that panel as well as the wrong size. The own panel is a
# list you look AT between moments; a lap clock while you are driving is a number
# you catch out of the corner of your eye, which is what the centre strip is for.
#
# ASSERTED AS A RELATIONSHIP, NEVER A LITERAL. The ask was "the same font as
# ROUND", so the claim is that the two agree -- which stays true the day somebody
# retunes ROUND, where `eq(size, 44)` would quietly stop meaning what it says.
# The same rule this project uses for anything read out of the environment.
func _it_is_read_at_a_glance_and_not_in_the_panel() -> void:
	var live: int = hud._own_lap_live.get_theme_font_size("font_size")
	var round_size: int = hud._round_label.get_theme_font_size("font_size")
	print("[hudlap] the live clock is %d px, ROUND is %d" % [live, round_size])
	eq(live, round_size,
		"the running lap is set at ROUND's size (%d against %d) -- it is a line "
			% [live, round_size]
		+ "you catch rather than one you study, and it was a status caption")

	# AND IT LEFT THE PANEL. A big label still inside the own column would be the
	# right size in the wrong place, which is half the report and the half a font
	# assertion cannot see.
	check(not hud._own_panel.is_ancestor_of(hud._own_lap_live),
		"the clock is no longer inside the own panel -- it moved to the top strip "
		+ "between that panel and the round column, rather than growing in place "
		+ "and pushing the name and hats around")
	check(not hud._own_panel.is_ancestor_of(hud._own_lap),
		"and the best went with it, because splitting one idea across two corners "
		+ "of the screen is worse than either place")

# AND WHERE IT LANDS, MEASURED, at a screen size that means something.
#
# THE ANCHORS ARE NOT THE LAYOUT. This project shipped a score screen in the
# corner of the display with four correct anchors because the test asserted the
# anchors -- so what is asserted here is the rect the player is looking at.
#
# NOT "does it overlap the round panel", WHICH WOULD BE WRONG. That panel's box
# is 947 px wide at 1280 and almost all of it is empty: the label fills the
# column and the glyphs are centre-aligned inside it. A box test would fail on a
# layout that looks perfect. The claim is the one the ask actually made -- the
# clock is clear of the own panel on its left and does not reach the middle,
# which is what "between the HUD and the round counter" means on screen.
func _it_sits_between_the_panel_and_the_round_line() -> void:
	var lap: Label = hud._own_lap_live
	if not check(lap.visible and lap.size.x > 0.0,
			"the clock has text to measure (%s)" % lap.text):
		return
	var screen: float = hud.get_viewport().get_visible_rect().size.x
	var panel_right: float = hud._own_panel.global_position.x + hud._own_panel.size.x
	var left: float = lap.global_position.x
	var right: float = left + lap.size.x
	print("[hudlap] at %d px wide: own panel ends at %.0f, the clock spans %.0f-%.0f, centre is %.0f"
		% [screen, panel_right, left, right, screen * 0.5])
	check(left > panel_right,
		"the clock starts clear of the own panel (%.0f against its right edge at "
			% left
		+ "%.0f) -- it left that panel rather than growing inside it" % panel_right)
	check(right < screen * 0.5,
		"and ends before the middle (%.0f against %.0f), where the round line is "
			% [right, screen * 0.5]
		+ "centred -- between the two is the place that was asked for")

# --- 1, 3 and 4. On the HUD itself ---------------------------------------------

func _nobody_has_a_lap_yet() -> void:
	var own: Label = hud._own_lap
	print("[hudlap] with no lap the label is `%s`, visible %s"
		% [own.text, own.visible])
	eq(own.text, "",
		"a player who has not finished a lap has nothing in the clock (`%s`)"
			% own.text)
	check(not own.visible,
		"and the node is hidden, so it takes no room beside the name either")

func _set_a_lap() -> void:
	var per_second: int = int(round(1.0 / SimConfig.TICK_DELTA))
	# THROUGH THE WORLD'S OWN RECORD, so what the HUD shows is what the lap
	# system stored. Handing the label a string would test the label.
	world._best_lap[A] = per_second * 21 + per_second / 5
	# AND A LAP IN PROGRESS, so the big label has glyphs in it. The position claim
	# measures a rect, and an empty Label is 1 px wide -- which would pass a
	# "left of centre" test while saying nothing about where the clock appears.
	world._lap_next[A] = 1
	world._lap_from[A] = world.tick - per_second * 7

func _a_lap_appears_for_the_player_who_drove_it() -> void:
	print("[hudlap] after recording 21.2 s the own label reads `%s`"
		% hud._own_lap.text)
	eq(hud._own_lap.text, "best 21.2s",
		"the HUD shows the lap the world recorded (`%s`) -- read from "
			% hud._own_lap.text
		+ "`best_lap_of` rather than from a copy that can drift")
	check(hud._own_lap.visible, "and the label is visible now there is one")

	# PER PLAYER. A friend with no lap must not inherit yours -- that would be a
	# shared clock wearing a scoreboard's clothes, and it is the failure a test
	# with one player cannot see.
	var rows: Dictionary = hud._friend_rows
	if not check(rows.has(B), "the friends panel has a row for the other player"):
		return
	print("[hudlap] the friend who has not lapped reads `%s`" % rows[B]["lap"].text)
	eq(rows[B]["lap"].text, "",
		"a friend with no lap of their own shows nothing (`%s`) rather than "
			% rows[B]["lap"].text
		+ "yours -- one clock for the party would be a shared timer, not a board")
	world._best_lap[B] = int(round(1.0 / SimConfig.TICK_DELTA)) * 19

func _and_only_for_that_player() -> void:
	var rows: Dictionary = hud._friend_rows
	if not rows.has(B):
		return
	eq(rows[B]["lap"].text, "19.0s",
		"and their own time once they have one (`%s`)" % rows[B]["lap"].text)
	eq(hud._own_lap.text, "best 21.2s", "while yours is untouched")
