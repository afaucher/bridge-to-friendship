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
enum Kind { RUSHER, ZOMBIE, SKIRMISHER, TURRET }

const SCENES := {
	Kind.RUSHER: "res://scenes/rusher.tscn",
	Kind.ZOMBIE: "res://scenes/zombie.tscn",
	Kind.SKIRMISHER: "res://scenes/skirmisher.tscn",
	Kind.TURRET: "res://scenes/turret.tscn",
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

# One per distinct colour on this corpse. See _assemble.
var _materials: Dictionary = {}
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
# TWO YAWS, AND THEY ARE NOT THE SAME ANGLE.
#
# `body_yaw` is which way the body itself is turned -- a zombie swings its whole
# node to face where it is walking, and its ARMS go with it. `aim_yaw` is the
# separate spin of the "Facing" pivot, which a turret uses to point its gun while
# its base stays bolted where it was poured.
#
# THIS PARAMETER WAS REMOVED ON PURPOSE AND THE REASONING EXPIRED. The note that
# replaced it said every body that can leave a corpse is a solid of revolution,
# so a pile has no orientation to get wrong -- true of a rusher, a capsule and a
# cone, and FALSE the day a zombie kept its arms and a turret grew a gun barrel.
# Reported from play as a turret whose barrel snaps to a new direction on the
# hit. A parameter dropped because nothing could observe it is one that comes
# back the moment something can, and the lesson is that "cannot be observed" was
# a fact about the CAST, not about the code.
static func spawn(parent: Node, kind_id: int, at: Vector3, body_yaw: float,
		aim_yaw: float, from: Vector3, has_from: bool, seed_value: int,
		count: int = 0) -> Node3D:
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
	corpse.rotation.y = body_yaw
	corpse.kind = kind_id
	corpse._assemble(built, seed_value, aim_yaw)
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
	var parts: Array = _parts_of(sample)
	if parts.is_empty():
		sample.free()
		return {}

	var pieces: Array = FragmentShape.fragment_body(parts, count)
	var meshes: Array = []
	var places: Array = []
	var sizes: Array = []
	var colours: Array = []
	var aimed: Array = []
	for piece in pieces:
		var mesh: ArrayMesh = FragmentShape.piece_mesh(parts, piece)
		meshes.append(mesh)
		places.append(FragmentShape.piece_placement(parts, piece))
		sizes.append(mesh.get_aabb())
		colours.append(parts[piece.part].colour)
		aimed.append(parts[piece.part].articulated)

	# The volume the whole body filled, for anything asking whether it hit the
	# pile. Taken across every part, so a turret's gun barrel counts.
	var low: float = INF
	var high: float = -INF
	var reach: float = 0.0
	for part in parts:
		var aabb: AABB = _part_bounds(part)
		low = minf(low, aabb.position.y)
		high = maxf(high, aabb.end.y)
		reach = maxf(reach, maxf(absf(aabb.position.x), absf(aabb.end.x)))
		reach = maxf(reach, maxf(absf(aabb.position.z), absf(aabb.end.z)))
	sample.free()

	_built[key] = {
		"meshes": meshes,
		"places": places,
		"bounds": sizes,
		"colours": colours,
		"aimed": aimed,
		# THE SHAPE OF THE BODY THAT DIED, for anything that wants to ask whether
		# it hit the pile. Read off the same parts the pieces were cut from, so it
		# cannot disagree with what is drawn -- and a cylinder rather than a
		# sphere, because a body is much taller than it is wide and a sphere would
		# be generous at the waist and mean at the head.
		"radius": reach,
		"low": low,
		"high": high,
	}
	return _built[key]

# EVERY VISIBLE MESH ON THE BODY, WITH WHERE IT SITS AND WHAT COLOUR IT IS.
#
# Walked rather than named. "The mesh called Mesh" was true of the first three
# enemies and false of the fourth: a TURRET is a tapered base, a ring and a gun
# barrel, in two different greys, and a ZOMBIE has two arms that were silently
# dropped from its corpse for as long as this looked for one node.
#
# VISIBLE ONLY, which does the right thing for free: a player's raised shield and
# anything else hidden at rest is gear rather than body, and gear is not what a
# corpse is made of.
#
# A mesh this file cannot lathe or box is SKIPPED rather than approximated. It
# will be missing from the pile, which is a visible gap somebody will report --
# far better than a corpse quietly the wrong shape, which nobody can see is
# wrong.
static func _parts_of(root: Node) -> Array:
	var out: Array = []
	_collect_parts(root, root, out, false)
	return out

static func _collect_parts(node: Node, root: Node, out: Array, aimed: bool) -> void:
	# Everything below a node called "Facing" turns with the aim rather than with
	# the body. See FragmentShape.Part.articulated.
	if node != root and node.name == "Facing":
		aimed = true
	var view := node as MeshInstance3D
	if view != null and view.visible and view.mesh != null:
		var part := FragmentShape.Part.new()
		var lathe: FragmentShape.Profile = FragmentShape.profile_from_mesh(view.mesh)
		var handled: bool = false
		if lathe != null:
			part.profile = lathe
			handled = true
		elif view.mesh is BoxMesh:
			part.box = (view.mesh as BoxMesh).size
			handled = true
		if handled:
			part.placement = _relative_to(view, root)
			part.articulated = aimed
			var mat := view.material_override as StandardMaterial3D
			part.colour = mat.albedo_color if mat != null else Color(0.6, 0.6, 0.6)
			out.append(part)
	for child in node.get_children():
		_collect_parts(child, root, out, aimed)

# A node's transform in the body's frame, walked up by hand: the scene is not in
# a tree, so global_transform is not available and would be the wrong question
# anyway -- what is wanted is the offset from the BODY, not from the world.
static func _relative_to(node: Node3D, root: Node) -> Transform3D:
	var out := Transform3D.IDENTITY
	var walk: Node = node
	while walk != null and walk != root:
		var here := walk as Node3D
		if here != null:
			out = here.transform * out
		walk = walk.get_parent()
	return out

# A part's extent in body space, for the hit volume.
static func _part_bounds(part: FragmentShape.Part) -> AABB:
	var half: Vector3
	if part.is_box():
		half = part.box * 0.5
	else:
		half = Vector3(part.profile.max_radius(),
			part.profile.height() * 0.5, part.profile.max_radius())
	var local := AABB(-half, half * 2.0)
	return part.placement * local

func _assemble(built: Dictionary, seed_value: int, aim_yaw: float) -> void:
	_rng.seed = seed_value
	hit_radius = float(built.get("radius", 0.5))
	hit_low = float(built.get("low", -0.9))
	hit_high = float(built.get("high", 0.9))

	_materials.clear()
	# ONE MATERIAL PER COLOUR ON THE BODY, and per CORPSE. A turret is two greys
	# and a zombie is one green; sharing a material between corpses would fade the
	# whole battlefield together, and sharing one between colours would repaint a
	# turret's gun the colour of its base.
	#
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

	var meshes: Array = built["meshes"]
	var places: Array = built["places"]
	var bounds: Array = built["bounds"]
	var colours: Array = built["colours"]
	var aimed: Array = built["aimed"]
	# The pivot sits at the body's own origin, so aiming is a spin about it.
	var aim := Transform3D(Basis(Vector3.UP, aim_yaw), Vector3.ZERO)
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
		view.material_override = _material_for(colours[i])
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
		# THE PIECE GOES EXACTLY WHERE IT CAME FROM, turned the way its PART was
		# turned. Its mesh was built about this same point in the part's own
		# space, so mesh plus placement reassembles the body vertex for vertex --
		# which is what makes the pile indistinguishable from the body.
		piece.transform = (aim * places[i]) if bool(aimed[i]) else places[i]
		fragments.append(piece)

func _material_for(colour: Color) -> StandardMaterial3D:
	var key: String = str(colour)
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.8
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	_materials[key] = mat
	return mat

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
	var alpha: float = clampf(life / SimConfig.CORPSE_FADE_SECONDS, 0.0, 1.0)
	for key in _materials:
		_materials[key].albedo_color.a = alpha

# Seconds left. An intact pile is on the standing clock; a scattered one is on
# the debris clock, measured from the scatter.
func remaining() -> float:
	if state == State.SCATTERED:
		return SimConfig.CORPSE_DEBRIS_LIFETIME - scatter_age
	return SimConfig.CORPSE_LIFETIME - age
