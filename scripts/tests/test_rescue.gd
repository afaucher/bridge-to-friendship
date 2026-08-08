extends "res://scripts/test_support/test_case.gd"

# MVP criteria B5, B5b, B6, B7, B8 — the whole failure-and-rescue loop.
#
# The claim this test exists to defend is the asymmetry in D2: **whether your
# friends can save you is decided by how you got hit, not by how fast they
# react.** Shoved along the deck and you catch the lip and are rescuable;
# launched clear of it and you simply fall. That is one rule with two outcomes,
# and it is the thing that makes standing near an edge legibly risky.
#
# Everything here runs on the world's own host tick with scripted input, so it
# exercises the code path the game uses.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "RescueWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

	eq(a.health, SimConfig.MAX_HEALTH, "a player starts at full health")

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_damage_and_grace()
		1: _phase_downed_and_revive()
		2: _phase_ledge_catch()
		3: _phase_launched_clear()
		4: _phase_drone_return()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

func _park(body: CharacterBody3D, cell: Vector2i, lift: float = 1.0) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, lift, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true

# --- 1. Damage, and the grace window that stops one tumble emptying the bar ----

func _phase_damage_and_grace() -> void:
	if phase_frame != 1:
		return
	_park(a, Vector2i(7, 1))
	check(a.take_damage(1), "a hit lands")
	eq(a.health, SimConfig.MAX_HEALTH - 1, "and costs a hit point")
	check(not a.take_damage(1), "a second hit inside the grace window is refused")
	eq(a.health, SimConfig.MAX_HEALTH - 1, "so the bar does not drain in one go")
	_advance(1)

# --- 2. Zero health downs you where you fell; a teammate revives you -----------

func _phase_downed_and_revive() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(7, 1))
		# Park the helper out of range to start, so revive cannot begin by
		# accident and the "reset when they wander off" rule is exercised.
		_park(b, Vector2i(13, 1))
		a.health = 1
		a.invulnerable = 0.0
		check(a.take_damage(1), "the last hit point can be taken")
		eq(a.state, PlayerBody.State.DOWNED, "zero health puts the player DOWNED")
		recorded["down_at"] = a.position
		return

	if phase_frame == 30:
		eq(a.position, recorded["down_at"], "downed where they fell, not moved")
		check(not a.take_damage(1), "a downed player takes no further damage")
		eq(a.revive_progress, 0.0, "and nobody is reviving them yet")
		# Bring the helper alongside.
		b.position = a.position + Vector3(1.5, 0.0, 0.0)
		return

	if phase_frame > 30 and a.state == PlayerBody.State.WALK:
		check(phase_frame < 30 + int(SimConfig.REVIVE_SECONDS * 60.0) + 20,
			"a teammate standing with them revives them, and promptly")
		eq(a.health, SimConfig.REVIVE_HEALTH, "revived at minimum health")
		_advance(2)
		return

	if phase_frame > 200:
		fail("a teammate stood alongside a downed player and never revived them")
		_advance(2)

# --- 3. Shoved along the deck: you catch the lip ------------------------------

func _phase_ledge_catch() -> void:
	if phase_frame == 1:
		# Toppling into the authored gap at z 2-3 (x 5-7), close to its lip --
		# the "shoved along the deck" case, where a rescue is meant to be
		# possible. Dropped INTO the gap rather than nudged toward it: a tumble
		# recovers as soon as it is slow and grounded, so a gentle push just
		# stands back up before it ever reaches the edge.
		a.position = world.grid.cell_surface_world(Vector2i(6, 2)) + Vector3(0.0, 0.5, 0.0)
		a.health = SimConfig.MAX_HEALTH
		a.begin_tumble(Vector3(0.0, 0.0, -1.0))
		return
	if phase_frame == 90:
		eq(a.state, PlayerBody.State.LEDGE_HANG,
			"a player who topples into a gap catches the lip automatically")
		check(a.position.y > SimConfig.FALL_KILL_Y, "and is still in the world")
		recorded["hang_y"] = a.position.y
		return
	if phase_frame == 120:
		# A hanging player cannot get themselves out. That is the entire point of
		# the state, and the reason the rope has something to do in M4.
		near(a.position.y, float(recorded["hang_y"]), 0.05,
			"and hangs there rather than climbing out on their own")
		check(a.mantle(), "but CAN be mantled onto the deck when something pulls")
		eq(a.state, PlayerBody.State.WALK, "which puts them back in control")
		_advance(3)

# --- 4. Launched clear of the deck: no rescue, and that is intended -----------

func _phase_launched_clear() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(6, 1), 6.0)
		# Thrown hard and high, the way a plinko ball to the chest will throw
		# someone. Nothing to catch: they are nowhere near a lip.
		a.begin_tumble(Vector3(0.0, 6.0, -26.0))
		return
	if phase_frame == 150:
		check(a.state != PlayerBody.State.LEDGE_HANG,
			"a player launched clear of the deck catches nothing")
		_advance(4)

# --- 5. Falling is a setback: the drone brings you back next to a friend ------

func _phase_drone_return() -> void:
	if phase_frame == 1:
		_park(b, Vector2i(7, 12))
		a.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 5.0, -20.0)
		a.state = PlayerBody.State.TUMBLE
		return
	if phase_frame == 30:
		check(world._returning.has(1), "a player who falls out of the world is picked up")
		return
	if phase_frame == int(SimConfig.DRONE_RETURN_SECONDS * 60.0) + 40:
		check(not world._returning.has(1), "and the drone finishes the job")
		eq(a.state, PlayerBody.State.WALK, "returning them in control")
		check(a.position.distance_to(b.position) < 6.0,
			"dropped next to a teammate (%.1f m away), not alone behind the party"
				% a.position.distance_to(b.position))
		check(a.health >= SimConfig.REVIVE_HEALTH, "and able to carry on")
		finish()
