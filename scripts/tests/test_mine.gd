extends "res://scripts/test_support/test_case.gd"

# M15c. The land mine: one second, then armed.
#
# The claims:
#   1. A PRESS PLACES ONE AT YOUR FEET, and costs exactly one use. No hold, no
#      aim -- the decision is where you were standing and when.
#   2. IT DOES NOTHING FOR A SECOND, asserted on EVERY tick of that second and not
#      merely at the end of it. The arming delay is the entire reason a mine is a
#      thing you place in advance rather than a melee attack with extra steps, so
#      "it is harmless for a duration" is a claim about the duration.
#   3. ONCE ARMED, WALKING INTO IT SETS IT OFF and the thing that walked in dies.
#   4. THE OWNER IS NOT EXEMPT. Standing on your own armed mine is fatal, which is
#      what makes stepping away part of the verb. It is also, per the damage model,
#      how a mine counters a shield: a blast beneath you is not in the arc.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const ARM_FRAMES := int(SimConfig.MINE_ARM_SECONDS * 60.0)

var world: Node3D = null
var layer: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var pressing: bool = false
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "MineWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	layer = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if pressing else 0
		return [t, Vector2.ZERO, actions, layer.facing]

func _physics_process(_delta: float) -> void:
	if layer == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_a_press_places_one()
		1: _phase_harmless_while_arming()
		2: _phase_a_rusher_trips_it()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	pressing = false
	_clear()

func _clear() -> void:
	for d in world._deployables:
		if is_instance_valid(d):
			d.queue_free()
	world._deployables.clear()
	for r in world._rushers:
		if is_instance_valid(r):
			r.queue_free()
	world._rushers.clear()
	layer.health = SimConfig.MAX_HEALTH
	layer.invulnerable = 0.0

# --- 1. A press places one ----------------------------------------------------

func _phase_a_press_places_one() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3))
		_arm_with_mines()
		recorded["at"] = layer.position
		pressing = true
		return
	if phase_frame == 3:
		eq(world._deployables.size(), 1, "a press places exactly one mine")
		if world._deployables.size() > 0:
			var m: Node = world._deployables[0]
			var flat: float = Vector2(m.position.x - layer.position.x,
				m.position.z - layer.position.z).length()
			check(flat < 0.5, "at your feet (%.2f m away)" % flat)
		var s: Node = _held()
		if s != null:
			eq(s.ammo, SimConfig.MINE_AMMO - 1, "and it cost exactly one use")
		return
	if phase_frame == 30:
		# HELD DOWN AND STILL ONE. A level bit with no edge detection would lay a
		# mine every tick and empty the pouch in three frames.
		eq(world._deployables.size(), 1,
			"and holding the button does not lay a second one")
		_advance(1)

# --- 2. Harmless for a second, then not ---------------------------------------

func _phase_harmless_while_arming() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5))
		_arm_with_mines()
		recorded["health"] = int(layer.health)
		pressing = true
		return
	if phase_frame == 3:
		pressing = false
		return
	# EVERY TICK OF THE ARMING WINDOW. The mine is under the player's feet the
	# whole time, so if arming did nothing this fails on the first frame rather
	# than passing a single late sample.
	if phase_frame > 3 and phase_frame < ARM_FRAMES:
		if int(layer.health) < int(recorded["health"]):
			check(false, "a mine is harmless while arming (went off on frame %d of %d)"
				% [phase_frame, ARM_FRAMES])
			_advance(2)
		return
	# ...and then it is not. The player never moved, so their own mine takes them:
	# stepping away is part of the verb.
	if phase_frame == ARM_FRAMES + 30:
		check(int(layer.health) < int(recorded["health"]),
			"and then it arms under its own owner (%d -> %d)"
				% [recorded["health"], layer.health])
		eq(world._deployables.size(), 0, "and is spent by going off")
		_advance(2)

# --- 3. Something else walks into it ------------------------------------------

func _phase_a_rusher_trips_it() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3))
		_arm_with_mines()
		pressing = true
		return
	if phase_frame == 3:
		pressing = false
		return
	if phase_frame == 20:
		# STEPPED AWAY BEFORE IT ARMS, which is the verb working as designed --
		# phase 2 is the proof that staying put does not end well, and leaving this
		# until after the arming window meant the mine had already taken its owner
		# and there was nothing left for the rusher to trip.
		_park(Vector2i(15, 9))
		return
	if phase_frame == ARM_FRAMES + 4:
		eq(world._deployables.size(), 1,
			"an armed mine with nobody near it just sits there")
		recorded["rusher"] = _spawn_rusher_on_the_mine()
		return
	if phase_frame == ARM_FRAMES + 20:
		eq(world._deployables.size(), 0, "something walking into it sets it off")
		check(_rusher_gone(), "and the thing that walked in is destroyed")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	layer.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	layer.velocity = Vector3.ZERO
	layer.state = PlayerBody.State.WALK
	layer.grounded = true

func _arm_with_mines() -> void:
	for s in world._specials.all():
		world._specials.destroy(s)
	var m: Node = world._specials.spawn_loose(layer.position, SpecialBody.Kind.MINE)
	m.hold(1)

func _held() -> Node:
	return world._specials.held_by(1)

# Dropped straight onto the mine. A rusher is the cheapest body in the game that
# counts as "something on legs", which is exactly what the trigger asks about.
func _spawn_rusher_on_the_mine() -> int:
	# GUARDED, because an out-of-range index in GDScript aborts the rest of the
	# frame's function silently -- so a missing mine would present as the assertion
	# below never running rather than as a failure.
	if world._deployables.size() == 0:
		return -1
	var at: Vector3 = world._deployables[0].position + Vector3(0.0, 1.0, 0.0)
	var r: Node = world._spawn_rusher(at)
	return int(r.rusher_id)

func _rusher_gone() -> bool:
	for r in world._rushers:
		if is_instance_valid(r) and int(r.rusher_id) == int(recorded.get("rusher", -1)):
			return false
	return true
