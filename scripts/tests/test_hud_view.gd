extends "res://scripts/test_support/test_case.gd"

# A shallow smoke test for the HUD's Control tree, and deliberately shallow:
# hud.gd is supposed to contain no decisions, so there is nothing here worth
# asserting in depth. What it pins is that the thing RUNS.
#
# Without it, nothing in the gate ever executes hud.gd at all -- hud_model.gd is a
# pure function and the tests that cover it never build a single node, so
# _ready() and _process() would ship having never been called. GDScript resolves
# a property at runtime, so a node property that does not exist raises then and
# nowhere else: `ProgressBar.tint_progress` is Godot 3 and was in the first draft
# of this file, and it would have thrown on the first frame of the first
# playtest.
#
# Headless builds the scene tree, it just does not draw it, so every node in here
# is really constructed and really updated.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudScript = preload("res://scripts/ui/hud.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

var world: Node3D = null
var hud: CanvasLayer = null
var phase: int = 0
var phase_frame: int = 0

func setup(main) -> void:
	world = Node3D.new()
	world.name = "HudViewWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)

	hud = HudScript.new()
	hud.name = "Hud"
	main.add_child(hud)
	hud.world = world

func _physics_process(_delta: float) -> void:
	phase_frame += 1
	# Give _process (which drives the HUD) a couple of frames to have run at all.
	if phase_frame < 3:
		return
	match phase:
		0: _phase_built()
		1: _phase_rescue_bar()
		2: _phase_roster_shrinks()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

func _phase_built() -> void:
	# THE HEALTH BAR REALLY DRAINS, checked before anything is asserted about it
	# being full. A zero-width rect in an undrawn headless layout would satisfy
	# "the fill is as wide as the bar" perfectly -- 0 == 0 -- so the instrument is
	# fed a case where it MUST report a difference first.
	if phase_frame == 3:
		world.player_body(1).health = 1
		return
	if phase_frame == 4:
		check(_own_fill_width() < hud._own_status.size.x,
			"a hurt player's bar is visibly shorter than the bar (%.0f of %.0f px)"
				% [_own_fill_width(), hud._own_status.size.x])
		check(hud._own_status.size.x > 1.0,
			"and the bar has a real width, so the comparison means something")
		world.player_body(1).health = SimConfig.MAX_HEALTH
		return

	check(hud._own_panel.visible, "the own panel is shown once there is a local avatar")
	eq(hud._own_slots.get_child_count(), 2,
		"two action slots -- the permanently-blank rope box was removed 2026-08-15")
	eq(hud._friend_rows.size(), 1, "and a row for the one other player")

	# An empty slot has to be visibly PRESENT rather than omitted, or the layout
	# jumps the moment somebody picks a special up. The special slot is the only
	# one that is ever empty now, and unlike the rope box it actually fills.
	var special: ColorRect = hud._own_slots.get_child(1)
	eq(special.color, HudScript.COLOR_SLOT_EMPTY,
		"an empty special slot draws as deliberately empty, not missing")

	# ONE BAR IN THE WHOLE PANEL, and for a healthy player it is their HEALTH.
	#
	# Both halves matter and both have been wrong. There were two crisis bars once
	# and the second was pure black whenever nobody was helping. Then there was one
	# crisis bar plus a row of health PIPS, so a hanging player was described in
	# two shapes at once, neither matching the bar over their own head. Counting
	# every ColorRect in the panel is what stops a second reading growing back:
	# what is asserted is the COUNT, not the identity of the one that survived.
	check(hud._own_status != null, "there is an own-status bar")
	eq(_own_bars(), 1, "and it is the ONLY bar in the panel -- no pips beside it")
	check(hud._own_status.visible,
		"which is always drawn, because health is now the bar's healthy case")
	eq(hud._own_status.color, PlayerBody.BAR_HEALTH_BACK,
		"green over red for a healthy player -- the colours the body itself uses")
	eq(_own_fill_width(), hud._own_status.size.x,
		"and full, because nothing has hit them yet (%.0f of %.0f px)"
			% [_own_fill_width(), hud._own_status.size.x])
	_advance(1)

func _phase_rescue_bar() -> void:
	if phase_frame == 3:
		world.player_body(2).begin_downed()
		world.player_body(1).begin_downed()
		return
	if phase_frame == 6:
		# NOBODY HELPING YET. The bar has to be the COUNTDOWN, drawn in the colour
		# the body's own head uses -- not a second empty bar beside it.
		check(hud._own_status.visible, "waiting for a rescue shows the one bar")
		eq(hud._own_status.color, PlayerBody.BAR_RESCUE_BACK,
			"in the countdown's colours, the same ones over the player's head")
		# THE SAME BAR THAT WAS SHOWING HEALTH A MOMENT AGO. Not a second one that
		# appeared beside it -- the count is still one.
		eq(_own_bars(), 1, "and there is still exactly one bar in the panel")

		world.player_body(1).rescue_progress = SimConfig.REVIVE_SECONDS * 0.5
		return
	if phase_frame == 9:
		# SOMEBODY IS ON IT. The SAME bar switches to the hold, because being
		# helped outranks the countdown -- the priority lives in
		# PlayerBody.status_bar() and both this and the 3D bar read it.
		eq(hud._own_status.color, PlayerBody.BAR_HAUL_BACK,
			"once somebody is hauling, the same bar becomes the hold")
		eq(_own_bars(), 1, "still exactly one bar")

		world.player_body(2).rescue_progress = SimConfig.REVIVE_SECONDS * 0.5
		return
	if phase_frame < 12:
		return
	var row: Dictionary = hud._friend_rows[2]
	check(row["bar"].visible, "a downed friend gets a bar")
	check(row["state"].visible, "and a state banner")
	eq(str(row["state"].text), "DOWN", "saying what is wrong")

	# A FRIEND'S ROW GETS THE SAME TREATMENT: one bar, no pips. It carried both
	# until 2026-08-15, which made a downed teammate three pieces of furniture
	# saying one thing.
	eq(_bars_in(row["row"]), 1, "and ONE bar in their row, not a bar and pips")
	_advance(2)

# HOW MANY READINGS OF THIS PLAYER ARE ON SCREEN. A bar is a direct ColorRect
# child of the panel (its fill is a child of the BAR, so it does not double-
# count), and a row of pips was a direct HBoxContainer child. Both counted here,
# because the mistake this guards against is a second reading coming back in a
# DIFFERENT SHAPE -- which is exactly what pips were.
#
# The action slots are ColorRects too and are deliberately not counted: they live
# in _own_slots, they are buttons rather than readings, and there are meant to be
# two of them.
func _own_bars() -> int:
	return _readings_in(hud._own_status.get_parent(), hud._own_slots)

func _bars_in(box: Node) -> int:
	return _readings_in(box, null)

func _readings_in(box: Node, skip: Node) -> int:
	var count := 0
	for child in box.get_children():
		if child == skip:
			continue
		if child is ColorRect:
			count += 1
		elif child is HBoxContainer or child is VBoxContainer:
			count += _readings_in(child, skip)
	return count

func _own_fill_width() -> float:
	return float((hud._own_status.get_node("Fill") as ColorRect).size.x)

func _phase_roster_shrinks() -> void:
	if phase_frame == 3:
		world._despawn_player(2)
		return
	if phase_frame < 6:
		return
	eq(hud._friend_rows.size(), 0, "a peer who leaves takes their row with them")
	check(hud._own_panel.visible, "and the local player still has a HUD")
	finish()
