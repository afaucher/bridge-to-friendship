extends "res://scripts/test_support/test_case.gd"

# WHICH MODE, ON SCREEN, IN BOTH STATES.
#
# There are two of these now and they are not the same sentence about the same
# thing:
#
#   THE LOBBY ONE, centred under ROUND, names what the SELECTOR is set to -- what
#   the party is deciding. It exists because there was no indicator at all: the
#   post cycles a colour on a banner and nothing said what the colour MEANT.
#
#   THE ROUND ONE, off to the right opposite the lap clock, names what is
#   actually RUNNING. Asked for after playing it: a run switches between four
#   modes with different rules and different scoring, and "which one am I in"
#   stops being obvious the moment it can change.
#
# THE TWO SOURCES ONLY AGREE BY LUCK, and that is the claim with teeth here. The
# selector stays dashable mid-round -- the choice is REMEMBERED for the next
# lobby -- so a player who changes their mind halfway through a race would have
# been told on screen that they were playing the mode they had just queued for
# afterwards. Every other claim in this file passes whether or not that is right.
#
# AND THE LOBBY BANNER HAD NO TEST AT ALL until this file. It was added from a
# playtest report, shipped, and nothing ever asserted it drew anything.

const HudModel = preload("res://scripts/ui/hud_model.gd")
const HudScript = preload("res://scripts/ui/hud.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")

const A := 41

var world: Node3D = null
var hud: Node = null
var done := false
var phase := 0
var _at := 0

func setup(main) -> void:
	timeout_seconds = 40.0
	# A REAL SCREEN. The headless viewport is 64x64 and every position on this HUD
	# is nonsense in it -- the centred round column lands at x = -441.
	main.get_window().size = Vector2i(1280, 720)
	world = Node3D.new()
	world.name = "ModeHudWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	hud = HudScript.new()
	hud.name = "ModeHud"
	main.add_child(hud)
	hud.world = world

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match phase:
		0:
			_the_two_are_the_same_size()
			_in_a_lobby()
			phase = 1
			_at = world.tick
		1:
			if world.tick < _at + 3:
				return
			_the_lobby_shows_the_choice_and_nothing_else()
			_in_a_round()
			phase = 2
			_at = world.tick
		2:
			if world.tick < _at + 3:
				return
			_a_round_names_what_is_running()
			done = true
			finish()

# --- Setting the world up --------------------------------------------------------

func _in_a_lobby() -> void:
	world.round_machine.state = RoundMachine.State.LOBBY
	world.round_machine.round_index = 0
	world.run_modes = [GameMode.TRACK]
	world.selected_mode = GameMode.RACE

func _in_a_round() -> void:
	world.round_machine.state = RoundMachine.State.RUNNING
	world.round_machine.round_index = 0
	# THE ROUND BEING PLAYED IS `TRACK`, THE SELECTOR SAYS `RACE`. That is not a
	# contrived state: dashing the selector mid-round is exactly what a party does
	# on the way out of a section, and the choice is held for the next lobby.
	world.run_modes = [GameMode.TRACK]
	world.selected_mode = GameMode.RACE

# --- 1. The same size as the pair it copies ---------------------------------------

func _the_two_are_the_same_size() -> void:
	# ASSERTED AS A RELATIONSHIP, NOT A LITERAL. The ask was "the same as the game
	# mode summary when you're in the lobby", so the claim is that the two agree --
	# which stays true the day somebody retunes the lobby pair, where eq(size, 30)
	# would quietly stop meaning what it says.
	var name_size: int = hud._playing_name.get_theme_font_size("font_size")
	var lobby_name: int = hud._mode_name.get_theme_font_size("font_size")
	var blurb_size: int = hud._playing_blurb.get_theme_font_size("font_size")
	var lobby_blurb: int = hud._mode_blurb.get_theme_font_size("font_size")
	print("[hudmode] name %d vs lobby %d, blurb %d vs lobby %d"
		% [name_size, lobby_name, blurb_size, lobby_blurb])
	eq(name_size, lobby_name,
		"the round summary's name is set at the lobby summary's size (%d vs %d)"
			% [name_size, lobby_name])
	eq(blurb_size, lobby_blurb,
		"and so is its blurb (%d vs %d) -- deliberately NOT the lap clock's size "
			% [blurb_size, lobby_blurb]
		+ "beside it: that is a number you watch, this is a line you read once")

# --- 2. A lobby shows the choice, and only one of them ------------------------------

func _the_lobby_shows_the_choice_and_nothing_else() -> void:
	print("[hudmode] in a lobby: centre `%s` (visible %s), side `%s` (visible %s)"
		% [hud._mode_name.text, hud._mode_name.visible,
			hud._playing_name.text, hud._playing_name.visible])
	check(hud._mode_name.visible, "in a lobby the centred summary is up")
	eq(hud._mode_name.text, GameMode.name_of(GameMode.RACE),
		"naming what the SELECTOR is set to (`%s`), which is what a party standing "
			% hud._mode_name.text
		+ "on the band is deciding")
	check(not hud._playing_name.visible,
		"and the side one is not, so the same sentence is never on screen twice -- "
		+ "a lobby keeps its big centred moment")

# --- 3. A round names what is RUNNING, not what is queued ---------------------------

func _a_round_names_what_is_running() -> void:
	print("[hudmode] mid-round: side `%s` (visible %s), centre visible %s; the "
			% [hud._playing_name.text, hud._playing_name.visible,
				hud._mode_name.visible]
		+ "selector says `%s`" % GameMode.name_of(world.selected_mode))
	check(hud._playing_name.visible,
		"mid-round the side summary is up -- which mode you are in stops being "
		+ "obvious the moment a run can switch between four of them")
	check(not hud._mode_name.visible,
		"and the centred one has gone, so still only one of them at a time")

	# THE CLAIM WITH TEETH. Everything above passes whether this is right or not.
	eq(hud._playing_name.text, GameMode.name_of(GameMode.TRACK),
		"it names the mode being PLAYED (`%s`), not the one the selector is set to "
			% hud._playing_name.text
		+ "(`%s`) -- those read from different places and only ever agree by luck, "
			% GameMode.name_of(world.selected_mode)
		+ "because the selector stays dashable mid-round and holds its choice for "
		+ "the next lobby")
	eq(hud._playing_blurb.text, GameMode.blurb_of(GameMode.TRACK),
		"and its blurb comes from the same mode (`%s`)" % hud._playing_blurb.text)

	# AND IT IS ON THE OTHER SIDE, measured. Anchors are not layout: this project
	# shipped a score screen in the corner of the display with four correct
	# anchors because the test asserted the anchors.
	var screen: float = hud.get_viewport().get_visible_rect().size.x
	var left: float = hud._playing_name.global_position.x
	print("[hudmode] at %d px the summary starts at %.0f, the lap clock at %.0f"
		% [screen, left, hud._own_lap_live.global_position.x])
	check(left > screen * 0.5,
		"the round summary sits past the middle (%.0f of %.0f), opposite the lap "
			% [left, screen * 0.5]
		+ "clock -- a pair reads as a pair because of where they are")
