extends "res://scripts/sim/gunner_body.gd"

# The enemy that holds a distance and shoots.
#
# IT IS ANSWERED BY CLOSING, which is what makes it different from a rusher. A
# rusher is answered by moving, so its answer is the same everywhere on the
# bridge; this one asks the player to walk INTO the thing shooting at them, which
# is a decision rather than a reflex.

const Conf = preload("res://scripts/sim/sim_config.gd")
const Grid = preload("res://scripts/grid/grid_config.gd")

# WHERE IT WAS POSTED, taken on its first tick rather than in _ready(): a gunner
# is positioned AFTER it is added to the tree, so _ready() would record the
# origin. Patrol wanders around this and nothing else -- a patrol is meant to make
# an enemy feel posted rather than parked, not to relocate the encounter the level
# author placed.
var home_cell: Vector2i = Vector2i.ZERO
var has_home: bool = false

var patrol_point: Vector3 = Vector3.ZERO
var has_patrol_point: bool = false
var patrol_pause: float = 0.0

# AM I ACTUALLY GETTING THERE? Without this, patrol DEADLOCKS: the grid says a
# cell is solid, which is a question about the DECK, and a pillar standing on that
# deck is a different question -- so a gunner steers into one, `move_and_slide`
# holds it against it, the walk never arrives and no new point is ever chosen.
# Measured before this existed: a gunner leaned on the pillar at (7,8) of
# test_flat for the whole rest of the phase.
#
# A PROGRESS CHECK RATHER THAN A TIME BUDGET, and the first attempt was the
# budget. "Twice as long as the walk should take" is up to twelve seconds for a
# point at the edge of the patrol radius -- correct by the formula and far too
# slack to look like anything but a broken enemy. Half a second of no progress is
# the same fact, noticed twenty times sooner.
var patrol_check: float = 0.0
var patrol_last_far: float = 0.0

func _init() -> void:
	kind = Kind.SKIRMISHER

func fire_range() -> float:
	return Conf.SKIRMISHER_RANGE

func fire_interval() -> float:
	return Conf.SKIRMISHER_FIRE_INTERVAL

# KNOCKED ABOUT LIKE ANYTHING ELSE ON LEGS. Running into it does something; it is
# the turret that is bolted down.
func receive_impact(hit) -> bool:
	velocity += hit.launch_for(position)
	return true

# FOUR THINGS TO DO, PICKED BY WHETHER IT HAS A TARGET AND HOW AWAKE IT IS.
#
# The four are not a state machine with transitions to keep straight: `alert` is a
# single number that rises in sight and falls out of it (gunner_body.gd), and each
# branch below is just a reading of it. That is why there is no "re-acquire" case
# -- an enemy that lost you halfway through waking resumes from halfway.
func move_for(target: Node) -> void:
	if not has_home:
		_take_post()
	if target != null:
		if is_engaged():
			_hold_band(target)
		else:
			# WAKING, AND IT DOES NOT WALK WHILE IT DOES. Standing and turning is the
			# clearest possible read that it has seen you, and it is also what makes
			# the window worth anything: a wake spent closing hands the player a
			# shorter reply than the numbers promise.
			_stand()
		return
	if alert > 0.0 and has_last_seen:
		_search()
	else:
		_patrol()

# APPROACH WHEN FAR, BACK OFF WHEN CLOSE, STAND STILL IN BETWEEN.
#
# The band is what makes this an enemy with a POSITION it wants rather than a
# target it runs at, and the dead zone in the middle is what stops it jittering
# back and forth across a single preferred distance forever.
func _hold_band(target: Node) -> void:
	var to_target := Vector3(target.position.x - position.x, 0.0,
		target.position.z - position.z)
	var range_to: float = to_target.length()
	var dir := Vector3.ZERO
	if range_to > Conf.SKIRMISHER_RANGE + Conf.SKIRMISHER_BAND:
		dir = to_target.normalized()
	elif range_to < Conf.SKIRMISHER_RANGE - Conf.SKIRMISHER_BAND:
		dir = -to_target.normalized()

	# IT MUST NOT WALK OFF THE BRIDGE IN EITHER DIRECTION. A body that retreats from
	# you until it falls is a comedy nobody authored, and it hands the player a free
	# kill for walking forwards.
	#
	# THE APPROACH USED TO BE EXEMPT -- "walking INTO the party is what it is for" --
	# and that was really a RUSHER's argument wearing a skirmisher's clothes.
	# hazards.md makes the walk-off-the-edge affordance specifically a rusher's, on
	# the grounds that a rusher is otherwise endable only by a weapon, so baiting one
	# over a hole is the cheapest tool a weaponless player has. A skirmisher already
	# has two answers -- close on it, or break line of sight -- and did not need a
	# third that costs the player nothing but standing still. That is the same free
	# kill the retreat rule exists to prevent, pointed the other way.
	#
	# It is also the consistency: searching and patrolling both ask the grid, so an
	# approach that did not was the one movement in this enemy's repertoire that
	# behaved differently, and it was the one the player watches.
	if dir.length_squared() > 0.0001 and not footing_toward(dir):
		dir = Vector3.ZERO

	velocity.x = dir.x * Conf.SKIRMISHER_SPEED
	velocity.z = dir.z * Conf.SKIRMISHER_SPEED

# --- With nobody to shoot -----------------------------------------------------

# IT GOES AND LOOKS WHERE YOU WERE. `alert` is the clock: it drains over
# GUNNER_FORGET_SECONDS with no target, so the search lasts exactly as long as the
# memory does and there is no second timer to keep in step with the first.
func _search() -> void:
	# _walk_to stands it still on arrival, so "got there, nobody here" needs no
	# branch of its own: it waits, looking, until the memory runs out.
	_walk_to(last_seen, Conf.SKIRMISHER_SPEED, 1.5)

# A BEAT, A STROLL, A BEAT. Wanders inside SKIRMISHER_PATROL_RADIUS of where it
# was posted, refusing any step the grid says has no floor under it.
func _patrol() -> void:
	if patrol_pause > 0.0:
		patrol_pause -= Conf.TICK_DELTA
		_stand()
		return
	if not has_patrol_point:
		_choose_patrol_point()
		if not has_patrol_point:
			_stand()
			return
	if not _walk_to(patrol_point, Conf.SKIRMISHER_PATROL_SPEED, 1.0) or _going_nowhere():
		has_patrol_point = false
		patrol_pause = Conf.SKIRMISHER_PATROL_PAUSE

# Has the walk closed on its point since the last check? Half a second at the
# patrol speed is a metre, so 20 cm is a floor a body that is genuinely walking
# clears easily and one leaning on a pillar never does.
func _going_nowhere() -> bool:
	patrol_check -= Conf.TICK_DELTA
	if patrol_check > 0.0:
		return false
	patrol_check = 0.5
	var far: float = Vector3(patrol_point.x - position.x, 0.0,
		patrol_point.z - position.z).length()
	var stalled: bool = far > patrol_last_far - 0.2
	patrol_last_far = far
	return stalled

func _take_post() -> void:
	if world == null or world.grid == null:
		return
	var grid: Node = world.grid
	home_cell = grid.cell_of_world(position)
	has_home = true

# A BOUNDED number of tries, never a reject-sampling `while`: CLAUDE.md has the
# scar from a loop that spun inside one physics frame waiting for an input that
# could not occur. A gunner posted somewhere with no room simply stands, which is
# what it did before patrol existed.
func _choose_patrol_point() -> void:
	if world == null or world.grid == null or not has_home:
		return
	var grid: Node = world.grid
	var reach: int = Conf.SKIRMISHER_PATROL_RADIUS
	for _attempt in 8:
		var cell := Vector2i(home_cell.x + randi_range(-reach, reach),
			home_cell.y + randi_range(-reach, reach))
		if cell == home_cell or not grid.is_solid(cell):
			continue
		if absi(grid.height_at(cell) - grid.height_at(home_cell)) > 1:
			continue
		patrol_point = grid.cell_surface_world(cell)
		has_patrol_point = true
		patrol_check = 0.5
		patrol_last_far = Vector3(patrol_point.x - position.x, 0.0,
			patrol_point.z - position.z).length()
		return

# Walk at a point. Returns false once it has arrived OR when the grid says there
# is nothing to step onto that way -- both of which mean "this walk is over",
# which is the answer patrol wants and the reason they share a return.
func _walk_to(point: Vector3, speed: float, arrive: float) -> bool:
	var to_point := Vector3(point.x - position.x, 0.0, point.z - position.z)
	if to_point.length() <= arrive:
		_stand()
		return false
	var dir := to_point.normalized()
	if not footing_toward(dir):
		_stand()
		return false
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	# It looks where it is going. Without this it would keep staring at whatever it
	# last aimed at while walking somewhere else, which reads as a bug rather than
	# as a patrol.
	aim_at(Grid.yaw_of_vector(dir))
	return true

func _stand() -> void:
	velocity.x = move_toward(velocity.x, 0.0, Conf.SKIRMISHER_SPEED * Conf.TICK_DELTA)
	velocity.z = move_toward(velocity.z, 0.0, Conf.SKIRMISHER_SPEED * Conf.TICK_DELTA)
