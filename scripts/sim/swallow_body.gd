extends CharacterBody3D

# THE BUBBLE SWALLOW. See implementation_plans/m28_bubble_swallow.md.
#
# An ambush that sits under the water with nothing showing, surfaces when somebody
# comes close, pulls them in and eats what they are carrying -- and does not
# destroy any of it. Kill it and everything falls out. Walk away and it is gone.
#
# SUBMERGED IS ABSOLUTE. No collider, so a bullet cannot find it; and the world's
# blast pass skips it explicitly, because `_blast_targets` walks the pools by
# DISTANCE and never asks about colliders. Two routes to a target, so two
# refusals -- a rule enforced on one of them is the shape of every collision-mask
# bug in this project.
#
# IT IS THE FIRST ENEMY HERE WITH HEALTH. Every other one dies to a single bullet;
# the only `health` field in the codebase before this was on PlayerBody. A hazard
# you have to shoot WHILE it is eating you has to survive the first shot, or there
# is no fight to have.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# `bus` is 2048 and the layer names run out there; a swallow is an enemy that
# bullets must find, so it sits with the things bullets already look for.
const LAYER := 1 << 3            # 4: "enemies", the layer rushers and gunners use

var swallow_id: int = 0
var cell: Vector2i = Vector2i.ZERO
var health: int = SimConfig.SWALLOW_HEALTH
var killed: bool = false

# UP OR UNDER. The whole of "you cannot pick it off at range" is this flag: while
# it is false the body has no shape and the blast pass steps over it.
var surfaced: bool = false

# THE BANK. Style ids and kinds rather than the nodes themselves -- a hat inside a
# swallow is not in the world, and keeping a freed or reparented node alive to
# represent it is the dangling-reference shape this project has paid for twice.
# The owner rides along so a loss can be attributed when nobody comes back for it.
var held_hats: Array = []        # [[style_id, owner_peer], ...]
var held_specials: Array = []    # [kind, ...]

var drain_timer: float = 0.0

var _shell: MeshInstance3D = null
var _maw: MeshInstance3D = null
var _bubbles: CPUParticles3D = null
var _shape: CollisionShape3D = null
var _built_for: int = -1         # the bank size the shell was last sized at

# HOW FAR OUT OF THE WATER IT IS, 0 to 1. Visual only: the collider is full size
# the instant it surfaces, because a hitbox that grows in would mean the first
# shots of the fight silently miss.
var _swell: float = 0.0
var _breath: float = 0.0

func _ready() -> void:
	collision_layer = LAYER
	collision_mask = 0            # it does not move; nothing needs to push it
	_build()
	_apply_surfaced()

# --- The look -----------------------------------------------------------------
#
# Five loads on one object, and the shell carries two of them: that it is UP, and
# how much it has eaten. See the table in the plan.

func _build() -> void:
	_shape = CollisionShape3D.new()
	_shape.shape = SphereShape3D.new()
	add_child(_shape)

	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	_shell.mesh = SphereMesh.new()
	var glass := StandardMaterial3D.new()
	glass.albedo_color = SimConfig.SWALLOW_SHELL
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# LIT LIKE GLASS, not like a solid. A flat-shaded opaque sphere the size of
	# this thing reads as a plinko ball, which is the one silhouette it must not
	# be mistaken for.
	glass.roughness = 0.15
	_shell.material_override = glass
	add_child(_shell)

	# THE MAW FACES UP. A mouth on the side is invisible from the only camera
	# anybody has -- it looks wrong in elevation and is right on screen.
	_maw = MeshInstance3D.new()
	_maw.name = "Maw"
	var disc := CylinderMesh.new()
	disc.top_radius = SimConfig.SWALLOW_MAW_RADIUS
	disc.bottom_radius = SimConfig.SWALLOW_MAW_RADIUS
	disc.height = 0.05
	_maw.mesh = disc
	var dark := StandardMaterial3D.new()
	dark.albedo_color = SimConfig.SWALLOW_MAW
	_maw.material_override = dark
	add_child(_maw)

	# WHAT IS VISIBLE WHILE IT IS UNDER, and the only thing that is. They mark a
	# PLACE rather than an imminent action, and nothing about them can be shot --
	# no collider here and none anywhere on the body while submerged.
	#
	# A PARTICLE SYSTEM RATHER THAN THREE SPHERES IN A ROW. Static bubbles read as
	# three balls parked on the water, which is the opposite of what they are for:
	# the whole job of this effect is to say "something is alive down there", and
	# a thing that does not move says the reverse.
	#
	# CPU RATHER THAN GPU PARTICLES. This is eight bubbles, so there is nothing to
	# gain from the GPU path, and the headless gate builds every node in this tree
	# -- a visual that only constructs on a machine with a renderer is a visual the
	# gate never once executes, which is how a UI script ships having never run.
	_bubbles = CPUParticles3D.new()
	_bubbles.name = "Bubbles"
	var puff := SphereMesh.new()
	puff.radius = 0.09
	puff.height = 0.18
	puff.radial_segments = 6
	puff.rings = 3
	_bubbles.mesh = puff
	var pale := StandardMaterial3D.new()
	pale.albedo_color = SimConfig.SWALLOW_SHELL
	pale.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bubbles.material_override = pale
	_bubbles.amount = 8
	_bubbles.lifetime = 1.8
	# RISING SLOWLY AND UNEVENLY. Buoyancy rather than a fountain: gravity is
	# turned around and kept small, so they drift up at the pace of something
	# breathing under water rather than being fired out of it.
	_bubbles.gravity = Vector3(0.0, 0.35, 0.0)
	_bubbles.direction = Vector3(0.0, 1.0, 0.0)
	_bubbles.spread = 12.0
	_bubbles.initial_velocity_min = 0.15
	_bubbles.initial_velocity_max = 0.45
	# EMITTED ACROSS THE CELL IT LIVES IN, not from a point -- a single column of
	# bubbles is a pipe, and what this has to look like is a patch of water with
	# something under it.
	_bubbles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_bubbles.emission_sphere_radius = 0.55
	_bubbles.scale_amount_min = 0.5
	_bubbles.scale_amount_max = 1.0
	# SHRINKING AS THEY GO, so they read as popping at the surface rather than
	# vanishing mid-rise.
	# `scale_amount_curve`, AND A `Curve`. Neither the name nor the type is the
	# GPU path's -- that one wants `scale_curve` on a ParticleProcessMaterial and
	# a CurveTexture -- and getting either wrong is a RUNTIME error, which in
	# GDScript aborts the rest of the function silently. It did, twice: `_resize`
	# never ran and the test passed both times, because nothing in it looked at
	# the mesh. There is a claim about that now.
	var fade := Curve.new()
	fade.add_point(Vector2(0.0, 1.0))
	fade.add_point(Vector2(0.75, 0.85))
	fade.add_point(Vector2(1.0, 0.0))
	_bubbles.scale_amount_curve = fade
	add_child(_bubbles)

	_resize()

# HOW BIG IT IS, IS HOW MUCH IT IS WORTH. And the collider grows with the mesh,
# because a mesh may not lie about its collider -- so a fed swallow really is an
# easier target. That is the risk and the reward of letting it eat.
func radius() -> float:
	return SimConfig.SWALLOW_RADIUS 		+ SimConfig.SWALLOW_GROWTH * float(held_hats.size() + held_specials.size())

func _resize() -> void:
	var total: int = held_hats.size() + held_specials.size()
	if total == _built_for:
		return
	_built_for = total
	var r: float = radius()
	var mesh := _shell.mesh as SphereMesh
	mesh.radius = r
	mesh.height = r * 2.0
	(_shape.shape as SphereShape3D).radius = r
	_maw.position = Vector3(0.0, r * 0.82, 0.0)

# THE ONLY THING IN THIS FILE THAT IS NOT THE SIMULATION, which is why it is in
# `_process` rather than in the world's tick: it changes nothing anybody can be
# hit by, so it does not have to be replayed, agreed on, or captured in a state
# blob.
func _process(delta: float) -> void:
	var want: float = 1.0 if surfaced else 0.0
	_swell = move_toward(_swell, want, delta / SimConfig.SWALLOW_SWELL_SECONDS)
	_breath = fmod(_breath + delta, SimConfig.SWALLOW_BREATH_SECONDS)
	if _shell == null:
		return
	# INWARD ONLY. `(1 - cos)/2` runs 0..1, so the factor runs from 1.0 down to
	# (1 - depth) and never above -- the mesh is sometimes a little inside its
	# collider and never outside it. See the note on the constants.
	var phase: float = TAU * _breath / SimConfig.SWALLOW_BREATH_SECONDS
	var breath: float = 1.0 - SimConfig.SWALLOW_BREATH_DEPTH * (0.5 - 0.5 * cos(phase))
	var shown: float = _swell * breath
	_shell.scale = Vector3.ONE * shown
	if _maw != null:
		# THE MAW RIDES THE SURFACE it is cut into, or it floats off the top of a
		# shrinking shell and reads as a second object.
		_maw.position = Vector3(0.0, radius() * 0.82 * shown, 0.0)
		_maw.scale = Vector3.ONE * maxf(shown, 0.001)

func _apply_surfaced() -> void:
	# THE SHELL STAYS VISIBLE WHILE IT SHRINKS BACK. `_process` drives the swell
	# to zero over SWALLOW_SWELL_SECONDS; hiding it here would make diving a cut
	# rather than a movement, and surfacing already is the only event this enemy
	# offers.
	_shell.visible = surfaced or _swell > 0.01
	_maw.visible = surfaced
	_bubbles.visible = not surfaced
	# STOPPED, NOT JUST HIDDEN. A hidden emitter goes on simulating, so surfacing
	# and diving repeatedly would leave a backlog of bubbles to pop out at once.
	_bubbles.emitting = not surfaced
	# THE SHAPE IS DISABLED, NOT RESIZED. A tiny collider is still a collider, and
	# "untouchable" has to mean there is nothing there at all.
	_shape.disabled = not surfaced

# --- Surfacing ----------------------------------------------------------------

# UP WHEN SOMEBODY IS IN REACH, DOWN WHEN NOBODY IS. A party that backs off does
# not get to plink at it: the fight has to be held, which is what makes the person
# being drained the one keeping it shootable.
func set_surfaced(up: bool) -> void:
	if up == surfaced:
		return
	surfaced = up
	# THE DRAIN CLOCK RESTARTS, so surfacing does not hand out a free hat from a
	# timer that has been running under water since the last visitor.
	drain_timer = 0.0
	_apply_surfaced()

# --- The pull -----------------------------------------------------------------

# WHAT THIS DOES TO A BODY AT `at`, as a world-space velocity to add.
#
# THE ARITHMETIC IS THE FAIRNESS. This enemy cannot warn you -- it has no
# wind-up by design -- so the thing that keeps it fair is that the pull is
# beatable at the rim and not in the core, and that is a statement about two
# numbers rather than a feel:
#
#   at the rim   PULL_RIM  < WALK_SPEED  -- you walked in, you can walk out
#   in the core  PULL_CORE > WALK_SPEED  -- legs are not the answer, shooting is
#
# Linear between them, so there is no step to stand on and the boundary a player
# feels is the same one the drain uses.
func pull_at(at: Vector3) -> Vector3:
	if not surfaced:
		return Vector3.ZERO
	var away: Vector3 = global_position - at
	away.y = 0.0
	var d: float = away.length()
	if d < 0.001 or d > SimConfig.SWALLOW_REACH:
		return Vector3.ZERO
	var strength: float = SimConfig.SWALLOW_PULL_CORE
	if d > SimConfig.SWALLOW_CORE:
		var t: float = (d - SimConfig.SWALLOW_CORE) 			/ maxf(0.001, SimConfig.SWALLOW_REACH - SimConfig.SWALLOW_CORE)
		strength = lerpf(SimConfig.SWALLOW_PULL_CORE, SimConfig.SWALLOW_PULL_RIM, t)
	return away.normalized() * strength

# INSIDE THE CORE IS WHERE YOU ARE EATEN, and it is the same boundary the pull
# stops being escapable at. One boundary doing two jobs on purpose: if they ever
# drift apart, "am I being eaten" stops being answerable by "can I still walk
# away", and the enemy stops being legible.
func holds(at: Vector3) -> bool:
	if not surfaced:
		return false
	var away: Vector3 = global_position - at
	away.y = 0.0
	return away.length() <= SimConfig.SWALLOW_CORE

# --- The bank -----------------------------------------------------------------

func swallow_hat(style_id: int, owner_peer: int) -> void:
	held_hats.append([style_id, owner_peer])
	_resize()

func swallow_special(kind: int) -> void:
	held_specials.append(kind)
	_resize()

func bank_size() -> int:
	return held_hats.size() + held_specials.size()

# --- Damage -------------------------------------------------------------------

func receive_hit(hit) -> bool:
	# NOT WHILE IT IS UNDER. The collider is gone, so a bullet cannot arrive here
	# at all -- this is the second refusal, for anything that finds a target by
	# walking a pool rather than by casting a ray.
	if not surfaced or killed:
		return false
	health -= int(hit.damage) if "damage" in hit else 1
	if health <= 0:
		killed = true
	return true

func is_spent() -> bool:
	return killed

# --- Replication --------------------------------------------------------------
#
# Motion rides the snapshot; DECISIONS go reliably. What it is holding and whether
# it is up are decisions, so they are here rather than in a delta -- a client that
# missed the packet naming a swallow's bank would draw an empty shell over
# somebody's hats.

func capture_state() -> Array:
	return [position, surfaced, health, held_hats.duplicate(),
		held_specials.duplicate(), drain_timer, killed]

func apply_state(s: Array) -> void:
	position = s[0]
	var up: bool = bool(s[1])
	health = int(s[2])
	held_hats = (s[3] as Array).duplicate()
	held_specials = (s[4] as Array).duplicate()
	drain_timer = float(s[5])
	killed = bool(s[6])
	_resize()
	if up != surfaced:
		surfaced = up
		_apply_surfaced()
