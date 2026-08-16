extends "res://scripts/test_support/test_case.gd"

# M17 phase 6: LEGS, and the rule that they are only ever a shortcut.
#
# The fixture is a THREE-UNIT BARE STEP with no ramp, no ladder and one player.
# There is no mantle in this game, so a bare step up is a wall at any height --
# which makes this segment permanently impassable, deliberately. That is what
# lets the test assert the thing the design actually cares about: the validator
# must say NOBODY CAN CROSS IT even while a player is standing there holding the
# means to get up, because a route gated by a consumable is a route that becomes
# impossible the moment the last charge is spent (2a-i).
#
# A fixture whose only way across were the legs could not make that claim. It
# would be a fixture asserting the exact thing the design forbids.
#
# The claims:
#   1. A press launches the body over a rise it cannot walk, ride or climb, and
#      it lands ON the deck rather than against its face. Measured as a position.
#   2. It costs a charge, and it stops working when the charges are gone -- which
#      is the entire argument for rule 2a-i and has to be shown, not asserted.
#   3. ONE LAUNCH PER PRESS. Holding the button does not empty the tank.
#   4. THE FLOOD CANNOT SEE LEGS. `party_of` has no field for them and this
#      segment is impassable to every party size, with the pickup sitting in it.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const LOW_CELL := Vector2i(2, 3)
const HIGH_CELL := Vector2i(2, 4)

var world: Node3D = null
var body: CharacterBody3D = null
# UNTYPED DELIBERATELY. Spent means gone -- the pool destroys an empty special --
# and per CLAUDE.md a freed object in a typed `Node` var raises on access, which
# aborts the rest of the frame and reads as a timeout rather than a failure.
var weapon = null
var frames: int = 0
var launches: int = 0
var was_grounded: bool = true
var ammo_at_first_landing: int = -1
var last_ammo: int = -1
var arrived_frame: int = -1
var arrived_row: int = -1
var gone_frame: int = -1

func setup(main) -> void:
	timeout_seconds = 45.0
	_check_the_flood_is_blind()

	world = Node3D.new()
	world.name = "LegsWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_legs.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	body.position = world.grid.cell_surface_world(LOW_CELL) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

	# Handed the legs directly rather than walked over the pickup: what is being
	# measured is the launch, and a pickup radius test failing would read as a
	# broken launch.
	weapon = world._specials.spawn_loose(body.position + Vector3(0.0, 0.5, 0.0),
		SpecialBody.Kind.LEGS)
	weapon.hold(1)

	# PRESS, RELEASE, PRESS. The button is tapped rather than held, which is what
	# makes claim 3 measurable: a held button that launched every tick would spend
	# all four charges inside the first burst.
	#
	# AND THE STICK IS RELEASED THE MOMENT THE STEP IS BEHIND US. Holding forward
	# forever launched the arrival off the far end of an eight-row fixture and the
	# test caught it forty metres below the deck -- the same "a rig that holds a
	# movement input walks the player off the map" note CLAUDE.md carries, and the
	# second time this milestone. The remaining charges are then spent standing
	# still, which is what claims 2 and 3 need and does not need any ground.
	world.scripted_inputs[1] = func(t: int) -> Array:
		var actions: int = SimConfig.ACTION_SPECIAL_HELD if t % 12 < 6 else 0
		var move: Vector2 = Vector2.ZERO if arrived_frame >= 0 else Vector2(0.0, -1.0)
		return [t, move, actions, body.facing]

# --- 4. The flood cannot see them ---------------------------------------------

func _check_the_flood_is_blind() -> void:
	var seg = SegmentData.from_file("res://segments/test_legs.seg")
	check(seg.is_valid(), "the fixture parses")

	# THE ABSENCE IS THE MECHANISM. If somebody ever adds `has_legs` to the party,
	# a generated section can start requiring a consumable and the failure is a
	# party stuck in it with no way to know why. A test that names the field is
	# the only thing that notices the day it appears.
	var party: Dictionary = SegmentValidator.party_of(4)
	check(not party.has("has_legs"),
		"the party model has no `has_legs` field -- an edge gated by a consumable "
		+ "may only ever be a SHORTCUT, and the flood enforces that by being "
		+ "unable to see one")

	check(SegmentValidator.validate(seg).size() > 0,
		"a three-unit bare step is impassable WITH the legs sitting in it -- the "
		+ "oracle does not count them")
	eq(SegmentValidator.min_party_size(seg_run(seg)), -1,
		"and no party size crosses it either: presence does not substitute for a "
		+ "wall with nothing on it")

func seg_run(seg) -> Array:
	return [seg]

# --- 1, 2 and 3. The launch --------------------------------------------------

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1

	# COUNTED AT THE EDGE, on the tick the body leaves the floor. Counting ticks
	# spent airborne would report the length of the arc, and the claim is about how
	# many TIMES it fired.
	if was_grounded and not body.grounded and body.velocity.y > 1.0:
		launches += 1
	# ARRIVED: standing, on the far side of the step. Recorded the first time it is
	# true rather than sampled at the end -- the end is four launches later.
	var row_now: int = world.grid.cell_of_world(body.position).y
	if arrived_frame < 0 and body.grounded and row_now >= HIGH_CELL.y:
		arrived_frame = frames
		arrived_row = row_now
	if is_instance_valid(weapon):
		last_ammo = int(weapon.ammo)
	# AFTER A LAUNCH, not after any landing. The body is dropped a metre onto the
	# deck at setup, so the first grounded edge in the run is that settle -- and it
	# happens before a charge could possibly have been spent, which is exactly the
	# reading that made this assertion fail against working code.
	if launches > 0 and not was_grounded and body.grounded and ammo_at_first_landing < 0:
		ammo_at_first_landing = last_ammo
	was_grounded = body.grounded

	# DONE WHEN THE SPECIAL IS GONE, not when its ammo reads zero. Spent means
	# gone: the pool destroys it in the same tick it is emptied, so the count is
	# never OBSERVED at zero and a test waiting for that number waits forever.
	if gone_frame < 0 and launches > 0 and not is_instance_valid(weapon):
		gone_frame = frames
	# ONE TICK OF GRACE, because `has_legs` is refreshed at the top of a world tick
	# and the special is destroyed further down it: on the tick it goes, the flag
	# still says yes. Asserting on that tick failed against entirely correct code.
	if (gone_frame < 0 or frames < gone_frame + 3) and frames < 900:
		return

	var top: float = world.grid.cell_surface_world(HIGH_CELL).y
	print("[legs] arrived on tick %d at row %d (step top %.2f), %d launches, "
		% [arrived_frame, arrived_row, top, launches]
		+ "last ammo seen %d, special %s after %d ticks"
		% [last_ammo, "gone" if not is_instance_valid(weapon) else "still held", frames])

	check(arrived_frame > 0,
		"a launch carries a lone player over a three-unit bare step -- a rise with "
		+ "no ramp, no ladder and nobody to be shoved by, which is a wall to every "
		+ "other verb in the game")
	check(arrived_row >= HIGH_CELL.y,
		"landing ON the deck rather than against its face (row %d, step at %d) "
			% [arrived_row, HIGH_CELL.y]
		+ "-- carried forward by the walk step's airborne steering, which is why "
		+ "the launch adds no horizontal impulse of its own")

	# 3. ONE PER PRESS. The button is down for six ticks of every twelve, so a
	# launch decided by the BUTTON rather than by its EDGE would spend all four
	# charges inside the first press and this count would be four launches from one
	# arc -- which is why the count is taken at the moment the feet leave the floor
	# and not from the ammo, which would agree either way.
	eq(launches, SimConfig.LEGS_AMMO,
		"one launch per press, not per tick: %d launches from %d charges"
			% [launches, SimConfig.LEGS_AMMO])
	eq(ammo_at_first_landing, SimConfig.LEGS_AMMO - 1,
		"and the first one cost exactly one charge")

	# 2. THEY RUN OUT, and that is the whole reason for rule 2a-i.
	check(not body.has_legs,
		"spent, the legs stop being a capability -- which is exactly why the "
		+ "flood may never count one toward a section being crossable")
	finish()
