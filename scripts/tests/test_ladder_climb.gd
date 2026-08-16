extends "res://scripts/test_support/test_case.gd"

# M17 phase 6: climbing a ladder.
#
# THE GLYPH HAS BEEN AUTHORABLE SINCE M2 and the validator has counted it as a
# way up ever since -- with nothing in the game able to climb one. That
# disagreement was found in this milestone and held shut with
# SegmentValidator.LADDERS_CLIMBABLE = false; this is the work that lets it be
# true, so the test has to prove the BODY does what the FLOOD claims.
#
# The fixture is a two-unit cliff with no ramp anywhere, so the ladder is the
# only way up and the test can actually fail.
#
# The claims:
#   1. A body pushing into a ladder from below CLIMBS IT and arrives on the deck.
#      Measured as a position, not a state -- entering CLIMB and going nowhere
#      would satisfy a state check perfectly.
#   2. The validator agrees, and BOTH halves are asserted: with ladders climbable
#      the cliff is passable, and the same fixture with the ladder removed is not.
#      Without the second, "passable" is satisfied by a validator that passes
#      everything.
#   3. A climb is not a free ride: it is SLOWER than walking the same distance.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const LADDER_CELL := Vector2i(2, 4)

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0
var climbed_ticks: int = 0
var best_y: float = -99.0

func setup(main) -> void:
	timeout_seconds = 45.0
	_check_validator()

	world = Node3D.new()
	world.name = "LadderWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_ladder.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	# At the foot of the cliff, walking into it.
	body.position = world.grid.cell_surface_world(Vector2i(2, 3)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	# STOP PUSHING ONCE YOU ARE UP. Holding forward forever walked the climber
	# straight off the far end of an eight-row fixture and the test caught them
	# mid-fall -- the same "a rig that holds a movement input walks the player off
	# the map" note CLAUDE.md already carries. Release the stick once the moment
	# being measured has passed.
	# PUSH UNTIL THE CLIMB ENDS, then stop -- not until a HEIGHT is reached. A
	# height cut-off fired just below the exit threshold and deadlocked the
	# climber hovering on the ladder above the lip: the test still passed, because
	# "higher than the cliff top" is true of somebody hanging over it. Ask the
	# state, which is the thing that actually says the climb is done.
	world.scripted_inputs[1] = func(t: int) -> Array:
		var climbing: bool = body.state == PlayerBody.State.CLIMB 			or body.position.y - PlayerBody.HALF_HEIGHT < world.grid.cell_surface_world(LADDER_CELL).y - 0.2
		return [t, Vector2(0.0, -1.0) if climbing else Vector2.ZERO, 0, body.facing]

# --- 2. The validator, both ways ---------------------------------------------

func _check_validator() -> void:
	var seg = SegmentData.from_file("res://segments/test_ladder.seg")
	check(seg.is_valid(), "the fixture parses")
	check(SegmentValidator.LADDERS_CLIMBABLE,
		"ladders are climbable now -- the flag exists because for months they "
		+ "were not, and the flood said otherwise")
	eq(SegmentValidator.validate(seg).size(), 0,
		"a cliff with a ladder up it is passable")

	# THE SAME FIXTURE WITHOUT THE LADDER. Without this half, "passable" would be
	# satisfied by a validator that passes everything.
	var bare = SegmentData.from_file("res://segments/test_ladder.seg")
	bare.contents[LADDER_CELL.y][LADDER_CELL.x] = GridConfig.Content.NONE
	check(SegmentValidator.validate(bare).size() > 0,
		"and the same cliff WITHOUT it is not -- so it is the ladder doing it")

# --- 1 and 3. The body actually goes up ---------------------------------------

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1
	best_y = maxf(best_y, body.position.y)
	if body.state == PlayerBody.State.CLIMB:
		climbed_ticks += 1
	if frames < 180:
		return

	var top: float = world.grid.cell_surface_world(LADDER_CELL).y
	var row: int = world.grid.cell_of_world(body.position).y
	print("[ladder] after 3s: y %.2f (cliff top %.2f), row %d, %d ticks climbing"
		% [body.position.y, top, row, climbed_ticks])

	# STANDING ON THE DECK, not hovering over it. Both halves are needed and the
	# first draft had only the height: "higher than the cliff top" is also true of
	# a climber stuck on the ladder above the lip, which is exactly what a
	# deadlocked exit looks like and exactly what it passed with.
	check(body.position.y > top,
		"a body pushing into a ladder from below ends up ON TOP of the cliff "
		+ "(y %.2f against a top of %.2f)" % [body.position.y, top])
	eq(body.state, PlayerBody.State.WALK,
		"and is WALKING again rather than still on the ladder")
	check(body.grounded, "with its feet on something")
	check(row >= LADDER_CELL.y,
		"on the far side of the cliff (row %d, ladder at %d)" % [row, LADDER_CELL.y])
	check(climbed_ticks > 10,
		"having actually climbed rather than been nudged up (%d ticks)" % climbed_ticks)

	# A LADDER COSTS TIME, which is what pays for it being the compact way up: it
	# climbs any height in one cell where a ramp needs a cell per unit.
	check(SimConfig.CLIMB_SPEED < SimConfig.WALK_SPEED,
		"and a climb is slower than a walk (%.1f against %.1f) -- the price of a "
			% [SimConfig.CLIMB_SPEED, SimConfig.WALK_SPEED]
		+ "ladder is time spent somewhere you cannot dodge or shoot")
	finish()
