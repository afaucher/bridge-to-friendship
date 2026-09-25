extends RefCounted

# A SMALL FIRE, burning at one point of an accessory -- the shrimp tail's
# outermost fan blade on one side. Presentation only, like the accessory it hangs
# off: no collider, nothing simulated, nothing on the wire. Which accessory burns
# and where is data in CharacterStyle.accessory_flames(); this file only knows
# what a fire looks like.
#
# THREE LAYERS, which is the standard recipe for stylized fire (2026-09-25,
# researched rather than guessed): a small bright CORE that glows, the FLAME
# body that carries the colour, and SMOKE above it. One emitter trying to be all
# three is a blob that is either too pale to read as fire or too dark to glow.
#
#   CORE   additive, near-white, small, fast and short-lived. Additive is what
#          makes a flame GLOW, and on its own it vanishes on anything pale -- the
#          first version of this was additive and disappeared against the studio
#          floor. Here it only has to brighten the flame it sits inside.
#   FLAME  MIXED alpha, yellow to orange to red, shrinking as it rises. Mixed is
#          what keeps it readable on a pale deck; the taper is what makes a
#          column of puffs a tongue of flame instead of a fountain.
#   SMOKE  black, mixed alpha, GROWING as it rises -- the opposite of the flame
#          -- slower, longer-lived, and starting above the flame. Drawn BEHIND
#          the flame (render_priority), so it never dims the fire it comes from.
#
# CPU RATHER THAN GPU PARTICLES, for the reason the swallow's bubbles give: the
# headless gate builds every node in this tree, and a visual that only
# constructs on a machine with a renderer is one the gate never executes. And
# the property names are the CPU path's -- `scale_amount_curve` takes a Curve,
# `color_ramp` a Gradient; the GPU names are different, and a wrong one is a
# runtime error that aborts apply_accessory silently. test_accessory asserts
# every layer's ramp and curve are really set.

# SMALL. A flame the size of a hand on the tip of a blade, not a torch: it is
# trim on a cosmetic, and anything that reads as a hazard on a PLAYER is the
# line art_direction.md's contract rule 1 draws.
const FLAME_AMOUNT := 24
const FLAME_LIFETIME := 0.55
const FLAME_SIZE := 0.16
const EMIT_RADIUS := 0.04

const CORE_AMOUNT := 10
const CORE_LIFETIME := 0.25
const CORE_SIZE := 0.09

# A LITTLE smoke: a few puffs, not a plume. It is a wisp that says "that is
# really burning", and a player trailing a column of black is a player nobody
# behind them can see.
const SMOKE_AMOUNT := 14
const SMOKE_LIFETIME := 1.5
const SMOKE_SIZE := 0.22
# Where the smoke starts, above the flame's root: roughly where the flame has
# burned down to nothing, so smoke rises OUT of the fire rather than through it.
const SMOKE_LIFT := 0.14

const CORE_HOT := Color(1.0, 0.97, 0.80, 0.9)
const CORE_FADE := Color(1.0, 0.80, 0.35, 0.0)
const HOT := Color(1.0, 0.92, 0.45, 1.0)
const WARM := Color(1.0, 0.45, 0.05, 0.95)
const EMBER := Color(0.70, 0.08, 0.02, 0.0)
const SMOKE_START := Color(0.05, 0.04, 0.04, 0.0)
const SMOKE_THICK := Color(0.04, 0.035, 0.035, 0.75)
const SMOKE_GONE := Color(0.10, 0.10, 0.10, 0.0)

static func build() -> Node3D:
	var fire := Node3D.new()
	fire.name = "Fire"
	# ALWAYS, because the shot runner photographs characters with processing
	# DISABLED (a body with no world must not run its own frame). The emitters
	# inherit this, so a fire in a still is burning rather than a frozen clump.
	fire.process_mode = Node.PROCESS_MODE_ALWAYS

	var smoke := _emitter("Smoke", SMOKE_AMOUNT, SMOKE_LIFETIME, SMOKE_SIZE, false)
	smoke.position = Vector3(0.0, SMOKE_LIFT, 0.0)
	smoke.emission_sphere_radius = EMIT_RADIUS * 1.5
	smoke.spread = 25.0
	smoke.gravity = Vector3(0.0, 0.5, 0.0)
	smoke.initial_velocity_min = 0.10
	smoke.initial_velocity_max = 0.25
	# Slows as it rises, so the wisp hangs a moment instead of shooting upward.
	smoke.damping_min = 0.3
	smoke.damping_max = 0.6
	smoke.scale_amount_curve = _curve([Vector2(0.0, 0.5), Vector2(1.0, 1.6)])
	smoke.color_ramp = _ramp([0.0, 0.2, 1.0], [SMOKE_START, SMOKE_THICK, SMOKE_GONE])
	# BEHIND the flame, whatever the camera does. Mixed-alpha particles sort by
	# their node's origin, and the smoke's origin is ABOVE the flame's, so from a
	# high camera it would otherwise draw on top and dim the fire it came from.
	(smoke.material_override as StandardMaterial3D).render_priority = -1
	fire.add_child(smoke)

	var flame := _emitter("Flame", FLAME_AMOUNT, FLAME_LIFETIME, FLAME_SIZE, false)
	flame.emission_sphere_radius = EMIT_RADIUS
	flame.spread = 18.0
	flame.gravity = Vector3(0.0, 1.2, 0.0)
	flame.initial_velocity_min = 0.15
	flame.initial_velocity_max = 0.40
	flame.scale_amount_curve = _curve([Vector2(0.0, 1.0), Vector2(0.6, 0.7), Vector2(1.0, 0.1)])
	flame.color_ramp = _ramp([0.0, 0.35, 1.0], [HOT, WARM, EMBER])
	fire.add_child(flame)

	var core := _emitter("Core", CORE_AMOUNT, CORE_LIFETIME, CORE_SIZE, true)
	core.emission_sphere_radius = EMIT_RADIUS * 0.6
	core.spread = 10.0
	core.gravity = Vector3(0.0, 1.6, 0.0)
	core.initial_velocity_min = 0.25
	core.initial_velocity_max = 0.45
	core.scale_amount_curve = _curve([Vector2(0.0, 1.0), Vector2(1.0, 0.2)])
	core.color_ramp = _ramp([0.0, 1.0], [CORE_HOT, CORE_FADE])
	(core.material_override as StandardMaterial3D).render_priority = 1
	fire.add_child(core)
	return fire

# One layer's common setup: a billboarded soft puff, unshaded, coloured by the
# ramp, full from its first frame, rising, and in WORLD space so a running
# player leaves a short trail behind the blade instead of carrying a rigid cone.
static func _emitter(label: String, amount: int, lifetime: float, size: float, additive: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = label
	p.amount = amount
	p.lifetime = lifetime
	# FULL FROM THE FIRST FRAME rather than lighting up over half a second, so a
	# character screen opened on this tail shows a fire, not a spark growing.
	p.preprocess = lifetime
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.2

	var puff := QuadMesh.new()
	puff.size = Vector2(size, size)
	p.mesh = puff
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_puff()
	p.material_override = mat
	return p

# A SOFT ROUND PUFF, not a square. A bare quad is a hard-edged tile, and fire
# made of tiles reads as pixels; a radial falloff from opaque to clear is what
# turns a few dozen quads into something that licks.
static func _soft_puff() -> GradientTexture2D:
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(1.0, 0.5)
	soft.width = 32
	soft.height = 32
	soft.gradient = _ramp([0.0, 1.0], [Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	return soft

static func _curve(points: Array) -> Curve:
	var c := Curve.new()
	# A Curve's default range is 0..1, and the smoke GROWS past 1 -- a point above
	# max_value is clamped silently, so the smoke would never get bigger.
	c.max_value = 2.0
	for pt in points:
		c.add_point(pt)
	return c

static func _ramp(offsets: Array, colours: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colours)
	return g
