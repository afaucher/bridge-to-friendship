extends "res://scripts/test_support/test_case.gd"

# M8.5. Picking hats up, stacking them, and the states that refuse.
#
# The claims:
#   1. Walking over a loose hat wears it; three stack in order, bottom-first.
#   2. A TUMBLING player walks straight through one. Scooping your own hats back
#      up as you roll through them would remove the entire cost of the tumble.
#   3. The stack cap refuses the sixth, INCLUDING within a single pass -- a dash
#      down a line of hats collects several in one tick.
#   4. The worn stack never touches the collider. M3's riding rules and the
#      carrier foot probe are all denominated in the player cylinder, so a stack
#      that grew it would change how players stand on each other, per hat.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "HatWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	a = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	# The player's own collider, recorded before any hat exists, so the "hats
	# never touch it" claim is measured rather than assumed.
	var shape := a.get_node_or_null("Shape") as CollisionShape3D
	recorded["radius"] = (shape.shape as CylinderShape3D).radius
	recorded["height"] = (shape.shape as CylinderShape3D).height

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_walk_over_one()
		1: _phase_stack_of_three()
		2: _phase_tumbling_takes_none()
		3: _phase_stack_cap()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. Walking over a loose hat wears it -------------------------------------

func _phase_walk_over_one() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		recorded["hat"] = _drop_hat_at(a.position)
		return
	if phase_frame == 5:
		eq(world.hats_worn_by(1).size(), 1, "walking over a loose hat wears it")
		var hat: Node = recorded["hat"]
		eq(hat.mode, HatBody.Mode.WORN, "and the hat knows it is worn")
		eq(hat.owner_peer, 1, "by the player who reached it")

		# THE COLLIDER IS UNTOUCHED. A hat you can stand on is a ladder, and five
		# of them are a staircase past an authored ascender gate.
		var shape := a.get_node_or_null("Shape") as CollisionShape3D
		var cyl := shape.shape as CylinderShape3D
		near(cyl.radius, float(recorded["radius"]), 0.0001, "the player's collider is unchanged")
		near(cyl.height, float(recorded["height"]), 0.0001, "in height as well as radius")
		check(hat.get_node("Shape").disabled, "and the worn hat's own shape is disabled")
		_advance(1)

# --- 2. Three stack, bottom-first ---------------------------------------------

func _phase_stack_of_three() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		return
	if phase_frame <= 4:
		# One per tick, so the order they arrive in is unambiguous.
		_drop_hat_at(a.position)
		return
	if phase_frame == 12:
		var worn: Array = world.hats_worn_by(1)
		eq(worn.size(), 3, "three hats stack")
		for i in worn.size():
			eq(worn[i].stack_index, i, "each knows where it sits (%d)" % i)
		# Bottom-first and rising: the visual joke is a tower, so the order has to
		# be a tower.
		check(worn[1].position.y > worn[0].position.y, "stacked upward")
		check(worn[2].position.y > worn[1].position.y, "in order")
		near(worn[1].position.y - worn[0].position.y, SimConfig.HAT_HEIGHT, 0.01,
			"spaced by HAT_HEIGHT")
		_advance(2)

# --- 3. A tumbling player picks up nothing ------------------------------------

func _phase_tumbling_takes_none() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		recorded["hat"] = _drop_hat_at(a.position + Vector3(0.0, 0.0, -0.2))
		# Tumble AFTER the hat is down, so the only difference from phase 1 is the
		# state the player is in.
		a.begin_tumble(Vector3(0.0, 1.0, 0.0))
		return
	if phase_frame == 20:
		eq(a.state, PlayerBody.State.TUMBLE, "the player is tumbling")
		eq(world.hats_worn_by(1).size(), 0,
			"and rolls through a hat without collecting it")
		_advance(3)

# --- 4. The stack cap, including within one pass ------------------------------

func _phase_stack_cap() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		# MORE THAN THE CAP, ALL AT ONCE AND ALL IN REACH. A dash down a line of
		# hats is meant to collect several in a single tick, which is exactly why
		# the cap has to be counted inside the pass rather than read from a worn
		# count that only updates afterwards.
		for i in SimConfig.HAT_MAX_STACK + 3:
			_drop_hat_at(a.position + Vector3(0.05 * float(i), 0.0, 0.0))
		return
	if phase_frame == 10:
		eq(world.hats_worn_by(1).size(), SimConfig.HAT_MAX_STACK,
			"the stack caps at HAT_MAX_STACK even when they all arrive at once")
		check(world.hat_count() > SimConfig.HAT_MAX_STACK,
			"and the rest are still on the deck, not consumed")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	a.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	a.velocity = Vector3.ZERO
	a.state = PlayerBody.State.WALK
	a.grounded = true

func _clear() -> void:
	world._hats.clear()

# A hat placed already settled, so it is collectable this instant. The settle
# grace is what phase 3 of test_hat_tumble is about; here it would only add
# frames.
func _drop_hat_at(at: Vector3) -> Node:
	return world._hats.spawn_loose(at)
