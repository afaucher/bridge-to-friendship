extends "res://scripts/test_support/test_case.gd"

# Every special an author places on a map EXISTS.
#
# Written because it did not. The playtest map crossed SPECIAL_MAX_LOOSE (8) when
# it reached twelve pickups, and the loose cap deleted the four OLDEST -- which,
# because authored cells drain in map order, was the four beside the spawn. The
# symptom was "still no specials at start", and there was no error, no warning and
# no log line anywhere: the cap did exactly what it was written to do, to the
# wrong population.
#
# THIS TEST USES THE PLAYTEST MAP DELIBERATELY, which is against the usual rule in
# CLAUDE.md. The claim is about AUTHORING, and the playtest map is the artefact
# being authored -- a fixture with three pickups on it could never have failed.
# The assertion is written against the file's own glyph count rather than a number
# typed in here, so adding or removing a pickup keeps it true.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const MAP := "res://segments/playtest_bridge.seg"

# Glyph -> the kind it authors. Mirrors GridConfig.CONTENT_GLYPHS; if that gains a
# special this must too, and the count assertion is what will say so.
const SPECIAL_GLYPHS := {
	"*": SpecialBody.Kind.MACHINE_GUN,
	"g": SpecialBody.Kind.GRENADE,
	"x": SpecialBody.Kind.MINE,
	"s": SpecialBody.Kind.SHIELD,
}

var world: Node3D = null
var frames: int = 0
var expected: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 30.0
	expected = _count_glyphs()
	world = Node3D.new()
	world.name = "AuthoredWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = [MAP]
	world.start(true, 1, false)
	world._spawn_player(1, 0)

func _physics_process(_delta: float) -> void:
	if world.tick == 0:
		return
	frames += 1
	# LATE, NOT ON THE FIRST TICK. The cull runs in the pool's per-tick step, so a
	# test that looked immediately after spawning would have passed against the
	# broken build -- everything is there for one frame.
	if frames == 120:
		var actual: Dictionary = _count_spawned()
		var total_expected: int = 0
		for glyph in expected:
			total_expected += int(expected[glyph])
		check(total_expected > SimConfig.SPECIAL_MAX_LOOSE,
			"the map authors MORE pickups than the loose cap (%d against %d) -- if it "
			% [total_expected, SimConfig.SPECIAL_MAX_LOOSE]
			+ "ever authors fewer, this test stops testing anything")

		for glyph in SPECIAL_GLYPHS:
			var kind: int = SPECIAL_GLYPHS[glyph]
			eq(int(actual.get(kind, 0)), int(expected.get(glyph, 0)),
				"every `%s` on the map is in the world" % glyph)

		# AND THE ONES NEAREST THE SPAWN SURVIVE, which is the half that actually
		# broke. Lowest ids are authored first, so a cap that trims the oldest takes
		# exactly these -- counting the total alone would still have caught it here,
		# but this is the claim a reader needs to see stated.
		check(_lowest_id() <= 4,
			"including the first ones authored (lowest surviving id %d)" % _lowest_id())
		finish()

# --- what the file says -------------------------------------------------------

func _count_glyphs() -> Dictionary:
	var out: Dictionary = {}
	var text: String = FileAccess.get_file_as_string(MAP)
	var in_content := false
	for line in text.split("\n"):
		var row: String = line.strip_edges()
		if row.begins_with("["):
			in_content = row == "[content]"
			continue
		if not in_content or row.begins_with("#") or row.is_empty():
			continue
		for ch in row:
			if SPECIAL_GLYPHS.has(ch):
				out[ch] = int(out.get(ch, 0)) + 1
	return out

# --- what the world built -----------------------------------------------------

func _count_spawned() -> Dictionary:
	var out: Dictionary = {}
	for s in world._specials.all():
		if is_instance_valid(s):
			out[int(s.kind)] = int(out.get(int(s.kind), 0)) + 1
	return out

func _lowest_id() -> int:
	var best: int = 1 << 30
	for s in world._specials.all():
		if is_instance_valid(s):
			best = mini(best, int(s.special_id))
	return best
