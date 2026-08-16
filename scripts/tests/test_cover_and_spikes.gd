extends "res://scripts/test_support/test_case.gd"

# M17 Phase 1: cover, and spike blocks.
#
# The two cheapest items on the world-generation list, and cover is the one that
# changes what a THEME can be: without it, "lots of shooting enemies" is a
# corridor you cross while being shot rather than a route with decisions in it.
#
# NEITHER NEEDS A NEW SYSTEM, and this file is largely a proof of that.
# SIGHT_BLOCKERS is `world | stones` and `_clear_line` already uses it, so a
# collider on the world layer breaks a gunner's line of sight with no code in the
# gunner. A spike block is a phase derived from the tick.
#
# The claims:
#   1. A GUNNER CANNOT SEE THROUGH COVER. Measured against the same gunner with
#      the cover removed, because "it cannot see me" is worthless without "and it
#      could a moment ago" -- the turret has a limited arc and a range, and either
#      would produce the same green.
#   2. Cover STOPS A BODY. Both shapes do; the difference between them is size,
#      not permeability, and that is worth pinning so nobody assumes a half wall
#      can be walked through.
#   3. SPIKES CYCLE. Out for part of the period and safe for the rest, derived
#      from the tick so every machine agrees -- and asserted over a whole period
#      rather than at one moment.
#   4. THEY HURT WHAT IS BESIDE THEM AND NOT WHAT IS ON THEM. The block is deck.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Where the fixture puts things.
const TURRET_CELL := Vector2i(4, 10)
const TREE_CELL := Vector2i(4, 4)
const WALL_CELL := Vector2i(4, 2)
const SPIKE_CELL := Vector2i(2, 6)

var world: Node3D = null
var body: CharacterBody3D = null
var frames: int = 0
var phase: int = 0
var phase_frame: int = 0
var out_ticks: int = 0
var in_ticks: int = 0
var hurt_beside: bool = false
var hurt_above: bool = false
var telegraph_ticks: int = 0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "CoverWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_cover.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	body = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	_check_sight()
	_check_solid()

func _park(cell: Vector2i) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

# --- 1. Cover blocks sight, and the control proves the instrument -------------

func _check_sight() -> void:
	var from: Vector3 = world.grid.cell_surface_world(TURRET_CELL) + Vector3(0.0, 1.0, 0.0)

	# Straight down the lane, with the tree between.
	var behind: Vector3 = world.grid.cell_surface_world(Vector2i(4, 1)) + Vector3(0.0, 1.0, 0.0)
	check(not world._clear_line(from, behind),
		"a gunner cannot see a player with cover between them")

	# THE CONTROL. One cell to the side, same distance, no cover on the line --
	# without this, "cannot see" would be satisfied by a broken raycast, by the
	# range, or by nothing being there at all.
	var clear: Vector3 = world.grid.cell_surface_world(Vector2i(7, 1)) + Vector3(0.0, 1.0, 0.0)
	check(world._clear_line(from, clear),
		"and CAN see one standing in the open at the same distance -- so the "
		+ "instrument works and it is the cover doing it")

# --- 2. Both shapes stop a body -----------------------------------------------

func _check_solid() -> void:
	var space := world.get_world_3d().direct_space_state
	for cell in [TREE_CELL, WALL_CELL]:
		var at: Vector3 = world.grid.cell_surface_world(cell)
		var query := PhysicsRayQueryParameters3D.create(
			at + Vector3(-1.4, 0.55, 0.0), at + Vector3(1.4, 0.55, 0.0))
		query.collision_mask = 1
		check(not space.intersect_ray(query).is_empty(),
			"cover at %s is solid at knee height" % str(cell))

# --- 3 and 4. The spike cycle -------------------------------------------------

func _physics_process(_delta: float) -> void:
	if body == null or world.tick == 0:
		return
	frames += 1
	phase_frame += 1
	match phase:
		0: _phase_on_the_block()
		1: _phase_beside_the_block()
		2: _phase_carried_over()

# HOW FAR OUT, not whether the mesh is visible. Those are different windows now:
# the spikes are SEEN rising before they are DANGEROUS, which is the whole point
# of the ramp -- a hazard that appears instantly can only be learned by dying to
# it. Measuring visibility would quietly assert the wrong one.
func _lift() -> float:
	return float(world.grid.spike_lift.get(SPIKE_CELL, 0.0))

func _dangerous() -> bool:
	return _lift() >= 0.6

# STANDING ON IT HURTS, and this assertion is the exact inverse of what it said
# until 2026-08-16.
#
# The old rule measured from the block's four NEIGHBOURS, so the safe spot was
# the middle of the spikes and the danger was a ring reaching 3.3 m out. It was
# deliberate and it was tested, which is why it survived — but it disagreed with
# the ART, and the art is the only thing a player has. Nine cones stand straight
# up out of one cell; that cell is what they hurt.
#
# From playtest, twice: once as "the elevator hurts you" (a lift two cells from a
# block, the rider inside the invisible ring), and once as "visually that is not
# at all what we show".
func _phase_on_the_block() -> void:
	if phase_frame == 1:
		_park(SPIKE_CELL)
		body.health = SimConfig.MAX_HEALTH
		return
	if _dangerous():
		out_ticks += 1
	else:
		in_ticks += 1
	# Seen but not yet lethal: the warning window.
	if _lift() > 0.02 and not _dangerous():
		telegraph_ticks += 1
	if phase_frame < int(SimConfig.SPIKE_PERIOD * 60.0) + 10:
		return

	# ASSERTED OVER A WHOLE PERIOD, not at a moment: a block stuck permanently out
	# and one stuck permanently in both look correct at the right single frame.
	check(out_ticks > 0, "the spikes come out (%d dangerous ticks)" % out_ticks)
	check(in_ticks > 0, "and go back in (%d safe ticks)" % in_ticks)
	# THE TELEGRAPH EXISTS. Without this the ramp could be a single frame and
	# everything else here would still pass -- and a hazard with no warning is
	# one a player can only learn by dying to it.
	check(telegraph_ticks > 10,
		"and there is a real window where they are VISIBLY RISING but not yet "
		+ "lethal (%d ticks) -- the movement is the warning" % telegraph_ticks)
	check(float(out_ticks) / float(out_ticks + in_ticks) < 0.5,
		"and are safe for most of the cycle (%.0f%% out) -- the safe window is the "
			% (100.0 * float(out_ticks) / float(out_ticks + in_ticks))
		+ "number that matters, because it has to be long enough to walk through")
	check(body.health < SimConfig.MAX_HEALTH,
		"and standing ON the block HURT (%d) -- it is drawn as spikes coming "
			% body.health
		+ "straight up out of that cell, so that cell is what they hurt; a hit "
		+ "test that disagrees with the art is a hazard players learn by dying to")
	phase = 1
	phase_frame = 0

# AND THE CELL NEXT DOOR IS SAFE. The half that stops "hurt me" being satisfied
# by a hazard that hurts everywhere: the old reach was 3.3 m, which is more than
# a cell and a half of bridge threatened by a block a metre wide.
func _phase_beside_the_block() -> void:
	if phase_frame == 1:
		_park(SPIKE_CELL + Vector2i(1, 0))
		body.health = SimConfig.MAX_HEALTH
		body.invulnerable = 0.0
		return
	if body.health < SimConfig.MAX_HEALTH:
		hurt_beside = true
	if phase_frame < int(SimConfig.SPIKE_PERIOD * 60.0) + 10:
		return
	check(not hurt_beside,
		"and standing in the NEXT CELL does not -- the danger is the block you "
		+ "can see, not a ring around something a metre away")
	phase = 2
	phase_frame = 0

# AND NOT FROM ABOVE. The case the playtest actually met: a lift, or legs,
# carrying somebody over a block whose whole silhouette is below their feet.
func _phase_carried_over() -> void:
	if phase_frame == 1:
		_park(SPIKE_CELL)
		# Held a clear body's height above the spikes, which is where a platform
		# passing over one puts you.
		body.position.y += SimConfig.SPIKE_TOP_REACH + 0.5
		body.velocity = Vector3.ZERO
		body.health = SimConfig.MAX_HEALTH
		body.invulnerable = 0.0
		return
	# Held there: gravity would drop the body onto the spikes and the phase would
	# be measuring the landing rather than the fly-over.
	body.position.y = world.grid.cell_surface_world(SPIKE_CELL).y 		+ SimConfig.SPIKE_TOP_REACH + 0.5
	body.velocity = Vector3.ZERO
	if body.health < SimConfig.MAX_HEALTH:
		hurt_above = true
	if phase_frame < int(SimConfig.SPIKE_PERIOD * 60.0) + 10:
		return
	check(not hurt_above,
		"and being carried OVER them does not hurt either -- passing above a "
		+ "hazard whose whole silhouette is below your feet should be exactly as "
		+ "safe as it looks, which is how a lift beside one read as the LIFT "
		+ "hurting you")
	finish()
