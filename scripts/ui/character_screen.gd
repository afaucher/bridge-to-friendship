extends CanvasLayer

# The character screen, opened from the main menu.
#
# BUILT IN CODE, LIKE EVERY OTHER SCREEN IN THIS GAME. hud.gd, score_screen.gd
# and debug_console.gd are all constructed in _ready() rather than authored as
# scenes, and main.gd:41-45 says that is on purpose. debug_console.gd is the
# closest model: a CanvasLayer built from a table, instantiated lazily, and
# openable from the menu with no world running.
#
# WHAT IS AND IS NOT WIRED UP YET (2026-08-20). The preview is real -- it is the
# actual player scene, so the beak you see is the beak the game ships. The COLOUR
# control is live but drives ONLY the preview: nothing is saved, nothing reaches
# the running game, and nothing is replicated. Eyes and the accessory slot do not
# exist yet. See design_ideas/character_customization.md for the parts still to
# build; this is the surface they will hang off.
#
# THE COLOUR ROW IS ALREADY WORTH LOOKING AT despite saving nothing, because it
# is where the derived nose can be SEEN. Drag the picker to yellow and watch the
# marker go dark rather than disappear -- that is CharacterStyle.nose_colour
# doing the one job this feature's sharpest finding asked of it.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const PlayerScene = preload("res://scenes/player.tscn")

# EXPLICIT, NEVER INHERITED. The headless viewport is 64x64 (CLAUDE.md), so a
# SubViewport left to take its size from its parent renders a postage stamp in
# the gate and something else entirely in a window. Two numbers, written down.
const PREVIEW_SIZE := Vector2i(380, 460)

# Degrees per second the model turns. A turntable rather than a fixed pose
# because the property the nose is FOR is only visible from some angles, and a
# preview that hides it would be the "measure on a fixture that cannot fail" trap
# rendered as a menu.
const SPIN_DEGREES := 24.0

const COLOR_PANEL := Color(0.08, 0.09, 0.12, 0.97)
const COLOR_SCRIM := Color(0.0, 0.0, 0.0, 0.55)
const COLOR_TEXT := Color(0.90, 0.92, 0.95)
const COLOR_DIM := Color(0.55, 0.60, 0.68)
const COLOR_HEAD := Color(0.45, 0.85, 1.0)

# The slots, as a table rather than as code. debug_console.gd's whole shape, and
# for its reason: the three unbuilt rows below become real by gaining a control,
# not by anyone editing the layout.
const SLOTS := [
	{"key": "colour", "label": "Colour", "state": "preview only -- not saved yet"},
	{"key": "nose", "label": "Nose", "state": "Beak -- the only shape so far"},
	{"key": "eyes", "label": "Eyes", "state": "not built"},
	{"key": "accessory", "label": "Accessory", "state": "not built -- horns, antlers or a tail"},
]

var _root: Control = null
var _pivot: Node3D = null
var _preview_body: Node3D = null
var _body_material: StandardMaterial3D = null
var _nose_material: StandardMaterial3D = null
var _body_colour: Color = CharacterStyle.DEFAULT_BODY

func _ready() -> void:
	layer = 80
	_build()
	visible = false
	set_process(false)

func toggle() -> void:
	visible = not visible
	# The turntable only turns while anybody is looking at it. A SubViewport set
	# to render every frame behind a hidden menu is a cost with no picture.
	set_process(visible)
	var vp := _preview_viewport()
	if vp != null:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_DISABLED

func _process(delta: float) -> void:
	if _pivot != null:
		_pivot.rotate_y(deg_to_rad(SPIN_DEGREES) * delta)

# --- Building -----------------------------------------------------------------

func _build() -> void:
	# A CONTROL PARENTED TO A CanvasLayer IS LAID OUT BY NOTHING, and its anchors
	# are four correct numbers about a rect of zero. CLAUDE.md carries this one
	# from 2026-08-17, reported from play as "the score screen is top left":
	# PRESET_FULL_RECT needs a parent CONTROL to take an area from, and a
	# CanvasLayer is not one. So the root is sized from the viewport by hand and
	# re-sized whenever the window changes; everything nested INSIDE it can then
	# use anchors normally, because it finally has a parent with a size.
	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)

	var scrim := ColorRect.new()
	scrim.color = COLOR_SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(scrim)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(centre)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.set_corner_radius_all(8)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	centre.add_child(panel)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	panel.add_child(columns)

	columns.add_child(_build_preview())
	columns.add_child(_build_controls())

func _build_preview() -> Control:
	var frame := SubViewportContainer.new()
	frame.stretch = true
	frame.custom_minimum_size = Vector2(PREVIEW_SIZE)

	var vp := SubViewport.new()
	vp.name = "Preview"
	vp.size = PREVIEW_SIZE
	# ITS OWN WORLD, which is what makes this safe to open from the main menu with
	# no game running -- and what stops the preview body appearing in the real
	# world if one IS running. It also gives the viewport its own physics space,
	# so the CharacterBody3D below cannot touch anything anybody is playing on.
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	frame.add_child(vp)

	# A WORLD OF ITS OWN HAS NO LIGHT IN IT. Borrowing the game's would mean the
	# preview is unlit on the menu, which is where it is mostly seen -- so it
	# carries its own, aimed from over the camera's shoulder.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-32.0, 152.0, 0.0)
	light.light_energy = 1.15
	vp.add_child(light)

	var camera := Camera3D.new()
	camera.current = true
	# PARENTED BEFORE IT IS AIMED. look_at works in GLOBAL space, so it needs the
	# node to be in a tree to have one -- called on a loose node it is either an
	# error or an aim at the wrong origin, depending on the version.
	vp.add_child(camera)
	# ON THE -Z SIDE, because that is where the nose points. A preview framed from
	# behind would show a plain cylinder and hide the one feature that has shipped.
	camera.position = Vector3(1.5, 0.75, -3.0)
	camera.look_at(Vector3(0.0, -0.05, 0.0), Vector3.UP)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	vp.add_child(_pivot)

	# THE REAL PLAYER SCENE, not a lookalike built from primitives.
	#
	# merchant_body.gd makes the same choice for the hat he holds up, and gives
	# the reason: a model built by hand "would drift the first time the trophy's
	# proportions were tuned". A character preview that disagrees with the
	# character is worse than no preview, because it is believed.
	#
	# PROCESS_MODE_DISABLED is what makes it safe. player_body.gd is a simulation
	# script; nothing here wants it stepping, falling, or reading input. A
	# CharacterBody3D that is never told to move_and_slide simply stands there,
	# which is exactly the pose a preview wants.
	_preview_body = PlayerScene.instantiate()
	_preview_body.process_mode = Node.PROCESS_MODE_DISABLED
	_pivot.add_child(_preview_body)
	_apply_preview_colour()
	return frame

func _build_controls() -> Control:
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	rows.custom_minimum_size = Vector2(340, 0)

	rows.add_child(_label("CHARACTER", 16, COLOR_HEAD))
	rows.add_child(_label("Nothing here is saved yet -- this screen previews\nwhat the customization system will drive.", 12, COLOR_DIM))

	for slot in SLOTS:
		rows.add_child(_row(slot))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.add_child(spacer)

	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(toggle)
	rows.add_child(close)
	return rows

func _row(slot: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var name_label := _label(str(slot.get("label", "")), 13, COLOR_TEXT)
	name_label.custom_minimum_size = Vector2(96, 0)
	head.add_child(name_label)

	# ONE BRANCH PER SLOT THAT HAS A CONTROL, and a label for the ones that do
	# not. An unbuilt slot is shown rather than hidden: a screen that lists what
	# is coming is a screen somebody can tell you is missing something.
	if str(slot.get("key", "")) == "colour":
		var picker := ColorPickerButton.new()
		picker.custom_minimum_size = Vector2(180, 28)
		picker.color = _body_colour
		picker.color_changed.connect(_on_colour_chosen)
		head.add_child(picker)
	else:
		head.add_child(_label(str(slot.get("state", "")), 12, COLOR_DIM))

	row.add_child(head)
	if str(slot.get("key", "")) == "colour":
		row.add_child(_label(str(slot.get("state", "")), 11, COLOR_DIM))
	return row

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label

# --- The preview's colour -----------------------------------------------------

func _on_colour_chosen(colour: Color) -> void:
	_body_colour = colour
	_apply_preview_colour()

# PER-INSTANCE MATERIALS, CREATED HERE AND NEVER THE SCENE'S.
#
# player.tscn's Mat_1 and NoseMat_1 are sub-resources, which means every instance
# of that scene SHARES them -- writing albedo_color through the node would tint
# every player in the game, including the ones on the bridge behind this menu.
# player_body.gd:178-182 records the same bug being fixed in the status bar,
# where one player's bar re-tinted the whole party's. New materials, assigned as
# an override on this instance only.
func _apply_preview_colour() -> void:
	if _preview_body == null:
		return
	var mesh := _preview_body.get_node_or_null("Mesh") as MeshInstance3D
	var nose := _preview_body.get_node_or_null("Facing/Nose") as MeshInstance3D
	if mesh == null or nose == null:
		return

	if _body_material == null:
		_body_material = StandardMaterial3D.new()
		_body_material.roughness = 0.7
		mesh.material_override = _body_material
	if _nose_material == null:
		_nose_material = StandardMaterial3D.new()
		_nose_material.roughness = 0.6
		nose.material_override = _nose_material

	_body_material.albedo_color = _body_colour
	_nose_material.albedo_color = CharacterStyle.nose_colour(_body_colour)

# --- Layout -------------------------------------------------------------------

func _fit_to_viewport() -> void:
	if _root == null:
		return
	var rect: Rect2 = get_viewport().get_visible_rect()
	_root.position = Vector2.ZERO
	_root.size = rect.size

func _preview_viewport() -> SubViewport:
	if _root == null:
		return null
	return _root.find_child("Preview", true, false) as SubViewport
