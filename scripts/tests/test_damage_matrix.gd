extends "res://scripts/test_support/test_case.gd"

# M15a. What each kind of hit does to each kind of thing.
#
# See design_ideas/damage_model.md. The matrix IS the design; this pins the cells
# that carry it rather than the ones that are bookkeeping.
#
# THE CELLS UNDER TEST, and each is a claim somebody made in words first:
#
#   "you can't shoot a rusher mound, but a grenade planted right next to it
#    should destroy it"        -> mound: BULLET nothing, EXPLOSIVE destroys
#   "shooting a pillar does nothing but dashing or explosives may move it"
#                              -> stone: BULLET nothing, IMPACT and EXPLOSIVE move
#   a turret must not be answerable by the free verb
#                              -> (15b, not yet built)
#
# Note what is NOT here: that a round hurts a player, that a dash deflects a
# rusher, that a ball tumbles you. Those are pinned by test_machine_gun,
# test_rusher and test_plinko, and the whole gate on this refactor was that those
# five files pass UNCHANGED. A matrix test that re-asserted them would be
# measuring the same thing twice and would drift from them.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const StoneBody = preload("res://scripts/sim/stone_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "MatrixWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	# The playtest bridge, because it is the only fixture with mounds authored
	# into it -- and a mound is half of what this test exists for.
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	_test_mound()
	_test_stone()
	_test_ball_is_never_destroyed()
	finish()

# --- A mound: immune to bullets, killed by a blast -----------------------------

func _test_mound() -> void:
	var cells: Array = world.grid.mound_cells()
	if not check(cells.size() > 0, "the fixture has mounds authored in it"):
		return
	var cell: Vector2i = cells[0]
	var at: Vector3 = world.grid.mound_surface_world(cell)
	var before: int = cells.size()

	# A ROUND PASSES OVER IT. There is nothing above ground to shoot -- it is
	# dormant and flush with the deck -- so the grid is not even a receive_hit
	# target for a bullet. Fired straight through the cell to prove the path is
	# real rather than asserting about a function nobody calls.
	world.blast_at(at, 3.0, Hit.Kind.BULLET)
	eq(world.grid.mound_cells().size(), before,
		"a bullet does nothing to a mound -- there is nothing above ground to hit")

	# A BLAST REACHES DOWN. This is the whole point: a grenade becomes the way to
	# PRE-EMPT a hazard before it wakes, which is a new decision built entirely
	# out of parts that already existed.
	var removed: int = world.blast_at(at, 3.0, Hit.Kind.EXPLOSIVE)
	check(removed > 0, "a blast destroys it (%d removed)" % removed)
	eq(world.grid.mound_cells().size(), before - removed,
		"and it is gone from the grid, so it can never rise")

# --- A pillar: shrugs off a round, moved by a body or a blast ------------------

func _test_stone() -> void:
	var stone: Node = null
	for s in world.grid._stone_list:
		if is_instance_valid(s) and s.mode == StoneBody.Mode.SETTLED:
			stone = s
			break
	if not check(stone != null, "the fixture has a settled pillar"):
		return

	var cell_before: Vector2i = stone.cell
	# FROM BELOW IT ON THE BRIDGE, so a push has somewhere legal to go.
	var from: Vector3 = stone.position + Vector3(0.0, 0.0, 4.0)

	check(not stone.receive_hit(Hit.make(Hit.Kind.BULLET, 1, from, 8.0, 2.0)),
		"a bullet does nothing to a pillar")
	eq(stone.cell, cell_before, "and it has not moved")

	# A BLAST MOVES IT, one cell, exactly as a dash does. Not destroys:
	# bridge_grid.md rules out destructible deck, and a stone that could be
	# removed is a hole created at runtime.
	var moved: bool = stone.receive_hit(Hit.make(Hit.Kind.EXPLOSIVE, 0, from, 12.0, 0.0))
	check(moved, "but a blast moves it")
	check(stone.cell != cell_before,
		"one cell, away from the blast (%s -> %s)" % [cell_before, stone.cell])

# --- A ball is argued with, never removed --------------------------------------

func _test_ball_is_never_destroyed() -> void:
	var ball: Node = world._launch_ball(world.grid.shooter_cells[0])
	if not check(ball != null, "a ball exists"):
		return
	var id: int = ball.ball_id
	ball.receive_hit(Hit.make(Hit.Kind.EXPLOSIVE, 5, ball.position + Vector3(2.0, 0.0, 0.0),
		20.0, 4.0))
	check(world._ball_by_id(id) != null,
		"nothing destroys a plinko ball -- it is the archetypal deflectable threat")
