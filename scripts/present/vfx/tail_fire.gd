extends RefCounted

# A SMALL FLAME, burning at one point of an accessory -- the shrimp tail's
# outermost fan blade on the character's left. Presentation only, like the
# accessory it hangs off: no collider, nothing simulated, nothing on the wire.
# Which accessory burns and where is data in CharacterStyle.accessory_flames();
# this file only knows what a flame looks like.
#
# CPU RATHER THAN GPU PARTICLES, for the reason the swallow's bubbles give: the
# headless gate builds every node in this tree, and a visual that only
# constructs on a machine with a renderer is one the gate never executes.
#
# AND THE PROPERTY NAMES ARE THE CPU PATH'S. `scale_amount_curve` takes a Curve
# and `color_ramp` a Gradient; the GPU path's names are different, and getting
# either wrong is a runtime error that aborts apply_accessory silently. The swallow
# lost its resize that way, twice. test_accessory asserts both are set.

# SMALL. A flame the size of a hand on the tip of a blade, not a torch: it is
# trim on a cosmetic, and anything that reads as a hazard on a PLAYER is the
# line art_direction.md's contract rule 1 draws.
const AMOUNT := 24
const LIFETIME := 0.55
const PUFF_SIZE := 0.16
const EMIT_RADIUS := 0.04

const HOT := Color(1.0, 0.92, 0.45, 1.0)
const WARM := Color(1.0, 0.45, 0.05, 0.95)
const EMBER := Color(0.70, 0.08, 0.02, 0.0)

static func build() -> CPUParticles3D:
	var fire := CPUParticles3D.new()
	fire.name = "Fire"
	fire.amount = AMOUNT
	fire.lifetime = LIFETIME
	# FULL FROM THE FIRST FRAME rather than lighting up over half a second, so a
	# character screen opened on this tail shows a flame, not a spark growing.
	fire.preprocess = LIFETIME
	# IN WORLD SPACE, so a running player leaves a short lick of flame behind the
	# blade instead of carrying a rigid cone of it around.
	fire.local_coords = false
	# ALWAYS, because the shot runner photographs characters with processing
	# DISABLED (a body with no world must not run its own frame). A flame that
	# only burns while its parent processes would render as a frozen clump there.
	fire.process_mode = Node.PROCESS_MODE_ALWAYS

	var puff := QuadMesh.new()
	puff.size = Vector2(PUFF_SIZE, PUFF_SIZE)
	fire.mesh = puff
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	# MIXED, NOT ADDITIVE. Additive is the textbook flame and it is invisible on
	# anything pale: over a bright deck the sum is white, and the first render of
	# this vanished entirely against the studio floor. Mixed alpha keeps the
	# flame its own colour on every background the bridge has.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	# A SOFT ROUND PUFF, not a square. A bare quad is a hard-edged tile, and a
	# flame made of tiles reads as pixels; a radial falloff from opaque to clear
	# is what turns a few dozen quads into something that licks.
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(1.0, 0.5)
	soft.width = 32
	soft.height = 32
	var falloff := Gradient.new()
	falloff.set_color(0, Color(1, 1, 1, 1))
	falloff.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = falloff
	mat.albedo_texture = soft
	fire.material_override = mat

	# RISING: gravity turned around, a narrow cone, and a small sphere to start
	# from, so it is a tongue of flame and not a fountain.
	fire.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fire.emission_sphere_radius = EMIT_RADIUS
	fire.direction = Vector3(0.0, 1.0, 0.0)
	fire.spread = 18.0
	fire.gravity = Vector3(0.0, 1.2, 0.0)
	fire.initial_velocity_min = 0.15
	fire.initial_velocity_max = 0.40
	fire.scale_amount_min = 0.7
	fire.scale_amount_max = 1.2

	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(0.6, 0.7))
	shrink.add_point(Vector2(1.0, 0.1))
	fire.scale_amount_curve = shrink

	var ramp := Gradient.new()
	ramp.set_color(0, HOT)
	ramp.set_color(1, EMBER)
	ramp.add_point(0.35, WARM)
	fire.color_ramp = ramp
	return fire
