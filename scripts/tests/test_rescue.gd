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
		4: _phase_own_fall_catches()
		5: _phase_drone_return()

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
		eq(a.rescue_progress, 0.0, "and nobody is reviving them yet")
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
		# The helper goes well clear, so the hang is genuinely unassisted first.
		_park(b, Vector2i(13, 8))
		return
	if phase_frame == 90:
		eq(a.state, PlayerBody.State.LEDGE_HANG,
			"a player who topples into a gap catches the lip automatically")
		check(a.position.y > SimConfig.FALL_KILL_Y, "and is still in the world")
		recorded["hang_y"] = a.position.y
		return
	if phase_frame == 150:
		# ALONE, THERE IS NO WAY OUT. Not a missing button -- the entire point of
		# the state. If this ever starts passing on its own, the co-op gate has
		# quietly opened.
		eq(a.state, PlayerBody.State.LEDGE_HANG, "and cannot get out on their own")
		near(a.position.y, float(recorded["hang_y"]), 0.05, "hanging where they caught")
		eq(a.rescue_progress, 0.0, "with nobody helping")
		# Bring a teammate to the lip.
		_park(b, Vector2i(6, 1))
		return
	if phase_frame > 150 and a.state == PlayerBody.State.WALK:
		check(phase_frame < 150 + int(SimConfig.LEDGE_HAUL_SECONDS * 60.0) + 20,
			"a teammate at the lip hauls them up, and promptly")
		check(a.grounded, "putting them back on the deck in control")
		_advance(3)
		return
	if phase_frame > 400:
		fail("a teammate stood at the lip and never hauled the hanging player up")
		_advance(3)

# --- 4. Launched clear of the deck: no rescue, and that is intended -----------

# Deliberately the SAME lip, from the SAME spot, at a different speed -- so the
# only thing that can explain the different outcome is the speed. An earlier
# version launched the player right across the bridge and checked 2.5 s later; it
# failed, correctly, because the body had bounced, slowed, and caught a lip
# somewhere else entirely. That is the right behaviour and the wrong test.
func _phase_launched_clear() -> void:
	if phase_frame == 1:
		a.position = world.grid.cell_surface_world(Vector2i(6, 2)) + Vector3(0.0, 0.5, 0.0)
		a.begin_tumble(Vector3(0.0, -2.0, -SimConfig.LEDGE_CATCH_MAX_SPEED * 1.6))
		recorded["caught_fast"] = false
		return
	if phase_frame <= 24:
		if a.state == PlayerBody.State.LEDGE_HANG:
			recorded["caught_fast"] = true
		return
	if phase_frame == 25:
		check(not bool(recorded["caught_fast"]),
			"a player arriving at a lip too fast catches nothing -- launched clear is launched clear")
		_advance(4)

# --- 4b. A fall you caused YOURSELF catches the same lip ----------------------
#
# Reported from playtest: "when you dash across a gap but fall short you don't
# seem to be able to grab -- is grabbing specific to kicks?" It was. The catch
# lived inside _step_tumble, so it was reachable only by being kicked, shot or
# rushed; your own dash ends in WALK, and WALK never asked.
#
# Same lip, same spot, same slow arrival as phase 3 -- the ONLY difference is
# that nothing put the player there. If the outcome differs, the rule is keyed on
# invisible state rather than on the fall, which is what D2 says it is not.
func _phase_own_fall_catches() -> void:
	if phase_frame == 1:
		_park(b, Vector2i(13, 8))
		# Airborne over the authored gap, in WALK. This is the shape a dash that
		# fell short leaves you in: end_shove zeroes the horizontal velocity and
		# hands you back to WALK, dropping.
		a.position = world.grid.cell_surface_world(Vector2i(6, 2)) + Vector3(0.0, 0.5, 0.0)
		a.velocity = Vector3(0.0, -1.0, -1.0)
		a.state = PlayerBody.State.WALK
		a.grounded = false
		a.health = SimConfig.MAX_HEALTH
		recorded["ever_tumbled"] = false
		return
	if phase_frame < 60:
		if a.state == PlayerBody.State.TUMBLE:
			recorded["ever_tumbled"] = true
		return
	if phase_frame == 60:
		eq(a.state, PlayerBody.State.LEDGE_HANG,
			"a player who falls under their OWN steam catches the lip too")
		# And got there directly. Without this the phase would also pass if
		# something had quietly tumbled the player first, which would leave the
		# original bug in place and the test green over it.
		check(not bool(recorded["ever_tumbled"]),
			"having never been tumbled -- the grab is not kick-only")
		_advance(5)

# --- 5. Falling is a setback: the drone brings you back next to a friend ------

func _phase_drone_return() -> void:
	if phase_frame == 1:
		_park(b, Vector2i(7, 12))
		# A REAL tumble first, not a state assignment: the mesh spin has to be
		# produced by the game's own mechanism for the "comes back upright"
		# assertion below to mean anything.
		_park(a, Vector2i(7, 14))
		a.begin_tumble(Vector3(9.0, 3.0, 0.0))
		return
	if phase_frame == 20:
		# VALIDATE THE INSTRUMENT BEFORE TRUSTING IT. If the mesh never tilted in
		# the first place, "upright at the end" passes no matter what the respawn
		# does, and this whole phase would be measuring nothing.
		recorded["tilt"] = _mesh_tilt(a)
		check(float(recorded["tilt"]) > 0.2,
			"a tumbling player's mesh pinwheels (%.2f rad off vertical)" % recorded["tilt"])
		a.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 5.0, -20.0)
		return
	if phase_frame == 40:
		check(world._returning.has(1), "a player who falls out of the world is picked up")
		return
	if phase_frame == int(SimConfig.DRONE_RETURN_SECONDS * 60.0) + 40:
		check(not world._returning.has(1), "and the drone finishes the job")
		eq(a.state, PlayerBody.State.WALK, "returning them in control")
		check(a.position.distance_to(b.position) < 6.0,
			"dropped next to a teammate (%.1f m away), not alone behind the party"
				% a.position.distance_to(b.position))
		check(a.health >= SimConfig.REVIVE_HEALTH, "and able to carry on")

		# Reported from playtest: "if you get knocked off into space, when you
		# respawn you might be rotated." The mesh angle was an accumulator that
		# only the normal exits from TUMBLE cleared, and the drone return is not
		# one of them -- it sets WALK from GameWorld directly -- so a player came
		# back leaning for the rest of the run. It is now derived from state.
		check(_mesh_tilt(a) < 0.01,
			"and STANDING UP straight, not still leaning from the tumble (%.3f rad)"
				% _mesh_tilt(a))

		# The other two things a hand-written respawn list kept forgetting.
		eq(a.rescue_progress, 0.0, "with no rescue credit banked from before the fall")
		eq(a.shove_cooldown, 0.0, "and a dash ready, so the first press after a respawn works")
		finish()

# How far the mesh's own up-axis has fallen away from vertical. Reads the thing a
# player actually sees, rather than an euler triple that wraps.
func _mesh_tilt(body: CharacterBody3D) -> float:
	var mesh := body.get_node_or_null("Mesh") as Node3D
	if mesh == null:
		return 0.0
	return mesh.transform.basis.y.angle_to(Vector3.UP)
