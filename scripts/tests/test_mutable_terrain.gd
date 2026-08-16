extends "res://scripts/test_support/test_case.gd"

# M17 phase 8: mutable terrain.
#
# One mechanism -- a cell stops being solid at runtime -- with two authored
# triggers. The design doc wanted "destroyable squares" and "timed blocks" as
# separate features; they are the same sentence with a different subject, and
# building the removal once makes both fall out.
#
# The claims:
#   1. A CRUMBLE CELL IS SOLID UNTIL IT IS STOOD ON. Asserted as a body resting
#      on it, not as a flag: a cell whose collider was never built passes any
#      state check about being "closed" perfectly.
#   2. It goes, and the player standing there falls. The delay is the mechanic --
#      a cell that vanished on contact would be an invisible instant-death line.
#   3. IT COMES BACK. 2b: an edge that exists ONCE strands a party of four the
#      moment the first across drops the floor. This is the assertion that keeps
#      the flood's "solid" answer honest.
#   4. A TIMED CELL runs on its own clock and its neighbours are OUT OF PHASE, so
#      a row of them is a rhythm rather than a wall that blinks in unison.
#   6. A CLOSE WAITS FOR THE VOLUME TO BE EMPTY. This one was not designed into
#      the fixture -- the crumble dropped the player onto the lip of its own hole
#      and they hung there, inside the slab's volume, for eight seconds. That is
#      the coincident-body trap in CLAUDE.md with a wall instead of a player, and
#      it is the whole reason mutable cells are host-owned and broadcast rather
#      than a pure function of the tick that each machine derives: a rule with an
#      authoritative exception is not a rule two machines can each compute.
#   5. THE FLOOD ROUTES THROUGH THEM. The fixture's only crossing is the mutable
#      isthmus, so a validator that treated a temporary cell as a hole would
#      reject it -- and would then reject every segment ever built from these.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const CRUMBLE_CELL := Vector2i(2, 4)
const TIMED_LEFT := Vector2i(1, 4)
const TIMED_RIGHT := Vector2i(3, 4)

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0

# Claim 1: it held a body up before anything happened to it.
var rested_ticks: int = 0
# Claims 2 and 3, recorded when they happen rather than sampled at the end --
# the cell is closed again by then, so the end knows nothing about either.
var opened_frame: int = -1
var fell_frame: int = -1
var closed_frame: int = -1
# Claim 4: every distinct open/closed pattern the two timed cells were seen in.
var timed_patterns: Dictionary = {}
# Claim 6: ticks the restore was DUE and refused because somebody was in the way.
var deferred_ticks: int = 0

func setup(main) -> void:
	timeout_seconds = 60.0
	_check_the_flood_routes_through()

	world = Node3D.new()
	world.name = "MutableWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_mutable.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	# Placed ON the crumble cell, standing still. No stick at all: what is being
	# measured is what the CELL does, and a walking body would confound "the floor
	# went" with "I walked off it".
	body.position = world.grid.cell_surface_world(CRUMBLE_CELL) 		+ Vector3(0.0, PlayerBody.HALF_HEIGHT + 0.05, 0.0)
	body.velocity = Vector3.ZERO
	world.scripted_inputs[1] = func(t: int) -> Array:
		return [t, Vector2.ZERO, 0, body.facing]

# --- 5. The oracle routes through a temporary cell ----------------------------

func _check_the_flood_routes_through() -> void:
	var seg = SegmentData.from_file("res://segments/test_mutable.seg")
	check(seg.is_valid(), "the fixture parses")
	eq(SegmentValidator.validate(seg).size(), 0,
		"a segment whose ONLY crossing is a row of mutable cells is valid -- 2b: "
		+ "an edge that exists periodically is available at a cost in time, "
		+ "because a party can wait, and the round clock is where that is paid")

	# THE OTHER HALF. Without it, "valid" is satisfied by an oracle that passes
	# everything -- and this fixture is one glyph away from being a real hole.
	var bare = SegmentData.from_file("res://segments/test_mutable.seg")
	for cell in [CRUMBLE_CELL, TIMED_LEFT, TIMED_RIGHT]:
		bare.kinds[cell.y][cell.x] = GridConfig.Kind.HOLE
	check(SegmentValidator.validate(bare).size() > 0,
		"and the same fixture with that row cut out is not -- so the isthmus is "
		+ "genuinely the only way across and the flood genuinely used it")

	# THE MERGE MUST REFUSE THEM, which is the entire reason this feature is cheap
	# rather than a re-merge and a shape re-upload per removed cell.
	check(SegmentBuilder.is_mutable(seg, CRUMBLE_CELL.x, CRUMBLE_CELL.y),
		"a crumble cell is excluded from the greedy deck merge")
	check(not SegmentBuilder.is_mutable(seg, 2, 2),
		"and ordinary deck is not -- the merge still does its job on everything "
		+ "that never moves")

# --- 1 to 4. What the cells actually do ---------------------------------------

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1

	var open: bool = world.grid.is_cell_open(CRUMBLE_CELL)
	if not open and opened_frame < 0:
		# RESTING, not merely present. A slab that was never built would satisfy
		# "the cell is closed" and drop the body on frame one.
		if body.grounded:
			rested_ticks += 1
	elif open and opened_frame < 0:
		opened_frame = frames
	if opened_frame > 0 and fell_frame < 0 and not body.grounded 			and body.position.y < world.grid.cell_surface_world(CRUMBLE_CELL).y:
		fell_frame = frames
	if opened_frame > 0 and closed_frame < 0 and not open:
		closed_frame = frames

	# Claim 4, sampled every tick: the pair of timed cells seen as a two-bit
	# pattern. Out of phase means the pattern takes more than one value.
	var pattern: String = "%s%s" % [
		"o" if world.grid.is_cell_open(TIMED_LEFT) else ".",
		"o" if world.grid.is_cell_open(TIMED_RIGHT) else "."]
	timed_patterns[pattern] = true

	# Claim 6, and it was not planned: the clock ran out and the cell STAYED open,
	# because the player it dropped had caught the lip of the hole and was hanging
	# inside the volume the slab would occupy.
	if open and float(world._restore_timer.get(CRUMBLE_CELL, 1.0)) <= 0.0:
		deferred_ticks += 1
	# Run until the crumble has been all the way round: solid, gone, back.
	if closed_frame < 0 and frames < 900:
		return

	print("[mutable] rested %d ticks, opened f%d, fell f%d, closed f%d, timed seen %s"
		% [rested_ticks, opened_frame, fell_frame, closed_frame,
			str(timed_patterns.keys())])

	# 1. IT HELD SOMEBODY UP FIRST.
	check(rested_ticks > int(SimConfig.CRUMBLE_DELAY * 0.5 / SimConfig.TICK_DELTA),
		"a crumble cell carries a standing body before it goes (%d ticks) -- the "
			% rested_ticks
		+ "delay is the mechanic: a cell that vanished on contact would be an "
		+ "invisible instant-death line rather than a decision")

	# 2. THEN IT GOES, AND SO DO YOU.
	check(opened_frame > 0, "it opens under the weight of somebody standing on it")
	check(fell_frame > 0,
		"and the body it was holding falls THROUGH it -- the collider really left, "
		+ "which no flag can tell you")

	# 3. AND IT COMES BACK.
	check(closed_frame > opened_frame,
		"it restores (open f%d, closed f%d) -- an edge that exists ONCE strands "
			% [opened_frame, closed_frame]
		+ "every player who was not first across, with nothing to tell them why")

	check(deferred_ticks > 60,
		"and it waited for the volume to clear before it did (%d ticks past due) "
			% deferred_ticks
		+ "-- a slab rebuilt around the body hanging in it is the coincident-body "
		+ "trap, and waiting is free")

	# 4. NEIGHBOURS OUT OF PHASE.
	check(timed_patterns.size() > 2,
		"two adjacent timed cells are out of phase (%d distinct patterns) -- a row "
			% timed_patterns.size()
		+ "of them is a rhythm to read, not a wall that blinks in unison")
	finish()
