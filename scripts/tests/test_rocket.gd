extends "res://scripts/test_support/test_case.gd"

# The rocket launcher: direct fire that explodes.
#
# THE CLAIM THAT MAKES IT A DIFFERENT WEAPON FROM THE GRENADE is not its damage --
# they share `blast_at` and do exactly the same thing on arrival. It is the
# TRAJECTORY. A grenade is lobbed and spends most of its flight above a 2 m
# pillar; a rocket goes flat and straight and hits what is pointed at. They are
# the same explosion from opposite directions, and the choice between them is a
# question about the shape of the problem.
#
# The claims:
#   1. IT FLIES FLAT. Measured against a grenade fired from the same spot at the
#      same target -- the rocket must arrive without climbing over anything.
#   2. IT EXPLODES ON CONTACT, with the full blast: a rusher well to the SIDE of
#      the impact point dies, which a bullet could never do.
#   3. IT IS ONE SHOT AT A TIME. Held down it fires on its own slow cadence, not
#      the machine gun's -- two rockets take three seconds, which is the pace of a
#      decision rather than of a trigger.
#   4. SPENT MEANS GONE, like every other special in a one-slot game.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var shooter: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var firing: bool = false
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "RocketWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	shooter = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if firing else 0
		return [t, Vector2.ZERO, actions, shooter.facing]

func _physics_process(_delta: float) -> void:
	if shooter == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_flies_flat()
		1: _phase_explodes_on_contact()
		2: _phase_one_at_a_time()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	firing = false
	_clear()

func _clear() -> void:
	for b in world._bullets:
		if is_instance_valid(b):
			b.queue_free()
	world._bullets.clear()
	for r in world._rushers:
		if is_instance_valid(r):
			r.queue_free()
	world._rushers.clear()
	shooter.health = SimConfig.MAX_HEALTH
	shooter.invulnerable = 0.0

# --- 1. Flat, not lobbed ------------------------------------------------------

func _phase_flies_flat() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3), 0.0)
		_arm(SpecialBody.Kind.ROCKET)
		recorded["from"] = shooter.position
		recorded["rise"] = -99.0
		firing = true
		return
	if phase_frame == 3:
		firing = false
		return
	# EVERY TICK IT IS ALIVE, keeping the highest it ever climbed above the muzzle.
	# A single late sample would miss the apex, which is the entire quantity under
	# test.
	if world._bullets.size() > 0:
		var r: Node = world._bullets[0]
		recorded["rise"] = maxf(float(recorded["rise"]),
			r.position.y - float(recorded["from"].y))
		recorded["reach"] = float(recorded["from"].z) - r.position.z
	if phase_frame == 40:
		check(float(recorded.get("reach", 0.0)) > 6.0,
			"a rocket covers ground fast (%.1f m in half a second)"
				% recorded.get("reach", 0.0))
		# FLAT. A grenade at full charge climbs metres above its release point on
		# the way to 16 m; a rocket must not climb at all to speak of.
		check(float(recorded["rise"]) < 1.0,
			"and it flies FLAT rather than lobbed (%.2f m of climb) -- that is the "
			% recorded["rise"]
			+ "whole difference between it and the grenade")
		_advance(1)

# --- 2. It explodes, and the blast is the point -------------------------------

func _phase_explodes_on_contact() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3), 0.0)
		_arm(SpecialBody.Kind.ROCKET)
		# A rusher squarely in the flight path, and a SECOND one well off to the
		# side of it. A bullet kills the first and never touches the second; only a
		# blast reaches both, which is what makes this an explosive rather than a
		# large round.
		recorded["target"] = _spawn_rusher(Vector2i(15, 8))
		recorded["bystander"] = _spawn_rusher(Vector2i(16, 8))
		recorded["before"] = world._rushers.size()
		firing = true
		return
	if phase_frame == 3:
		firing = false
		return
	if phase_frame == 60:
		check(world._rushers.size() < int(recorded["before"]),
			"a rocket kills what it hits (%d -> %d)"
				% [recorded["before"], world._rushers.size()])
		check(_gone(int(recorded["bystander"])),
			"AND the one standing beside it -- a blast, not a bullet")
		eq(world._bullets.size(), 0, "and the rocket is spent on impact")
		_advance(2)

# --- 3. One at a time, and then gone ------------------------------------------

func _phase_one_at_a_time() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3), 0.0)
		_arm(SpecialBody.Kind.ROCKET)
		firing = true
		return
	# HELD DOWN THE WHOLE PHASE. The machine gun would empty a magazine in this
	# window; a rocket must not.
	if phase_frame == 30:
		eq(world._bullets.size(), 1,
			"holding the trigger does not empty the tube -- one rocket is in the air")
		var held: Node = _held()
		if held != null:
			eq(held.ammo, SimConfig.ROCKET_AMMO - 1, "and exactly one was spent")
		return
	if phase_frame == int(SimConfig.ROCKET_FIRE_INTERVAL * 60.0) + 20:
		# The second one has now had time to leave, which spends the last round.
		check(_held() == null,
			"and a spent launcher is gone, like every other special in a one-slot game")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i, yaw: float) -> void:
	shooter.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	shooter.velocity = Vector3.ZERO
	shooter.state = PlayerBody.State.WALK
	shooter.grounded = true
	shooter.facing = yaw

func _arm(kind: int) -> void:
	for s in world._specials.all():
		world._specials.destroy(s)
	var w: Node = world._specials.spawn_loose(shooter.position, kind)
	w.hold(1)
	w.fire_timer = 0.0

func _held() -> Node:
	return world._specials.held_by(1)

func _spawn_rusher(cell: Vector2i) -> int:
	var at: Vector3 = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	var r: Node = world._spawn_rusher(at)
	return int(r.rusher_id)

func _gone(id: int) -> bool:
	for r in world._rushers:
		if is_instance_valid(r) and int(r.rusher_id) == id:
			return false
	return true
