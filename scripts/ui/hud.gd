extends CanvasLayer

# The HUD, per D5: your health and three action slots top-left, your friends'
# name, health and special top-right.
#
# THIS FILE DECIDES NOTHING. Every question -- which countdown applies, how full
# a bar is, who counts as a friend, what order they come in -- is answered by
# hud_model.gd, which is a pure function and is what the gate actually tests. If
# a behaviour is worth asserting it does not belong here.
#
# Built in code rather than as a .tscn, matching scene_lighting.gd and the bridge
# camera. A hand-edited .tscn is a file Godot parses, and CLAUDE.md records what
# a BOM in one of those costs.
#
# Bars are ColorRects rather than ProgressBars on purpose: a ProgressBar's fill
# colour in Godot 4 lives in a theme StyleBox, not in a `tint_progress` property
# (that was Godot 3), and a HUD is not worth a theme resource.

const HudModel = preload("res://scripts/ui/hud_model.gd")
const TeammateMarkers = preload("res://scripts/ui/teammate_markers.gd")

const COLOR_HEALTH := Color(0.91, 0.29, 0.33)
const COLOR_HEALTH_LOST := Color(0.20, 0.20, 0.24)
const COLOR_GRACE := Color(1.00, 0.93, 0.55)
const COLOR_SLOT_READY := Color(0.88, 0.90, 0.96)
const COLOR_SLOT_COOLING := Color(0.42, 0.44, 0.52)
const COLOR_SLOT_EMPTY := Color(0.26, 0.27, 0.32)
const COLOR_TEXT := Color(0.92, 0.93, 0.96)
const COLOR_DIM := Color(0.62, 0.64, 0.70)
const COLOR_ALERT := Color(1.00, 0.45, 0.22)
const COLOR_BAR_BACK := Color(0.11, 0.11, 0.14)

# A FACE, WHERE THERE IS ONE. Small on purpose: this is a co-op game about where
# your friends ARE, so the portrait is an identifier beside a name, not a
# character card. At 26 px it reads as "who" without competing with the health
# pips, which are the thing you actually act on.
const AVATAR_SIZE := Vector2(26.0, 26.0)

const PIP_SIZE := Vector2(18.0, 18.0)
const SLOT_SIZE := Vector2(58.0, 40.0)
const BAR_SIZE := Vector2(150.0, 8.0)

# Eight-point compass, because the game already is one: the dash locks to four
# world axes and the camera is fixed-yaw, so "NE" means the same thing on every
# screen. Letters rather than arrow glyphs -- the default theme font is not
# guaranteed to carry the diagonal arrows, and a missing glyph is a blank box.
const COMPASS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var world: Node = null

var _own_panel: Control = null
var _own_name: Label = null
var _own_face: TextureRect = null
var _own_pips: HBoxContainer = null
var _own_slots: HBoxContainer = null
var _own_state: Label = null
var _own_bleed: ColorRect = null
var _own_rescue: ColorRect = null

var _markers: Control = null

var _friends_panel: Control = null
var _friends_box: VBoxContainer = null
var _friend_rows: Dictionary = {}      # peer -> {row, name, pips, state, bar, bearing}

func _ready() -> void:
	layer = 0        # under the menu's CanvasLayer, which is where the menu belongs
	_build_own_panel()
	_build_friends_panel()
	_build_markers()

func _process(_delta: float) -> void:
	var model: Dictionary = HudModel.build(world)
	var active: bool = bool(model.get("active", false))
	_own_panel.visible = active
	_friends_panel.visible = active
	if not active:
		return
	_update_own(model["own"])
	_update_friends(model["friends"])
	_update_markers(model["friends"], _delta)

# --- Avatars ------------------------------------------------------------------
#
# STEAM IS ASKED EVERY FRAME AND ANSWERS INSTANTLY, because SteamManager caches --
# the first ask starts an async fetch and returns null, and every ask after it
# returns the cached texture. Polling is therefore the simple correct thing here
# and a signal would buy nothing.
#
# NULL IS THE ORDINARY ANSWER. No Steam, no picture on the account, or it has not
# arrived yet -- all three look the same and all three mean "hide it". The HUD is
# built and laid out identically either way, so a machine with no Steam is not a
# degraded HUD, it is the same HUD without portraits. That also makes this
# testable: the gate has no Steam client and never will.
func _avatar() -> TextureRect:
	var face := TextureRect.new()
	face.custom_minimum_size = AVATAR_SIZE
	# STRETCH ONLY, NO EXPAND MODE. EXPAND_IGNORE_SIZE made headless print
	# "Failed to get image size." once a real avatar was set -- the dummy
	# rasterizer cannot answer the query that mode makes. The avatar is a fixed
	# 26 px either way because custom_minimum_size says so, so the expand mode was
	# buying nothing and costing an error line in the gate. A stray error in a
	# green run is worse than no error at all: it teaches people to skim past them.
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.visible = false
	return face

func _set_avatar(face: TextureRect, steam_id: int) -> void:
	if face == null:
		return
	var texture: Texture2D = NetworkManager.steam_avatar(steam_id)
	face.texture = texture
	face.visible = texture != null

# --- Offscreen and downed markers ---------------------------------------------

func _build_markers() -> void:
	_markers = Control.new()
	_markers.name = "TeammateMarkers"
	_markers.set_script(TeammateMarkers)
	add_child(_markers)

func _update_markers(friends: Array, delta: float) -> void:
	if _markers == null:
		return
	var list: Array = []
	for friend in friends:
		list.append({
			"at": friend.get("at", Vector3.ZERO),
			# A friend who is waiting for a rescue -- downed OR hanging off a
			# ledge. Both are "come and get me", and the marker does not care
			# which.
			"downed": bool(friend.get("needs_help", false)),
			"peer": int(friend.get("peer", 0)),
		})
	var cam: Camera3D = null
	if world != null and "camera" in world:
		cam = world.camera as Camera3D
	_markers.visible = cam != null
	_markers.refresh(list, cam, delta)

# --- Own panel ----------------------------------------------------------------

func _build_own_panel() -> void:
	var box := _anchored_box(Control.PRESET_TOP_LEFT)
	_own_panel = box.get_parent()

	# YOUR OWN FACE BESIDE YOUR OWN NAME. Beside rather than instead: the name is
	# what a player says out loud to their friends, and a portrait cannot be said.
	var own_header := HBoxContainer.new()
	own_header.add_theme_constant_override("separation", 8)
	box.add_child(own_header)

	_own_face = _avatar()
	own_header.add_child(_own_face)
	_own_name = _label("", 18, COLOR_TEXT)
	own_header.add_child(_own_name)

	_own_pips = HBoxContainer.new()
	_own_pips.add_theme_constant_override("separation", 5)
	box.add_child(_own_pips)

	_own_slots = HBoxContainer.new()
	_own_slots.add_theme_constant_override("separation", 8)
	box.add_child(_own_slots)

	_own_state = _label("", 20, COLOR_ALERT)
	box.add_child(_own_state)

	_own_bleed = _bar(COLOR_ALERT)
	box.add_child(_own_bleed)
	_own_rescue = _bar(COLOR_HEALTH)
	box.add_child(_own_rescue)

func _update_own(own: Dictionary) -> void:
	_own_name.text = str(own.get("name", ""))
	_set_avatar(_own_face, int(own.get("steam_id", 0)))

	# The grace window is why one tumble through a pillar field does not empty
	# the bar (B7). It is 0.75 s and entirely unknowable today; flashing the pips
	# is the cheapest way to make "that hit did not count" legible.
	var grace: float = float(own.get("grace", 0.0))
	_sync_pips(_own_pips, int(own.get("health", 0)), int(own.get("max_health", 0)),
		PIP_SIZE, COLOR_HEALTH.lerp(COLOR_GRACE, grace),
		COLOR_HEALTH_LOST.lerp(COLOR_GRACE, grace))

	_sync_slots(own.get("slots", []))

	_own_state.text = str(own.get("state_label", ""))
	_own_state.visible = _own_state.text != ""
	_set_bar(_own_bleed, float(own.get("bleed_out", HudModel.NO_BAR)))
	_set_bar(_own_rescue, float(own.get("rescue", HudModel.NO_BAR)))

func _sync_slots(slots: Array) -> void:
	while _own_slots.get_child_count() < slots.size():
		var slot := ColorRect.new()
		slot.custom_minimum_size = SLOT_SIZE
		var caption := _label("", 11, COLOR_TEXT)
		caption.set_anchors_preset(Control.PRESET_FULL_RECT)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_child(caption)
		_own_slots.add_child(slot)

	for i in slots.size():
		var data: Dictionary = slots[i]
		var slot: ColorRect = _own_slots.get_child(i)
		var caption: Label = slot.get_child(0)
		caption.text = str(data.get("label", ""))
		# AMMO UNDER THE NAME. Fixed uses is the model every special shares, so the
		# count is not decoration -- running dry is how you lose the slot, and it is
		# the only number on this panel that only ever goes down.
		if data.has("ammo") and bool(data.get("filled", false)):
			caption.text = "%s\n%d" % [caption.text, int(data["ammo"])]
		if not bool(data.get("filled", false)):
			# DELIBERATELY EMPTY, not broken. Rope arrives in M4 and special in
			# M12; an unexplained blank box in a playtest build reads as a bug and
			# costs someone a report.
			slot.color = COLOR_SLOT_EMPTY
			caption.add_theme_color_override("font_color", COLOR_DIM)
		else:
			slot.color = COLOR_SLOT_COOLING.lerp(COLOR_SLOT_READY,
				1.0 - float(data.get("cooldown", 0.0)))
			caption.add_theme_color_override("font_color", Color.BLACK)

# --- Friends panel ------------------------------------------------------------

func _build_friends_panel() -> void:
	_friends_box = _anchored_box(Control.PRESET_TOP_RIGHT)
	_friends_panel = _friends_box.get_parent()
	_friends_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_friends_box.alignment = BoxContainer.ALIGNMENT_END

func _update_friends(friends: Array) -> void:
	var seen: Dictionary = {}
	for entry in friends:
		var peer: int = int(entry.get("peer", 0))
		seen[peer] = true
		if not _friend_rows.has(peer):
			_friend_rows[peer] = _build_friend_row()
		_update_friend_row(_friend_rows[peer], entry)

	# Drop rows for peers who left. Iterating a COPY of the keys: erasing from a
	# Dictionary while iterating it is undefined.
	for peer_key in _friend_rows.keys().duplicate():
		if seen.has(peer_key):
			continue
		var row: Node = _friend_rows[peer_key]["row"]
		_friends_box.remove_child(row)
		row.queue_free()
		_friend_rows.erase(peer_key)

func _build_friend_row() -> Dictionary:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	_friends_box.add_child(row)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(header)

	var state := _label("", 13, COLOR_ALERT)
	header.add_child(state)
	var name_label := _label("", 15, COLOR_TEXT)
	header.add_child(name_label)
	var face := _avatar()
	header.add_child(face)
	var bearing := _label("", 13, COLOR_DIM)
	header.add_child(bearing)

	var pips := HBoxContainer.new()
	pips.add_theme_constant_override("separation", 4)
	pips.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(pips)

	var bar := _bar(COLOR_ALERT)
	row.add_child(bar)

	return {"row": row, "name": name_label, "state": state, "pips": pips,
		"bar": bar, "bearing": bearing, "face": face}

func _update_friend_row(nodes: Dictionary, entry: Dictionary) -> void:
	nodes["name"].text = str(entry.get("name", ""))
	_set_avatar(nodes.get("face"), int(entry.get("steam_id", 0)))
	nodes["state"].text = str(entry.get("state_label", ""))
	nodes["state"].visible = nodes["state"].text != ""

	# Where they are, because a fixed-yaw camera and a 40 m leash (D3) mean a
	# friend is routinely off screen -- most of all when they are hanging off a
	# lip, which is the one moment the panel exists for.
	nodes["bearing"].text = "%s %dm" % [
		compass_point(float(entry.get("bearing", 0.0))),
		int(round(float(entry.get("distance", 0.0)))),
	]

	var needs_help: bool = bool(entry.get("needs_help", false))
	nodes["name"].add_theme_color_override("font_color",
		COLOR_ALERT if needs_help else COLOR_TEXT)

	_sync_pips(nodes["pips"], int(entry.get("health", 0)), int(entry.get("max_health", 0)),
		PIP_SIZE * 0.7, COLOR_HEALTH, COLOR_HEALTH_LOST)

	# A rescue in progress beats a bleed-out running down: the useful thing to
	# know is that someone is already on it.
	var rescue: float = float(entry.get("rescue", HudModel.NO_BAR))
	var bar: ColorRect = nodes["bar"]
	if rescue > 0.0:
		_bar_fill(bar).color = COLOR_HEALTH
		_set_bar(bar, rescue)
	else:
		_bar_fill(bar).color = COLOR_ALERT
		_set_bar(bar, float(entry.get("bleed_out", HudModel.NO_BAR)))

# --- Small builders -----------------------------------------------------------

func _anchored_box(preset: int) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(preset)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	return box

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label

func _bar(colour: Color) -> ColorRect:
	var back := ColorRect.new()
	back.custom_minimum_size = BAR_SIZE
	back.color = COLOR_BAR_BACK
	back.visible = false
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = colour
	fill.position = Vector2.ZERO
	fill.size = Vector2(0.0, BAR_SIZE.y)
	back.add_child(fill)
	return back

func _bar_fill(bar: ColorRect) -> ColorRect:
	return bar.get_node("Fill") as ColorRect

# NO_BAR is not zero. Zero means "this applies and is empty"; NO_BAR means the
# bar does not apply and drawing it would announce a crisis that is not
# happening.
func _set_bar(bar: ColorRect, value: float) -> void:
	if value <= HudModel.NO_BAR + 0.0001:
		bar.visible = false
		return
	bar.visible = true
	var fill := _bar_fill(bar)
	fill.size = Vector2(bar.size.x * clampf(value, 0.0, 1.0), bar.size.y)

func _sync_pips(into: HBoxContainer, health: int, max_health: int, size: Vector2,
		full: Color, lost: Color) -> void:
	while into.get_child_count() < max_health:
		into.add_child(ColorRect.new())
	# remove_child BEFORE queue_free: queue_free is deferred, so a loop that
	# waited for the child count to drop would never terminate.
	while into.get_child_count() > max_health:
		var extra: Node = into.get_child(into.get_child_count() - 1)
		into.remove_child(extra)
		extra.queue_free()
	for i in into.get_child_count():
		var pip: ColorRect = into.get_child(i)
		pip.custom_minimum_size = size
		pip.color = full if i < health else lost

# Bearing in radians clockwise from up-bridge, to one of eight compass points.
static func compass_point(bearing: float) -> String:
	return COMPASS[posmod(int(round(bearing / (TAU / 8.0))), 8)]
