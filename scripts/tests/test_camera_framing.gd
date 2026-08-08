extends "res://scripts/test_support/test_case.gd"

# The camera's three load-bearing properties, asserted rather than eyeballed:
#
#   1. The WHOLE BRIDGE fits across the screen, at whatever width the bridge
#      happens to be. This is the one that silently regresses -- change the cell
#      size or the bridge width and the framing is wrong on every machine.
#   2. It NEVER tracks sideways. A camera that chased a player across a 30 m deck
#      would make it feel like a corridor and would slide the world under someone
#      lining up an axis-locked dash.
#   3. It DOES track along the bridge, in height as well as distance -- the deck
#      is pitched and steps up in layers, so following z alone lets the party
#      climb out of frame.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var player: CharacterBody3D = null
var camera: Camera3D = null
var frame: int = 0
var start_camera: Vector3 = Vector3.ZERO
var start_x: float = 0.0

func setup(main) -> void:
	timeout_seconds = 25.0
	world = Node3D.new()
	world.name = "CameraWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	# The world a human would be looking at, which is what gates the camera
	# taking the viewport and the lighting being built at all.
	world.view_active = true
	world.start(true, 1, false)

	# A bridge carries no lighting of its own -- .seg files describe structure
	# and nothing else -- so if this ever stops being built the game renders
	# flat-lit and nothing else fails.
	var lighting: Node = world.get_node_or_null("Lighting")
	if check(lighting != null, "a bridge world builds its own lighting"):
		check(lighting.get_node_or_null("WorldEnvironment") != null, "with a sky")
		var sun: DirectionalLight3D = lighting.get_node_or_null("Sun")
		if check(sun != null, "and a sun"):
			check(sun.shadow_enabled, "that casts shadows")
			check(absf(sun.rotation_degrees.x) > 20.0 and absf(sun.rotation_degrees.x) < 80.0,
				"at an angle that gives the deck relief rather than flattening it")

	camera = world.camera
	if not check(camera != null, "the world built a camera"):
		finish()
		return
	eq(camera.bridge_width_cells, world.grid.width,
		"the camera frames the bridge that was actually built, not a default")

	world._spawn_player(1, 0)
	player = world.player_body(1)
	# Lane 9 is clear of every authored gap for the stretch this test walks, and
	# well away from the rows where the parapet is suppressed. The first version
	# walked diagonally off the exposed run and then failed the frustum check
	# from halfway down a fall, which is a confusing way to be told the test rig
	# picked a bad route.
	player.position = world.grid.cell_surface_world(Vector2i(9, 1)) + Vector3(0.0, 1.2, 0.0)

	# Drive through the world's own input hook, NOT by calling player.step() from
	# here. The world runs its own host tick, so stepping the body as well moves
	# it twice a frame -- with the world's half supplying no input, which reads as
	# movement that is inexplicably weak and then as a fall.
	world.scripted_inputs[1] = func(t: int) -> Array:
		# Sideways first, then along the bridge, separated so each assertion is
		# about one motion and cannot be satisfied by the other.
		if t > 10 and t <= 70:
			return PlayerInput.make(t, Vector2(1.0, 0.0), 0)      # east
		if t > 70:
			return PlayerInput.make(t, Vector2(0.0, -1.0), 0)     # up the bridge
		return PlayerInput.empty(t)

	# 1. The whole bridge across. Checked at the framing distance the camera
	# actually uses, against the bridge's real half-width.
	var half_bridge: float = float(world.grid.width) * GridConfig.CELL_SIZE * 0.5
	check(camera.visible_half_width() > half_bridge,
		"the camera sees past both parapets (%.1f m visible vs %.1f m of bridge)"
			% [camera.visible_half_width(), half_bridge])

	# It should not be absurdly wide either -- a camera framed for several times
	# the bridge has pulled so far back that players are specks.
	check(camera.visible_half_width() < half_bridge * 2.5,
		"and does not frame far more bridge than exists (%.1f m)" % camera.visible_half_width())

	start_camera = camera.desired_position()
	start_x = player.position.x
	eq(start_camera.x, 0.0, "the camera sits on the bridge's centre line")

func _physics_process(_delta: float) -> void:
	if player == null or world.tick == 0:
		return
	frame = world.tick

	if frame == 70:
		check(absf(player.position.x - start_x) > 3.0,
			"the player really did move sideways (%.2f m)" % (player.position.x - start_x))
		eq(camera.desired_position().x, 0.0,
			"and the camera did not follow it sideways")

	if frame == 220:
		check(player.position.y > -5.0,
			"the player is still on the bridge rather than mid-fall (y = %.2f)" % player.position.y)

		var now: Vector3 = camera.desired_position()
		eq(now.x, 0.0, "the camera still sits on the centre line after a sideways walk")

		# ...and it did follow along the bridge. -Z is up the bridge.
		check(now.z < start_camera.z - 3.0,
			"the camera followed along the bridge (%.2f m)" % (start_camera.z - now.z))

		# The player is still framed: both bridge edges at the player's row are
		# inside the frustum, and so is the player.
		var edge_x: float = float(world.grid.width) * GridConfig.CELL_SIZE * 0.5
		camera.position = now
		check(camera.is_position_in_frustum(player.global_position),
			"the player is on screen")
		check(camera.is_position_in_frustum(Vector3(-edge_x + 0.5, player.position.y, player.position.z)),
			"the left edge of the bridge is on screen")
		check(camera.is_position_in_frustum(Vector3(edge_x - 0.5, player.position.y, player.position.z)),
			"the right edge of the bridge is on screen")
		finish()
