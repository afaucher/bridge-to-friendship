extends "res://scripts/test_support/test_case.gd"

# Walls are one box per RUN, not one per cell.
#
# READ THIS BEFORE CITING IT AS THE FIX FOR "PLAYERS GET SNAGGED ON WALLS". That
# playtest report (2026-08-22) is what prompted the merge, and the reasoning was
# sound by analogy: `_build_ramps` carries a note from 2026-08-08 saying per-cell
# shapes put a seam at every cell boundary and a flat-bottomed body walking a
# surface made of them stops dead, `on_wall`, with every contact reading clean.
# The deck merge has the same note from 2026-08-14. Parapets were still per-cell.
#
# **BUT THE SNAG DOES NOT REPRODUCE ON A PARAPET, AND IT WAS LOOKED FOR.** With
# the merge reverted so every wall is a box per cell again, a body driven into the
# east parapet and along it showed **zero stalled ticks and a worst tick of 91-98%
# of full pace, at approach angles of 8, 27, 45 and 73 degrees** -- identical to
# the merged build, to two decimal places on the distance. Total distance was the
# first instrument and was worse than useless: it averaged over two seconds and
# returned the SAME 8.43 m either way. Per-tick progress is sharper and still
# found nothing.
#
# So: the merge is kept because it is a real reduction (22 walled faces became 3
# boxes on this fixture) and it removes a known hazard class by construction, and
# claim 1 below is a REGRESSION GUARD rather than a demonstration. What Aaron hit
# is most likely something else -- the deck's own merged rectangles, a ramp-deck
# junction, a half-wall or a stone -- and is still open. Do not close that report
# on the strength of this file.
#
# The claims:
#   1. A body pressed into a parapet and walking along it keeps full pace, every
#      tick. Guards the property; does not prove the fix, see above.
#   2. THE WALL STILL BLOCKS. Merging boxes is exactly the sort of change that can
#      pass claim 1 by deleting the wall, and CLAUDE.md has the scar from a
#      barrier that was built, positioned, replicated, drawn, and on a layer
#      nothing masked -- so this walks a body INTO the wall under power and
#      asserts it does not get through.
#   3. THE RUNS REALLY MERGED. A structural count, and after the A/B above it is
#      the ONLY assertion here that a revert would fail -- which is exactly why it
#      is worth having.
#
# THE EAST EDGE OF test_flat, deliberately: it is solid deck for all twelve rows,
# so the parapet along it is one unbroken 24 m run. The WEST edge has a `no_wall`
# patch at rows 4-5 and would have measured a wall with a hole in it.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentBuilder = preload("res://scripts/grid/segment_builder.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var walker: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

# Into the wall (+X, east) and up the bridge (-Z) at the same time. The diagonal
# is the whole point: a body merely walking parallel to a wall never touches it,
# and a seam only catches something pressed against it.
var drive: Vector2 = Vector2(1.0, -1.0).normalized()

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "WallWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	walker = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, drive, 0)

func _physics_process(_delta: float) -> void:
	if walker == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_slides_the_length_of_it()
		1: _phase_but_it_still_blocks()
		2: _phase_the_runs_merged()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. It does not snag ------------------------------------------------------

func _phase_slides_the_length_of_it() -> void:
	if phase_frame == 1:
		# ROW 1, WITH THE WHOLE FIXTURE AHEAD. `DIR_NORTH` is -Z and cell z + 1, so
		# driving "north" walks UP the row indices -- the first version of this
		# started at row 10 with one row of runway, walked off the end of a 12-row
		# fixture, and reported 7.58 m of lateral drift that was a body falling.
		# Not IN the last column either: spawned inside the wall the solver would
		# eject it, and an ejection is not a walk.
		_park(Vector2i(28, 1))
		return
	if phase_frame == 20:
		recorded["from"] = walker.position
		recorded["last_z"] = walker.position.z
		recorded["stalls"] = 0
		recorded["worst"] = 1.0
		return
	# PER-TICK PROGRESS, NOT TOTAL DISTANCE, and the first version of this phase
	# measured the total. THE A/B IS WHY: with the merge reverted and the parapet
	# built a box per cell, the body still covered 8.43 m in 120 ticks -- the same
	# number, to two decimals, as the merged build. A snag is a TICK, and a
	# two-second total averages it away completely. Same shape as CLAUDE.md's note
	# that a max answers "did it ever" and a duty cycle answers "is it running".
	if phase_frame > 20 and phase_frame <= 20 + TRAVEL_TICKS:
		var step: float = absf(walker.position.z - float(recorded["last_z"]))
		var full: float = SimConfig.WALK_SPEED * absf(drive.y) * SimConfig.TICK_DELTA
		var fraction: float = step / full
		recorded["last_z"] = walker.position.z
		recorded["worst"] = minf(float(recorded["worst"]), fraction)
		if fraction < 0.5:
			recorded["stalls"] = int(recorded["stalls"]) + 1
	if phase_frame == 20 + TRAVEL_TICKS:
		var moved: float = absf(walker.position.z - float(recorded["from"].z))
		var wanted: float = SimConfig.WALK_SPEED * drive.length() * 0.5 \
			* float(TRAVEL_TICKS) * SimConfig.TICK_DELTA
		print("[wall] slid %.2f m in %d ticks (wanted %.2f); %d stalled ticks, "
			% [moved, TRAVEL_TICKS, wanted, recorded["stalls"]]
			+ "worst tick %.0f%% of full pace" % (float(recorded["worst"]) * 100.0))
		check(moved > wanted,
			"a body pressed into a parapet walks the length of it (%.2f m of %.2f)"
				% [moved, wanted])
		eq(int(recorded["stalls"]), 0,
			"and never checks against a seam on the way -- not one tick under half "
			+ "pace in %d" % TRAVEL_TICKS)
		# AND IT REALLY WAS TOUCHING IT. Without this the phase is satisfied by a
		# body that drifted away from the wall on tick one and had a clear walk --
		# which is not the case anybody reported.
		var gap: float = absf(walker.position.x - float(recorded["from"].x))
		check(gap < 3.0,
			"and stayed against it the whole way (%.2f m of lateral drift)" % gap)
		# AND IT WAS STILL ON THE BRIDGE, which is how the first run of this phase
		# "passed" its distance claim: a body that walks off the end keeps moving,
		# and a distance assertion has no opinion about whether the ground was
		# still under it.
		check(absf(walker.position.y - float(recorded["from"].y)) < 1.0,
			"on the deck the whole way (%.2f m of fall)"
				% (float(recorded["from"].y) - walker.position.y))
		_advance(1)

# Two seconds of walking, which at WALK_SPEED crosses most of the fixture.
const TRAVEL_TICKS := 120

# --- 2. And the wall is still a wall ------------------------------------------

func _phase_but_it_still_blocks() -> void:
	if phase_frame == 1:
		drive = Vector2(1.0, 0.0)          # straight east, into the parapet
		_park(Vector2i(28, 6))
		return
	if phase_frame == 20:
		recorded["x"] = walker.position.x
		return
	if phase_frame == 140:
		var pushed: float = walker.position.x - float(recorded["x"])
		print("[wall] %.2f m gained walking into the parapet for 2 s" % pushed)
		check(pushed < 1.2,
			"a parapet still stops a body walking into it (%.2f m gained)" % pushed)
		check(walker.position.y > float(recorded["x"]) - 1000.0 \
			and walker.position.y > -5.0,
			"and it is still on the bridge rather than through the edge")
		_advance(2)

# --- 3. The structure, so a revert is named here ------------------------------
#
# A COUNT, NOT A BEHAVIOUR, and it is here because claim 1 is a walk: CLAUDE.md's
# note is that a gate can walk over a hole for months. If the merge is undone, the
# walk may well still pass on the day -- seam catches are famously "sometimes" --
# and this will not.

func _phase_the_runs_merged() -> void:
	if phase_frame != 1:
		return
	var seg = SegmentData.from_file("res://segments/test_flat.seg")
	check(seg != null, "the fixture parsed")
	if seg == null:
		finish()
		return

	var cells_with_walls := 0
	for z in seg.length:
		for x in seg.width:
			for dir in 4:
				if seg.has_wall(x, z, dir):
					cells_with_walls += 1

	var built = SegmentBuilder.build(seg, 0, 0)
	print("[wall] %d walled cell-faces became %d boxes"
		% [cells_with_walls, built.wall_box_count])

	check(built.wall_box_count > 0, "the fixture has parapets at all")
	# THE RATIO IS THE CLAIM. Per-cell building makes these two numbers EQUAL by
	# construction, so any merging at all separates them -- an arithmetic
	# impossibility rather than a threshold somebody picked. Halved is a long way
	# clear of "one or two runs happened to be length 1".
	check(built.wall_box_count < cells_with_walls / 2,
		"and they are built as runs, not per cell (%d boxes for %d faces)"
			% [built.wall_box_count, cells_with_walls])
	built.root.queue_free()
	finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	walker.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	walker.velocity = Vector3.ZERO
	walker.state = PlayerBody.State.WALK
	walker.grounded = true
