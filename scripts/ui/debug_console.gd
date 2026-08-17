extends CanvasLayer

# The debug console. See implementation_plans/m14_debug_console.md.
#
# THERE IS NO PER-KNOB CODE IN THIS FILE, and that is the requirement it exists to
# meet. It walks DebugSettings.OPTIONS and builds a row per entry and a control
# per KIND. Adding a setting is one dictionary entry in debug_settings.gd and
# nothing here changes -- because a debug surface that costs a UI edit per knob is
# one nobody adds knobs to, and then the numbers people want to try stay
# untryable.
#
# EVERY CHANGE GOES THROUGH THE WORLD, never straight into DebugSettings: any
# player may ask, the host decides, and everyone gets the answer. See
# GameWorld.push_setting. Editing the local singleton directly would give two
# people tuning the same number two different games.

const DebugSettingsScript = preload("res://scripts/debug_settings.gd")

const PANEL_WIDTH := 520.0
const COLOR_PANEL := Color(0.06, 0.07, 0.09, 0.94)
const COLOR_TEXT := Color(0.90, 0.92, 0.95)
const COLOR_DIM := Color(0.55, 0.60, 0.68)
const COLOR_SECTION := Color(0.45, 0.85, 1.0)

var world: Node = null

var _panel: PanelContainer = null
var _rows: VBoxContainer = null
# key -> the control that displays it, so an incoming replicated change can be
# reflected without rebuilding the panel under the player's cursor.
var _controls: Dictionary = {}
var _echo: Dictionary = {}
# True while a control is being updated FROM the config, so the signal it emits
# does not bounce straight back out as a fresh request.
var _syncing: bool = false

func _ready() -> void:
	layer = 90
	_build()
	visible = false
	DebugSettings.changed.connect(_on_setting_changed)

func toggle() -> void:
	visible = not visible
	if visible:
		_refresh_all()

# --- Building, entirely from the registry -------------------------------------

func _build() -> void:
	_panel = PanelContainer.new()
	# BOTTOM LEFT, OUT OF THE HUD'S WAY (2026-08-16). The panel was pinned to the
	# top corner, which is where the round state, the clock and the score all live
	# -- so opening the console hid the things a playtester has the console open to
	# watch. The bottom corner is the emptiest part of the screen: the camera looks
	# down the bridge, so the near edge of the deck is what is under there.
	#
	# ANCHORED, NOT POSITIONED. `position` is a pixel offset from the parent's top
	# left and would leave the panel wherever the window last happened to be that
	# size; anchoring to the bottom keeps it in the corner through a resize, which
	# matters because this is a floating layer over a game that changes resolution.
	# GROW_DIRECTION_BEGIN is the half that is easy to miss -- without it a panel
	# that grows as knobs are added grows DOWNWARD off the bottom of the screen,
	# and the registry is designed to be appended to.
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.grow_horizontal = Control.GROW_DIRECTION_END
	_panel.offset_left = 24
	_panel.offset_bottom = -24
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	_panel.add_child(_rows)

	_rows.add_child(_label("DEBUG  —  changes apply to everyone", 15, COLOR_TEXT))

	var by_section: Dictionary = DebugSettingsScript.sections()
	var names: Array = by_section.keys()
	names.sort()
	for section in names:
		_rows.add_child(_label(str(section).to_upper(), 12, COLOR_SECTION))
		for key in by_section[section]:
			_rows.add_child(_row(str(key)))

func _row(key: String) -> Control:
	var entry: Dictionary = DebugSettingsScript.OPTIONS[key]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var name := _label(str(entry.get("label", key)), 13, COLOR_TEXT)
	name.custom_minimum_size = Vector2(190, 0)
	name.tooltip_text = str(entry.get("help", ""))
	row.add_child(name)

	var control: Control = _control_for(key, entry)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.tooltip_text = str(entry.get("help", ""))
	_controls[key] = control
	row.add_child(control)

	# A live read-back beside every control. A slider whose value you cannot read
	# is a slider you cannot report a number from, and the whole point of this
	# panel is to produce numbers somebody writes into sim_config.gd afterwards.
	var echo := _label("", 13, COLOR_DIM)
	echo.custom_minimum_size = Vector2(72, 0)
	echo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_echo[key] = echo
	row.add_child(echo)
	return row

# ONE BRANCH PER KIND, not per key. This is the only place that knows a float is
# a slider, and it is what keeps the registry the single source of truth.
func _control_for(key: String, entry: Dictionary) -> Control:
	match DebugSettingsScript.kind_of(key):
		DebugSettingsScript.KIND_FLOAT, DebugSettingsScript.KIND_INT:
			var slider := HSlider.new()
			slider.min_value = float(entry.get("min", 0.0))
			slider.max_value = float(entry.get("max", 1.0))
			slider.step = float(entry.get("step", 1.0))
			slider.value_changed.connect(func(v: float): _push(key, v))
			return slider
		DebugSettingsScript.KIND_BOOL:
			var box := CheckBox.new()
			box.text = "on"
			box.toggled.connect(func(on: bool): _push(key, 1 if on else 0))
			return box
		_:
			var options := OptionButton.new()
			for choice in entry["choices"]:
				options.add_item(str(choice))
			options.item_selected.connect(func(i: int): _push(key, i))
			return options

# --- Values in and out --------------------------------------------------------

func _push(key: String, value: Variant) -> void:
	if _syncing:
		return
	if world != null and world.has_method("push_setting"):
		world.push_setting(key, value)
	else:
		# No world yet -- the menu is open at the main menu. Local is the only
		# thing that could be meant.
		DebugSettings.set_value(key, value)

func _on_setting_changed(key: String, _value: Variant) -> void:
	_refresh(key)

func _refresh_all() -> void:
	for key in _controls.keys():
		_refresh(str(key))

func _refresh(key: String) -> void:
	if not _controls.has(key):
		return
	var value: Variant = DebugSettings.get_value(key)
	# GUARDED, or setting the control fires its own signal and pushes the value
	# straight back at the host -- which on a client would be a request storm every
	# time a snapshot arrived.
	_syncing = true
	var control: Control = _controls[key]
	if control is HSlider:
		(control as HSlider).value = float(value)
	elif control is CheckBox:
		(control as CheckBox).button_pressed = int(value) != 0
	elif control is OptionButton:
		(control as OptionButton).selected = int(value)
	_syncing = false

	var echo: Label = _echo.get(key, null)
	if echo != null:
		echo.text = _format(key, value)

func _format(key: String, value: Variant) -> String:
	match DebugSettingsScript.kind_of(key):
		DebugSettingsScript.KIND_FLOAT:
			# A knob stepped in whole units is a whole number. "100.00" for a
			# percentage is noise, and the echo exists to be READ OUT in a
			# playtest report.
			var step: float = float(DebugSettingsScript.OPTIONS[key].get("step", 0.0))
			return str(int(round(float(value)))) if step >= 1.0 else "%.2f" % float(value)
		DebugSettingsScript.KIND_INT:
			return str(int(value))
		DebugSettingsScript.KIND_BOOL:
			return "on" if int(value) != 0 else "off"
		_:
			return DebugSettings.get_choice_name(key)

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label
