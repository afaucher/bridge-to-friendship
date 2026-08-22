extends "res://scripts/test_support/test_case.gd"

# The aim dot and the charge bar under it (2026-08-22). Together they are what
# M21 was parked waiting for.
#
# WHY THERE IS A TEST AT ALL: `_update_laser_sight` is gated on `view_active`,
# which is FALSE in every headless world, so this whole readout would ship having
# never been executed once. That is the trap CLAUDE.md records from the HUD --
# headless builds the tree and simply does not draw it, GDScript resolves
# properties at runtime, and `ProgressBar.tint_progress` was a Godot 3 name that
# raised on the first frame and nowhere earlier. `SphereMesh.radial_segments`,
# `QuadMesh.size`, `billboard_mode` and `no_depth_test` are all the same bet.
#
# The claims:
#   1. THE THREE MODES ARE THREE MODES. `off` draws nothing, `beam` draws the
#      line and not the dot, `dot` the reverse. Asserted in both directions,
#      because a readout stuck permanently on satisfies half of them.
#   2. THE DOT IS ON THE SHOT LINE. Not "the dot exists" -- that is the assertion
#      that lets a marker drift a metre off what it claims to mark. Checked
#      against `aim_direction`, the function that FIRES, and checked as a bearing
#      rather than by recomputing the ray: a second copy of the reach maths would
#      agree with itself and prove nothing.
#   3. THE BAR TRACKS THE CHARGE, and is absent at zero. A bar that is always
#      there is a bar nobody reads.
#
# NO FRAME IS ADVANCED WITH `view_active` TRUE. That flag also gates
# `_remember_hat`, which writes the developer's saved hat to user:// -- a test
# that quietly mutates real user state is one nobody can trust twice. The readout
# is driven by calling it directly.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var body: CharacterBody3D = null
var grenade: Node = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "ReadoutWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if body == null or world.tick < 4:
		return
	set_physics_process(false)

	body.position = world.grid.cell_surface_world(Vector2i(15, 8)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true
	grenade = world._specials.spawn_loose(body.position + Vector3(0.0, 0.5, 0.0),
		SpecialBody.Kind.GRENADE)
	grenade.hold(1)
	# The local player is who the readout is for; a headless world has no local
	# peer by default.
	world.local_peer = 1
	world.view_active = true

	_check_modes()
	_check_dot_is_on_the_shot_line()
	_check_charge_bar()

	world.view_active = false
	DebugSettings.set_value("laser_sight", 2)
	finish()

# --- 1. Three modes -----------------------------------------------------------

func _check_modes() -> void:
	DebugSettings.set_value("laser_sight", 0)          # off
	world._update_laser_sight()
	check(not _shown(world._dot) and not _shown(world._laser),
		"`off` draws no aim readout at all")

	DebugSettings.set_value("laser_sight", 1)          # beam
	world._update_laser_sight()
	check(_shown(world._laser), "`beam` draws the line")
	check(not _shown(world._dot), "and not the dot")

	DebugSettings.set_value("laser_sight", 2)          # dot
	world._update_laser_sight()
	check(_shown(world._dot), "`dot` draws the dot")
	check(not _shown(world._laser), "and not the line")

# --- 2. It marks the shot, not a guess ----------------------------------------

func _check_dot_is_on_the_shot_line() -> void:
	DebugSettings.set_value("laser_sight", 2)
	world._update_laser_sight()
	if not _shown(world._dot):
		check(false, "no dot to measure")
		return
	var muzzle: Vector3 = world._muzzle_of(grenade, body)
	var along: Vector3 = world.aim_direction(body, grenade)
	var to_dot: Vector3 = world._dot.global_position - muzzle
	check(to_dot.length() > 0.2, "the dot is out in the world, not on the barrel")
	var bearing: float = to_dot.normalized().dot(along)
	print("[readout] dot %.2f m out, bearing dot-product %.5f" % [to_dot.length(), bearing])
	# A BEARING, NOT A POSITION. Recomputing the reach here would be a second copy
	# of the thing under test agreeing with itself; the claim that matters is that
	# the marker lies along the direction the shot will actually take.
	check(bearing > 0.999,
		"and it sits ON the line the shot takes (dot-product %.5f with "
			% bearing + "aim_direction, the function that fires)")

# --- 3. The bar ---------------------------------------------------------------

func _check_charge_bar() -> void:
	grenade.charge = 0.0
	world._update_laser_sight()
	check(not _shown(world._bar_fill),
		"an uncharged throw shows no bar -- one that is always there is one "
		+ "nobody reads")

	grenade.charge = SimConfig.GRENADE_CHARGE_TIME * 0.5
	world._update_laser_sight()
	check(_shown(world._bar_fill), "charging shows it")
	var half: float = (world._bar_fill.mesh as QuadMesh).size.x

	grenade.charge = SimConfig.GRENADE_CHARGE_TIME
	world._update_laser_sight()
	var full: float = (world._bar_fill.mesh as QuadMesh).size.x
	print("[readout] fill width %.3f at half charge, %.3f at full" % [half, full])
	check(full > half + 0.1,
		"and it grows with the hold (%.2f -> %.2f)" % [half, full])
	# UNDER the dot, which is the whole point of putting it here rather than in
	# the HUD corner: a player charging a throw is looking at the world.
	check(world._bar_fill.global_position.y < world._dot.global_position.y,
		"and it sits below the aim point")
	grenade.charge = 0.0

func _shown(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.visible
