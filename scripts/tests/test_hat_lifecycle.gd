extends "res://scripts/test_support/test_case.gd"

# M8.5: hats are created and destroyed correctly, and an endless run does not
# leak them.
#
# THE CULL IS NOT OPTIONAL, and it is the part with no visible symptom until it
# is far too late. A run scatters hats forever; nothing about a dropped hat makes
# it go away on its own, so without a cull the body count climbs for as long as
# anybody plays.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "HatLifeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	a = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	a.position = world.grid.cell_surface_world(Vector2i(25, 9)) + Vector3(0.0, 1.0, 0.0)

	# AUTHORED HATS EXIST. The playtest map places them; test_flat does not, so
	# this checks the plumbing rather than the content: the glyph is read, the
	# builder reports the cell, and the pool turns it into a body.
	_test_authoring(main)

func _test_authoring(main) -> void:
	var authored := Node3D.new()
	authored.name = "AuthoredHatWorld"
	authored.set_script(GameWorldScript)
	main.add_child(authored)
	authored.segment_paths = ["res://segments/playtest_bridge.seg"]
	authored.start(true, 1, false)
	# One tick, because authored hats are drained in the hat pass rather than at
	# load -- so a segment streamed in mid-run goes down the same path as the
	# first one.
	authored._host_tick()
	check(authored.hat_count() > 0,
		"the ^ glyph puts real hats in the world (%d)" % authored.hat_count())
	authored.stop()
	authored.queue_free()

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_knocked_into_a_hole()
		1: _phase_cull_caps_the_debris()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. A hat that leaves the world is destroyed ------------------------------

func _phase_knocked_into_a_hole() -> void:
	if phase_frame == 1:
		world._hats.clear()
		world._hats.spawn_loose(a.position + Vector3(3.0, 0.0, 0.0))
		var doomed: Node = world._hats.spawn_loose(a.position + Vector3(5.0, 0.0, 0.0))
		doomed.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 2.0, -18.0)
		return
	if phase_frame == 10:
		eq(world.hat_count(), 1,
			"a hat that falls out of the world is destroyed, and the live count is right")
		_advance(1)

# --- 2. The cull keeps loose hats inside their cap ----------------------------

func _phase_cull_caps_the_debris() -> void:
	if phase_frame == 1:
		world._hats.clear()
		# Well past the cap, which is what an endless run of tumbles produces.
		for i in SimConfig.HAT_MAX_LOOSE + 12:
			world._hats.spawn_loose(a.position + Vector3(0.0, 0.0, -3.0 - 0.4 * float(i)))
		check(world.hat_count() > SimConfig.HAT_MAX_LOOSE, "more hats than the cap exist")
		return
	if phase_frame == 5:
		eq(world.hat_count(), SimConfig.HAT_MAX_LOOSE,
			"the cull holds loose hats at HAT_MAX_LOOSE")

		# OLDEST FIRST. Ids are monotonic, so the survivors must be the highest
		# ids -- the debris behind the party clears rather than the hat somebody
		# is walking toward.
		var lowest: int = 1 << 30
		for hat in world._hats.all():
			lowest = mini(lowest, hat.hat_id)
		check(lowest > 12, "and it culls the OLDEST, not whichever it met first")
		finish()
