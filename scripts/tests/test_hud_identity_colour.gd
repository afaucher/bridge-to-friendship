extends "res://scripts/test_support/test_case.gd"

# The player's chosen colour, drawn as an outline around their HUD widget.
#
# WHAT THIS IS FOR: matching a row to a body currently means READING A NAME, and
# the HUD's whole job is to be read at a glance while something is trying to kill
# you. A colour is matched without reading.
#
# THE TEST GOES THROUGH THE REAL PATH -- a real GameWorld, a real HUD, and the
# HUD's own _process pulling its own model. CLAUDE.md's shield note is the reason:
# a test that hand-builds the dictionary it feeds in has tested a function and
# not a feature, and the shield's bug was entirely in the caller that built the
# real one. So nothing here constructs a model entry.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HudScript = preload("res://scripts/ui/hud.gd")
const CharacterStyle = preload("res://scripts/sim/character_style.gd")

# Far apart from each other AND from the default, so no assertion can be
# satisfied by a colour that was simply never set.
const MINE := Color(0.90, 0.25, 0.20)
const THEIRS := Color(0.20, 0.85, 0.35)

var world: Node3D = null
var hud: CanvasLayer = null

func setup(main) -> void:
	world = Node3D.new()
	world.name = "HudColourWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)

	# Set through the world's own dictionary, which is what the wire fills in on a
	# real client -- see GameWorld._set_characters.
	world.player_colours[1] = MINE
	world.player_colours[2] = THEIRS

	hud = HudScript.new()
	hud.name = "Hud"
	main.add_child(hud)
	hud.world = world
	# The HUD's own frame function, pulling its own model. Called directly rather
	# than waited for so this stays a one-frame test with nothing timing-dependent
	# in it.
	hud._process(0.0)

	_test_own_outline()
	_test_friend_outline()
	_test_the_two_are_not_one_resource()
	_test_a_peer_with_no_colour_shows_none()
	_test_leaving_takes_the_frame_with_it()
	finish()

func _border_of(panel: PanelContainer) -> Color:
	if panel == null:
		return Color.TRANSPARENT
	var style := panel.get_theme_stylebox("panel") as StyleBoxFlat
	return Color.TRANSPARENT if style == null else style.border_color

# --- 1 and 2. The colour reaches both kinds of widget -------------------------
#
# Both, because they are built by different functions -- _build_own_panel and
# _build_friend_row -- and only one of them was ever going to be forgotten.

func _test_own_outline() -> void:
	check(hud._own_outline != null, "the HUD built an outline around your own panel")
	check(_border_of(hud._own_outline).is_equal_approx(MINE),
		"and it is your colour -- %s" % _border_of(hud._own_outline))

func _test_friend_outline() -> void:
	if not check(hud._friend_rows.has(2), "the HUD built a row for the other player"):
		return
	var panel: PanelContainer = hud._friend_rows[2].get("outline")
	check(panel != null, "with an outline of its own")
	check(_border_of(panel).is_equal_approx(THEIRS),
		"carrying THEIR colour, not yours -- %s" % _border_of(panel))

# --- 3. THE SHARED-RESOURCE TRAP ----------------------------------------------
#
# A StyleBox handed to two panels is one resource with two owners, so writing a
# border colour on either writes it on both -- and the last one to update wins
# for everybody. This project has now paid for that shape three times: worn hats
# sharing the scene's meshes, the status bar sharing its materials, and the
# player body sharing player.tscn's Mat_1 earlier in this same feature.
#
# The assertions above CANNOT see it. Two panels sharing one box would both end
# up whatever colour was written last, and if that happened to be checked first
# it would look perfect.

func _test_the_two_are_not_one_resource() -> void:
	var mine: StyleBox = hud._own_outline.get_theme_stylebox("panel")
	var theirs: StyleBox = (hud._friend_rows[2]["outline"] as PanelContainer).get_theme_stylebox("panel")
	check(mine != theirs, "each widget owns its own StyleBox rather than sharing one")
	# And the values really did land differently, which is the observable half of
	# the same claim.
	check(not _border_of(hud._own_outline).is_equal_approx(
			_border_of(hud._friend_rows[2]["outline"])),
		"so two players on screen at once show two different colours")

# --- 4. No answer yet is no outline, not a wrong one --------------------------
#
# A peer whose announcement has not arrived has no entry, and player_colour falls
# back to the default. What must NOT happen is a placeholder that looks like a
# real choice -- the outline is the thing being trusted to identify somebody.

func _test_a_peer_with_no_colour_shows_none() -> void:
	world.player_colours.erase(2)
	hud._process(0.0)
	var shown: Color = _border_of(hud._friend_rows[2]["outline"])
	check(shown.is_equal_approx(CharacterStyle.DEFAULT_BODY),
		"a peer who has not announced shows the default rather than the last "
		+ "player's colour -- %s" % shown)
	world.player_colours[2] = THEIRS
	hud._process(0.0)

# --- 5. The frame leaves with the player --------------------------------------
#
# _update_friends removes `row` from the friends box when a peer goes. The row
# handle is now the OUTLINE panel rather than the column inside it, and if those
# two ever disagree the box keeps an empty bordered frame for every player who
# has ever disconnected -- which accumulates, on screen, forever.

func _test_leaving_takes_the_frame_with_it() -> void:
	var before: int = hud._friends_box.get_child_count()
	check(before > 0, "there is a row to lose -- %d" % before)
	world._despawn_player(2)
	hud._process(0.0)
	check(not hud._friend_rows.has(2), "the row is forgotten when the player leaves")
	check(hud._friends_box.get_child_count() == before - 1,
		"and the bordered frame goes with it rather than being left behind -- %d children"
			% hud._friends_box.get_child_count())
