extends "res://scripts/test_support/test_case.gd"

# The hats you own, across launches. See scripts/hat_config.gd.
#
#   * First ever launch gives you a RANDOM hat, and saves it.
#   * You start every session wearing whatever is saved.
#   * Acquiring a hat makes THAT hat yours -- steal one and it is yours tomorrow.
#   * Lose them and they are gone: the next session starts you bare.
#
# THE WHOLE STACK, AND BIG HATS TOO, since 2026-08-23. The file used to hold one
# int -- the topmost ORDINARY hat -- and now holds an array of every worn style.
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
	_test_the_whole_stack_is_kept()
	_test_acquiring_replaces_it()
	_test_losing_it_leaves_you_bare()
	_test_saved_style_is_a_real_hat()
	_test_an_old_file_still_loads()
	_test_a_broken_file_cannot_take_the_spawn_with_it()

	HatConfig.reset()
	HatConfig.path_override = ""
	finish()

# --- A first ever launch --------------------------------------------------------

func _test_first_launch_rolls_one() -> void:
	var first: Array = HatConfig.load_styles()
	eq(first.size(), 1, "a first ever launch gives you exactly one hat")
	check(int(first[0]) != HatConfig.NONE, "and it is a hat (%d)" % int(first[0]))

	# ...AND SAVES IT. Rolling one and forgetting to write it would give a
	# different hat every launch, which is the opposite of the point.
	eq(HatConfig.load_styles(), first,
		"and saves it, rather than rolling a new one every launch")

# --- Restarting the game -------------------------------------------------------

func _test_survives_a_restart() -> void:
	HatConfig.save_styles([4242])
	# A fresh read is what a restart IS, as far as this file is concerned: no
	# in-memory state carries across, only what is on disk.
	eq(HatConfig.load_styles(), [4242], "your hat survives quitting and restarting")

# --- The whole tower, in order -------------------------------------------------

func _test_the_whole_stack_is_kept() -> void:
	# ORDER MATTERS AND IS PART OF THE CLAIM. A stack is drawn bottom-up and the
	# restore wears them at slots 0..n, so a set would put yesterday's tower back
	# in a different order -- and the tallest hat, which is the one the merchant
	# charged for, could end up buried in the middle of it.
	HatConfig.save_styles([11, 22, 33])
	eq(HatConfig.load_styles(), [11, 22, 33],
		"the whole stack is kept, bottom first -- a tower is what you built, and "
		+ "putting it back in another order is not putting it back")

	# BIG HATS TOO. This reverses a decision recorded on 2026-08-18 -- a tall hat
	# came only from the merchant, so refusing to persist it made the trade a bet.
	# Overruled deliberately: it is more fun to keep your big hat.
	var tall: int = HatStyle.random_tall_style()
	check(HatStyle.is_tall(tall), "the fixture really is a tall hat (%d)" % tall)
	HatConfig.save_styles([7, tall])
	eq(HatConfig.load_styles(), [7, tall],
		"and a TALL hat persists like any other -- the trade is a purchase now, "
		+ "which was the point of paying for it")

# --- Acquiring a hat makes it yours --------------------------------------------

func _test_acquiring_replaces_it() -> void:
	HatConfig.save_styles([4242])
	HatConfig.save_styles([777])
	eq(HatConfig.load_styles(), [777],
		"acquiring a hat makes THAT hat yours -- steal one and you keep it")

# --- Losing them ---------------------------------------------------------------

func _test_losing_it_leaves_you_bare() -> void:
	HatConfig.save_styles([777])
	HatConfig.save_styles([])
	eq(HatConfig.load_styles(), [],
		"and losing them is remembered: the next session starts you bare")

	# AN EMPTY STACK MUST SURVIVE A ROUND TRIP, and this is the case a sloppy
	# default eats. If "no hats" were stored as a missing key, load_styles would
	# treat it as a first launch and hand you a free replacement -- which would
	# make losing your hat cost nothing at all.
	var cfg := ConfigFile.new()
	eq(cfg.load(HatConfig.path()), OK, "the file still exists with nothing in it")
	var stored = cfg.get_value(HatConfig.SECTION, HatConfig.KEY, null)
	eq(typeof(stored), TYPE_ARRAY, "and an empty stack is stored explicitly")
	eq((stored as Array).size(), 0, "as an empty array rather than an absent key")

# --- Whatever is saved has to be a hat -----------------------------------------

func _test_saved_style_is_a_real_hat() -> void:
	HatConfig.reset()
	var rolled: int = int(HatConfig.load_styles()[0])
	# The roll is the only randomness in the whole feature; everything about how
	# that hat LOOKS is a pure function of this number, so any value it can
	# produce has to be a hat somebody would want to see.
	var k: Dictionary = HatStyle.knobs(rolled)
	check(k["height"] >= HatStyle.HEIGHT_MIN - 0.001, "a rolled hat has a real height")
	check(k["base"] > 0.0, "and a real crown")
	check(HatStyle.PALETTE.has(k["colour"]), "and a colour from the palette")

# --- A file written by yesterday's build ---------------------------------------

func _test_an_old_file_still_loads() -> void:
	# WRITTEN BY HAND IN THE OLD SHAPE, because that is the only way to test a
	# format nothing in the tree produces any more. A single int under `hat_style`
	# is exactly what three people have on disk right now.
	HatConfig.reset()
	var cfg := ConfigFile.new()
	cfg.set_value(HatConfig.SECTION, HatConfig.KEY_LEGACY, 4242)
	cfg.save(HatConfig.path())
	eq(HatConfig.load_styles(), [4242],
		"a config from before the stack existed reads as a stack of one -- losing "
		+ "it was acceptable, and not losing it costs three lines")

# --- ...and a file written by nothing at all -----------------------------------

func _test_a_broken_file_cannot_take_the_spawn_with_it() -> void:
	# THE ONE INPUT THIS GAME CANNOT TEST AGAINST EVERY VERSION OF ITSELF is
	# whatever somebody happens to have on disk. And in GDScript a bad read does
	# not fail loudly -- it aborts the rest of the calling function (CLAUDE.md),
	# which here is the spawn. So the claim is not that garbage loads correctly,
	# it is that garbage RETURNS.
	for junk in [ "a string where an array goes", 3.5, {"not": "an array"},
			[1, "two", null, 3] ]:
		HatConfig.reset()
		var cfg := ConfigFile.new()
		cfg.set_value(HatConfig.SECTION, HatConfig.KEY, junk)
		cfg.save(HatConfig.path())
		var got: Array = HatConfig.load_styles()
		check(true, "a config holding %s loads as %s rather than raising"
			% [str(junk).substr(0, 28), str(got)])

	# The mixed array is the interesting one: the entries that ARE styles survive
	# and the rest are dropped. A wrong number is a wrong hat, which is worse than
	# a missing one.
	eq(HatConfig.load_styles(), [1, 3],
		"and the readable entries of a half-broken stack are kept")
