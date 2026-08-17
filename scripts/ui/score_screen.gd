extends Control

# THE ROUND BOARD. M19 phase 3.
#
# Not a bigger `_board_panel`. The old board was three small centred labels
# tucked under the round headline inside the HUD; this is a different object that
# happens to appear at the same moment, and building it as a growth of the old one
# would have meant the HUD laying out a full-screen panel in among its corner
# widgets.
#
# THREE QUARTERS OF THE SCREEN, BY ANCHOR AND NOT BY ARITHMETIC. 0.125 to 0.875 on
# both axes is exactly three quarters, centred, at every resolution -- and it is
# the only way to say that which survives the headless viewport being 64x64.
# CLAUDE.md's note from the teammate marker is that any pixel figure computed
# against the screen is a statement about the harness rather than about the game.
const INSET := 0.125

const COLOR_SCRIM := Color(0.03, 0.04, 0.06, 0.86)
const COLOR_PANEL := Color(0.09, 0.10, 0.14, 0.97)
const COLOR_TEXT := Color(0.92, 0.94, 0.98)
const COLOR_DIM := Color(0.58, 0.62, 0.70)
const COLOR_LEAD := Color(1.0, 0.84, 0.35)
const COLOR_BADGE := Color(0.55, 0.85, 1.0)

const StatRegistry = preload("res://scripts/sim/stat_registry.gd")

# FONT SIZES ARE FOR A 1080-TALL SCREEN and are scaled from there -- see
# `scaled_font`. The board is defined as a FRACTION of the viewport, so its text
# has to be too, or it is sized for exactly one monitor.
#
# THEY ARE ALSO MUCH BIGGER THAN A HUD'S, which is the point. These were first
# written at HUD sizes -- 34 down to 16 -- and reported from play as "the text is
# tiny compared to the space". A HUD label is read out of the corner of your eye
# while you play; this is a board four people look AT, from across a room,
# occupying three quarters of the screen with nothing else on it.
const FONT_TITLE := 64
const FONT_RANK := 48
const FONT_NAME := 34
const FONT_STAT := 30
const FONT_VALUE := 32
const FONT_BADGE := 24
const REFERENCE_HEIGHT := 1080.0
const AVATAR_BASE := 96.0

var _panel: PanelContainer = null
var _grid: GridContainer = null
var _title: Label = null
# WHAT IS CURRENTLY DRAWN, so the grid is rebuilt when the round changes and not
# sixty times a second. A scoreboard is static for its whole life; rebuilding it
# per frame would also destroy and recreate every avatar texture.
var _signature: String = ""

func _ready() -> void:
	name = "ScoreScreen"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	# SIZED FROM THE VIEWPORT, NOT BY ANCHORS. A Control whose parent is a
	# CanvasLayer is not laid out by anything: there is no parent Control to take a
	# rect from, so PRESET_FULL_RECT sets four correct numbers against a parent
	# area of zero and the node stays 0x0 at the origin. Everything anchored INSIDE
	# it then collapses too, and a PanelContainer with nothing to fill falls back
	# to its content's minimum size in the top-left corner -- which is exactly what
	# this looked like.
	#
	# Reported from play as "the score screen is top left", and the reason it got
	# there is worth keeping: the test asserted the ANCHORS, which were right the
	# whole time. Asserting the input to a layout is not asserting the layout.
	get_viewport().size_changed.connect(_fit)
	_fit()

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = COLOR_SCRIM
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	_panel = PanelContainer.new()
	_panel.anchor_left = INSET
	_panel.anchor_right = 1.0 - INSET
	_panel.anchor_top = INSET
	_panel.anchor_bottom = 1.0 - INSET
	_panel.offset_left = 0.0
	_panel.offset_right = 0.0
	_panel.offset_top = 0.0
	_panel.offset_bottom = 0.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	# FILL THE PANEL. Without this the whole board sits at its own minimum size in
	# the middle of a panel three quarters of the screen wide, which is the other
	# half of "the text is tiny compared to the space" -- the type was small AND
	# the block it was in refused to grow.
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(column)

	_title = _label("", FONT_TITLE, COLOR_TEXT)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 26)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_grid)

# Full screen, and kept there through a resize -- this is a floating layer over a
# game that changes resolution. The panel inside it is anchored, so three quarters
# stays three quarters once this rect is right.
func _fit() -> void:
	var view: Vector2 = get_viewport_rect().size
	position = Vector2.ZERO
	size = view
	# EVERY SIZE IN HERE IS DERIVED FROM THAT HEIGHT, so a resize has to rebuild
	# rather than just re-lay-out. Clearing the signature is what makes the next
	# refresh do it; the board is static for its whole life, so this costs nothing.
	_signature = ""

# TEXT AS A FRACTION OF THE SCREEN, and a PURE FUNCTION of it so the arithmetic
# can be asserted. CLAUDE.md's note from the teammate marker: the headless
# viewport is 64x64, so anything that reads the real screen inside a test is
# measuring the harness -- split the maths out and hand it an explicit size.
#
# CLAMPED AT BOTH ENDS. Below about half, a board somebody is meant to read from
# across a room becomes a HUD again; above double, four columns of it stop fitting
# side by side on the ultrawide it was scaled up for.
static func scaled_font(base: int, screen_height: float) -> int:
	var scale: float = clampf(screen_height / REFERENCE_HEIGHT, 0.5, 2.0)
	return maxi(8, int(round(float(base) * scale)))

func _scale() -> float:
	return clampf(get_viewport_rect().size.y / REFERENCE_HEIGHT, 0.5, 2.0)

# `board` is the array RoundMachine.rank builds: already ordered, each entry
# carrying its display rank, its stats and its badges. Nothing is computed here --
# a client that worked out its own ranks or badges would be deriving them from
# numbers it was handed anyway, and any disagreement would show as two players
# looking at different awards.
func refresh(board: Array, round_index: int) -> void:
	var signature: String = "%d|%s" % [round_index, str(board)]
	if signature == _signature:
		return
	_signature = signature
	_rebuild(board, round_index)

func _rebuild(board: Array, round_index: int) -> void:
	for child in _grid.get_children():
		child.queue_free()
	_title.text = "ROUND %d" % round_index
	if board.is_empty():
		return

	_grid.columns = board.size() + 1

	# --- Row one: who. Avatar, name, rank. --------------------------------------
	_grid.add_child(_label("", FONT_STAT, COLOR_DIM))
	for entry in board:
		_grid.add_child(_player_header(entry))

	# --- The common block -------------------------------------------------------
	#
	# ROWS ARE STATS AND COLUMNS ARE PLAYERS, which is the orientation that lets
	# you answer "who shot most" by reading across one line. The other way round
	# makes every comparison a scan down four separate columns.
	for key in StatRegistry.common_keys():
		_grid.add_child(_label(StatRegistry.label_of(key), FONT_STAT, COLOR_DIM))
		var best: int = _best_value(board, key)
		for entry in board:
			var stats: Dictionary = entry.get("stats", {})
			var value: int = int(stats.get(key, 0))
			var text: String = StatRegistry.format_value(key, value)
			# THE HIT COUNT CARRIES ITS RATE. Two numbers that only mean anything
			# together, so they are one cell rather than two rows apart.
			var over: String = StatRegistry.percent_of(key)
			if over != "":
				text = "%d  (%s)" % [value,
					StatRegistry.percent_text(value, int(stats.get(over, 0)))]
			# LEADER MARKED ONLY WHEN THERE IS SOMETHING TO LEAD. If the whole
			# party is level, colouring all four gold says nothing -- the same
			# argument the badge rules make one level up.
			var leads: bool = value == best and not _everyone_level(board, key)
			var cell := _label(text, FONT_VALUE, COLOR_LEAD if leads else COLOR_TEXT)
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			# EVERY PLAYER COLUMN THE SAME WIDTH, and together they take the panel.
			# A GridContainer gives its spare width to the cells that ask for it,
			# so asking in every player cell is what spreads them evenly.
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_grid.add_child(cell)

	# --- The badges -------------------------------------------------------------
	_grid.add_child(_label("", FONT_STAT, COLOR_DIM))
	for entry in board:
		_grid.add_child(_badge_column(entry.get("badges", [])))

func _player_header(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var face := TextureRect.new()
	face.custom_minimum_size = Vector2.ONE * (AVATAR_BASE * _scale())
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# NULL BESIDE A MACHINE WITH NO STEAM, AND THAT IS NOT AN ERROR. The gate has
	# no Steam client and a dev box does, so the only honest statement about this
	# is the RELATIONSHIP -- shown exactly when there is something to show.
	# CLAUDE.md has this one costing a day in both directions already.
	var texture: Texture2D = NetworkManager.steam_avatar(int(entry.get("steam_id", 0)))
	face.texture = texture
	face.visible = texture != null
	box.add_child(face)

	var rank: int = int(entry.get("rank", 0))
	var rank_label := _label(_ordinal(rank), FONT_RANK, COLOR_LEAD if rank == 1 else COLOR_TEXT)
	rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(rank_label)

	var name_label := _label(str(entry.get("name", "")), FONT_NAME, COLOR_TEXT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(name_label)

	# WHAT THE RANK WAS FOR, kept from the old board. A number nobody can explain
	# is a number nobody trusts.
	var why: String = "%d hats" % int(entry.get("hats", 0))
	if not bool(entry.get("made_it", false)):
		why += " - left behind"
	var why_label := _label(why, FONT_BADGE, COLOR_DIM)
	why_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(why_label)
	return box

func _badge_column(badges: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for badge in badges:
		var key: String = str(badge.get("key", ""))
		# THE NUMBER WITH THE LABEL. "Furthest travelled" is a claim; "furthest
		# travelled, 340 m" is a claim somebody can argue with, which is the point
		# of putting it on a screen four people are looking at.
		var text: String = "%s  %s" % [StatRegistry.label_of(key),
			StatRegistry.format_value(key, int(badge.get("value", 0)))]
		# SAY IT WAS SHARED. "Most kills" and "most kills, tied" are different
		# claims, and the badge already carries which one it is.
		if int(badge.get("tie", 1)) > 1:
			text += " (tied)"
		var line := _label(text, FONT_BADGE, COLOR_BADGE)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(line)
	return box

# --- Helpers ------------------------------------------------------------------

func _best_value(board: Array, key: String) -> int:
	var best: int = 0
	var first := true
	for entry in board:
		var value: int = int((entry.get("stats", {}) as Dictionary).get(key, 0))
		if first:
			best = value
			first = false
		elif StatRegistry.best_of(key) == StatRegistry.LEAST:
			best = mini(best, value)
		else:
			best = maxi(best, value)
	return best

func _everyone_level(board: Array, key: String) -> bool:
	if board.size() < 2:
		return true
	var first: int = int((board[0].get("stats", {}) as Dictionary).get(key, 0))
	for entry in board:
		if int((entry.get("stats", {}) as Dictionary).get(key, 0)) != first:
			return false
	return true

# 1st, 2nd, 3rd, 4th. Small enough a party that the general English rule is not
# needed, and a table is easier to be sure of than modulo arithmetic.
func _ordinal(rank: int) -> String:
	match rank:
		1: return "1st"
		2: return "2nd"
		3: return "3rd"
		4: return "4th"
	return "%dth" % rank

# The HUD's outline treatment, for the same reason: this panel is drawn over the
# world and a hard edge is what keeps text legible on whatever is behind it.
func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	var points: int = scaled_font(size, get_viewport_rect().size.y)
	label.add_theme_font_size_override("font_size", points)
	label.add_theme_color_override("font_color", colour)
	label.add_theme_constant_override("outline_size", maxi(3, int(0.12 * float(points))))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
