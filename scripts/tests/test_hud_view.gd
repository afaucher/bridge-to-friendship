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

	# Nobody is in trouble, so no crisis bars are on screen.
	check(not hud._own_bleed.visible, "no bleed-out bar for a walking player")
	check(not hud._own_rescue.visible, "and no rescue bar")
	_advance(1)

func _phase_rescue_bar() -> void:
	if phase_frame == 3:
		world.player_body(2).begin_downed()
		world.player_body(2).rescue_progress = SimConfig.REVIVE_SECONDS * 0.5
		return
	if phase_frame < 6:
		return
	var row: Dictionary = hud._friend_rows[2]
	check(row["bar"].visible, "a downed friend gets a bar")
	check(row["state"].visible, "and a state banner")
	eq(str(row["state"].text), "DOWN", "saying what is wrong")
	_advance(2)

func _phase_roster_shrinks() -> void:
	if phase_frame == 3:
		world._despawn_player(2)
		return
	if phase_frame < 6:
		return
	eq(hud._friend_rows.size(), 0, "a peer who leaves takes their row with them")
	check(hud._own_panel.visible, "and the local player still has a HUD")
	finish()
