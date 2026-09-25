extends MarginContainer

# THE LAP CLOCK: the race mode's own piece of the HUD (RaceMode.hud_widgets).
#
# ON ITS OWN, IN THE TOP STRIP BETWEEN THE HUD AND THE ROUND LINE. It used to sit
# beside your name inside the own panel at 16 px, which is the size of a status
# caption. Reported as "that counter is WAY too small" -- and it was the wrong KIND
# of thing to be in that panel as well as the wrong size. The own panel is a list
# you look AT between moments; a lap clock while you are driving is a number you
# catch out of the corner of your eye.
#
# ANCHORED AT A FRACTION rather than offset from the panel beside it. The own
# panel's width depends on the player's name, their hats and their held weapon,
# so pinning to its edge would make the clock move whenever any of those changed.
#
# THE RUNNING CLOCK AND THE BEST, TWO LABELS AND NOT ONE DOING BOTH. A single
# label showing the live lap while driving and the best otherwise hides your
# target at the only moment you are chasing it -- you cross the line and the next
# lap starts on the same tick, so the best would flash past in a frame.

const HudModel = preload("res://scripts/ui/hud_model.gd")

# Start-line white rather than the alert orange: a lap time is something you did
# well, and every other coloured thing on this HUD is a warning.
const COLOR_LAP := Color(0.85, 0.86, 0.92)
# The lap being driven right now, brighter than the best beside it: it is the
# number changing, and the one a driver is actually watching.
const COLOR_LAP_LIVE := Color(1.00, 0.97, 0.80)
# A third of the way across: between the top-left own panel and the centred round
# column at any width.
const ANCHOR_X := 0.3

var live: Label = null
var best: Label = null

# `make_label` is the HUD's own label factory, so the clock gets the same outline
# every other line on the HUD does.
func build(make_label: Callable) -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor_left = ANCHOR_X
	anchor_right = ANCHOR_X
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_theme_constant_override("margin_top", 14)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(column)

	live = make_label.call("", 44, COLOR_LAP_LIVE)
	live.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(live)
	best = make_label.call("", 18, COLOR_LAP)
	best.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(best)

func refresh(model: Dictionary) -> void:
	var own: Dictionary = model.get("own", {})
	var best_text: String = HudModel.lap_label(int(own.get("best_lap", 0)))
	best.text = ("best " + best_text) if best_text != "" else ""
	best.visible = best_text != ""
	live.text = HudModel.lap_label(int(own.get("lap_running", 0)))
	live.visible = live.text != ""
