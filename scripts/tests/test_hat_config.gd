extends "res://scripts/test_support/test_case.gd"

# The hat you own, across launches. See scripts/hat_config.gd.
#
#   * First ever launch gives you a RANDOM hat, and saves it.
#   * You start every session wearing whatever is saved.
#   * Acquiring a hat makes THAT hat yours -- steal one and it is yours tomorrow.
#   * Lose it and it is gone: the next session starts you bare.
#
# Every case here writes to a DISPOSABLE path. A test that rewrote the real
# user:// file would quietly change the developer's own saved hat every time the
# gate ran, which is a test nobody can trust twice.

const HatConfig = preload("res://scripts/hat_config.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")

func setup(_main) -> void:
	HatConfig.path_override = "user://test_hat_config.cfg"
	HatConfig.reset()

	_test_first_launch_rolls_one()
	_test_survives_a_restart()
	_test_acquiring_replaces_it()
	_test_losing_it_leaves_you_bare()
	_test_saved_style_is_a_real_hat()

	HatConfig.reset()
	HatConfig.path_override = ""
	finish()

# --- A first ever launch --------------------------------------------------------

func _test_first_launch_rolls_one() -> void:
	var first: int = HatConfig.load_style()
	check(first != HatConfig.NONE, "a first ever launch gives you a hat (%d)" % first)

	# ...AND SAVES IT. Rolling one and forgetting to write it would give a
	# different hat every launch, which is the opposite of the point.
	var again: int = HatConfig.load_style()
	eq(again, first, "and saves it, rather than rolling a new one every launch")

# --- Restarting the game -------------------------------------------------------

func _test_survives_a_restart() -> void:
	HatConfig.save_style(4242)
	# A fresh read is what a restart IS, as far as this file is concerned: no
	# in-memory state carries across, only what is on disk.
	eq(HatConfig.load_style(), 4242, "your hat survives quitting and restarting")

# --- Acquiring a hat makes it yours --------------------------------------------

func _test_acquiring_replaces_it() -> void:
	HatConfig.save_style(4242)
	HatConfig.save_style(777)
	eq(HatConfig.load_style(), 777,
		"acquiring a hat makes THAT hat yours -- steal one and you keep it")

# --- Losing it ------------------------------------------------------------------

func _test_losing_it_leaves_you_bare() -> void:
	HatConfig.save_style(777)
	HatConfig.save_style(HatConfig.NONE)
	eq(HatConfig.load_style(), HatConfig.NONE,
		"and losing it is remembered: the next session starts you bare")

	# NONE MUST SURVIVE A ROUND TRIP, and this is the case a sloppy default eats.
	# If "no hat" were stored as a missing key, load_style would treat it as a
	# first launch and hand you a free replacement -- which would make losing your
	# hat cost nothing at all.
	var cfg := ConfigFile.new()
	eq(cfg.load(HatConfig.path()), OK, "the file still exists with nothing in it")
	eq(int(cfg.get_value(HatConfig.SECTION, HatConfig.KEY, 999)), HatConfig.NONE,
		"and 'no hat' is stored explicitly rather than as an absent key")

# --- Whatever is saved has to be a hat -----------------------------------------

func _test_saved_style_is_a_real_hat() -> void:
	HatConfig.reset()
	var rolled: int = HatConfig.load_style()
	# The roll is the only randomness in the whole feature; everything about how
	# that hat LOOKS is a pure function of this number, so any value it can
	# produce has to be a hat somebody would want to see.
	var k: Dictionary = HatStyle.knobs(rolled)
	check(k["height"] >= HatStyle.HEIGHT_MIN - 0.001, "a rolled hat has a real height")
	check(k["base"] > 0.0, "and a real crown")
	check(HatStyle.PALETTE.has(k["colour"]), "and a colour from the palette")
