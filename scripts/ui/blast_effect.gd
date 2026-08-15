extends Node3D

# What an explosion LOOKS like. Built entirely in code, like hitbox_view.gd, so
# the numbers and the reasons sit next to each other rather than in a .tscn nobody
# reads.
#
# TWO PARTS, AND THE FIRST ONE IS GAMEPLAY.
#
#   THE FLASH is a sphere expanded to the blast's TRUE radius. It is not
#   decoration: BLAST_RADIUS is 4 m, a grenade's near throw lands inside it on
#   purpose, and until this existed there was no way for a player to learn how big
#   "in the blast" is except by dying in it. A visual that lies about the radius
#   would be worse than none, so it reads the radius it is handed and nothing else.
#
#   THE SHARDS are the character. A one-shot GPUParticles3D burst -- the standard
#   Godot recipe for this is `one_shot = true` with `explosiveness = 1.0`, which
#   emits the whole amount on the first frame instead of dribbling them out over
#   the lifetime.
#
# WARM, like everything on this bridge that hurts you. See special_body's kind
# colours: cool is the shield and nothing else.
#
# IT FREES ITSELF. An effect that needs an owner to remember to clean it up is one
# that leaks the first time an owner is culled mid-animation -- and a grenade is
# destroyed at the exact moment it makes one of these.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# The flash is FAST. Long enough to read at 30 m, short enough that it is gone
# before the player has to act on what it revealed.
const FLASH_SECONDS := 0.18

# It starts as a ball rather than a point, or the first frame is invisible.
const FLASH_START_FRACTION := 0.18

const SHARD_LIFETIME := 0.55
const SHARD_COUNT := 26

var _age: float = 0.0
var _radius: float = SimConfig.BLAST_RADIUS
var _flash: MeshInstance3D = null
var _flash_material: StandardMaterial3D = null

# `radius` is the same number blast_at resolved damage with. Passing it rather
# than reading the constant means a smaller blast, if one is ever added, draws
# itself correctly for free.
static func spawn(parent: Node, at: Vector3, radius: float) -> Node3D:
	var fx := Node3D.new()
	fx.set_script(load("res://scripts/ui/blast_effect.gd"))
	fx.name = "Blast"
	parent.add_child(fx)
	fx.position = at
	fx._setup(radius)
	return fx

func _setup(radius: float) -> void:
	_radius = maxf(radius, 0.5)
	_build_flash()
	_build_shards()

func _build_flash() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8

	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# SEEN FROM INSIDE. The player who mistimed their own throw is standing in it,
	# and a back-face-culled sphere is invisible to exactly the person who most
	# needs to be told what just happened.
	_flash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# DEPTH TEST STAYS ON, unlike the hitbox view. A blast behind a pillar did not
	# reach you, and one that glowed through the pillar would say it did.
	_flash_material.albedo_color = Color(1.0, 0.93, 0.7, 0.85)

	_flash = MeshInstance3D.new()
	_flash.name = "Flash"
	_flash.mesh = sphere
	_flash.material_override = _flash_material
	_flash.scale = Vector3.ONE * (_radius * FLASH_START_FRACTION)
	add_child(_flash)

func _build_shards() -> void:
	var particles := GPUParticles3D.new()
	particles.name = "Shards"
	particles.amount = SHARD_COUNT
	particles.lifetime = SHARD_LIFETIME
	# THE WHOLE POINT OF A BURST: one_shot stops it repeating, explosiveness 1.0
	# emits every particle on the first frame. Without the second one this is a
	# fountain that happens to stop, which reads as a flare rather than a bang.
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.local_coords = false

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = 180.0
	mat.initial_velocity_min = _radius * 1.2
	mat.initial_velocity_max = _radius * 3.0
	# The game's own gravity, so debris falls at the rate everything else does.
	mat.gravity = Vector3(0.0, -SimConfig.GRAVITY, 0.0)
	mat.damping_min = 1.0
	mat.damping_max = 4.0
	mat.scale_min = 0.35
	mat.scale_max = 0.9
	mat.angular_velocity_min = -360.0
	mat.angular_velocity_max = 360.0

	# White-hot into ember into nothing. The alpha reaching zero is what ends a
	# shard; there is no separate fade to keep in step with the lifetime.
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.95, 0.75, 1.0))
	ramp.set_color(1, Color(0.85, 0.25, 0.05, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	mat.color_ramp = ramp_tex

	particles.process_material = mat

	# CHUNKY AND UNSHADED. A box catches the eye at 30 m where a billboard quad
	# turns to mush, and this game is read at that distance.
	var shard := BoxMesh.new()
	shard.size = Vector3(0.16, 0.16, 0.16)
	var shard_mat := StandardMaterial3D.new()
	shard_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shard_mat.vertex_color_use_as_albedo = true
	shard_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shard.material = shard_mat
	particles.draw_pass_1 = shard

	add_child(particles)
	particles.emitting = true

func _process(delta: float) -> void:
	_age += delta

	if _flash != null:
		var t: float = clampf(_age / FLASH_SECONDS, 0.0, 1.0)
		# Fast out, slow in: most of the growth happens in the first few frames,
		# which is what makes it read as a detonation rather than a balloon.
		var eased: float = 1.0 - pow(1.0 - t, 3.0)
		var span: float = _radius * (1.0 - FLASH_START_FRACTION)
		_flash.scale = Vector3.ONE * (_radius * FLASH_START_FRACTION + span * eased)
		_flash_material.albedo_color.a = 0.85 * (1.0 - t)
		if t >= 1.0:
			_flash.queue_free()
			_flash = null

	# Outlived by the shards, so the node cannot go while they are still in the
	# air. A small margin on top: a particle emitted on the last possible frame
	# still owes its full lifetime.
	if _age >= SHARD_LIFETIME + 0.2:
		queue_free()
