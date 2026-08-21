extends RefCounted

const CharacterStyle = preload("res://scripts/sim/character_style.gd")

# The character you chose, across launches.
#
# BESIDE THE HAT, IN THE SAME FILE, WITH NO MIGRATION -- which hat_config.gd
# opens by promising is possible:
#
#   "the file is a plain ConfigFile with one named key rather than anything
#    clever: the next thing to persist (bindings, a chosen colour, a score) has
#    to be able to land beside it without a migration."
#
# It names a chosen colour outright. So this is another key in the same
# `[player]` section, written through the same load-then-set-then-save shape so
# neither file can clobber the other's keys.
#
# NO FIRST-RUN ROLL, and that is the difference from the hat. A hat is DEALT --
# `HatConfig.load_style` rolls one on a first launch because the game is handing
# you something. A character is CHOSEN, so an unconfigured player gets a
# documented default that is identical on every machine, and a default nobody
# rolled is a default a test can assert.

const SECTION := "player"
const KEY_BODY := "body_colour"
const DEFAULT_PATH := "user://player.cfg"

# Tests point this somewhere disposable. Without it, running the gate would read
# and rewrite the DEVELOPER'S OWN saved character -- hat_config.gd carries the
# identical field for the identical reason, and its note is the whole argument:
# a test that quietly mutates real user state is a test nobody can trust twice.
static var path_override: String = ""

static func path() -> String:
	return path_override if path_override != "" else DEFAULT_PATH

# The body colour to play in. The default is the blue the game has always used,
# so a player who never opens the screen looks exactly like a player has always
# looked -- see CharacterStyle.DEFAULT_BODY for why that value specifically.
static func load_body_colour() -> Color:
	var cfg := ConfigFile.new()
	if cfg.load(path()) != OK:
		return CharacterStyle.DEFAULT_BODY
	# STORED AS A HTML STRING, not as a Color. A ConfigFile round-trips a Color
	# fine, but it writes it as `Color(0.25, 0.6, 0.85, 1)` -- a constructor call
	# that a hand-edit can turn into a parse failure for the WHOLE file, taking
	# the saved hat down with it. Six hex characters cannot do that.
	var stored: String = str(cfg.get_value(SECTION, KEY_BODY, ""))
	if stored == "" or not Color.html_is_valid(stored):
		return CharacterStyle.DEFAULT_BODY
	return Color.html(stored)

static func save_body_colour(colour: Color) -> void:
	var cfg := ConfigFile.new()
	# Load first so this never clobbers the hat sitting in the same file.
	cfg.load(path())
	cfg.set_value(SECTION, KEY_BODY, colour.to_html(false))
	cfg.save(path())

# Test support: forget everything, so the next load is a first-ever run.
static func reset() -> void:
	if FileAccess.file_exists(path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path()))
