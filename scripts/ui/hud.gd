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
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")

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
# character card. At 26 px it reads as "who" without competing with the status
# bar, which is the thing you actually act on.
const AVATAR_SIZE := Vector2(26.0, 26.0)

const SLOT_SIZE := Vector2(58.0, 40.0)

# ONE BAR PER PLAYER, and it is now the ONLY reading of their condition on this
# panel -- health, the bleed-out countdown and a rescue in progress are all the
# same strip of colour. Health used to be a row of PIPS with the crisis bar
# somewhere below it, so a player in trouble was described in two places, in two
# shapes, and neither of them matched the bar over their own head in the world.
#
# Bigger than the old crisis bar because it inherited the pips' job: this is the
# number you act on.
const BAR_SIZE := Vector2(160.0, 13.0)
const FRIEND_BAR_SIZE := Vector2(120.0, 9.0)

# Eight-point compass, because the game already is one: the dash locks to four
# world axes and the camera is fixed-yaw, so "NE" means the same thing on every
# screen. Letters rather than arrow glyphs -- the default theme font is not
# guaranteed to carry the diagonal arrows, and a missing glyph is a blank box.
const COMPASS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var world: Node = null

var _own_panel: Control = null
var _own_name: Label = null
var _own_face: TextureRect = null
var _own_slots: HBoxContainer = null
var _own_state: Label = null
# ONE BAR. Not one crisis bar -- ONE BAR, full stop, and it took three passes to
# get here:
#
#   there were a bleed-out bar and a rescue bar stacked together, and the second
#   was pure black whenever nobody was helping (which is most of the time you
#   spend waiting), so it was reported as a bar that had failed to draw;
#   then there was one crisis bar, but health was still a row of PIPS above it
#   and the state word had the bar under it, so a hanging player was described
#   three times in three shapes;
#   now everything this player's condition amounts to -- health, the countdown,
#   a rescue in progress -- is this one strip, driven by the same
#   PlayerBody.status_bar() that draws the bar over their own head in the world.
#
# So a player learns ONE thing to read: green draining is health, red draining is
# a clock, blue filling is help arriving. In the panel, over their head, and over
# a teammate's head, it is the same bar saying the same thing.
var _own_status: ColorRect = null

var _markers: Control = null

# THE ROUND BANNER AND THE BOARD, both centred and both transient. Centre-top is
# the most expensive real estate on the screen and it is deliberately empty
# except when the round state is doing something a player has to act on: get to
# the strip, or read the result.
var _round_panel: VBoxContainer = null
var _round_label: Label = null
var _round_clock: Label = null
var _board_panel: VBoxContainer = null

var _friends_panel: Control = null
var _friends_box: VBoxContainer = null
var _friend_rows: Dictionary = {}      # peer -> {row, name, state, bar, bearing, face}

func _ready() -> void:
	layer = 0        # under the menu's CanvasLayer, which is where the menu belongs
	_build_own_panel()
	_build_friends_panel()
	_build_markers()
	_build_round_panel()

func _process(_delta: float) -> void:
	var model: Dictionary = HudModel.build(world)
	var active: bool = bool(model.get("active", false))
	_own_panel.visible = active
	_friends_panel.visible = active
	if not active:
		return
	_update_own(model["own"])
	_update_friends(model["friends"])
	_update_markers(model["friends"])
	_update_round(model.get("round", {}))

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

func _update_markers(friends: Array) -> void:
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
	_markers.refresh(list, cam)

# --- The round ----------------------------------------------------------------

func _build_round_panel() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_CENTER_TOP)
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 14)
	add_child(margin)

	_round_panel = VBoxContainer.new()
	_round_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(_round_panel)

	_round_label = _label("", 22, COLOR_TEXT)
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_round_label)

	_round_clock = _label("", 30, COLOR_ALERT)
	_round_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_round_clock)

	_board_panel = VBoxContainer.new()
	_board_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_board_panel.add_theme_constant_override("separation", 3)
	_round_panel.add_child(_board_panel)

func _update_round(entry: Dictionary) -> void:
	if _round_panel == null:
		return
	if entry.is_empty():
		_round_panel.visible = false
		return
	_round_panel.visible = true

	var state: int = int(entry.get("state", 0))
	var label: String = str(entry.get("label", ""))
	if bool(entry.get("waiting", false)):
		# THE INSTRUCTION, not the state name. "LOBBY" tells a player where they
		# are, which they can see; what they need is what to do about it, and this
		# is the only screen in the game that says it.
		label = "LOBBY -- everyone onto the checker to begin"
	_round_label.text = label

	# The countdown while the round closes; the elapsed clock while it runs; a
	# blank in the lobby, because a timer that is always there is not read.
	var countdown: float = float(entry.get("countdown", -1.0))
	if countdown >= 0.0:
		_round_clock.text = "%0.0f" % ceilf(countdown)
		_round_clock.add_theme_color_override("font_color",
			CrisisFlash.alternate(COLOR_ALERT, CrisisFlash.now()))
		_round_clock.visible = true
	elif state == RoundMachine.State.RUNNING:
		_round_clock.text = _mmss(float(entry.get("elapsed", 0.0)))
		_round_clock.add_theme_color_override("font_color", COLOR_DIM)
		_round_clock.visible = true
	else:
		_round_clock.visible = false

	_sync_board(entry.get("board", []))

func _sync_board(board: Array) -> void:
	while _board_panel.get_child_count() < board.size():
		var row := _label("", 18, COLOR_TEXT)
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_board_panel.add_child(row)
	for i in _board_panel.get_child_count():
		var row: Label = _board_panel.get_child(i)
		row.visible = i < board.size()
		if not row.visible:
			continue
		var entry: Dictionary = board[i]
		var hats: int = int(entry.get("hats", 0))
		# WHAT THE RANK WAS FOR, spelled out. A number nobody can explain is a
		# number nobody trusts, and this is the first scoring criterion the game
		# has ever shown.
		var why: String = "%d hats" % hats
		if hats == 1:
			why = "1 hat"
		elif hats == 0:
			why = "made it" if bool(entry.get("made_it", false)) else "did not make it"
		row.text = "%d.  %s  --  %s" % [i + 1, str(entry.get("name", "")), why]
		row.add_theme_color_override("font_color",
			COLOR_TEXT if bool(entry.get("made_it", false)) else COLOR_DIM)

static func _mmss(seconds: float) -> String:
	var whole: int = int(maxf(0.0, seconds))
	return "%d:%02d" % [whole / 60, whole % 60]

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

	_own_status = _bar(BAR_SIZE)
	box.add_child(_own_status)

	_own_slots = HBoxContainer.new()
	_own_slots.add_theme_constant_override("separation", 8)
	box.add_child(_own_slots)

	# THE WORD, WITH NO BAR UNDER IT. "HANGING" says which trouble you are in; the
	# bar above already says how much of it is left, and it said so first.
	_own_state = _label("", 20, COLOR_ALERT)
	box.add_child(_own_state)

func _update_own(own: Dictionary) -> void:
	_own_name.text = str(own.get("name", ""))
	_set_avatar(_own_face, int(own.get("steam_id", 0)))

	_sync_slots(own.get("slots", []))

	_own_state.text = str(own.get("state_label", ""))
	_own_state.visible = _own_state.text != ""

	# THE GRACE WINDOW RIDES ON THE ONE BAR NOW. It is 0.75 s of invulnerability
	# after a hit (B7) and entirely unknowable otherwise -- it is why one tumble
	# through a pillar field does not empty your health. The pips used to carry it;
	# washing the bar toward the same warm yellow keeps "that hit did not count"
	# legible now that there is nothing else on screen to carry it.
	_set_status_bar(_own_status, own.get("status", {}),
		float(own.get("grace", 0.0)))

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
			# DELIBERATELY EMPTY, not broken -- an unexplained blank box in a
			# playtest build reads as a bug and costs somebody a report.
			#
			# The only slot that is ever empty now is the SPECIAL one, and it is
			# empty because your hands are. The permanently-blank ROPE box that
			# used to sit beside it was removed on 2026-08-15: this treatment is
			# for a slot that fills, and a box that never has is furniture.
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

	# THE SAME ONE BAR, smaller. A friend's row carried pips AND a crisis bar, so a
	# downed teammate was three separate pieces of furniture saying one thing. It
	# is one now, and it is the one they are already wearing on their head.
	var bar := _bar(FRIEND_BAR_SIZE)
	row.add_child(bar)

	return {"row": row, "name": name_label, "state": state,
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

	# NO GRACE TINT FOR A FRIEND: the model does not publish theirs, and it should
	# not. A 0.75 s window on somebody else's body is not something you can act on,
	# and it exists to explain YOUR hits.
	_set_status_bar(nodes["bar"], entry.get("status", {}))

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

func _bar(size: Vector2) -> ColorRect:
	var back := ColorRect.new()
	back.custom_minimum_size = size
	back.color = COLOR_BAR_BACK
	back.visible = false
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = COLOR_ALERT
	fill.position = Vector2.ZERO
	fill.size = Vector2(0.0, size.y)
	back.add_child(fill)
	return back

func _bar_fill(bar: ColorRect) -> ColorRect:
	return bar.get_node("Fill") as ColorRect

# ONE BAR, EVERY KIND, ALWAYS DRAWN. This used to hide itself for anything that
# was not a crisis, because health lived in pips beside it -- so the panel gave
# your condition in two different shapes and neither matched the bar over your
# own head out in the world. status_bar() now answers every case including the
# healthy one, and this draws whatever it says.
#
# THE HUD DRAWS THE HEALTHY CASE AND THE BODY DOES NOT, which is not a
# disagreement: a panel is somewhere you look on purpose, and a floating bar is
# something that appears in front of you. Silence is right in the world and
# useless in the corner of a screen.
#
# `grace` washes the bar toward the warm yellow for the invulnerable window after
# a hit. Zero for anybody but yourself.
func _set_status_bar(bar: ColorRect, status: Dictionary, grace: float = 0.0) -> void:
	if bar == null:
		return
	if status.is_empty():
		bar.visible = false
		return
	bar.color = Color(status.get("back", COLOR_BAR_BACK)).lerp(COLOR_GRACE, grace)
	# THE SAME FLASH AS THE BAR OVER THEIR HEAD AND THE TRIANGLE POINTING AT THEM,
	# because it is the same clock -- crisis_flash reads wall time rather than
	# taking a delta, so three separate widgets blink together with nothing passed
	# between them. Whether it flashes at all is the BODY's call (status["flash"]);
	# this only draws it.
	_bar_fill(bar).color = CrisisFlash.fill_for(status, CrisisFlash.now()).lerp(
		COLOR_GRACE, grace)
	_set_bar(bar, float(status.get("fraction", HudModel.NO_BAR)))

func _set_bar(bar: ColorRect, value: float) -> void:
	if value <= HudModel.NO_BAR + 0.0001:
		bar.visible = false
		return
	bar.visible = true
	var fill := _bar_fill(bar)
	fill.size = Vector2(bar.size.x * clampf(value, 0.0, 1.0), bar.size.y)

# Bearing in radians clockwise from up-bridge, to one of eight compass points.
static func compass_point(bearing: float) -> String:
	return COMPASS[posmod(int(round(bearing / (TAU / 8.0))), 8)]
