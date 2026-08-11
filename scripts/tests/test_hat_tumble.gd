extends "res://scripts/test_support/test_case.gd"

# M8.5: losing hats, and the two different ways it happens.
#
#   TUMBLE or LEDGE_HANG pops the WHOLE STACK onto the deck, scattered. They are
#   still in the world and anyone can walk over and take them -- including you,
#   once they have settled.
#
#   FALLING OUT OF THE WORLD destroys them outright. Confirmed by playtest
#   2026-08-10: if you fall, you lose them. Dropping them where you went over
#   would rescue the one failure the design deliberately does not rescue, and
#   would leave a free pile at the exact spot that just killed you.
#
# Plus the settle grace, which is the thing standing between "the tumble cost you
# your hats" and "you rolled through them and picked them straight back up".

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 50.0
	world = Node3D.new()
	world.name = "HatTumbleWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	# A SECOND PLAYER, PARKED FAR AWAY AND SAFE, and phase 4 does not work without
	# them. A solo player falling out of the world is the whole party being out,
	# which is a wipe -- and _restart_at_checkpoint clears every hat, so "the hats
	# are gone" would be true whether or not falling destroys them. Verified by
	# A/B: with one player the phase passes even with the rule removed.
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_whole_stack_pops()
		1: _phase_settle_grace()
		2: _phase_hang_pops_too()
		3: _phase_falling_destroys()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. The whole stack, and no two hats from the same point ------------------

func _phase_whole_stack_pops() -> void:
	if phase_frame == 1:
		_wear(3)
		return
	if phase_frame == 6:
		eq(world.hats_worn_by(1).size(), 3, "wearing three")
		a.begin_tumble(Vector3(6.0, 2.0, 0.0))
		return
	if phase_frame == 7:
		# THE WHOLE STACK, not the top hat. Popping one would make hats a
		# slowly-eroding counter; popping the stack makes carrying five a running,
		# escalating, visible bet -- and it means the reward curve and the risk
		# curve are the same curve, so there is no second lever to balance.
		eq(world.hats_worn_by(1).size(), 0, "entering TUMBLE pops the WHOLE stack")
		eq(world.hat_count(), 3, "and all three are still in the world")

		# NO TWO FROM THE SAME POINT. Two bodies spawned coincident depenetrate
		# straight through the floor -- the trap CLAUDE.md opens with -- which is
		# why the scatter is a deterministic fan rather than a random direction.
		var seen: Array = []
		for hat in world._hats.all():
			for other in seen:
				check(hat.position.distance_to(other) > 0.01,
					"hats leave from distinct points (%.3f m apart)"
						% hat.position.distance_to(other))
			seen.append(hat.position)
		_advance(1)

# --- 2. None of them is collectable until it has settled ----------------------

func _phase_settle_grace() -> void:
	if phase_frame == 1:
		# The player is still mid-tumble from the phase above; put them back on
		# their feet ON TOP of the scattered hats. Under a naive rule they would
		# now re-collect the lot.
		a.state = PlayerBody.State.WALK
		a.velocity = Vector3.ZERO
		a.grounded = true
		var centre := Vector3.ZERO
		for hat in world._hats.all():
			centre += hat.position
		centre /= float(maxi(world._hats.count(), 1))
		a.position = centre + Vector3(0.0, 0.9, 0.0)
		recorded["flying"] = 0
		return
	if phase_frame == 3:
		for hat in world._hats.all():
			if hat.mode == HatBody.Mode.FLYING:
				recorded["flying"] = int(recorded["flying"]) + 1
		check(int(recorded["flying"]) > 0, "the scattered hats are still FLYING")
		eq(world.hats_worn_by(1).size(), 0,
			"and a player standing in them collects none of them")
		return
	# The scatter throws them a couple of cells, so by now they are nowhere near
	# where the player was standing when they popped -- walk over to one rather
	# than assuming they landed underfoot.
	if phase_frame == int(SimConfig.HAT_SETTLE_GRACE * 60.0) + 90:
		var settled: Node = null
		for hat in world._hats.all():
			if hat.is_collectable():
				settled = hat
				break
		if not check(settled != null, "the scattered hats settle and become collectable"):
			_advance(2)
			return
		a.position = settled.position + Vector3(0.0, 0.9, 0.0)
		a.velocity = Vector3.ZERO
		a.state = PlayerBody.State.WALK
		a.grounded = true
		return
	if phase_frame == int(SimConfig.HAT_SETTLE_GRACE * 60.0) + 100:
		# ...and afterwards they ARE collectable, which is what stops the grace
		# being a permanent ban rather than a delay.
		check(world.hats_worn_by(1).size() > 0,
			"once settled, they can be picked up again (%d)" % world.hats_worn_by(1).size())
		_advance(2)

# --- 3. Catching a lip costs them too -----------------------------------------

func _phase_hang_pops_too() -> void:
	if phase_frame == 1:
		world._hats.clear()
		_wear(2)
		return
	if phase_frame == 6:
		eq(world.hats_worn_by(1).size(), 2, "wearing two")
		a._begin_hang(world.grid.cell_surface_world(Vector2i(25, 9)), GridConfig.DIR_NORTH)
		return
	if phase_frame == 8:
		eq(world.hats_worn_by(1).size(), 0, "catching a lip pops the stack as well")
		check(world.hat_count() == 2, "and they are on the deck, not destroyed")
		_advance(3)

# --- 4. Falling out of the world DESTROYS them --------------------------------

func _phase_falling_destroys() -> void:
	if phase_frame == 1:
		world._hats.clear()
		a.state = PlayerBody.State.WALK
		a.grounded = true
		a.position = world.grid.cell_surface_world(Vector2i(25, 9)) + Vector3(0.0, 1.0, 0.0)
		_wear(3)
		return
	if phase_frame == 6:
		eq(world.hats_worn_by(1).size(), 3, "wearing three")
		eq(world.hat_count(), 3, "and three exist")
		# Off the bottom of the world.
		a.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 5.0, -20.0)
		return
	if phase_frame == 40:
		# NO WIPE: the second player is still on their feet, so the run continues
		# and the only thing that could have removed these hats is the fall rule.
		eq(world.wipes, 0, "the run did not wipe -- a teammate is still up")
		# GONE, not scattered. This is the difference between a tumble and a fall,
		# and it is the same asymmetry D2 already draws: how badly it went decides
		# what it costs you.
		eq(world.hat_count(), 0, "and their hats went with them -- destroyed, not dropped")
		eq(world.hats_worn_by(1).size(), 0, "with nothing still worn")
		finish()

# --- helpers ------------------------------------------------------------------

func _wear(n: int) -> void:
	a.state = PlayerBody.State.WALK
	a.grounded = true
	for i in n:
		world._hats.spawn_loose(a.position + Vector3(0.05 * float(i), 0.0, 0.0))
