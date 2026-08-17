extends "res://scripts/test_support/test_case.gd"

# THE CO-OP GATE, WALKED RATHER THAN MEASURED (MVP criterion A4).
#
# A player walks up the gentle ramp and arrives on the upper deck; the same
# player walks at the steep ramp and does not. That single difference is what
# every "you need each other here" moment in the level design is authored from,
# so it is worth proving by driving a body at it rather than by checking a slope
# number the geometry might not honour.
#
# It is also the test that catches a ramp which does not physically MEET the deck
# above it. That bug is invisible to any assertion about angles or heights --
# the slope is right, the endpoints are right, and the slab is simply in slightly
# the wrong place -- but a player walking up stops at the top and cannot get on.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# test_ascent's three routes. Gentle is 4 cells at 1 unit each; steep is 2 cells
# at 2 units each; both finish at height 4.
const GENTLE_LANE := 3
const STEEP_LANE := 12
const START_Z := 2
const UPPER_Z := 9
const UPPER_HEIGHT := 4

# Enough to climb, not enough to walk off the far end of a 14-row fixture --
# which is what the first version did, and it reported as "fell past the ramp".
const CLIMB_TICKS := 220

var world: Node3D = null
var gentle: CharacterBody3D = null
var steep: CharacterBody3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "RampWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_ascent.seg"]
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	gentle = world.player_body(1)
	steep = world.player_body(2)

	gentle.position = _foot_of(GENTLE_LANE)
	steep.position = _foot_of(STEEP_LANE)

	# Both hold "forward" for the whole run, through the world's own input hook.
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.make(t, Vector2(0.0, -1.0), 0)

func _foot_of(lane: int) -> Vector3:
	return world.grid.cell_surface_world(Vector2i(lane, START_Z)) + Vector3(0.0, 1.2, 0.0)

func _physics_process(_delta: float) -> void:
	if gentle == null:
		return
	if world.tick < CLIMB_TICKS:
		return

	# The gentle ramp is walkable alone, and the player ends up ON the upper
	# level -- not stalled at the lip of it, and not fallen past it.
	var gentle_cell: Vector2i = world.grid.cell_of_world(gentle.position)
	check(gentle_cell.y >= UPPER_Z - 2,
		"a lone player walks up the gentle ramp (reached z = %d)" % gentle_cell.y)
	eq(world.grid.height_at(gentle_cell), UPPER_HEIGHT,
		"and is standing on the upper level")
	# Height is checked against the deck under the player's OWN cell: the bridge
	# is pitched, so a fixed expected height is only right at one row.
	near(gentle.position.y, world.grid.cell_surface_world(gentle_cell).y + 0.9, 0.25,
		"resting on it (y = %.2f)" % gentle.position.y)
	check(gentle.grounded, "and grounded rather than falling past it")

	# The steep ramp has NO single-player solution. If this ever passes, the
	# co-op gate has quietly opened and every authored "you need help here" beat
	# in the level design has stopped meaning anything.
	var steep_climb: float = steep.position.y - _foot_of(STEEP_LANE).y
	check(steep_climb < GridConfig.HEIGHT_UNIT * 2.0,
		"a lone player cannot walk up the steep ramp (gained %.2f m of %d)"
			% [steep_climb, UPPER_HEIGHT])

	_test_wide_ramp_has_no_seam()
	finish()

# A WIDE RAMP MUST BE ONE SURFACE, walkable at any lateral offset.
#
# The playtest bridge's gentle ramp is two cells wide, and built as one wedge per
# column it had a vertical seam down the middle that a flat-bottomed cylinder
# caught on. It presented as getting stuck "sometimes" -- entirely depending on
# which side of the middle you happened to walk up, which is why a single-lane
# test never saw it. This walks the seam deliberately.
func _test_wide_ramp_has_no_seam() -> void:
	var seg = SegmentData.from_file("res://segments/playtest_bridge.seg")
	if not check(seg.is_valid(), "the playtest map parses"):
		return
	var built = SegmentBuilder.build(seg)

	# Count the collision shapes covering the ramp cells. Two cells wide and two
	# long is FOUR wedges if nothing merges, one if everything does.
	var ramp_cells := 0
	for z in seg.length:
		for x in seg.width:
			if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				ramp_cells += 1
	check(ramp_cells >= 4, "the playtest map has a multi-cell ramp to check (%d cells)" % ramp_cells)

	var structure: Node = built.root.get_node("Structure")
	# Count by "not a box" rather than by a specific shape CLASS. Everything else
	# the builder emits -- deck, skirts, walls -- is a BoxShape3D, and the wedge
	# has already changed class once (convex hull -> trimesh, 2026-08-16). A test
	# that names the class goes quietly to zero on the day it changes, and
	# `0 < ramp_cells` passes just as well as the real answer does.
	var wedges := 0
	for child in structure.get_children():
		if child is CollisionShape3D and not (child.shape is BoxShape3D):
			wedges += 1
	check(wedges >= 1, "the ramp emitted a wedge collider at all (%d)" % wedges)
	# One wedge per contiguous BLOCK of ramp, not per cell and not per column.
	check(wedges < ramp_cells,
		"a wide ramp merges into fewer wedges than it has cells (%d wedges, %d cells)"
			% [wedges, ramp_cells])
	built.root.free()
