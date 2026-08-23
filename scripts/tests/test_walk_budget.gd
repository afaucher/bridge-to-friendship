extends "res://scripts/test_support/test_case.gd"

# THE WALKING CEILING, and what it is NOT.
#
# THIS FILE MEASURES A DENOMINATOR, NOT A BUDGET. Read carelessly it says a
# section should be twenty-nine times longer than anything authored -- which is
# wrong, and was written down as a conclusion on 2026-08-15 before a playtest
# corrected it. The number here is the speed of a body holding full stick in a
# straight line on clear deck with nothing in the way, and NO METRE OF THIS GAME
# IS ANY OF THOSE THINGS.
#
# THERE IS NO SUCH THING AS "THE LENGTH OF THE DEMO LEVEL", and two wrong
# conclusions on 2026-08-15 came from assuming there was.
#
# Solo (main.gd `_on_local_pressed`) sets `assemble_run`, which builds
# RUN_INITIAL_SEGMENTS and then keeps RUN_LOOKAHEAD_SEGMENTS ahead of the lead
# player FOREVER. `playtest_bridge` is the FIRST SEGMENT of an unbounded run, not
# a level with an end. So a session covers many segments, and comparing a
# five-minute play report against one segment's 60 m compares a session to a
# fraction of its opening stretch.
#
# WHAT M16 CHANGES, and the open question it leaves: a ROUND is now one section
# segment, 16 to 30 rows, 32 to 60 m. Whether that is five minutes of play is not
# knowable from anything in this file and is not knowable from a play report
# about the endless run either -- it needs somebody to play a round, with the
# round clock the HUD now shows. Until then the section size is UNVALIDATED.
#
# What the ceiling below does establish, and all it establishes: walking is fast
# relative to any distance authored so far, so distance is a weak lever on how
# long anything takes. Thirty more metres of empty deck is five seconds.
#
# THE MEASUREMENT: 5.88 m/s on clear deck, 98% of WALK_SPEED -- the missing 2% is
# the four-degree pitch, and that is the whole difference between the arithmetic
# and the world. It is kept because it is the denominator every "how much of the
# round was spent moving" question needs, and because a constant nobody has
# checked against the running game is a constant that has drifted.
#
# IT IS NOT EVIDENCE ABOUT HOW LONG A SECTION TAKES. Only playing one is, and the
# only such evidence is a human report. If that ever needs to be a gate, the rig
# is a party on a live playtest_bridge timed end to end -- not this.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# A short measured window, extrapolated. Simulating the full five minutes is
# 18,000 ticks per sample and buys nothing: a body at terminal walking speed on
# uniform deck covers the next second exactly like the last one, and the run-up
# is subtracted out by measuring between two marks rather than from the start.
# CLEAR DECK, AND NOT VERY MUCH OF IT. The first version of this walked the
# PLAYTEST BRIDGE and measured 0.68 m/s -- eleven per cent of WALK_SPEED -- which
# is not a walking speed, it is a body standing at the lip of the cliff at z7
# with the stick held down. It was measuring the level, not the walk.
#
# This project already has the rule ("measure on a fixture with nothing else
# moving in it", "before believing a rig, check what it does on a case that must
# be clean") and the first draft broke it anyway. The clean case is a flat
# segment and a lane with no holes in it: test_flat's x = 2 is solid for its
# whole length, while the hole field at z6 starts at x = 4.
const LANE_X := 2
const SETTLE_TICKS := 30           # half a second to reach terminal speed
const SAMPLE_TICKS := 120          # two seconds, which is 12 m of a 22 m lane

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0
var mark: Vector3 = Vector3.ZERO
var wander: float = 0.0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "WalkBudgetWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	body.position = world.grid.cell_surface_world(Vector2i(LANE_X, 0)) 		+ Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

	# STRAIGHT UP-BRIDGE, FULL STICK. -Z is up-bridge (GridConfig).
	world.scripted_inputs[1] = func(t: int) -> Array:
		return [t, Vector2(0.0, -1.0), 0, body.facing]

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1
	if frames == SETTLE_TICKS:
		mark = body.position
		return
	if frames < SETTLE_TICKS:
		return
	# STRICTLY LESS THAN, so the measurement lands exactly SAMPLE_TICKS after the
	# mark. It was <=, which sampled SAMPLE_TICKS + 1 ticks of travel and divided
	# by SAMPLE_TICKS -- an 0.83% overshoot that only became visible when the
	# bridge was flattened on 2026-08-23 and the up-bridge speed became exactly
	# WALK_SPEED. It reported 6.05 m/s against a ceiling of 6.00, which is 121/120
	# to the decimal, and the ceiling assertion is what caught it.
	if frames < SETTLE_TICKS + SAMPLE_TICKS:
		wander += absf(body.velocity.x) * SimConfig.TICK_DELTA
		return

	var travelled: Vector3 = body.position - mark
	var seconds: float = float(SAMPLE_TICKS) * SimConfig.TICK_DELTA
	var up_bridge: float = -travelled.z          # -Z is up-bridge
	var path: float = travelled.length()

	var per_second: float = up_bridge / seconds
	var in_five: float = per_second * RoundMachine.TARGET_SECONDS
	var cells: float = in_five / GridConfig.CELL_SIZE

	print("[walk] %.1f s sampled: %.1f m up-bridge (%.2f m/s), %.1f m of path"
		% [seconds, up_bridge, per_second, path])
	print("[walk] FIVE MINUTES = %.0f m = %.0f cells = %.1f playtest_bridge lengths"
		% [in_five, cells, cells / 30.0])
	print("[walk] ceiling (WALK_SPEED x %ds) = %.0f m; measured is %.0f%% of it"
		% [int(RoundMachine.TARGET_SECONDS),
			SimConfig.WALK_SPEED * RoundMachine.TARGET_SECONDS,
			100.0 * per_second / SimConfig.WALK_SPEED])
	# THE LEVEL'S LENGTH IS GEOMETRY, NOT A WALK. playtest_bridge is 30 cells by
	# its own header; walking it to find that out would just re-measure the
	# hazards in it, which is what the first draft of this file accidentally did.
	var demo_m: float = 30.0 * GridConfig.CELL_SIZE
	print("[walk] the demo level is 30 cells = %.0f m -- %.0f s of clear walking, %.0f%% of the budget"
		% [demo_m, demo_m / per_second,
			100.0 * (demo_m / per_second) / RoundMachine.TARGET_SECONDS])

	# THE INSTRUMENT IS VALID. A body that never moved would report a beautifully
	# consistent zero, and the whole point of this file is a number nobody has to
	# take on faith.
	check(up_bridge > 10.0, "the probe really walked (%.1f m)" % up_bridge)
	check(per_second > 0.5 * SimConfig.WALK_SPEED,
		"at something like walking pace (%.2f of %.1f m/s)"
			% [per_second, SimConfig.WALK_SPEED])
	check(per_second <= SimConfig.WALK_SPEED + 0.01,
		"and never faster than WALK_SPEED -- a measurement above the ceiling is a "
		+ "broken instrument, not a fast player (%.2f m/s)" % per_second)

	# WALK_SPEED IS STILL WHAT IT SAYS IT IS. That is the whole standing claim --
	# a constant this file can catch drifting, and nothing more. The ratio to a
	# section's length is PRINTED and deliberately NOT asserted: a playtest puts a
	# section at about five minutes, which no measurement in here can see, and an
	# assertion about it would be this file claiming authority it does not have.
	near(per_second, SimConfig.WALK_SPEED, 0.4,
		"clear-deck walking is WALK_SPEED less the pitch (%.2f of %.1f m/s)"
			% [per_second, SimConfig.WALK_SPEED])
	finish()
