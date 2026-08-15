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
	check(hud._own_panel.visible, "the own panel is shown once there is a local avatar")
	eq(hud._own_pips.get_child_count(), SimConfig.MAX_HEALTH,
		"one health pip per hit point")
	eq(hud._own_slots.get_child_count(), 2,
		"two action slots -- the permanently-blank rope box was removed 2026-08-15")
	eq(hud._friend_rows.size(), 1, "and a row for the one other player")

	# An empty slot has to be visibly PRESENT rather than omitted, or the layout
	# jumps the moment somebody picks a special up. The special slot is the only
	# one that is ever empty now, and unlike the rope box it actually fills.
	var special: ColorRect = hud._own_slots.get_child(1)
	eq(special.color, HudScript.COLOR_SLOT_EMPTY,
		"an empty special slot draws as deliberately empty, not missing")

	# ONE STATUS BAR, and nothing to say right now. There were two here until
	# 2026-08-15 -- a countdown and a rescue bar -- and the second was pure black
	# whenever nobody was helping, which is most of the time somebody spends
	# waiting. A bar showing "0% of a rescue" is indistinguishable from a bar that
	# failed to draw, and it was reported as exactly that.
	check(hud._own_status != null, "there is ONE own-status bar, not two")
	check(not hud._own_status.visible, "and it says nothing for a walking player")
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
		# AND THE ONLY OTHER BAR IN THE OWN PANEL IS NOT A SECOND CRISIS BAR.
		# Counting them is what stops a second one reappearing unnoticed.
		eq(_own_bars(), 1, "and there is exactly one of them")

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
	_advance(2)

# Every ColorRect directly in the own panel that is acting as a bar. Fills are
# CHILDREN of a bar, so counting top-level ones counts bars.
func _own_bars() -> int:
	var count := 0
	for child in _own_box().get_children():
		if child is ColorRect:
			count += 1
	return count

func _own_box() -> Node:
	return hud._own_status.get_parent()

func _phase_roster_shrinks() -> void:
	if phase_frame == 3:
		world._despawn_player(2)
		return
	if phase_frame < 6:
		return
	eq(hud._friend_rows.size(), 0, "a peer who leaves takes their row with them")
	check(hud._own_panel.visible, "and the local player still has a HUD")
	finish()
