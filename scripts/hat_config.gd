extends RefCounted

const HatStyle = preload("res://scripts/sim/hat_style.gd")

# The hats you own, across launches.
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
#   * Lose your hats and they are gone: the next session starts you bare.
#
# THE WHOLE STACK, AND BIG HATS TOO (2026-08-23). It used to save the topmost
# ORDINARY hat and nothing else, and the reasoning for the exclusion was written
# down at length on 2026-08-18: a tall hat comes only from the merchant, so
# refusing to persist it made the trade a bet rather than a purchase. That is a
# real argument and it was overruled deliberately -- "it is more fun to keep your
# big hat". Both changes weaken the same thing, that hats are held at risk, and
# the risk that remains is the one that was always the sharpest: a fall still
# takes the lot.
#
# It is what makes the feature's own premise pay off. "That is MY hat on your
# head" only means something if the hat was mine yesterday too.

const NONE := -1

const SECTION := "player"
# The OLD key, an int, read once and never written. See load_styles().
const KEY_LEGACY := "hat_style"
const KEY := "hat_stack"
const DEFAULT_PATH := "user://player.cfg"

# Tests point this somewhere disposable. Without it, running the gate would
# read and rewrite the developer's own saved hat -- and a test that quietly
# mutates real user state is a test nobody can trust twice.
static var path_override: String = ""

static func path() -> String:
	return path_override if path_override != "" else DEFAULT_PATH

# The hats to start this session in, bottom of the stack first, rolling and saving
# one on a first ever run.
#
# The roll is the ONLY randomness here. Everything about how a hat looks is a pure
# function of its number (see hat_style.gd), so the same saved value is the same
# hat forever and on every machine.
#
# NOTHING HERE MAY RAISE ON A FILE IT DOES NOT UNDERSTAND. A config is the one
# input this game cannot test against every version of itself -- it is whatever
# somebody happened to have on disk -- and in GDScript a bad read does not fail
# loudly, it aborts the rest of the calling function (CLAUDE.md). That would take
# the spawn with it. So every value is type-checked before it is used, and
# anything unrecognised reads as "no hats" rather than as an error.
static func load_styles() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(path()) != OK:
		# ORDINARY ONLY, like every other roll in the game. A first-ever launch
		# must not hand out the merchant's hat -- it is the one thing you can only
		# get by trading for it, and a free one on install would be the loudest
		# possible way to break that.
		var rolled: Array = [HatStyle.random_ordinary_style()]
		save_styles(rolled)
		return rolled

	var stored = cfg.get_value(SECTION, KEY, null)
	if typeof(stored) == TYPE_ARRAY:
		var out: Array = []
		for entry in stored:
			# A style is an int and a hat is a pure function of it, so an entry that
			# is not one has no hat to be. Dropped rather than defaulted: a wrong
			# number is a wrong hat, which is worse than a missing one.
			if typeof(entry) == TYPE_INT or typeof(entry) == TYPE_FLOAT:
				out.append(int(entry))
		return out

	# A FILE FROM BEFORE THE STACK EXISTED holds a single int under the old key.
	# Read as a stack of one. Three people have a config and losing their hat was
	# explicitly acceptable -- this is three lines to not lose it anyway, and the
	# old key is never written again, so the migration retires itself.
	var legacy = cfg.get_value(SECTION, KEY_LEGACY, null)
	if typeof(legacy) == TYPE_INT or typeof(legacy) == TYPE_FLOAT:
		var one: int = int(legacy)
		return [] if one == NONE else [one]
	return []

static func save_styles(styles: Array) -> void:
	var cfg := ConfigFile.new()
	# Load first so this never clobbers a key somebody else added.
	cfg.load(path())
	var clean: Array = []
	for entry in styles:
		if typeof(entry) == TYPE_INT or typeof(entry) == TYPE_FLOAT:
			clean.append(int(entry))
	cfg.set_value(SECTION, KEY, clean)
	cfg.save(path())

# Test support: forget everything, so the next load_styles() is a first ever run.
static func reset() -> void:
	if FileAccess.file_exists(path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path()))
