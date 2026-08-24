extends "res://scripts/test_support/test_case.gd"

# M8.5. A stack of hats is not a rod.
#
# The claims:
#   1. A player standing still wears a DEAD UPRIGHT stack. A wobble that never
#      settles is a stack that is always slightly wrong, and four of them on
#      screen would read as a rendering fault rather than as comedy.
#   2. Changing speed tips it, AGAINST the change -- the head moves out from under
#      the hats.
#   3. THE LEAN ACCUMULATES. The top of the tower tips further than the bottom and
#      is displaced sideways by every hat under it. This is the whole feature: a
#      stack that tilted as one piece is a rod with a hinge at the head, which is
#      what it already looked like.
#   4. No hat exceeds HAT_LEAN_MAX against the one below it, however hard the
#      player is thrown about. The clamp is what keeps five hats at 25 degrees
#      instead of somewhere past horizontal.
#   5. It comes back. A stack that leans over and stays there is the one failure
#      this must not have.
#
# CLAIM 3 IS THE ONE CARRYING THE DESIGN, and it is the only one here that fails
# if the lean is deleted -- 1, 4 and 5 are all true of a stack that never moves.
# Checked by reverting: with pose_stack composing an identity basis, this test
# fails on "the top of the tower leans further than the bottom" and passes
# everything else.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const STACK := 4

var world: Node3D = null
var a: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0

# What the scripted input hands the body. Set by the phases.
var drive: Vector2 = Vector2.ZERO
var fire_shove: bool = false

# Peaks observed during the acceleration window, since a lean is a transient: the
# question here is "did it ever", which is the one question a max can answer.
var peak_bottom: float = 0.0
var peak_top: float = 0.0
var peak_pair: float = 0.0
var peak_side: float = 0.0
var lean_x_at_peak: float = 0.0
var peak_pair_dash: float = 0.0

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "LeanWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	a = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = 0
		if fire_shove:
			# Edge-triggered, exactly like a key press: set for one tick only.
			fire_shove = false
			actions = SimConfig.ACTION_SHOVE
		return PlayerInput.make(t, drive, actions)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_build()
		1: _phase_upright_at_rest()
		2: _phase_a_standing_start()
		3: _phase_settles_again()
		4: _phase_a_dash_pegs_the_clamp()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- Build a tower -------------------------------------------------------------

func _phase_build() -> void:
	if phase_frame == 1:
		a.position = world.grid.cell_surface_world(Vector2i(25, 9)) + Vector3(0.0, 1.0, 0.0)
		a.velocity = Vector3.ZERO
		a.state = PlayerBody.State.WALK
		a.grounded = true
		return
	# One per tick, so they stack in an unambiguous order.
	if phase_frame <= 1 + STACK:
		world._hats.spawn_loose(a.position)
		return
	if phase_frame == 10:
		eq(_worn().size(), STACK, "a tower of %d" % STACK)
		_advance(1)

# --- 1. Standing still, it is upright ------------------------------------------

func _phase_upright_at_rest() -> void:
	# Long enough for any spring the build kicked to have died: the decay constant
	# is 2/HAT_LEAN_DAMPING, about a fifth of a second.
	if phase_frame < 90:
		return
	var worn: Array = _worn()
	for i in worn.size():
		check(_tilt(worn[i]) < deg_to_rad(0.25),
			"hat %d stands upright on a player who is standing still (%.4f rad)"
				% [i, _tilt(worn[i])])
	# And still spaced correctly, which is what says the pose function did not
	# quietly start shortening the tower to pay for the lean.
	# BY THE HAT BELOW'S OWN SLOT, not by a constant. It was `SimConfig.HAT_HEIGHT`
	# until 2026-08-23, when a slot became the hat's drawn height -- and a spacing
	# assertion written against a constant is a claim about the CATALOGUE rather
	# than about the pose function it is here to watch. This form says the thing
	# that is actually load-bearing, and would have held either side of that change.
	near(worn[1].global_position.y - worn[0].global_position.y,
		worn[0].slot_height(), 0.01,
		"spaced by the slot of the hat underneath (%.3f m)" % worn[0].slot_height())
	# GLOBAL, not local. Worn hats used to be children of the player, so "over the
	# middle of the head" was `position.x == 0`. They now live at the pool root and
	# are driven by global transform (a RigidBody3D parented under another physics
	# body is invisible to the round sweep, which cost the shoot-a-hat verb), so
	# the same claim is a DIFFERENCE between two globals.
	near(worn[0].global_position.x - a.global_position.x, 0.0, 0.001,
		"and sits over the middle of the head")
	_advance(2)

# --- 2, 3, 4. A standing start --------------------------------------------------

func _phase_a_standing_start() -> void:
	if phase_frame == 1:
		# Straight along +X, from a dead stop. WALK_ACCEL reaches WALK_SPEED in
		# about six ticks, which is the change the hats are supposed to notice.
		drive = Vector2(1.0, 0.0)
		return

	var worn: Array = _worn()
	if worn.size() == STACK:
		peak_bottom = maxf(peak_bottom, _tilt(worn[0]))
		peak_top = maxf(peak_top, _tilt(worn[STACK - 1]))
		peak_side = maxf(peak_side, absf(worn[STACK - 1].position.x))
		for i in range(1, worn.size()):
			peak_pair = maxf(peak_pair, _between(worn[i - 1], worn[i]))
		if _tilt(worn[STACK - 1]) >= peak_top:
			lean_x_at_peak = worn[STACK - 1].basis.y.x

	if phase_frame == 40:
		check(peak_bottom > deg_to_rad(0.5),
			"accelerating tips the stack (bottom hat reached %.2f deg)"
				% rad_to_deg(peak_bottom))

		# THE CLAIM THE FEATURE IS FOR. Four hats' worth of lean at the top against
		# one at the bottom; anything that tilted the stack as a single rigid piece
		# would give the same number twice.
		check(peak_top > peak_bottom * 1.5,
			"and the top of the tower leans further than the bottom (%.2f deg vs %.2f)"
				% [rad_to_deg(peak_top), rad_to_deg(peak_bottom)])
		check(peak_side > 0.05,
			"so the top hat hangs out past the head by %.2f m" % peak_side)

		# Away from the acceleration: the head moved and the hats did not.
		check(lean_x_at_peak < 0.0,
			"leaning back against a player accelerating toward +X (%.3f)" % lean_x_at_peak)

		# THE CLAMP, measured per PAIR rather than on the total -- five degrees is
		# a per-hat budget and the tower is allowed to reach five times it.
		check(peak_pair <= deg_to_rad(SimConfig.HAT_LEAN_MAX_DEG) + 0.001,
			"no hat passes HAT_LEAN_MAX against the one below it (%.2f deg)"
				% rad_to_deg(peak_pair))
		_advance(3)

# --- 5. And it comes back -------------------------------------------------------

func _phase_settles_again() -> void:
	if phase_frame == 1:
		drive = Vector2.ZERO
		return
	# Two seconds: nine decay constants after the stop kick.
	if phase_frame == 120:
		var worn: Array = _worn()
		for i in worn.size():
			check(_tilt(worn[i]) < deg_to_rad(0.25),
				"hat %d is upright again once the player stops (%.4f rad)"
					% [i, _tilt(worn[i])])
		_advance(4)

# --- 4, the other half. A dash actually REACHES the clamp -----------------------
#
# WITHOUT THIS THE CLAMP ASSERTION ABOVE CANNOT FAIL. A standing start peaks near
# 1.4 degrees against a 5 degree budget, so "no hat passes HAT_LEAN_MAX" is true
# of a stack that never leans at all -- exactly the shape of the ramp test that
# asserted a player could not climb and never asserted that a shoved one could.
# 56 m/s in one tick is the hardest thing that can happen to a wearer, and it is
# what the limit was written for.

func _phase_a_dash_pegs_the_clamp() -> void:
	if phase_frame == 1:
		# Along -X: the dash covers 5.6 m and row 9 of test_flat is solid deck all
		# the way back, so the player is still on the bridge at the end of it.
		drive = Vector2(-1.0, 0.0)
		fire_shove = true
		return

	var worn: Array = _worn()
	if worn.size() == STACK:
		for i in range(1, worn.size()):
			peak_pair_dash = maxf(peak_pair_dash, _between(worn[i - 1], worn[i]))

	if phase_frame == 40:
		eq(_worn().size(), STACK, "the stack survives a dash -- a shove is not a tumble")
		var limit: float = deg_to_rad(SimConfig.HAT_LEAN_MAX_DEG)
		check(peak_pair_dash > limit * 0.98,
			"a 56 m/s dash pegs the lean at the clamp (%.2f deg of %.2f)"
				% [rad_to_deg(peak_pair_dash), SimConfig.HAT_LEAN_MAX_DEG])
		check(peak_pair_dash <= limit + 0.001,
			"and never past it (%.3f deg)" % rad_to_deg(peak_pair_dash))
		finish()

# --- helpers --------------------------------------------------------------------

func _worn() -> Array:
	return world.hats_worn_by(1)

# How far off vertical a hat is, in the player's frame. The body is a
# CharacterBody3D and never rotates, so this is also how far off vertical it is
# in the world.
func _tilt(hat: Node3D) -> float:
	return hat.basis.y.angle_to(Vector3.UP)

func _between(lower: Node3D, upper: Node3D) -> float:
	return upper.basis.y.angle_to(lower.basis.y)
