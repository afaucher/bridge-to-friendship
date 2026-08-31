extends "res://scripts/test_support/test_case.gd"

# THE LEVEL'S OWN SUPPLY COMES BACK AFTER A WIPE.
#
# Reported: "frequently after losing a round you wind up in a lobby with no
# specials on the ground."
#
# `_restart_at_checkpoint` clears every special in the world -- deliberately, so
# a checkpoint cannot be farmed by failing with a full gun -- and then puts the
# party back on ground the run is KEEPING. It said in a comment that "the authored
# pickup respawns with the segment", which is true of a segment that gets rebuilt
# and a wipe rebuilds nothing: `authored_special_cells` is a QUEUE, drained on the
# tick that ground was first built, so after that the grid no longer knew what the
# segment had supplied. Destroyed once, gone for the rest of the run.
#
# Measured before the fix: a lobby holding 12 specials holds 0 after a wipe, and
# still 0 three seconds later.
#
# The claims:
#   1. A wipe really does take them (the anti-stockpile rule still holds).
#   2. And the level's own layout is back on the ground afterwards -- hats as
#      well as specials, because an authored hat is SUPPLY. What a hat means
#      depends on where it came from: one the party earned is score and a wipe
#      takes it; one the level laid on the deck is there to be picked up again.
#   3. Twice over, without stacking two bodies on one cell -- two pickups in one
#      place is not "more supply", it is the coincident-bodies trap.
#
# CLAIM 1 IS SAMPLED INSIDE THE WIPE, NOT AFTER IT. The restock goes through the
# same pending queue the level's first load uses, and that queue is drained on the
# NEXT tick -- so a count taken a few ticks later sees the restocked world and
# reads as though nothing was ever taken. The first version of this test asserted
# exactly that and failed against a correct fix.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")

const A := 41

var world: Node3D = null
var done := false
var phase := 0
var _at := 0
var _before := 0
var _cells_before: Dictionary = {}
var _hat_cells_before: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "SupplyWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = 2024
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.LOBBY

# Loose specials by the cell they are standing on, so "how many" and "how many
# places" are two different numbers -- which is what claim 3 needs.
func _loose_by_cell() -> Dictionary:
	var out: Dictionary = {}
	for s in world._specials.all():
		if not is_instance_valid(s) or int(s.mode) == SpecialBody.Mode.HELD:
			continue
		var cell: Vector2i = world.grid.cell_of_world(s.global_position)
		out[cell] = int(out.get(cell, 0)) + 1
	return out

func _loose_hat_cells() -> Dictionary:
	var out: Dictionary = {}
	for h in world._hats.all():
		if not is_instance_valid(h) or h.mode == HatBody.Mode.WORN:
			continue
		var cell: Vector2i = world.grid.cell_of_world(h.global_position)
		out[cell] = int(out.get(cell, 0)) + 1
	return out

func _physics_process(_delta: float) -> void:
	if done or world.tick < 30:
		return
	match phase:
		0:
			world._extend_run()
			_cells_before = _loose_by_cell()
			_hat_cells_before = _loose_hat_cells()
			_before = world.special_count()
			print("[supply] the run laid out %d specials over %d cells, and %d hats"
				% [_before, _cells_before.size(), _hat_cells_before.size()])
			if not check(_before > 0 and _hat_cells_before.size() > 0,
					"the level really supplies something to lose (%d specials, %d "
						% [_before, _hat_cells_before.size()]
					+ "hats) -- every claim below is about an empty set otherwise"):
				done = true
				finish()
				return

			# --- 1. It really was taken, measured ON THE SPOT ------------------
			world._restart_at_checkpoint()
			print("[supply] the instant the wipe returns: %d specials, %d loose hats"
				% [world.special_count(), _loose_hat_cells().size()])
			eq(world.special_count(), 0,
				"the wipe takes every special first (%d left) -- a weapon carried "
					% world.special_count()
				+ "backwards through a failure would make a checkpoint a place to "
				+ "stockpile, and that rule is untouched by the restock")
			phase = 1
			_at = world.tick
		1:
			if world.tick < _at + 3:
				return
			# --- 2. And the level's layout is back ----------------------------
			var after: Dictionary = _loose_by_cell()
			var hats_after: Dictionary = _loose_hat_cells()
			print("[supply] after the wipe: %d specials over %d cells (was %d), %d hats (was %d)"
				% [world.special_count(), after.size(), _cells_before.size(),
					hats_after.size(), _hat_cells_before.size()])
			eq(after.size(), _cells_before.size(),
				"the level's own specials are on the ground again -- %d cells "
					% after.size()
				+ "stocked against the %d it laid out. What you were CARRYING is "
					% _cells_before.size()
				+ "still gone; what the LEVEL put down is there, because the party "
				+ "is about to walk through it again")
			eq(hats_after.size(), _hat_cells_before.size(),
				"and its hats too (%d against %d) -- an authored hat is supply "
					% [hats_after.size(), _hat_cells_before.size()]
				+ "rather than score, and the two were being treated as one thing")
			_worst_stack(after, "after one wipe")
			world._restart_at_checkpoint()
			phase = 2
			_at = world.tick
		2:
			if world.tick < _at + 3:
				return
			# --- 3. Twice, without stacking -----------------------------------
			var again: Dictionary = _loose_by_cell()
			print("[supply] after a second wipe: %d specials over %d cells, %d hats"
				% [world.special_count(), again.size(), _loose_hat_cells().size()])
			eq(again.size(), _cells_before.size(),
				"a second wipe restocks the same layout rather than a different one")
			eq(_loose_hat_cells().size(), _hat_cells_before.size(),
				"and the same hats")
			_worst_stack(again, "after two wipes")
			phase = 3
			_at = world.tick
		3:
			# --- 3b. THE DEDUPE PATH, WHICH NOTHING ABOVE REACHES --------------
			#
			# Both wipes above restock into an EMPTY queue, because the previous
			# drain emptied it -- so the guard against re-queuing a cell that is
			# already pending is never asked a question. It matters on the tick a
			# segment has just been built and not yet drained, which is a real
			# window and a rare one. Asked directly here rather than waited for.
			var row: int = world.grid.lobby_row_near(world.round_machine.rear_row)
			world.grid.restock_supply_from(row)
			var queued_once: int = world.grid.authored_special_cells.size()
			world.grid.restock_supply_from(row)
			var queued_twice: int = world.grid.authored_special_cells.size()
			print("[supply] restocking twice with the queue still full: %d then %d pending"
				% [queued_once, queued_twice])
			check(queued_once > 0,
				"the second restock really had something pending to collide with "
				+ "(%d) -- otherwise this phase asks nothing" % queued_once)
			eq(queued_twice, queued_once,
				"restocking a cell that is already pending adds nothing (%d -> %d) "
					% [queued_once, queued_twice]
				+ "-- the queue is drained once a tick, so a duplicate entry is two "
				+ "bodies in one place, which in this engine is the "
				+ "coincident-bodies trap rather than extra supply")
			done = true
			finish()

func _worst_stack(by_cell: Dictionary, when: String) -> void:
	# NOTHING TO SAY ABOUT AN EMPTY SET. "No cell holds two" is trivially true of
	# no cells, and asserting it there turns one failure above into three noisy
	# ones that are not about stacking at all.
	if by_cell.is_empty():
		return
	var worst := 0
	var where := Vector2i.ZERO
	for cell in by_cell:
		if int(by_cell[cell]) > worst:
			worst = int(by_cell[cell])
			where = cell
	eq(worst, 1,
		"and never two on one cell %s (worst %d at %s) -- the queue is drained "
			% [when, worst, where]
		+ "once a tick, so a restock that re-queued a cell already pending would "
		+ "put two bodies in one place, which in this engine is the "
		+ "coincident-bodies trap rather than extra supply")
