extends "res://scripts/test_support/test_case.gd"

# The character screen: that it builds, that it is laid out, and that previewing
# a colour cannot touch anybody else.
#
# HEADLESS BUILDS THE WHOLE CONTROL TREE, it just does not draw it -- so a screen
# IS testable even though its picture is not. That matters more than it sounds:
# GDScript resolves properties at runtime, so a UI script the gate never
# instantiates ships having never executed a single line. See test_hud_view.gd,
# which exists for the same reason.
#
# WHAT IS ASSERTED IS SIZE AND POSITION, NEVER ANCHORS. CLAUDE.md's 2026-08-17
# entry is exactly this shape: the score screen shipped in the top-left corner
# while its test asserted the anchors, which were right the whole time. A Control
# parented to a CanvasLayer is laid out by nothing, so PRESET_FULL_RECT sets four
# correct numbers about a rect of zero. Asserting the INPUT to a layout is not
# asserting the layout -- measure what the player is looking at.

const CharacterScreenScript = preload("res://scripts/ui/character_screen.gd")
const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")

func setup(_main) -> void:
	var screen: CanvasLayer = CharacterScreenScript.new()
	add_child(screen)

	_test_it_built(screen)
	_test_it_is_laid_out(screen)
	_test_preview_viewport_size(screen)
	_test_camera_faces_the_model(screen)
	_test_preview_is_the_real_player(screen)
	_test_colour_does_not_leak(screen)
	_test_toggle(screen)
	finish()

# --- 1. It exists at all ------------------------------------------------------

func _test_it_built(screen: CanvasLayer) -> void:
	check(screen._root != null, "the screen built a root Control")
	check(screen._pivot != null, "and a pivot for the turntable")
	check(screen._preview_body != null, "and a preview body")
	check(not screen.visible, "and starts hidden")

# --- 2. It is actually laid out -----------------------------------------------
#
# A RELATIONSHIP, NOT A NUMBER. The headless viewport is 64x64 and a window is
# not, so "the root is 1280 wide" is a claim about the machine rather than about
# the code. That it MATCHES the viewport is true everywhere.

func _test_it_is_laid_out(screen: CanvasLayer) -> void:
	var want: Vector2 = screen.get_viewport().get_visible_rect().size
	check(screen._root.size == want,
		"the root fills the viewport -- %s against %s" % [screen._root.size, want])
	check(screen._root.position == Vector2.ZERO, "and sits at the origin")
	# The failure this is really about: a Control that was never given a size.
	check(screen._root.size.x > 0.0 and screen._root.size.y > 0.0,
		"and is not the 0x0 rect an anchored-to-a-CanvasLayer Control would be")

# --- 3. The viewport size is written down, not inherited ----------------------
#
# CLAUDE.md: the headless viewport is 64x64. A SubViewport that takes its size
# from its surroundings renders a postage stamp in the gate and something else in
# a window, and the offscreen-marker test already cost a day to that.

func _test_preview_viewport_size(screen: CanvasLayer) -> void:
	var vp: SubViewport = screen._preview_viewport()
	if not check(vp != null, "the preview SubViewport is findable"):
		return
	check(vp.size == CharacterScreenScript.PREVIEW_SIZE,
		"the preview is its declared size -- %s against %s" % [vp.size, CharacterScreenScript.PREVIEW_SIZE])
	check(Vector2(vp.size) != screen.get_viewport().get_visible_rect().size,
		"and is NOT whatever the host viewport happens to be")
	check(vp.own_world_3d, "the preview has its own world, so it cannot appear in a running game")
	check(vp.get_node_or_null("DirectionalLight3D") != null or _has_light(vp),
		"and its own light, because a fresh World3D has none")

func _has_light(vp: SubViewport) -> bool:
	for child in vp.get_children():
		if child is DirectionalLight3D:
			return true
	return false

# --- 3b. THE CAMERA IS POINTED AT THE MODEL -----------------------------------
#
# THIS IS THE ASSERTION WHOSE ABSENCE SHIPPED AN EMPTY PREVIEW. The first version
# of this file checked that a camera EXISTED, which it did, while it faced the
# wrong way entirely: `look_at` was called on a node that was not yet in the
# tree, failed in C++ rather than in GDScript -- so it printed an error and let
# the script continue -- and left the camera in its default orientation, at
# z = -3 looking further away from the player. Everything else here passed.
#
# It is the same shape as three notes in CLAUDE.md: a blocker that exists is not
# a blocker that blocks, and asserting a layout's anchors is not asserting its
# layout. A camera that exists is not a camera that is looking at anything.

func _test_camera_faces_the_model(screen: CanvasLayer) -> void:
	var vp: SubViewport = screen._preview_viewport()
	if vp == null:
		return
	var camera: Camera3D = null
	for child in vp.get_children():
		if child is Camera3D:
			camera = child
			break
	if not check(camera != null, "the preview has a camera"):
		return

	check(camera.position.is_equal_approx(CharacterScreenScript.CAMERA_POS),
		"the camera stands where it meant to -- %s" % camera.position)

	# A Camera3D looks down its own -Z. So the question is whether that axis
	# agrees with the direction from the camera to the thing it is supposed to be
	# framing, and a dot product is the whole test.
	var want: Vector3 = (CharacterScreenScript.CAMERA_TARGET - camera.position).normalized()
	var facing: Vector3 = -camera.transform.basis.z.normalized()
	var agreement: float = facing.dot(want)
	check(agreement > 0.99,
		"and is aimed at the model rather than away from it -- dot %.3f (1.0 is dead on, negative is backwards)"
			% agreement)

	# The model has to be in FRONT of it as well as along the axis: a camera
	# aimed correctly from behind the subject satisfies a dot product and frames
	# nothing.
	var to_model: Vector3 = CharacterScreenScript.CAMERA_TARGET - camera.position
	check(to_model.dot(facing) > 0.0, "with the model in front of the lens, not behind it")

# --- 4. It previews the real thing --------------------------------------------
#
# The merchant's signage argument: a model built by hand drifts the first time
# the real one is tuned, and a preview that disagrees with the character is worse
# than none because it is believed.

func _test_preview_is_the_real_player(screen: CanvasLayer) -> void:
	var nose := screen._preview_body.get_node_or_null("Facing/Nose") as MeshInstance3D
	check(nose != null, "the preview carries the real player's facing marker")
	check(screen._preview_body.process_mode == Node.PROCESS_MODE_DISABLED,
		"and is not simulating -- a preview body must not step, fall or read input")

# --- 5. A previewed colour cannot reach anybody else --------------------------
#
# THE TRAP THIS IS REALLY ABOUT. player.tscn's materials are sub-resources, so
# every instance of the scene shares them: writing albedo_color through the node
# would tint every player on the bridge behind this menu. player_body.gd:178-182
# records the identical bug being fixed in the status bar, where one player's bar
# re-tinted the whole party's.
#
# A test that only checked the preview looked right would pass while doing this.

func _test_colour_does_not_leak(screen: CanvasLayer) -> void:
	var fresh: Node3D = PlayerScene.instantiate()
	add_child(fresh)
	var fresh_mesh := fresh.get_node_or_null("Mesh") as MeshInstance3D
	if not check(fresh_mesh != null, "a fresh player instance has a mesh to compare against"):
		return
	var before: Color = (fresh_mesh.material_override as StandardMaterial3D).albedo_color

	screen._on_colour_chosen(Color(0.95, 0.1, 0.1))

	var after: Color = (fresh_mesh.material_override as StandardMaterial3D).albedo_color
	check(before == after,
		"tinting the preview left every other player alone -- %s became %s" % [before, after])

	# And the preview really did change, or the assertion above is satisfied by a
	# function that does nothing at all.
	var preview_mesh := screen._preview_body.get_node_or_null("Mesh") as MeshInstance3D
	var shown: Color = (preview_mesh.material_override as StandardMaterial3D).albedo_color
	check(shown != before, "while the preview itself did change -- %s" % shown)

	# The nose followed it, derived rather than fixed.
	var preview_nose := screen._preview_body.get_node_or_null("Facing/Nose") as MeshInstance3D
	var nose_shown: Color = (preview_nose.material_override as StandardMaterial3D).albedo_color
	check(nose_shown == CharacterStyle.nose_colour(shown),
		"and the nose is the derived colour for the body being shown")

# --- 6. Opening and closing ---------------------------------------------------

func _test_toggle(screen: CanvasLayer) -> void:
	screen.toggle()
	check(screen.visible, "toggling opens it")
	var vp: SubViewport = screen._preview_viewport()
	check(vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"and starts the preview rendering")
	screen.toggle()
	check(not screen.visible, "toggling again closes it")
	check(vp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"and stops it, so a hidden menu costs nothing")
