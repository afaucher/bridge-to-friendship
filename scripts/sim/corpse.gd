extends Node3D

# WHAT IS LEFT WHERE AN ENEMY WAS.
#
# A dead rusher, zombie or skirmisher is not deleted -- it is REPLACED by the
# pieces of itself, standing exactly where its body stood, in exactly the shape
# its body had. Walk into the pile, or blow it up, and it comes apart. See
# design_ideas/death_fragments.md; the cutting is scripts/sim/fragment_shape.gd.
#
# ON THE FRAME IT APPEARS IT IS INVISIBLE AS A CHANGE. That is the whole reason
# the fragmenter goes to the trouble of tiling the body exactly: the alternative
# -- a body vanishing and a heap of approximately-body-shaped chips appearing --
# is a silhouette popping on the one frame the player is looking straight at it.
#
# --- IT IS COSMETIC, AND THAT IS A DESIGN DECISION WITH TEETH -----------------
#
# Debris is on its own collision layer which NOTHING masks but the world and
# other debris. A player cannot be pushed by it, blocked by it, or stand on it.
# Three things follow, and they are why it is worth giving up the satisfaction of
# kicking a skull about:
#
#   * IT NEEDS NO REPLICATION. Nothing authoritative reads a fragment, so two
#     machines may tumble the same corpse differently at no cost. Only the DEATH
#     is told (game_world's _corpse_seen), exactly as a blast is -- and for the
#     same reason a blast is: an enemy leaving the snapshot is ALSO what happens
#     when one burrows away or falls off the bridge, and neither of those is a
#     death anybody should see rubble from.
#   * IT CANNOT KILL ANYONE. A pile of physics debris that could shove would be a
#     new way to be pushed off a bridge, arriving from an object the player has no
#     reason to think is dangerous and no verb to answer.
#   * IT CANNOT WEDGE A DOORWAY. A corpse in a corridor that blocked movement
#     would be terrain that appears mid-fight.
#
# The BUMP is therefore detected on the corpse and not on the pieces: one
# proximity check while the pile is intact, the same shape as every other
# proximity rule in this game (a mound waking, a grave opening). Once scattered
# the fragments are inert scenery with a fuse on them.
#
# --- WHY THE PIECES ARE RIGID BODIES -----------------------------------------
#
# CLAUDE.md is emphatic that everything in this game is a hand-written integrator
# because its behaviour is a DESIGNED RULE, and that the plinko ball is the one
# exception because a ball is simply a ball. Debris is the second exception on
# exactly the same argument: there is no rule about where a chip of a dead zombie
# should land. And the determinism objection does not apply for the reason above
# -- nothing replays a fragment, because nothing depends on one.
#
# They are FROZEN while the pile is intact, so an untouched corpse costs the
# solver nothing at all.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const FragmentShape = preload("res://scripts/sim/fragment_shape.gd")

# WHAT CAN LEAVE A CORPSE, and the only list of it. An int rather than a scene
# path because this crosses the wire: a client should not be told to `load()` an
# arbitrary string by the far end.
enum Kind { RUSHER, ZOMBIE, SKIRMISHER }

const SCENES := {
	Kind.RUSHER: "res://scenes/rusher.tscn",
	Kind.ZOMBIE: "res://scenes/zombie.tscn",
	Kind.SKIRMISHER: "res://scenes/skirmisher.tscn",
}

const LAYER_DEBRIS := 1 << 12       # project.godot layer 13
const LAYER_WORLD := 1 << 0

# The debris mask: the deck, and each other. NOT players, NOT enemies -- see the
# header. This is the one place in the project where a deliberately narrow mask
# is the feature rather than the bug, so it is written as named bits and the test
# asserts both halves: that debris DOES collide with the world, and that a player
# does NOT collide with debris.
const DEBRIS_MASK := LAYER_WORLD | LAYER_DEBRIS

enum State { INTACT, SCATTERED }

var kind: int = Kind.RUSHER
var state: int = State.INTACT
var age: float = 0.0
# Time since the scatter, which is what the debris lifetime is measured from --
# a pile burst on the last second of its standing life still gets a full flight.
var scatter_age: float = 0.0
var fragments: Array = []

# The volume the living body filled, in corpse-local space. See `covers`.
var hit_radius: float = 0.5
var hit_low: float = -0.9
var hit_high: float = 0.9

var _material: StandardMaterial3D = null
var _rng := RandomNumberGenerator.new()

# ONE BUILD PER KIND, KEPT. Cutting a profile into sixteen cells and lathing a
# mesh for each is cheap once and wasteful sixty times; the meshes are immutable
# and shared between every corpse of that kind. The MATERIAL is not shared -- it
# is duplicated per corpse below, because fading one pile must not fade the rest,
# which is the trap special_body.gd already documents about sub-resources.
static var _built: Dictionary = {}


# THE ONLY WAY TO MAKE ONE. `from` is where the disturbance came from: pass
# `has_from` false for a body that simply died and should stand there, true for a
# blast, which never leaves a pile standing.
# NO YAW. Every body that can leave a corpse is a solid of revolution, so the
# pile has no orientation to get wrong -- and a parameter whose value cannot be
# observed is one that rots quietly until the day it matters. If an asymmetric
# enemy ever needs a corpse, fragment_shape has to grow a non-lathe case anyway,
# and the facing goes in beside it.
static func spawn(parent: Node, kind_id: int, at: Vector3,
		from: Vector3, has_from: bool, seed_value: int, count: int = 0) -> Node3D:
	if not SCENES.has(kind_id):
		return null
	# `count` overrides CORPSE_FRAGMENTS, and exists for the shot manifest: the
	# density of a death is a look to be chosen by eye, and choosing it means
	# rendering three of them side by side rather than editing a constant three
	# times. Zero means "whatever the game ships".
	var built: Dictionary = _build(kind_id, count if count > 0 else SimConfig.CORPSE_FRAGMENTS)
	if built.is_empty():
		return null

	var corpse := Node3D.new()
	corpse.set_script(load("res://scripts/sim/corpse.gd"))
	parent.add_child(corpse)
	# AFTER the add, or a sibling of the same name silently makes this an
	# anonymous @Node3D@1234 -- CLAUDE.md's entry on gunshot nodes, and several
	# corpses in one frame is exactly the case that hits it.
	corpse.name = "Corpse"
	corpse.position = at
	corpse.kind = kind_id
	corpse._assemble(built, seed_value)
	if has_from:
		corpse.scatter(from, SimConfig.CORPSE_BLAST_BOOST)
	return corpse

# CUT EVERY KIND UP NOW, BEFORE ANYTHING DIES.
#
# The cache below means a kind is cut once and reused, but LAZILY -- so without
# this the first rusher to die does the cutting, in the middle of a fight, on the
# frame it dies. Measured (test_corpse_cost): a cold build is about 7 ms against
# a 16.7 ms frame, and there is one per kind, each landing the first time the
# player kills that enemy. A hitch at the exact moment somebody is watching the
# thing they just shot.
#
# Called from GameWorld.start(), where 20 ms is invisible. Idempotent and static,
# so a second world in the same process pays nothing.
static func prime() -> void:
	for kind_id in SCENES.keys():
		_build(kind_id, SimConfig.CORPSE_FRAGMENTS)

# Cut the body up once and remember it. Returns {} if the scene has no mesh this
# file knows how to lathe, which is the honest answer for a shape that is not a
# solid of revolution: the caller shows nothing rather than showing a wrong thing.
static func _build(kind_id: int, count: int) -> Dictionary:
	# KEYED BY COUNT AS WELL AS KIND. Keyed by kind alone, the first corpse of a
	# kind would decide the piece count for every later one -- which is invisible
	# in the game, where the count never varies, and wrong in the one place the
	# override exists for.
	var key: String = "%d/%d" % [kind_id, count]
	if _built.has(key):
		return _built[key]

	var packed: PackedScene = load(str(SCENES[kind_id]))
	if packed == null:
		return {}
	var sample: Node = packed.instantiate()
	var mesh_node := sample.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_node == null or mesh_node.mesh == null:
		sample.free()
		return {}

	var profile: FragmentShape.Profile = FragmentShape.profile_from_mesh(mesh_node.mesh)
	if profile == null:
		sample.free()
		return {}

	# THE ENEMY'S OWN MATERIAL, so a corpse can never be a different colour from
	# the thing that died. Same argument as reading the profile off the mesh.
	var source := mesh_node.material_override as StandardMaterial3D
	var colour: Color = source.albedo_color if source != null else Color(0.6, 0.6, 0.6)

	var cells: Array = FragmentShape.fragment(profile, count)
	var meshes: Array = []
	var centres: Array = []
	var sizes: Array = []
	for cell in cells:
		var centre: Vector3 = FragmentShape.cell_centre(profile, cell)
		var mesh: ArrayMesh = FragmentShape.cell_mesh(profile, cell, centre)
		meshes.append(mesh)
		centres.append(centre)
		sizes.append(mesh.get_aabb())
	sample.free()

	_built[key] = {
		"colour": colour,
		"meshes": meshes,
		"centres": centres,
		"bounds": sizes,
		# THE SHAPE OF THE BODY THAT DIED, for anything that wants to ask whether
		# it hit the pile. Read off the same profile the pieces were cut from, so
		# it cannot disagree with what is drawn -- and a cylinder rather than a
		# sphere, because a body is much taller than it is wide and a sphere would
		# be generous at the waist and mean at the head.
		"radius": profile.max_radius(),
		"low": profile.y0,
		"high": profile.y1,
	}
	return _built[key]

func _assemble(built: Dictionary, seed_value: int) -> void:
	_rng.seed = seed_value
	hit_radius = float(built.get("radius", 0.5))
	hit_low = float(built.get("low", -0.9))
	hit_high = float(built.get("high", 0.9))

	_material = StandardMaterial3D.new()
	_material.albedo_color = built["colour"]
	_material.roughness = 0.8
	# A DEPTH PRE-PASS, NOT PLAIN ALPHA, AND THE PICTURE IS THE ARGUMENT.
	#
	# The fade at the end of a corpse's life needs a transparent material, and it
	# is set from the start rather than switched on later: changing the mode
	# mid-life moves the material between render passes, and the sort order it
	# lands in is a different question from the one it left.
	#
	# But TRANSPARENCY_ALPHA does not WRITE DEPTH. Sixteen pieces of one body are
	# sixteen objects in the alpha pass sorted by their ORIGINS, painting over each
	# other in whatever order that gives -- so an intact pile rendered with a
	# quarter of itself missing and the inside of its own far wall showing through.
	# CLAUDE.md already records this exact pass, on the status bar that went solid
	# black when its fill slid behind its own backing.
	#
	# ALPHA_DEPTH_PRE_PASS lays depth down first, so the opaque part of a
	# translucent object occludes correctly and only the genuinely faded part
	# blends. One material for the whole life, and it looks like a solid body while
	# it is one.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS

	var meshes: Array = built["meshes"]
	var centres: Array = built["centres"]
	var bounds: Array = built["bounds"]
	for i in range(meshes.size()):
		var piece := RigidBody3D.new()
		piece.collision_layer = LAYER_DEBRIS
		piece.collision_mask = DEBRIS_MASK
		# The engine's gravity is 9.8 and this game's is 24; debris that fell at a
		# different rate to everything else would read as floating. Same line the
		# plinko ball carries, for the same reason.
		piece.gravity_scale = SimConfig.GRAVITY / 9.8
		piece.freeze = true
		piece.can_sleep = true

		var view := MeshInstance3D.new()
		view.mesh = meshes[i]
		view.material_override = _material
		piece.add_child(view)

		# A BOX AND NOT THE CONVEX HULL OF THE PIECE. Two reasons, and the second
		# is the one that matters: a box is a fraction of the solver cost, on
		# something there may be a hundred of; and CLAUDE.md's entry on a convex
		# hull disagreeing with a cylinder by METRES at 160 m up the bridge is a
		# warning about exactly this family of shape at exactly the distances a
		# corpse appears at. Nobody can see the difference on a chip that lives
		# three seconds -- and a wrong resting angle is invisible where an ejection
		# is not.
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var aabb: AABB = bounds[i]
		box.size = Vector3(maxf(aabb.size.x, 0.02), maxf(aabb.size.y, 0.02),
			maxf(aabb.size.z, 0.02))
		shape.shape = box
		shape.position = aabb.position + aabb.size * 0.5
		piece.add_child(shape)

		add_child(piece)
		piece.name = "Fragment%d" % i
		# THE PIECE GOES EXACTLY WHERE IT CAME FROM. Its mesh was built around this
		# same centre, so mesh plus placement reassembles the body vertex for
		# vertex -- which is what makes the pile indistinguishable from the body.
		piece.position = centres[i]
		fragments.append(piece)

# COME APART. `from` is where the push came from -- a body that walked into the
# pile, or the centre of a blast -- and `boost` multiplies the throw.
#
# Idempotent: a second bump on an already-scattered corpse does nothing, so a
# player standing in the debris does not re-launch it sixty times a second.
func scatter(from: Vector3, boost: float = 1.0) -> void:
	if state == State.SCATTERED:
		return
	state = State.SCATTERED
	scatter_age = 0.0
	for piece in fragments:
		if not is_instance_valid(piece):
			continue
		piece.freeze = false
		var away: Vector3 = piece.global_position - from
		if away.length_squared() < 0.0001:
			# Dead centre. Any direction will do, but it must not be zero or the
			# piece sits in the middle of a burst doing nothing.
			away = Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0))
		away = away.normalized()
		# Falls off with distance, so a nudge to one side of the pile tips it over
		# rather than detonating it.
		var reach: float = clampf(1.0 - piece.global_position.distance_to(from)
			/ (SimConfig.CORPSE_BUMP_RADIUS * 2.0), 0.25, 1.0)
		piece.linear_velocity = (away * SimConfig.CORPSE_SCATTER_SPEED
			+ Vector3.UP * SimConfig.CORPSE_SCATTER_LIFT) * reach * boost
		piece.angular_velocity = Vector3(
			_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-1.0, 1.0)).normalized() * SimConfig.CORPSE_SCATTER_SPIN

# Is `point` inside the volume the body occupied? Corpse-local, so the caller
# passes a world point and this does the subtraction.
func covers(point: Vector3) -> bool:
	var local: Vector3 = point - global_position
	if local.y < hit_low or local.y > hit_high:
		return false
	return local.x * local.x + local.z * local.z <= hit_radius * hit_radius

func is_intact() -> bool:
	return state == State.INTACT

# The pile's centre in world space, which is what the bump test measures from.
# NOT the node origin: that is at the enemy's feet-to-centre origin and the test
# wants the middle of the mass.
func centre() -> Vector3:
	return global_position

# --- Life --------------------------------------------------------------------
#
# _physics_process rather than _process: everything else in this game is
# denominated in fixed ticks, and a fade that ran on render frames would take a
# different length of time on a different machine.
func _physics_process(delta: float) -> void:
	age += delta
	if state == State.SCATTERED:
		scatter_age += delta

	var life: float = remaining()
	if life <= 0.0:
		queue_free()
		return
	if _material != null:
		_material.albedo_color.a = clampf(life / SimConfig.CORPSE_FADE_SECONDS, 0.0, 1.0)

# Seconds left. An intact pile is on the standing clock; a scattered one is on
# the debris clock, measured from the scatter.
func remaining() -> float:
	if state == State.SCATTERED:
		return SimConfig.CORPSE_DEBRIS_LIFETIME - scatter_age
	return SimConfig.CORPSE_LIFETIME - age
