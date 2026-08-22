extends "res://scripts/test_support/test_case.gd"

# Where a round landed (2026-08-22).
#
# THE FEATURE IS THE TWO COLOURS, NOT THE SPARK. At 10 m/s with 10 degrees of
# spread a round crossing 12 m has a cone four metres wide against a body under
# one metre, so most shots miss -- and from behind the gun a hit and a miss looked
# identical. A single generic puff would say "something happened here", which the
# player already knew. So every claim below is asserted in BOTH directions: the
# cover colour on cover, the connect colour on a body. One of those alone is a
# spark, not information.
#
# WHY A TEST FOR SOMETHING COSMETIC: `_play_impact` is gated on `view_active`,
# false in every headless world, so the whole effect would ship having never been
# executed once -- and GDScript resolves properties at runtime, so a renamed enum
# or a Godot 3 spelling raises on the first frame and nowhere earlier.
# `ParticleProcessMaterial.color_ramp`, `draw_pass_1` and `explosiveness` are all
# that bet. Same reasoning as test_blast_effect, next door.
#
# The claims:
#   1. A round into the DECK makes an impact, in the cover colour.
#   2. A round into a BODY makes one, in the connect colour. The pair is the
#      feature.
#   3. IT CLEANS ITSELF UP. It is created on the tick the bullet is destroyed, so
#      nothing is left owning it.
#   4. A ROCKET MAKES A BLAST AND NOT ONE OF THESE. Two effects on one impact
#      means one of them is lying about the scale, and the exclusion is a single
#      `else` that somebody will one day be tempted to widen.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const ShotImpact = preload("res://scripts/ui/shot_impact.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "ImpactWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	# THE VIEW GATE, ON. Effects are skipped where nobody is looking, so without
	# this the gate runs every line of this file except the ones that matter.
	world.view_active = true
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	victim = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_cover()
		1: _phase_connect()
		2: _phase_it_tidies_up()
		3: _phase_a_rocket_does_not()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0
	for fx in _effects("Impact") + _effects("Blast"):
		fx.queue_free()

# --- 1. Into the deck ---------------------------------------------------------

func _phase_cover() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 10))
		# Straight down into the deck from three metres up. Guaranteed to strike
		# world geometry, which is the "cover did its job" case.
		world._spawn_round(world.to_global(victim.position + Vector3(4.0, 3.0, 0.0)),
			Vector3.DOWN, 0, RID())
		return
	if phase_frame == FLIGHT:
		var made: Array = _effects("Impact")
		eq(made.size(), 1, "a round into the deck leaves one mark")
		if made.size() == 1:
			var top: Color = _ramp_start(made[0])
			print("[impact] cover colour %s" % top)
			check(top.is_equal_approx(ShotImpact.COVER_HOT),
				"and it is the COVER colour (%s), not the connect one" % top)
		_advance(1)

# The round travels 3 m at MG_BULLET_SPEED. Derived, because that constant has
# moved twice and a hardcoded window broke three tests the day it last did.
const FLIGHT := 40

# --- 2. Into a body -----------------------------------------------------------

func _phase_connect() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 10))
		victim.invulnerable = 0.0
		# Level, from four metres away, at the body. A player has `receive_hit`,
		# which is the same question _resolve_round_hit asks.
		world._spawn_round(world.to_global(victim.position + Vector3(-4.0, 0.0, 0.0)),
			Vector3(1.0, 0.0, 0.0), 0, RID())
		return
	if phase_frame == FLIGHT:
		var made: Array = _effects("Impact")
		check(made.size() >= 1, "a round into a body leaves a mark too")
		if made.size() >= 1:
			var top: Color = _ramp_start(made[0])
			print("[impact] connect colour %s" % top)
			check(top.is_equal_approx(ShotImpact.CONNECT_HOT),
				"and it is the CONNECT colour (%s) -- the pair is the whole "
					% top + "feature, since a spark that looks the same either "
				+ "way tells the shooter what they already knew")
		recorded["count"] = made.size()
		_advance(2)

# --- 3. And then it is gone ---------------------------------------------------

func _phase_it_tidies_up() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 10))
		world._spawn_round(world.to_global(victim.position + Vector3(4.0, 3.0, 0.0)),
			Vector3.DOWN, 0, RID())
		return
	if phase_frame == FLIGHT:
		check(_effects("Impact").size() > 0, "the mark is there to begin with")
		return
	if phase_frame == FLIGHT + int(ShotImpact.LIFETIME * 2.5 / SimConfig.TICK_DELTA):
		eq(_effects("Impact").size(), 0,
			"and it frees itself -- it is created on the tick the bullet is "
			+ "destroyed, so anything waiting for an owner to tidy up would leak")
		_advance(3)

# --- 4. A rocket is not one of these ------------------------------------------

func _phase_a_rocket_does_not() -> void:
	if phase_frame == 1:
		_park(Vector2i(15, 10))
		victim.invulnerable = 999.0     # its own blast is not the subject here
		world._spawn_round(world.to_global(victim.position + Vector3(6.0, 3.0, 0.0)),
			Vector3.DOWN, 0, RID(), true)
		return
	# A BLAST IS ALSO SHORT-LIVED, so this window has two edges. A rocket crosses
	# 3 m at ROCKET_SPEED in about 8 ticks and blast_effect frees itself 45 ticks
	# after that -- the first version of this phase looked at tick 80 and reported
	# "a rocket draws no blast", which is a claim about the rocket and was really a
	# claim about arriving late.
	if phase_frame == 30:
		var blasts: int = _effects("Blast").size()
		var marks: int = _effects("Impact").size()
		print("[impact] rocket produced %d blast, %d impact" % [blasts, marks])
		check(blasts > 0, "a rocket still draws its blast")
		eq(marks, 0,
			"and no impact mark beside it -- two effects on one hit means one of "
			+ "them is lying about the scale")
		victim.invulnerable = 0.0
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	victim.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.state = PlayerBody.State.WALK
	victim.grounded = true

func _effects(named: String) -> Array:
	var found: Array = []
	for child in world.get_children():
		if is_instance_valid(child) and child.name.begins_with(named) \
				and not child.is_queued_for_deletion():
			found.append(child)
	return found

# The first colour of the particle ramp, read back off the built material. This is
# the OUTPUT rather than the flag that produced it -- asserting the input to an
# effect is not asserting the effect, which is the note CLAUDE.md carries from the
# score screen's anchors.
func _ramp_start(fx: Node) -> Color:
	var particles: GPUParticles3D = fx.get_node_or_null("Sparks") as GPUParticles3D
	if particles == null:
		return Color(0, 0, 0, 0)
	var mat: ParticleProcessMaterial = particles.process_material as ParticleProcessMaterial
	if mat == null or mat.color_ramp == null:
		return Color(0, 0, 0, 0)
	return (mat.color_ramp as GradientTexture1D).gradient.get_color(0)
