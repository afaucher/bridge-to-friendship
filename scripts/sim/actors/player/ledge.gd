extends RefCounted

# LEDGES (M5): catching a lip on the way down, hanging off it, and being hauled
# back up or letting go. The LEDGE_HANG state -- and one of the two ways a player
# ends up waiting on a teammate, so it shares the rescue clock with DOWNED.
#
# Part of PlayerBody. It holds no state of its own; hang_dir and ledge_cooldown
# are the body's, and ride capture_state() with everything else.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

# Catch a lip you are falling past. AUTOMATIC, no input: this fires most often
# mid-tumble, when the player has no control to answer a prompt with.
#
# Grid-based rather than a geometric probe, because the bridge IS a grid: "am I
# over a hole with solid deck beside me at about my height" is exactly the
# question, and it is a pure function of position, so a replay re-derives it.
func try_catch() -> bool:
	if body.world == null or body.world.grid == null:
		return false
	if body.ledge_cooldown > 0.0:
		return false          # just let go of one; a hang is one chance per fall
	# A PASSENGER IS NOT FALLING, HOWEVER MUCH THEY LOOK LIKE IT.
	#
	# Reported from play: "when you drive off the edge of the map in the bus, you
	# still land on something solid below the map -- your bus disappears and it
	# marks you hanging for this period." There is nothing solid down there. The
	# rider caught a ledge on the way past it and LEDGE_HANG holds a body still.
	#
	# EVERY GATE ABOVE PASSES FOR A RIDER, and passes because of the seat rather
	# than in spite of it. `_plant_riders` writes `velocity = Vector3.ZERO` every
	# tick, so a passenger on a bus toppling into the infield reads as a body
	# drifting downward at nothing -- the most catchable thing in the game -- and
	# as the bus sinks past the lip it spends several ticks within
	# LEDGE_CATCH_REACH of solid deck. Measured: the grab lands 1.4 m below the
	# rim, and the plant then re-seats the hanging body and carries it down to
	# y = -29.4, where it stops. It stops because a hang does not fall and because
	# -29.4 is not past FALL_KILL_Y, so nothing rescues it either: pinned in
	# mid-air under the map, marked HANGING, until the eight-second timer runs out.
	#
	# The velocity gate is what the trajectory rule is MADE of -- "over an edge but
	# still near the deck catches, launched clear does not" -- and a seat forges
	# its input. So the question has to be asked of the seat.
	#
	# `_try_board_or_leave` has assumed this all along ("somebody hanging off a
	# ledge is not standing beside a bus"); this is the line that makes it true.
	if body.world != null and body.world.has_method("bus_carrying") 			and body.world.bus_carrying(body.peer_id) != null:
		return false
	if body.velocity.y > 0.0 or body.velocity.length() > SimConfig.LEDGE_CATCH_MAX_SPEED:
		return false

	var grid: Node = body.world.grid
	var cell: Vector2i = grid.cell_of_world(body.position)
	if grid.is_solid(cell):
		return false          # still over deck; nothing to catch

	for dir in 4:
		var neighbour: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if not grid.is_solid(neighbour):
			continue
		# YOU CANNOT HOLD ON TO A WATERFALL. The lip of a fall is solid deck like
		# any other, so without this the reading is exactly backwards: the current
		# carries you over the edge and then you dangle from the thing that threw
		# you, which is a rescue the fall was not supposed to have.
		#
		# Same shape as the rule that stopped a bus passenger catching a ledge on
		# the way down: an entry condition has to ask what the state will do.
		if grid.kind_at(neighbour) == GridConfig.Kind.WATER:
			continue
		var lip: Vector3 = grid.cell_surface_world(neighbour)
		# Level with the lip, or just below it. Far below and you are past it --
		# which is exactly the "launched clear of the deck" case that is meant to
		# have no rescue.
		if body.position.y > lip.y or lip.y - body.position.y > SimConfig.LEDGE_CATCH_REACH:
			continue
		begin_hang(lip, dir)
		return true
	return false

func begin_hang(lip: Vector3, dir: int) -> void:
	body.state = State.LEDGE_HANG
	body.state_timer = 0.0
	# AND IT SHOUTS. Same as going down, and for a better reason: a hang is eight
	# seconds where a bleed-out is fifteen, so the state with less time in it is
	# the one that most needs somebody told immediately.
	body._call_for_help_automatically()
	body._roll_self_revive_window()
	body.velocity = Vector3.ZERO
	body.grounded = false
	body.hang_dir = dir
	body._pop_hats()
	# BEFORE the position is moved below, so it lands on the deck it was standing
	# on rather than in the hole the player is now dangling into. Not a rescue --
	# a hanging player still cannot reach it -- but a teammate can.
	body._drop_special()
	# Hanging just off the edge on the hole side, head about level with the deck.
	var outward: Vector3 = GridConfig.DIR_VECTORS[dir]
	body.position = lip - outward * (GridConfig.CELL_SIZE * 0.5 + 0.35) - Vector3(0.0, HALF_HEIGHT, 0.0)

func step() -> void:
	# Nothing to simulate: a hanging player holds still. The world runs the
	# countdown, because letting go and being drone-returned are its business.
	body.velocity = Vector3.ZERO

# Climb onto the deck being hung from. A hanging player CANNOT call this on their
# own -- that is the whole point of the state. It exists for whatever is pulling
# them: the rope, in M4.
func mantle() -> bool:
	if body.state != State.LEDGE_HANG or body.world == null or body.world.grid == null:
		return false
	var grid: Node = body.world.grid
	var cell: Vector2i = grid.cell_of_world(body.position)
	var target: Vector2i = cell + GridConfig.DIR_CELLS[body.hang_dir]
	if not grid.is_solid(target):
		return false
	body.position = grid.cell_surface_world(target) + Vector3(0.0, HALF_HEIGHT + 0.05, 0.0)
	body.state = State.WALK
	body.state_timer = 0.0
	body.velocity = Vector3.ZERO
	body.grounded = true
	return true

# Let go, and fall. What happens when the hang timer runs out.
func release() -> void:
	if body.state != State.LEDGE_HANG:
		return
	body.state = State.TUMBLE
	body.state_timer = 0.0
	body.grounded = false
	# YOU LET GO; YOU DO NOT GET IT BACK. The body is released 0.9 m under the
	# lip, which is inside LEDGE_CATCH_REACH, so without this it grabs the same
	# lip again on the next tick and the countdown starts over -- forever.
	body.ledge_cooldown = SimConfig.LEDGE_REGRAB_COOLDOWN
