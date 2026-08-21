extends "res://scripts/test_support/test_case.gd"

# The camera's load-bearing properties, asserted rather than eyeballed:
#
#   1. The frame is a FIXED number of metres. It used to be derived from the
#      bridge's width, which was the same thing while every bridge was the same
#      width; when M22's canvas went 15 -> 21 that would have zoomed every player
#      out by 40% to show six cells of air. This is the one that silently
#      regresses -- change the cell size or the frame width and the framing is
#      wrong on every machine.
#   2. On a bridge that FITS the frame it never tracks sideways -- the behaviour
#      the game has always had, and the reason is unchanged: a camera that chased
#      a player across a 30 m deck would make it feel like a corridor and would
#      slide the world under someone lining up a dash.
#   3. On a bridge WIDER than the frame it pans, and never looks past the deck.
#      Walk to one edge and it reads exactly like a bridge of the frame's width,
#      except there is no wall on the far side because the bridge keeps going.
#   4. It DOES track along the bridge, in height as well as distance -- the deck
#      is pitched and steps up in layers, so following z alone lets the party
#      climb out of frame.
#
# 2 AND 3 ARE BOTH ASSERTED, ON TWO FIXTURES. A camera that never moved would
# satisfy 2 alone, and one that always chased would satisfy 3 alone; only having
# both says the clamp is what decides. Half a gate is not a gate.

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
	# A TEST FIXTURE, not the playtest map. This walked playtest_bridge until
	# 2026-08-10 and the route it took ended in a hole at z7 -- which had always
	# been a fall, but a fall takes ~1.3 s to reach the kill plane, so the wipe
	# that followed landed AFTER this test's last assertion and nobody noticed.
	# Making the ledge grab work for self-inflicted falls turned that fall into an
	# instant catch, a solo hang is a wipe by definition, and the restart yanked
	# the camera back to the checkpoint mid-measurement.
	#
	# The failure was real and the route was always wrong; only the timing had
	# been hiding it. Tuning a map for feel must not be able to do this, which is
	# why the fixtures exist and why the playtest map is not one.
	world.segment_paths = ["res://segments/test_flat.seg"]
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
	# COLUMN 22, WALKING EAST TO ~25, which is clear of every hole in test_flat for
	# the whole length: the gaps sit at x 9-12 and x 18-21 on rows 2-3, and x 4-21
	# on row 6. Anything at x >= 22 threads all of them.
	#
	# The route has to survive the SIDEWAYS leg too -- an earlier version named a
	# clear start lane and then walked three cells east out of it, which is how it
	# ended up over a hole. State what is clear AFTER the movement, not before.
	player.position = world.grid.cell_surface_world(Vector2i(22, 1)) + Vector3(0.0, 1.2, 0.0)

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

	# 1. A FIXED FRAME. test_flat is 30 cells wide and the frame is 15, so this
	# fixture is deliberately the WIDER-THAN-THE-FRAME case; the narrower case
	# gets its own world at the bottom of the file.
	var half_frame: float = float(camera.frame_width_cells) * GridConfig.CELL_SIZE * 0.5
	check(camera.visible_half_width() > half_frame,
		"the camera sees past both edges of the width it frames (%.1f m visible "
			% camera.visible_half_width()
		+ "vs %.1f m framed) -- the margin is what makes a bridge read as a "
			% half_frame
		+ "structure in the air rather than as a floor")
	check(camera.visible_half_width() < half_frame * 2.5,
		"and does not frame far more than that (%.1f m)" % camera.visible_half_width())

	# THE FRAME DOES NOT GROW WITH THE BRIDGE, which is the regression this test
	# exists for. A 30-cell fixture must not pull the camera back to fit 30 cells.
	var half_bridge: float = float(world.grid.width) * GridConfig.CELL_SIZE * 0.5
	check(camera.visible_half_width() < half_bridge,
		"and a bridge WIDER than the frame is not zoomed out to fit (%.1f m "
			% camera.visible_half_width()
		+ "visible against %.1f m of bridge) -- framing the canvas would shrink "
			% half_bridge
		+ "every player on screen to show ground nobody is standing on")

	start_camera = camera.desired_position()
	start_x = player.position.x

func _physics_process(_delta: float) -> void:
	if player == null or world.tick == 0:
		return
	frame = world.tick

	if frame == 70:
		check(absf(player.position.x - start_x) > 3.0,
			"the player really did move sideways (%.2f m)" % (player.position.x - start_x))
		# ON A BRIDGE WIDER THAN THE FRAME IT PANS. Not chasing: the clamp below
		# is what stops it, and this only says the pan happens at all.
		check(absf(camera.desired_position().x) > 0.5,
			"and on a bridge wider than the frame the camera panned with it "
			+ "(%.2f m) rather than holding a centre line that would leave a third "
				% camera.desired_position().x
			+ "of the deck permanently off screen")

	if frame == 220:
		check(player.position.y > -5.0,
			"the player is still on the bridge rather than mid-fall (y = %.2f)" % player.position.y)

		var now: Vector3 = camera.desired_position()

		# ...and it did follow along the bridge. -Z is up the bridge.
		check(now.z < start_camera.z - 3.0,
			"the camera followed along the bridge (%.2f m)" % (start_camera.z - now.z))

		# IT NEVER LOOKS PAST THE DECK. This is the assertion that separates a
		# clamped pan from a camera that chases: however far the player walks, the
		# frame stays inside the bridge, so there is never dead air at one side.
		var half: float = camera.visible_half_width()
		var edge_x: float = float(world.grid.width) * GridConfig.CELL_SIZE * 0.5
		check(now.x - half >= -edge_x - 0.01,
			"the frame's left edge is still on the deck (%.2f m against a bridge "
				% (now.x - half)
			+ "edge at %.2f m) -- a camera allowed past it would show empty air "
				% -edge_x
			+ "beside the bridge, which is the 'corridor' failure by another route")
		check(now.x + half <= edge_x + 0.01,
			"and so is the right (%.2f m against %.2f m)" % [now.x + half, edge_x])

		camera.position = now
		check(camera.is_position_in_frustum(player.global_position),
			"and the player -- who the camera is FOR -- is on screen")
		_test_a_bridge_that_fits_holds_still()
		finish()

# THE OTHER HALF, AND THE ONE THAT PROTECTS EVERY RUN THAT EXISTS TODAY.
#
# Everything above is measured on a 30-cell fixture, which is wider than the
# frame and therefore the panning case. A camera that simply chased the player
# would pass all of it. So a bridge NARROWER than the frame gets its own world,
# and there the old contract has to hold exactly: dead centre, and it stays there
# however far sideways somebody walks.
func _test_a_bridge_that_fits_holds_still() -> void:
	var narrow := Node3D.new()
	narrow.name = "NarrowCameraWorld"
	narrow.set_script(GameWorldScript)
	world.get_parent().add_child(narrow)
	# 15 cells, which is the frame's own width -- the baseline this game has been
	# played at for its whole life.
	narrow.segment_paths = ["res://segments/test_stats.seg"]
	narrow.start(true, 1, false)
	narrow._spawn_player(881204773, 0)
	var body: Node = narrow.player_body(881204773)

	var cam: Camera3D = narrow.camera
	if not check(cam != null, "the narrow world built a camera"):
		return
	eq(cam.bridge_width_cells, narrow.grid.width,
		"which knows the width of the bridge that was actually built")

	# Told where the deck is, exactly as the live world tells it every tick.
	var half_deck: float = float(narrow.grid.width) * GridConfig.CELL_SIZE * 0.5
	cam.set_deck_bounds(-half_deck, half_deck)
	for x in [-half_deck + 1.0, 0.0, half_deck - 1.0]:
		eq(cam.camera_x_for(x), 0.0,
			"a bridge that fits the frame is framed WHOLE and the camera holds "
			+ "the centre line, with the player at x %.1f -- the property the "
				% x
			+ "game has always had, and the reason is unchanged: a camera that "
			+ "chased sideways would slide the world under a dash")
	body.queue_free()
	narrow.queue_free()
