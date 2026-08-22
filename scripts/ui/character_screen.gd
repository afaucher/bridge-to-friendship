extends CanvasLayer

# The character screen, opened from the main menu.
#
# BUILT IN CODE, LIKE EVERY OTHER SCREEN IN THIS GAME. hud.gd, score_screen.gd
# and debug_console.gd are all constructed in _ready() rather than authored as
# scenes, and main.gd:41-45 says that is on purpose. debug_console.gd is the
# closest model: a CanvasLayer built from a table, instantiated lazily, and
# openable from the menu with no world running.
#
# THE PREVIEW IS THE REAL PLAYER SCENE, painted by the function the game paints
# with -- so nothing here can show you a character the bridge will not.
#
# Two of the four rows are choices and two are not, which is the design rather
# than a stage of construction:
#
#   colour     a free picker. Saved, replicated, worn.
#   accessory  horns, antlers, a tail, or none. One at a time.
#   nose       NOT a choice. It is the facing marker the dash depends on, and its
#              colour is derived from the body so it can never be hidden.
#   eyes       NOT a choice. Everybody has them; what varies comes from a saved
#              seed, including whether the two match.
#
# The colour row is the one worth playing with, because it is where the derived
# nose can be SEEN: drag the picker onto the old marker yellow and watch the beak
# go dark instead of disappearing.

const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const CharacterConfig = preload("res://scripts/character_config.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")
const HatConfig = preload("res://scripts/hat_config.gd")

# EXPLICIT, NEVER INHERITED. The headless viewport is 64x64 (CLAUDE.md), so a
# SubViewport left to take its size from its parent renders a postage stamp in
# the gate and something else entirely in a window. Two numbers, written down.
const PREVIEW_SIZE := Vector2i(380, 460)

# Degrees per second the model turns. A turntable rather than a fixed pose
# because the property the nose is FOR is only visible from some angles, and a
# preview that hides it would be the "measure on a fixture that cannot fail" trap
# rendered as a menu.
const SPIN_DEGREES := 24.0

# Where the preview camera stands and what it looks at. Constants because the
# test asserts the camera is actually AIMED at the model, and a test that
# restates the numbers is a test that agrees with whatever the code does.
#
# ON THE -Z SIDE, because that is where the nose points. A preview framed from
# behind shows a plain cylinder and hides the one feature that has shipped.
const CAMERA_POS := Vector3(1.5, 0.75, -3.0)
const CAMERA_TARGET := Vector3(0.0, -0.05, 0.0)

const COLOR_PANEL := Color(0.08, 0.09, 0.12, 0.97)
const COLOR_SCRIM := Color(0.0, 0.0, 0.0, 0.55)
const COLOR_TEXT := Color(0.90, 0.92, 0.95)
const COLOR_DIM := Color(0.55, 0.60, 0.68)
const COLOR_HEAD := Color(0.45, 0.85, 1.0)

# The slots, as a table rather than as code. debug_console.gd's whole shape, and
# for its reason: the three unbuilt rows below become real by gaining a control,
# not by anyone editing the layout.
# ONLY THE ROWS THAT ARE ACTUALLY A CHOICE.
#
# The nose and the eyes used to be listed here with a line each explaining that
# they are not selectable, which is a screen explaining itself instead of being
# obvious. A control you cannot operate is not information, it is furniture --
# and the same goes for the captions under the two real rows, which described
# mechanics (saved when, applied when) that the player finds out by using them.
const SLOTS := [
	{"key": "colour", "label": "Colour"},
	{"key": "accessory", "label": "Accessory"},
]

var _root: Control = null
var _pivot: Node3D = null
var _hats_root: Node3D = null
var _preview_body: Node3D = null
var _body_colour: Color = CharacterStyle.DEFAULT_BODY
var _character_seed: int = 0
var _accessory: String = CharacterStyle.ACCESSORY_NONE

func _ready() -> void:
	layer = 80
	# What is already on disk, before anything is built, so the preview and the
	# picker both open showing the character you are actually playing.
	_body_colour = CharacterConfig.load_body_colour()
	# Rolls one on a first-ever launch, so opening this screen is a perfectly good
	# way to acquire a face -- there is no order in which you have a colour and no
	# eyes.
	_character_seed = CharacterConfig.load_character_seed()
	_accessory = CharacterConfig.load_accessory()
	_build()
	visible = false
	set_process(false)

func toggle() -> void:
	visible = not visible
	# RE-READ ON OPEN. The hat on disk changes while you play -- steal one and it is
	# yours -- so a stack built once in _ready() would be showing you the hat you
	# had when the process started.
	if visible:
		_refresh_hats()
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
	# AIMED WITH ARITHMETIC, NOT WITH look_at.
	#
	# `Node3D.look_at` works in GLOBAL space, so it needs the node to be in a tree
	# to have one -- and NOTHING HERE IS IN THE TREE YET. This whole subtree hangs
	# off `frame`, which its caller parents only after this function returns.
	#
	# THE FAILURE MODE IS WHY THIS COMMENT IS LONG. look_at fails in C++, not in
	# GDScript: it prints `Node not inside tree` and RETURNS, so the script sails
	# on with the camera left in its default orientation -- at z = -3 looking
	# further away from the model. The preview then renders empty space, the
	# screen opens looking perfectly fine, and the only evidence is one line in a
	# log nobody reads. Shipped exactly that on 2026-08-20 and it was reported as
	# "no character preview".
	#
	# `Transform3D.looking_at` is pure maths on a value. No tree, no global space,
	# no failure mode, and a test can check the result.
	camera.transform = Transform3D(Basis(), CAMERA_POS).looking_at(CAMERA_TARGET, Vector3.UP)
	vp.add_child(camera)

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

	# THE HAT GOES ON THE PIVOT, NOT ON THE BODY, so it turns with the model
	# without being parented to a physics body. Same rule HatPool.pose_stack
	# follows for the opposite reason -- a RigidBody3D hung off another physics
	# body is invisible to a raycast, which cost this game the "shoot a hat off"
	# verb for a whole milestone.
	_hats_root = Node3D.new()
	_hats_root.name = "Hats"
	_pivot.add_child(_hats_root)
	_refresh_hats()
	return frame

# YOUR HAT, ON YOUR CHARACTER. Everything else on this screen is loaded from a
# `*Config` -- colour, seed, accessory -- and the hat is the fourth thing in that
# list: `HatConfig` calls it "the hat you own, across launches", and starting a
# session wearing it is the whole premise. A character screen that showed the
# other three and not this one is showing you most of a character.
#
# A STACK RATHER THAN A HAT, even though the saved state is currently one. The
# spacing is the tricky part and it is already solved -- `HatStyle.slot_height` is
# what HatPool.pose_stack and hat_body's worn collider BOTH ask, and CLAUDE.md
# records what it cost when a stack was spaced one way and shot at another. Asking
# the same function here means the preview cannot disagree with the tower either,
# and a stack becomes a list rather than a rewrite.
func _refresh_hats() -> void:
	_render_hats(_worn_styles())

# Split from the reader so a test can hand it a stack without touching the saved
# file: HatConfig.path() is under user://, which on a developer machine is a real
# character somebody is playing.
func _render_hats(styles: Array) -> void:
	if _hats_root == null:
		return
	# REMOVED, not just freed. queue_free defers to the end of the frame, so a
	# caller that rebuilds and then counts would see the old hats and the new ones
	# at once.
	for old in _hats_root.get_children():
		_hats_root.remove_child(old)
		old.queue_free()
	var base: float = PlayerBody.HALF_HEIGHT
	for style_id in styles:
		var hat := Node3D.new()
		hat.name = "Hat"
		# apply_style rather than apply: a plain Node3D has no `style_id`, and
		# reading a property that does not exist raises. It writes these two meshes
		# and skips the `Shape` child when there is none, which is what makes it
		# reusable as a display model with no collider. Same trick merchant_body
		# uses for the hat he holds up.
		var crown := MeshInstance3D.new()
		crown.name = "Crown"
		hat.add_child(crown)
		var brim := MeshInstance3D.new()
		brim.name = "Brim"
		hat.add_child(brim)
		HatStyle.apply_style(hat, style_id)
		var slot: float = HatStyle.slot_height(style_id)
		# `mount_offset`, not half a slot -- an ordinary hat stands on its origin
		# and a tall one straddles it, and using the slot centre for both is what
		# left every ordinary hat floating 17.5 cm off the head.
		hat.position = Vector3(0.0, base + HatStyle.mount_offset(style_id), 0.0)
		_hats_root.add_child(hat)
		base += slot

# One entry, or none. It is a list because the drawing above is a stack and the
# in-game tower is one too; the day this screen is opened over a live world, the
# only change is where this reads from.
func _worn_styles() -> Array:
	var saved: int = HatConfig.load_style()
	return [] if saved == HatConfig.NONE else [saved]

func _build_controls() -> Control:
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	rows.custom_minimum_size = Vector2(340, 0)

	rows.add_child(_label("CHARACTER", 16, COLOR_HEAD))

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
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var head := row
	var name_label := _label(str(slot.get("label", "")), 13, COLOR_TEXT)
	name_label.custom_minimum_size = Vector2(96, 0)
	head.add_child(name_label)

	# ONE BRANCH PER SLOT, and every slot in the table has a control -- the ones
	# that were only ever a caption are gone.
	var key: String = str(slot.get("key", ""))
	match key:
		"colour":
			var picker := ColorPickerButton.new()
			picker.custom_minimum_size = Vector2(180, 28)
			picker.color = _body_colour
			picker.color_changed.connect(_on_colour_chosen)
			head.add_child(picker)
		"accessory":
			# BUILT FROM CharacterStyle.ACCESSORIES, never from a list written out
			# again here. A second copy of the catalogue is a second thing to keep
			# in step, and the one that drifts is the one nobody is testing.
			var choices := OptionButton.new()
			choices.custom_minimum_size = Vector2(180, 28)
			for i in CharacterStyle.ACCESSORIES.size():
				var kind: String = CharacterStyle.ACCESSORIES[i]
				choices.add_item(kind.capitalize(), i)
				if kind == _accessory:
					choices.select(i)
			choices.item_selected.connect(_on_accessory_chosen)
			head.add_child(choices)
	return row

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label

# --- The preview's colour -----------------------------------------------------

# SAVED ON EVERY CHANGE, with no confirm step.
#
# There is nothing to cancel: a colour is not a transaction and the preview
# beside it already shows exactly what was saved. An Apply button would only
# create a state where the screen and the disk disagree, which is a bug nobody
# has to have.
#
# It takes effect at the next SPAWN rather than immediately, and that is a
# property of where this screen lives rather than a decision: the button that
# opens it is on the menu, and the menu is hidden while a world is running. If
# the screen ever becomes reachable mid-session, this is the line that has to
# start telling the world.
func _on_colour_chosen(colour: Color) -> void:
	_body_colour = colour
	_apply_preview_colour()
	CharacterConfig.save_body_colour(colour)

func _on_accessory_chosen(index: int) -> void:
	if index < 0 or index >= CharacterStyle.ACCESSORIES.size():
		return
	_accessory = CharacterStyle.ACCESSORIES[index]
	_apply_preview_colour()
	CharacterConfig.save_accessory(_accessory)

# THE SAME FUNCTION THE GAME CALLS, on the same scene the game spawns.
#
# This used to build its own materials here, which worked and was a lie waiting
# to happen: two code paths painting the same scene drift, and the one nobody
# plays is the one that drifts. PlayerBody.apply_look is now the only thing that
# knows how a character is painted, so the preview cannot show you a face the
# bridge will not.
#
# It also inherits the per-instance materials for free -- player.tscn's Mat_1 is
# a sub-resource shared by every instance, so painting through the node would
# tint every player in a game running behind this menu. apply_look creates its
# own; see the note there, and player_body.gd's status bar for the original bug.
func _apply_preview_colour() -> void:
	if _preview_body == null or not _preview_body.has_method("apply_look"):
		return
	_preview_body.apply_look(_body_colour, _character_seed, _accessory)

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
