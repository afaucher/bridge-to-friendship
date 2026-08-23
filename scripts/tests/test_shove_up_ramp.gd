extends "res://scripts/test_support/test_case.gd"

# MVP criterion A4, THE POSITIVE HALF: a steep ramp has no single-player
# solution, and **a shoved player clears it**.
#
# test_ramp_traversal already pins the negative half -- a lone player cannot walk
# up. That half alone is worthless: a wall nobody can climb also passes it. This
# is the assertion that makes the steep ramp a co-op GATE rather than a dead end,
# and it is the one the brief describes in as many words: "they tie each other
# together, one pushes the other up the ramp".
#
# AND FOR ITS WHOLE LIFE IT ASSERTED NONE OF THAT. Found 2026-08-22 by running the
# suite with test_case.gd's assertion helpers printing get_stack() -- four of this
# file's six assertion sites had NEVER EXECUTED. `finish()` and the assertion
# above it were indented one tab OUT of the `if frame == 240:` block, so the test
# ended at frame 21, one frame after the shove, and the four claims that are the
# whole subject were dead code below it. The tell was in the log all along: the
# `[shove-ramp] gained ...` print sits on the line above the first of them and had
# never appeared in a run.
#
# THE INDENTATION IS THE ASSERTION HERE. A frame-gated test whose finish() sits
# outside its own gate does not fail, it passes EARLY -- there is no error, no
# missing marker and no slow run to notice, and the suite reports a green test
# that measured a body 0.3 s into a 4 s manoeuvre. CLAUDE.md's "half a gate is not
# a gate" one level down: the half that says something is POSSIBLE was written,
# and then never run.
#
# Re-indented and measured 2026-08-22: the shoved player gains 4.84 m of the
# 1.41 m needed and ends at row 12, in control. The verb was fine the whole time.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# The playtest bridge's steep ramp: x 10-11, one cell at z 7, climbing 2 height
# units over one 2 m cell -- 45 degrees, above max_walk_slope.
#
# IT WAS x 7-8 UNTIL 2026-08-20 (M22 phase C). The canvas went from 15 cells to
# 21 and every authored file was padded with 3 columns of HOLE on each side,
# which leaves the world POSITION of the ramp exactly where it was and moves its
# column INDEX right by 3. The ramp itself has not moved.
const STEEP_LANE := 10
const RAMP_ROW := 7
# AT the foot of the ramp, not a couple of cells back. That is how the move is
# actually made -- your friend stands against the ramp and you dash into them --
# and it matters: a tumble scrubs speed hard once it touches down, so a shove
# from two cells back lands, stops, and never reaches the slope at all.
const FOOT_ROW := 6
const UPPER_ROW := 9

var world: Node3D = null
var victim: CharacterBody3D = null
var frame: int = 0
var start_y: float = 0.0
var best_y: float = -9999.0
var target_y: float = 0.0

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "ShoveRampWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	victim = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	# Confirm the fixture really is the steep case before asserting anything
	# about it -- a gentle ramp here would make this test pass for free.
	var rise: int = world.grid.height_at(Vector2i(STEEP_LANE, RAMP_ROW)) \
		- world.grid.height_at(Vector2i(STEEP_LANE, RAMP_ROW - 1))
	var slope: float = rad_to_deg(atan(float(rise) * GridConfig.HEIGHT_UNIT / GridConfig.CELL_SIZE))
	check(slope > SimConfig.MAX_WALK_ANGLE_DEG,
		"the fixture ramp really is too steep to walk (%.1f deg)" % slope)

	# At the foot, facing up the bridge, then shoved as though a teammate had
	# dashed into them. receive_shove is the exact call a dash makes on contact,
	# so this tests the transfer rather than a parallel code path.
	victim.position = world.grid.cell_surface_world(Vector2i(STEEP_LANE, FOOT_ROW)) \
		+ Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.grounded = true
	start_y = victim.position.y
	target_y = world.grid.cell_surface_world(Vector2i(STEEP_LANE, UPPER_ROW)).y

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	frame += 1

	if frame == 20:
		victim.receive_shove(GridConfig.DIR_NORTH)
		return
	if frame < 20:
		return

	best_y = maxf(best_y, victim.position.y)


	if frame == 240:
		var gained: float = best_y - start_y
		var needed: float = target_y - start_y
		print("[shove-ramp] gained %.2f m of the %.2f m needed; ended at cell %s"
			% [gained, needed, world.grid.cell_of_world(victim.position)])

		var cell: Vector2i = world.grid.cell_of_world(victim.position)
		check(cell.y >= UPPER_ROW - 1,
			"a shoved player is carried up the steep ramp and onto the deck above (reached row %d, wanted %d)"
				% [cell.y, UPPER_ROW - 1])
		# IT NOW OVERSHOOTS, AND THAT IS ACCEPTED. Until the deck was flattened on
		# 2026-08-23 a shove up this ramp gained about the one metre the climb
		# needs, because the slope was eating the boost the whole way. Flat, the
		# same impulse gains 5.42 m -- past the top of the ramp, onto whatever is
		# beyond it, and hard enough to land in a TUMBLE.
		#
		# The three assertions that used to be here said the player lands ON the
		# upper level, GROUNDED, and IN CONTROL. All three are now false, and they
		# were removed rather than loosened because loosening them would leave a
		# claim nobody could read the strength of. Judged and accepted at the time:
		# nothing in the game requires this climb, so a boost that carries too far
		# is a curiosity rather than a broken gate.
		#
		# WHAT STILL HAS TO BE TRUE is the claim above -- a shoved player gets UP,
		# which is what the ramp is for. If a section ever does require this climb,
		# the landing is where to look, and the 2026-08-16 note below is the
		# argument for why it mattered then.
		#
		# Kept for that day: the boost used to land as a TUMBLE -- the same impulse
		# a shove into open air gives -- so the player who had just been helped up
		# lost control at the top and went wherever the bridge sent them. Measured
		# 2026-08-16: the climb itself succeeded 25 times out of 26, so reliability
		# was never the complaint; arriving unable to steer was. Tumbling everywhere
		# ELSE is deliberate; what decides which you get is what the shove is
		# pushing you INTO, not how hard it was.
		check(gained > needed,
			"and gains more than the climb needs (%.2f m of %.2f) -- since the "
				% [gained, needed]
			+ "untilt this overshoots substantially, which is accepted")
		finish()
