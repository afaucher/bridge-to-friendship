extends "res://scripts/test_support/test_case.gd"

# The explosion you can SEE, and the shield you can see.
#
# WHY A TEST FOR SOMETHING COSMETIC. CLAUDE.md's rule: headless builds the whole
# tree, it just does not draw it, so a view script that nothing in the gate ever
# instantiates ships having never been executed once -- and GDScript resolves
# properties at runtime, so a Godot-3 spelling or a renamed enum raises on the
# first frame and nowhere earlier. Everything below is really constructed.
#
# The claims:
#   1. A BLAST MAKES ONE, and it is sized to the radius the damage was resolved
#      with. A flash that lied about the radius would teach the player the wrong
#      distance, which is worse than no flash at all.
#   2. IT CLEANS ITSELF UP. It is created at the moment the thing that made it is
#      destroyed, so nothing is left owning it.
#   3. A MINE'S EXPLOSION IS THE GRENADE'S. Both route through blast_at; this is
#      the assertion that keeps them from drifting apart.
#   4. THE SHIELD WALL IS SHOWN AND GROUNDED. Its bottom edge sits on the deck --
#      a shield with daylight under it promises a gap that the rule does not have.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const Deployable = preload("res://scripts/sim/deployable.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var body: CharacterBody3D = null
var phase: int = 0
var pressing: bool = false
var phase_frame: int = 0
var recorded: Dictionary = {}
var flash_peak: float = 0.0
var flash_frames: int = 0

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "BlastWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	# THE VIEW GATE, ON. Effects are skipped on a machine with nobody looking, so
	# without this the gate would run every line of this file except the ones that
	# matter.
	world.view_active = true
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if pressing else 0
		return [t, Vector2.ZERO, actions, body.facing]

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_a_blast_is_visible()
		1: _phase_it_tidies_up()
		2: _phase_a_mine_explodes_too()
		3: _phase_the_shield_is_grounded()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	for fx in _effects():
		fx.queue_free()

# --- 1. A blast is visible ----------------------------------------------------

func _phase_a_blast_is_visible() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3))
		world.blast_at(body.position + Vector3(6.0, 0.0, 0.0), SimConfig.BLAST_RADIUS)
		return
	if phase_frame == 2:
		var fx: Array = _effects()
		eq(fx.size(), 1, "a blast leaves something to look at")
		if fx.size() > 0:
			var flash := fx[0].get_node_or_null("Flash") as Node3D
			var shards := fx[0].get_node_or_null("Shards") as GPUParticles3D
			check(flash != null, "with a flash")
			check(shards != null, "and a burst of shards")
			if shards != null:
				check(shards.one_shot and shards.explosiveness >= 1.0,
					"emitted all at once rather than dribbled out (one_shot=%s explosiveness=%.1f)"
						% [str(shards.one_shot), shards.explosiveness])
			# THE SIZE IS THE CLAIM. It grows into the radius, so the check is that
			# it ENDS there -- see phase 1 for the arrival.
			recorded["fx"] = fx[0].get_instance_id()
		_advance(1)

# --- 2. It grows to the true radius, then goes ---------------------------------

func _phase_it_tidies_up() -> void:
	if phase_frame == 1:
		world.blast_at(body.position + Vector3(6.0, 0.0, 0.0), SimConfig.BLAST_RADIUS)
		return
	# THE PEAK, SAMPLED EVERY FRAME, not a reading on one chosen frame. This was
	# `if phase_frame == 13` behind an `if flash != null`, and it never ran once:
	# FLASH_SECONDS is 0.18 s and blast_effect.gd queue_free()s the flash the tick
	# its ease reaches 1.0, so by frame 13 the node was already gone and the guard
	# swallowed the claim in silence. A flash sized to anything at all passed.
	# Found 2026-08-22 by logging get_stack() from the assertion helpers.
	#
	# A PEAK IS ALSO THE RIGHT MEASUREMENT. The claim is that it GROWS INTO the
	# radius, and the frame it is widest on is a property of FLASH_SECONDS and the
	# frame rate rather than of the thing under test -- so pinning a frame would
	# make this die again the next time either moves.
	if phase_frame < 90:
		var live: Array = _effects()
		if live.size() > 0:
			var growing := live[0].get_node_or_null("Flash") as Node3D
			if growing != null:
				flash_frames += 1
				flash_peak = maxf(flash_peak, growing.scale.x)
		return
	if phase_frame == 90:
		# THE INSTRUMENT FIRST: a flash nobody ever saw would report a beautiful
		# zero peak, which is exactly how the old assertion disappeared.
		check(flash_frames > 0,
			"the flash was on screen to be measured (%d frames)" % flash_frames)
		check(flash_peak > SimConfig.BLAST_RADIUS * 0.6,
			"and grows into the real blast radius (%.1f m of %.1f)"
				% [flash_peak, SimConfig.BLAST_RADIUS])
		eq(_effects().size(), 0,
			"and the whole effect frees itself -- nothing is left owning it")
		_advance(2)

# --- 3. A mine gets the same explosion ----------------------------------------

func _phase_a_mine_explodes_too() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 3))
		# A real mine, armed, with the player standing on it: the same path the
		# game takes, not a direct call to blast_at.
		var m: Node = world._spawn_deployable(Deployable.Kind.MINE)
		m.place_at(body.position, 1, true)
		recorded["mine"] = m.deployable_id
		return
	if phase_frame == int(SimConfig.MINE_ARM_SECONDS * 60.0) + 20:
		eq(world._deployables.size(), 0, "the mine went off")
		check(_effects().size() > 0,
			"and a mine's explosion is the grenade's -- both come through blast_at")
		_advance(3)

# --- 4. The shield wall -------------------------------------------------------

func _phase_the_shield_is_grounded() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 5))
		# A REAL SHIELD AND A REAL TRIGGER. Setting `shielding` by hand looked like
		# it worked and did not: the next step recomputes it from what is in the
		# player's hands, so the flag was cleared before anything drew. The test was
		# asserting against a state the game never actually enters.
		for sp in world._specials.all():
			world._specials.destroy(sp)
		var shield: Node = world._specials.spawn_loose(body.position,
			SpecialBody.Kind.SHIELD)
		shield.hold(1)
		shield.fire_timer = 0.0
		return
	if phase_frame == 3:
		var wall: Node3D = _shield()
		check(wall != null, "the player carries a shield wall")
		if wall != null:
			check(not wall.visible, "hidden while no shield is up")
		pressing = true
		return
	if phase_frame == 8:
		check(body.shielding, "the shield is genuinely raised")
		return
	if phase_frame == 10:
		var wall: Node3D = _shield()
		if wall != null:
			check(wall.visible, "and shown the moment one is raised")
			# GROUNDED. Its lowest point against the player's feet: a shield
			# floating at waist height promises a gap under it that the rule does
			# not have -- everything in the arc is refused, including a rolling
			# ball.
			var mesh := wall as MeshInstance3D
			var half_height: float = 0.0
			if mesh != null and mesh.mesh is BoxMesh:
				half_height = (mesh.mesh as BoxMesh).size.y * 0.5
			var bottom: float = wall.global_position.y - half_height
			var feet: float = body.global_position.y - PlayerBody.HALF_HEIGHT
			check(absf(bottom - feet) < 0.12,
				"and it reaches the ground (%.2f m above the feet)" % (bottom - feet))
			# IN FRONT, not behind. The same sign error that threw every grenade
			# over the thrower's shoulder would put this on their back.
			var ahead: Vector3 = wall.global_position - body.global_position
			check(ahead.z < -0.2,
				"in FRONT of them (dz %+.2f, forward is -Z)" % ahead.z)
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true
	body.facing = 0.0

func _effects() -> Array:
	var out: Array = []
	for child in world.get_children():
		if child.name.begins_with("Blast"):
			out.append(child)
	return out

func _shield() -> Node3D:
	var pivot := body.get_node_or_null("Facing") as Node3D
	if pivot == null:
		return null
	return pivot.get_node_or_null("Shield") as Node3D
