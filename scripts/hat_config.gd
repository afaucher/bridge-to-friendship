extends RefCounted

const HatStyle = preload("res://scripts/sim/hat_style.gd")

# The hat you own, across launches.
#
# THE GAME'S FIRST PIECE OF STATE THAT OUTLIVES A SESSION, which is why the file
# is a plain ConfigFile with one named key rather than anything clever: the next
# thing to persist (bindings, a chosen colour, a score) has to be able to land
# beside it without a migration.
#
# THE RULE, from playtest:
#   * First ever launch gives you a RANDOM hat, and saves it.
#   * You start every session wearing whatever is saved.
#   * Acquiring a hat makes THAT hat yours -- steal one and it is yours tomorrow.
#   * Lose your hat and it is gone: the next session starts you bare.
#
# It is what makes the feature's own premise pay off. "That is MY hat on your
# head" only means something if the hat was mine yesterday too.

const NONE := -1

const SECTION := "player"
const KEY := "hat_style"
const DEFAULT_PATH := "user://player.cfg"

# Tests point this somewhere disposable. Without it, running the gate would
# read and rewrite the developer's own saved hat -- and a test that quietly
# mutates real user state is a test nobody can trust twice.
static var path_override: String = ""

static func path() -> String:
	return path_override if path_override != "" else DEFAULT_PATH

# The hat to start this session in, rolling and saving one on a first ever run.
#
# The roll is the ONLY randomness here. Everything about how that hat looks is a
# pure function of the number (see hat_style.gd), so the same saved value is the
# same hat forever and on every machine.
static func load_style() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(path()) != OK:
		# ORDINARY ONLY, like every other roll in the game. A first-ever launch
		# must not hand out the merchant's hat -- it is the one thing you can only
		# get by trading for it, and a free one on install would be the loudest
		# possible way to break that.
		var rolled: int = HatStyle.random_ordinary_style()
		save_style(rolled)
		return rolled
	var value: int = int(cfg.get_value(SECTION, KEY, NONE))
	return value

static func save_style(style: int) -> void:
	var cfg := ConfigFile.new()
	# Load first so this never clobbers a key somebody else added.
	cfg.load(path())
	cfg.set_value(SECTION, KEY, style)
	cfg.save(path())

# Test support: forget everything, so the next load_style() is a first ever run.
static func reset() -> void:
	if FileAccess.file_exists(path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path()))
