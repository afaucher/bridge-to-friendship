extends "res://scripts/test_support/test_case.gd"

# The saved character: that it round-trips, that a first run has a real default,
# and that it shares a file with the saved hat without either eating the other.

const CharacterConfig = preload("res://scripts/character_config.gd")
const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const HatConfig = preload("res://scripts/hat_config.gd")

# SOMEWHERE DISPOSABLE, AND THIS IS THE FIRST LINE FOR A REASON. Without it this
# test reads and rewrites the DEVELOPER'S OWN character and hat -- hat_config.gd
# carries the same field and says why: a test that quietly mutates real user
# state is a test nobody can trust twice.
const TEST_PATH := "user://test_character.cfg"

func setup(_main) -> void:
	CharacterConfig.path_override = TEST_PATH
	HatConfig.path_override = TEST_PATH
	CharacterConfig.reset()

	_test_first_run_default()
	_test_round_trip()
	_test_shares_a_file_with_the_hat()
	_test_survives_a_corrupt_value()
	_test_the_override_is_doing_something()

	CharacterConfig.reset()
	CharacterConfig.path_override = ""
	HatConfig.path_override = ""
	finish()

# --- 1. A first launch has a character, and it is the same one everywhere ------
#
# NO ROLL, unlike the hat. A hat is dealt, so HatConfig rolls one; a character is
# chosen, so an unconfigured player gets a documented default. The difference
# matters here because a rolled default is one no test can assert and one that
# makes two fresh installs look different for no reason anybody chose.

func _test_first_run_default() -> void:
	CharacterConfig.reset()
	var first: Color = CharacterConfig.load_body_colour()
	check(first == CharacterStyle.DEFAULT_BODY,
		"a first-ever launch is the documented default -- got %s" % first)

	# And reading it did not WRITE it. HatConfig.load_style deliberately saves its
	# roll (it has to, or the hat would differ every launch); this has nothing to
	# save, and a load with a side effect is a load that fights a later write.
	check(not FileAccess.file_exists(CharacterConfig.path()),
		"and reading a default did not create a file")

	var again: Color = CharacterConfig.load_body_colour()
	check(first == again, "and it is the same on the next read")

# --- 2. What you chose is what you get ----------------------------------------

func _test_round_trip() -> void:
	# Deliberately not a round number: a value that survives to_html and back is a
	# stronger claim than one that would survive being truncated.
	var chosen := Color(0.317, 0.772, 0.418)
	CharacterConfig.save_body_colour(chosen)
	var loaded: Color = CharacterConfig.load_body_colour()
	# 8 bits per channel is what the storage format holds, so the tolerance is the
	# format's own resolution rather than a number picked to make this pass.
	near(loaded.r, chosen.r, 1.0 / 255.0, "red survives the round trip")
	near(loaded.g, chosen.g, 1.0 / 255.0, "green survives the round trip")
	near(loaded.b, chosen.b, 1.0 / 255.0, "blue survives the round trip")

# --- 3. Two settings, one file ------------------------------------------------
#
# hat_config.gd's header promises the next thing to persist can "land beside it
# without a migration". This is that claim being cashed: both use
# load-then-set-then-save, so neither write drops the other's key.

func _test_shares_a_file_with_the_hat() -> void:
	var colour := Color(0.8, 0.2, 0.6)
	CharacterConfig.save_body_colour(colour)
	HatConfig.save_styles([4242])

	near(CharacterConfig.load_body_colour().r, colour.r, 1.0 / 255.0,
		"saving a hat did not clobber the colour")
	eq(HatConfig.load_styles(), [4242], "and the hat is still there")

	# And the other order, because "A then B" working says nothing about "B then A"
	# -- one of the two writes could be the destructive one.
	CharacterConfig.save_body_colour(Color(0.1, 0.9, 0.3))
	eq(HatConfig.load_styles(), [4242], "saving a colour did not clobber the hat")

# --- 4. A hand-edited file cannot take the game down --------------------------
#
# The colour is stored as six hex characters rather than as a Color, because a
# ConfigFile writes a Color as the constructor call `Color(0.25, 0.6, 0.85, 1)`
# -- and a botched hand-edit of THAT is a parse failure for the whole file, which
# would take the saved hat with it.

func _test_survives_a_corrupt_value() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CharacterConfig.path())
	cfg.set_value(CharacterConfig.SECTION, CharacterConfig.KEY_BODY, "not a colour")
	cfg.save(CharacterConfig.path())
	check(CharacterConfig.load_body_colour() == CharacterStyle.DEFAULT_BODY,
		"a nonsense value falls back to the default rather than raising")

# --- 5. The override is real --------------------------------------------------
#
# An override that silently did nothing would leave every assertion above true
# AND be quietly writing to the developer's real save the whole time. Check the
# path actually moved.

func _test_the_override_is_doing_something() -> void:
	eq(CharacterConfig.path(), TEST_PATH, "the override redirects the path")
	CharacterConfig.path_override = ""
	eq(CharacterConfig.path(), CharacterConfig.DEFAULT_PATH,
		"and clearing it goes back to the real one")
	check(CharacterConfig.DEFAULT_PATH != TEST_PATH,
		"which is a different file from the one this test writes")
	CharacterConfig.path_override = TEST_PATH
