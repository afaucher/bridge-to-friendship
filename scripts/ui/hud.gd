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
const ScoreScreen = preload("res://scripts/ui/score_screen.gd")

const COLOR_GRACE := Color(1.00, 0.93, 0.55)
const COLOR_SLOT_READY := Color(0.88, 0.90, 0.96)
const COLOR_SLOT_COOLING := Color(0.42, 0.44, 0.52)
const COLOR_SLOT_EMPTY := Color(0.26, 0.27, 0.32)
const COLOR_TEXT := Color(0.92, 0.93, 0.96)
const COLOR_DIM := Color(0.62, 0.64, 0.70)
const COLOR_ALERT := Color(1.00, 0.45, 0.22)
# The lap clock. Start-line white rather than the alert orange: a lap time is
# something you did well, and every other coloured thing on this HUD is a
# warning.
const COLOR_LAP := Color(0.85, 0.86, 0.92)

# Where the lap clock sits across the top: a third of the way over, which is
# between the top-left own panel and the centred round column at any width.
const LAP_ANCHOR_X := 0.3

# And the mode summary, mirrored across the round column: between it and the
# friends panel top-right, at the distance from centre the lap clock sits on the
# other side. A pair reads as a pair because of where they are, not because they
# are the same size.
const MODE_ANCHOR_X := 0.7
# The lap being driven right now, brighter than the best beside it: it is the
# number changing, and the one a driver is actually watching.
const COLOR_LAP_LIVE := Color(1.00, 0.97, 0.80)
# The mode name in the lobby. Warm and bright: it is an announcement of what
# everybody is about to do, not a warning about anything.
const COLOR_MODE := Color(0.98, 0.90, 0.62)
const COLOR_BAR_BACK := Color(0.11, 0.11, 0.14)

# --- Identity outlines --------------------------------------------------------
#
# A player's chosen colour, drawn as a BORDER around their widget -- their own
# panel, and one per friend row.
#
# AN OUTLINE RATHER THAN A FILL, and that is the rule this feature runs on
# instead of taste. Every other colour in this file means something: alert
# orange, grace yellow, the four states of a status bar. Identity colour is the
# newcomer, and a newcomer does not get to overwrite a channel that already
# carries a rule. A border is a zone nothing else was using -- the same answer
# art_direction.md reaches for when it gives a style a jersey rather than tinting
# the whole avatar.
#
# It is worth having because the HUD's whole job is to be read at a glance while
# something is trying to kill you, and matching a row to a body currently means
# READING A NAME. A colour is matched without reading.
const OUTLINE_WIDTH := 3
const OUTLINE_BG := Color(0.05, 0.05, 0.07, 0.72)
const OUTLINE_RADIUS := 6
const OUTLINE_PAD := 8

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

# THE SELF-REVIVE LINE, drawn INSIDE the status bar rather than as a strip of its
# own -- because THE STATUS BAR IS THE MOVING PART. Its countdown fill already
# sweeps across this rect once per crisis, and all this adds is the thing that
# fill has to cross. A second sweeping marker beside it would be two moving parts
# telling one story, and the panel is allowed exactly one bar anyway: a rule paid
# for twice (pips beside a crisis bar; two crisis bars, one of them black). A line
# is not a second reading of your condition, it is a target.
#
# The thinnest it may be drawn. The window is a DURATION (0.25 s), so on the
# slower of the two countdowns it works out at 2.7 px -- and a line thinner than
# it is aimable would make the timing harder than the number says.
const REVIVE_LINE_MIN_WIDTH := 3.0
const COLOR_REVIVE_WINDOW := Color(0.35, 0.85, 0.45, 0.85)
const FRIEND_BAR_SIZE := Vector2(120.0, 9.0)

# Eight-point compass, because the game already is one: the dash locks to four
# world axes and the camera is fixed-yaw, so "NE" means the same thing on every
# screen. Letters rather than arrow glyphs -- the default theme font is not
# guaranteed to carry the diagonal arrows, and a missing glyph is a blank box.
const COMPASS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var world: Node = null

var _own_panel: Control = null
var _own_outline: PanelContainer = null
var _own_name: Label = null
var _own_lap: Label = null
var _own_lap_live: Label = null
var _mode_name: Label = null
var _mode_blurb: Label = null
# The same pair again, in the top strip, for while a round is running. See
# _build_playing_panel.
var _playing_name: Label = null
var _playing_blurb: Label = null
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
# THE ROUND BOARD, which is its own object rather than a bigger _board_panel --
# see score_screen.gd. _board_panel stays for now and is simply not shown while
# the screen is up; deleting it is a separate change from adding this.
var _score_screen: Control = null

var _friends_panel: Control = null
var _friends_box: VBoxContainer = null
var _friend_rows: Dictionary = {}      # peer -> {row, name, state, bar, bearing, face}

func _ready() -> void:
	layer = 0        # under the menu's CanvasLayer, which is where the menu belongs
	_build_own_panel()
	_build_friends_panel()
	_build_markers()
	_build_lap_panel()
	_build_playing_panel()
	_build_round_panel()
	_build_score_screen()

func _process(_delta: float) -> void:
	var model: Dictionary = HudModel.build(world)
	var active: bool = bool(model.get("active", false))
	if not active:
		_own_panel.visible = false
		_friends_panel.visible = false
		_score_screen.visible = false
		return
	_update_own(model["own"])
	_update_friends(model["friends"])
	_update_markers(model["friends"])
	_update_round(model.get("round", {}))

	# THE BOARD HIDES THE HUD, and hides it rather than dimming it. A panel that
	# covers the numbers you are reading is worse than no panel -- the same
	# instinct that moved the debug console out of the top corner -- and the
	# scoreboard occupies the middle three quarters of the screen, which is where
	# the round headline, the clock and the teammate markers all live.
	#
	# NOTHING IS DESTROYED, only made invisible: the round is ten seconds long and
	# the HUD comes straight back.
	var round_entry: Dictionary = model.get("round", {})
	var board: Array = round_entry.get("board", [])
	var showing: bool = not board.is_empty()
	if showing:
		_score_screen.refresh(board, int(round_entry.get("index", 0)))
	_score_screen.visible = showing
	_own_panel.visible = not showing
	_friends_panel.visible = not showing
	_round_panel.visible = not showing
	if _markers != null:
		_markers.visible = _markers.visible and not showing

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

func _build_score_screen() -> void:
	_score_screen = Control.new()
	_score_screen.set_script(ScoreScreen)
	add_child(_score_screen)

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

# THE LAP CLOCK, ON ITS OWN, IN THE TOP STRIP BETWEEN THE HUD AND THE ROUND LINE.
#
# It used to sit beside your name inside the own panel at 16 px, which is the
# size of a status caption. Reported as "that counter is WAY too small" -- and it
# was the wrong KIND of thing to be in that panel as well as the wrong size. The
# own panel is a list you look AT between moments; a lap clock while you are
# driving is a number you catch out of the corner of your eye, which is exactly
# what the note on _round_label says the centre strip is for. So it moves up
# there and takes ROUND's size with it.
#
# ANCHORED AT A FRACTION rather than offset from the panel beside it. The own
# panel's width depends on the player's name, their hats and their held weapon,
# so pinning to its edge would make the clock move whenever any of those changed.
# A third of the way across is between the two at every resolution and stays put.
#
# THE RUNNING CLOCK AND THE BEST, STILL TWO LABELS AND NOT ONE DOING BOTH. A
# single label showing the live lap while driving and the best otherwise hides
# your target at the only moment you are chasing it -- you cross the line and the
# next lap starts on the same tick, so the best would flash past in a frame. The
# best stays small underneath: it is the thing you check, not the thing you watch.
func _build_lap_panel() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	margin.anchor_left = LAP_ANCHOR_X
	margin.anchor_right = LAP_ANCHOR_X
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 14)
	add_child(margin)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(column)

	_own_lap_live = _label("", 44, COLOR_LAP_LIVE)
	_own_lap_live.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_own_lap_live)
	_own_lap = _label("", 18, COLOR_LAP)
	_own_lap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_own_lap)

# WHAT YOU ARE PLAYING, opposite the lap clock.
#
# THE LOBBY BANNER IS DELIBERATELY LOBBY-ONLY and says so where it is built:
# "mid-round it would be a permanent caption naming the thing you are already
# doing, which is furniture -- and furniture does not get read." That reasoning is
# overruled here, by the person who has played it: a run now switches between four
# modes with different rules and different scoring, and "which one am I in" stops
# being obvious the moment it can change.
#
# ONE ON SCREEN AT A TIME. This one shows exactly when the centred one does not,
# so a lobby keeps its big centred moment and a round gets the same sentence off
# to the side. Two copies of one line is worse than either place.
#
# THE LOBBY'S OWN SIZE, NOT THE CLOCK'S. The clock beside it took ROUND's 44
# because it is a number you WATCH -- caught out of the corner of the eye,
# changing ten times a second. This is a reference: read once, then ignored.
# Matching its weight to the clock would make it compete with the one thing on
# screen that has to be glanced at while driving.
func _build_playing_panel() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	margin.anchor_left = MODE_ANCHOR_X
	margin.anchor_right = MODE_ANCHOR_X
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 14)
	add_child(margin)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(column)

	_playing_name = _label("", 30, COLOR_MODE)
	_playing_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_playing_name)
	_playing_blurb = _label("", 16, COLOR_DIM)
	_playing_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_playing_blurb)

func _build_round_panel() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_CENTER_TOP)
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 14)
	add_child(margin)

	_round_panel = VBoxContainer.new()
	_round_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(_round_panel)

	# DOUBLED FROM 22 (2026-08-16). This line is the only thing on screen that
	# says what the round is DOING -- "everyone onto the checker to begin", the
	# closing countdown, who won -- and it was set at the size of a status caption
	# rather than of an announcement. It is read from across the room, once, while
	# somebody is also trying to play.
	#
	# The scoreboard rows and the peer panel are deliberately NOT scaled with it:
	# those are lists you look AT, and this is a line you catch out of the corner
	# of your eye.
	_round_label = _label("", 44, COLOR_TEXT)
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_round_label)

	# The clock goes with it, or the countdown becomes the small print under the
	# headline it is the whole point of.
	_round_clock = _label("", 60, COLOR_ALERT)
	_round_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_round_clock)

	# THE MODE NAME, UNDER THE ROUND LINE AND ABOVE THE BOARD. It belongs in this
	# column because it is the same kind of thing: a line you catch rather than a
	# list you study, and in a lobby it is the most important sentence on screen.
	_mode_name = _label("", 30, COLOR_MODE)
	_mode_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_mode_name)
	_mode_blurb = _label("", 16, COLOR_DIM)
	_mode_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_panel.add_child(_mode_blurb)

	_board_panel = VBoxContainer.new()
	_board_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	_board_panel.add_theme_constant_override("separation", 3)
	_round_panel.add_child(_board_panel)

# THE MODE THE PARTY IS ABOUT TO PLAY, named, while they are standing in a lobby
# deciding.
#
# THERE WAS NO INDICATOR AT ALL. The selector post cycles a colour on a banner
# and nothing anywhere said what the colour meant, so the choice was made from
# memory or not made. A control whose effect is unreadable is a control nobody
# uses on purpose.
#
# LOBBY ONLY. Mid-round it would be a permanent caption naming the thing you are
# already doing, which is furniture -- and furniture does not get read, which is
# the note the round timer next door already carries.
func _update_mode_banner(entry: Dictionary) -> void:
	var showing: bool = bool(entry.get("waiting", false))
	_mode_name.visible = showing
	_mode_blurb.visible = showing
	if not showing:
		return
	_mode_name.text = str(entry.get("mode_name", ""))
	var blurb: String = str(entry.get("mode_blurb", ""))
	_mode_blurb.text = blurb
	_mode_blurb.visible = blurb != ""

# THE SAME SENTENCE, WHILE THE ROUND IS RUNNING. Fed from `playing_*` rather than
# from `mode_*`: those name what the SELECTOR is set to, which is what a lobby is
# deciding and is not what anybody is currently playing. The selector stays
# dashable mid-round -- the choice is remembered for the next lobby -- so reusing
# the lobby fields here would name the mode you had just picked for AFTERWARDS.
func _update_playing_banner(entry: Dictionary) -> void:
	var in_round: bool = not bool(entry.get("waiting", false))
	_playing_name.visible = in_round
	_playing_blurb.visible = in_round
	if not in_round:
		return
	_playing_name.text = str(entry.get("playing_name", ""))
	var line: String = str(entry.get("playing_blurb", ""))
	_playing_blurb.text = line
	_playing_blurb.visible = line != ""

func _update_round(entry: Dictionary) -> void:
	_update_mode_banner(entry)
	_update_playing_banner(entry)
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
		# WHAT THE RANK WAS FOR, spelled out. A number nobody can explain is a
		# number nobody trusts -- and it used to say HATS whichever mode had just
		# been played, so a race was scored on lap times and explained by hats.
		# `HudModel.rank_reason` reads the same precedence the comparator sorted
		# by, and the score screen asks it too rather than keeping a second copy.
		var why: String = HudModel.rank_reason(entry)
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

	# Re-parent the column inside an outline panel. Built here rather than in
	# _anchored_box because the round and board panels use that too and are not
	# anybody's: an outline on them would be a colour that means nothing.
	var margin: Node = box.get_parent()
	margin.remove_child(box)
	_own_outline = _outline_panel()
	margin.add_child(_own_outline)
	_own_outline.add_child(box)

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

	# ON THE COUNTDOWN BAR ITSELF, not under it. The panel is allowed exactly one
	# bar (see the note on _own_status) and this does not spend that budget: the
	# window and the marker are drawn INSIDE the status bar, over the very clock
	# they are a gamble against.
	_build_revive_overlay(_own_status)

	_own_slots = HBoxContainer.new()
	_own_slots.add_theme_constant_override("separation", 8)
	box.add_child(_own_slots)

	# THE WORD, WITH NO BAR UNDER IT. "HANGING" says which trouble you are in; the
	# bar above already says how much of it is left, and it said so first.
	_own_state = _label("", 20, COLOR_ALERT)
	box.add_child(_own_state)

func _update_own(own: Dictionary) -> void:
	_own_name.text = str(own.get("name", ""))
	var best: String = HudModel.lap_label(int(own.get("best_lap", 0)))
	_own_lap.text = ("best " + best) if best != "" else ""
	_own_lap.visible = best != ""
	_own_lap_live.text = HudModel.lap_label(int(own.get("lap_running", 0)))
	_own_lap_live.visible = _own_lap_live.text != ""
	_set_outline(_own_outline, own.get("colour", Color.TRANSPARENT))
	_set_avatar(_own_face, int(own.get("steam_id", 0)))

	_sync_slots(own.get("slots", []))

	_own_state.text = str(own.get("state_label", ""))
	_own_state.visible = _own_state.text != ""

	# THE GRACE WINDOW RIDES ON THE ONE BAR NOW. It is 0.75 s of invulnerability
	# after a hit (B7) and entirely unknowable otherwise -- it is why one tumble
	# through a pillar field does not empty your health. The pips used to carry it;
	# washing the bar toward the same warm yellow keeps "that hit did not count"
	# legible now that there is nothing else on screen to carry it.
	_set_call_flash(_own_status, bool(own.get("calling", false)), BAR_SIZE)
	_set_status_bar(_own_status, own.get("status", {}),
		float(own.get("grace", 0.0)))
	_set_revive_bar(_own_status, own.get("self_revive", {}))

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
			# A NEGATIVE COUNT MEANS UNLIMITED (M24, the sidearm). Every other
			# special counts down to zero, so printing a literal number for a
			# gun that never runs out would read as an empty one.
			var rounds: int = int(data["ammo"])
			caption.text = "%s\n%s" % [caption.text,
				"∞" if rounds < 0 else str(rounds)]
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
	var outline := _outline_panel()
	_friends_box.add_child(outline)

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	outline.add_child(row)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(header)

	var state := _label("", 13, COLOR_ALERT)
	header.add_child(state)
	var name_label := _label("", 15, COLOR_TEXT)
	header.add_child(name_label)
	var lap := _label("", 13, COLOR_LAP)
	header.add_child(lap)
	var face := _avatar()
	header.add_child(face)
	var bearing := _label("", 13, COLOR_DIM)
	header.add_child(bearing)

	# THE SAME ONE BAR, smaller. A friend's row carried pips AND a crisis bar, so a
	# downed teammate was three separate pieces of furniture saying one thing. It
	# is one now, and it is the one they are already wearing on their head.
	var bar := _bar(FRIEND_BAR_SIZE)
	row.add_child(bar)

	# THE ROW HANDLE IS THE OUTLINE, not the VBox inside it. _update_friends
	# removes `row` from _friends_box when a peer leaves, and the child of that
	# box is now the panel -- handing back the inner column would leave an empty
	# bordered frame on screen for every player who ever disconnected.
	return {"row": outline, "outline": outline, "name": name_label, "state": state,
		"bar": bar, "bearing": bearing, "face": face, "lap": lap}

func _update_friend_row(nodes: Dictionary, entry: Dictionary) -> void:
	nodes["name"].text = str(entry.get("name", ""))
	_set_outline(nodes.get("outline"), entry.get("colour", Color.TRANSPARENT))
	_set_avatar(nodes.get("face"), int(entry.get("steam_id", 0)))
	nodes["state"].text = str(entry.get("state_label", ""))
	nodes["state"].visible = nodes["state"].text != ""
	nodes["lap"].text = HudModel.lap_label(int(entry.get("best_lap", 0)))
	nodes["lap"].visible = nodes["lap"].text != ""

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
	_set_call_flash(nodes["bar"], bool(entry.get("calling", false)), FRIEND_BAR_SIZE)
	_set_status_bar(nodes["bar"], entry.get("status", {}))

# --- Small builders -----------------------------------------------------------

# A panel whose border carries one player's colour.
#
# ITS OWN StyleBoxFlat, NEVER A SHARED ONE. A theme stylebox handed to two panels
# is one resource with two owners, so setting a border colour on either would set
# it on both -- the same trap player.tscn's materials have, which this project
# has now paid for on hats, on the status bar, and on the player body. One panel,
# one box, written through afterwards.
func _outline_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = OUTLINE_BG
	style.set_border_width_all(OUTLINE_WIDTH)
	# Starts invisible rather than at some placeholder colour: a peer whose
	# announcement has not arrived should show no outline at all, not the wrong
	# one. _set_outline fills it in as soon as there is an answer.
	style.border_color = Color.TRANSPARENT
	style.set_corner_radius_all(OUTLINE_RADIUS)
	style.set_content_margin_all(OUTLINE_PAD)
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _set_outline(panel: PanelContainer, colour: Color) -> void:
	if panel == null:
		return
	var style := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if style == null:
		return
	style.border_color = colour

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

	# AN OUTLINE, BECAUSE THERE IS NO BACKGROUND TO DESIGN AGAINST (2026-08-16,
	# reported as "the white text for the game phase at the top is almost
	# unreadable").
	#
	# This HUD draws straight over the world, and the world under the top of the
	# screen is the bridge deck: a CHECKERBOARD, so half of every glyph sits on a
	# light square. White on white is the worst case and it is guaranteed to
	# happen somewhere in any line of text.
	#
	# The alternative is a panel behind the text, and it was not taken: a solid
	# strip across the top of the screen is a permanent occlusion bought to fix an
	# occasional one, and this game is played by looking at things in the middle
	# distance. An outline costs nothing when the background is already dark and
	# saves the line when it is not.
	#
	# SCALED WITH THE FONT so a 34 px clock and an 18 px scoreboard row get the
	# same weight of edge rather than the same number of pixels; a fixed outline
	# reads as a heavy smudge on small text and as nothing on large.
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	# THE RATIO IS THE KNOB, and it was cut from 0.22 when the banner doubled: at
	# 22 px that gave a 5 px edge, which is chunky but fine, and at 44 px it gives
	# 10 px, which is a black halo rather than an outline. 0.14 lands at 3 px on
	# the small rows and 6 px on the banner, which is the usual weight for text
	# over an arbitrary background.
	label.add_theme_constant_override("outline_size",
		maxi(3, int(round(float(size) * 0.14))))
	# And a soft shadow under it, which is what separates the glyph from a
	# background of the SAME brightness -- an outline alone still disappears
	# against mid grey.
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.5))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)
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
# HOW MUCH TALLER A CALLING PLAYER'S BAR GETS. Height rather than width, because
# the width is the READING -- how much health, how much countdown -- and a bar
# that got longer would be saying something false about the number in it.
const CALL_BAR_SCALE := 2.0

# A CALL FLASHES THE BAR BIGGER, on the crisis clock.
#
# THE SAME CLOCK AS EVERYTHING ELSE THAT ASKS FOR ATTENTION -- the downed colour,
# the offscreen marker -- so a player in trouble does ONE thing at whatever
# frequency, rather than several things at several. A steady enlargement would be
# read once and become the new normal.
#
# ON YOUR OWN BAR TOO. Pressing a key and seeing nothing happen is how a player
# concludes it is broken, and the confirmation costs nothing: you already know you
# are calling, so nothing is being told to you that you did not just do.
# THE SELF-REVIVE BAR: a window to hit and a marker sweeping toward it.
#
# THREE RECTS AND NO ANIMATION STATE. Both positions come from the model every
# frame -- ultimately from `state_timer`, which is the same number the host judges
# the press against -- so this widget cannot drift out of step with the rule. A
# marker tweened locally would look identical and be wrong by however far the two
# clocks had wandered, which is the whole class of bug the sweep was made a pure
# function to avoid.
func _build_revive_overlay(back: ColorRect) -> void:
	var line := ColorRect.new()
	line.name = "Window"
	line.color = COLOR_REVIVE_WINDOW
	# ADDED AFTER THE FILL, so it draws on top of it. The line has to stay visible
	# through the moment the fill's edge is ON it, which is the moment it exists
	# for -- underneath, it would disappear exactly when it matters.
	back.add_child(line)
	line.visible = false

# HIDDEN IS A STATEMENT. An empty dictionary means a press would do nothing right
# now -- you are on your feet, or somebody is already hauling you -- and the line
# going away says so without a word. A line left sitting there while the button is
# inert would be the HUD promising something the game will refuse.
#
# NO ANIMATION STATE. The position comes from the model every frame, ultimately
# from `state_timer` -- the same number the host judges the press against -- so
# this cannot drift out of step with the rule it is drawing.
func _set_revive_bar(bar: ColorRect, spec: Dictionary) -> void:
	if bar == null:
		return
	var line: ColorRect = bar.get_node_or_null("Window") as ColorRect
	if line == null:
		return
	line.visible = not spec.is_empty()
	if spec.is_empty():
		return
	var full: float = maxf(bar.size.x, BAR_SIZE.x)
	var width: float = maxf(full * float(spec.get("width", 0.0)), REVIVE_LINE_MIN_WIDTH)
	# CENTRED ON THE MARK, and clamped so it stays inside its own track. The mark
	# is where the fill's edge WILL BE at the winning moment, so the line has to
	# straddle it rather than start at it.
	line.size = Vector2(width, maxf(bar.size.y, bar.custom_minimum_size.y))
	line.position = Vector2(
		clampf(full * float(spec.get("line", 0.0)) - width * 0.5, 0.0, full - width), 0.0)

func _set_call_flash(bar: ColorRect, calling: bool, base: Vector2) -> void:
	var tall: bool = calling and CrisisFlash.on(CrisisFlash.now())
	bar.custom_minimum_size = Vector2(base.x, base.y * (CALL_BAR_SCALE if tall else 1.0))
	_bar_fill(bar).size.y = bar.custom_minimum_size.y

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
