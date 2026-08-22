extends Node3D

# Where a round landed. Asked for after the bullet speed fell to 10 m/s, and the
# timing is not a coincidence: rounds only just became slow enough to watch, so
# the moment they arrive is legible for the first time.
#
# IT ANSWERS "DID I CONNECT?", which is the one thing the shooter genuinely
# cannot tell right now. At 10 m/s with 10 degrees of spread, a round crossing
# 12 m has a cone four metres wide against a body under one metre -- most shots
# miss, and until this existed a miss and a hit looked identical from behind the
# gun. So there are TWO colours and not one: a generic spark would say "something
# happened here", which the player already knew.
#
#   WARM   -- it hit something that takes a hit. A connect.
#   PALE   -- it hit the world: deck, parapet, pillar. Cover did its job.
#
# That is deliberately the same split the damage matrix draws, rather than a
# colour per object: the question is binary, and a legend with six entries is one
# nobody learns mid-fight.
#
# IT FREES ITSELF, like blast_effect.gd. The bullet that made it is destroyed on
# the same tick, so anything waiting for an owner to tidy up would leak.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# SHORT. This fires several times a second across a party of four, and a puff
# that outlives the shot becomes a fog that hides the thing it is reporting.
const LIFETIME := 0.3
const SPARKS := 9

const CONNECT_HOT := Color(1.0, 0.85, 0.45, 1.0)
const CONNECT_COOL := Color(0.95, 0.25, 0.15, 0.0)
const COVER_HOT := Color(0.92, 0.92, 0.96, 0.9)
const COVER_COOL := Color(0.55, 0.55, 0.6, 0.0)

var _age: float = 0.0

# `at` and `normal` are in the PARENT's space -- the GameWorld's -- like every
# other position crossing this boundary. Two worlds sit a kilometre apart in one
# physics space, so a global point would land in whichever one is at the origin.
static func spawn(parent: Node, at: Vector3, normal: Vector3, connected: bool) -> Node3D:
	var fx := Node3D.new()
	fx.set_script(load("res://scripts/ui/shot_impact.gd"))
	fx.name = "Impact"
	parent.add_child(fx)
	fx.position = at
	fx._setup(normal, connected)
	return fx

func _setup(normal: Vector3, connected: bool) -> void:
	var particles := GPUParticles3D.new()
	particles.name = "Sparks"
	particles.amount = SPARKS
	particles.lifetime = LIFETIME
	# one_shot stops it repeating; explosiveness 1.0 emits the lot on the first
	# frame. Without the second it is a fountain that happens to stop, which reads
	# as a flare rather than as an impact -- same recipe as blast_effect's shards.
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.local_coords = false

	var mat := ParticleProcessMaterial.new()
	# BACK ALONG THE SURFACE NORMAL, which is what makes this read as a ricochet
	# rather than as a puff of smoke. A flat spray would look the same whatever it
	# hit, and the direction is free information the raycast already returned.
	var away: Vector3 = normal
	if away.length_squared() < 0.0001:
		away = Vector3.UP
	mat.direction = away.normalized()
	mat.spread = 55.0
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 5.5
	mat.gravity = Vector3(0.0, -SimConfig.GRAVITY, 0.0)
	mat.damping_min = 2.0
	mat.damping_max = 6.0
	mat.scale_min = 0.3
	mat.scale_max = 0.7

	var ramp := Gradient.new()
	ramp.set_color(0, CONNECT_HOT if connected else COVER_HOT)
	ramp.set_color(1, CONNECT_COOL if connected else COVER_COOL)
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	mat.color_ramp = ramp_tex
	particles.process_material = mat

	# CHUNKY AND UNSHADED, for the reason blast_effect gives: a box still catches
	# the eye at 30 m where a billboard quad turns to mush, and this game is read
	# at that distance.
	var bit := BoxMesh.new()
	bit.size = Vector3(0.07, 0.07, 0.07)
	var bit_mat := StandardMaterial3D.new()
	bit_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bit_mat.vertex_color_use_as_albedo = true
	bit_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bit.material = bit_mat
	particles.draw_pass_1 = bit

	add_child(particles)
	particles.emitting = true

func _process(delta: float) -> void:
	_age += delta
	# A margin past the lifetime so the last spark is not cut off mid-flight.
	if _age > LIFETIME * 1.6:
		queue_free()
