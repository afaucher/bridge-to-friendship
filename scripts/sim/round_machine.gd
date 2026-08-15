extends RefCounted

# THE ROUND. Lobby, section, lobby -- and the state that says which.
#
# This is M16's load-bearing object and, per the plan, it is also the in-game
# menu. A menu is a state machine you can see; if the state is real and
# replicated then the menu is a view of it, and every future console, vote or
# selection screen is a field here rather than a new system.
#
# FOUR STATES, AND THE PLAN SAID FIVE. `ARMING` was going to be "somebody is on
# the checker, waiting for the others" -- but that is not a state, it is the
# LOBBY with a predicate that is not satisfied yet. A state nothing branches on
# is a state that can disagree with the thing it was derived from.
#
# WHAT THE PARTY IS ALWAYS IN is a CORRIDOR between two boundaries: `rear_row`,
# the strip they came through, and `target_row`, the strip they are heading for.
# Crossing promotes one to the other. Both walls, both predicates, the scoring
# and the spawn rules are all expressed against those two numbers, which is why
# there is no separate notion of "which segment am I in" anywhere in here.
#
# NOTHING IN HERE READS A CLOCK TO DECIDE ANYTHING. `round_clock` accumulates and
# is shown and scored, and no transition consults it -- five minutes is an
# authoring budget, not a mechanism (see the plan's R6a). The gate on that lives
# in test_round_machine and is deliberately a claim that something is IMPOSSIBLE.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

enum State { LOBBY, RUNNING, CLOSING, SCORING }

# How long the party gets, once the first of them is over the line, before the
# round closes behind the stragglers.
const CLOSE_SECONDS := 30.0

# How long the board stays up before the lobby is free again. The players are
# already standing in the lobby by then -- this is the state, not a screen.
const SCORE_SECONDS := 10.0

# The design target a section is authored against. Read by nothing; shown, and
# compared against `round_clock` on the board. See the note above.
const TARGET_SECONDS := 300.0

var state: int = State.LOBBY
var round_index: int = 0

# The corridor. -1 means "the bridge does not have one yet", which is a real
# state on a run whose next segment has not been appended -- not an error, and
# never a guess.
var rear_row: int = -1
var target_row: int = -1

var round_clock: float = 0.0
var close_timer: float = 0.0

# WHO LIVED, recorded AT THE MOMENT OF CONTACT and never re-derived. By the time
# the board opens the closing sequence has moved people, so asking "who is
# standing on the checker" then would be a question about where bodies ended up
# rather than about what players did.
var reached: Dictionary = {}       # peer -> true

# The last round's board, kept so the lobby can show it.
var board: Array = []

func is_lobby() -> bool:
	return state == State.LOBBY or state == State.SCORING

func state_name() -> String:
	match state:
		State.LOBBY: return "LOBBY"
		State.RUNNING: return "ROUND"
		State.CLOSING: return "CLOSING"
		State.SCORING: return "SCORES"
	return ""

# --- The tick -----------------------------------------------------------------

func step(world) -> void:
	if world.grid == null or world.players.is_empty():
		return

	# THE CORRIDOR IS RE-ASKED EVERY TICK WHILE IT IS UNKNOWN. A run builds
	# lazily, so at the moment a lobby is entered the next boundary may not exist
	# yet; the plan's R2 applies to this as much as to the crossing check. An
	# answer taken once, in the handler that fired on entry, would be -1 forever.
	if target_row < 0:
		target_row = world.grid.gate_after(_rearmost_row(world))

	match state:
		State.LOBBY: _step_lobby(world)
		State.RUNNING: _step_running(world)
		State.CLOSING: _step_closing(world)
		State.SCORING: _step_scoring(world)

func _step_lobby(world) -> void:
	if target_row < 0:
		return
	# EVERY PLAYER, POLLED. Not the handler that fired when somebody stepped on --
	# this project has already lost a day to a readiness check that only ran in an
	# event handler and therefore never ran again (CLAUDE.md).
	if not _all_at_or_past(world, target_row):
		return
	_cross(world)

func _step_running(world) -> void:
	round_clock += SimConfig.TICK_DELTA
	if _everyone_is_out(world):
		# THE ONLY OTHER ENDING. With no clock to fire, reaching the strip is the
		# one way forward, so a wiped party would otherwise have no exit from a
		# section at all. Scored as a round nobody finished.
		_begin_scoring(world)
		return
	if target_row < 0:
		return
	if not _any_at_or_past(world, target_row):
		return
	state = State.CLOSING
	close_timer = CLOSE_SECONDS
	_mark_arrivals(world)

func _step_closing(world) -> void:
	round_clock += SimConfig.TICK_DELTA
	close_timer = maxf(0.0, close_timer - SimConfig.TICK_DELTA)
	# EVERY TICK OF THE WINDOW, not at its end. Anyone who gets over the line
	# while the clock runs has made it, and marking them here is what makes that
	# true of the last tick as well as the first.
	_mark_arrivals(world)
	if _everyone_is_out(world):
		_begin_scoring(world)
		return
	if close_timer > 0.0:
		return
	_cross(world)
	_begin_scoring(world)

func _step_scoring(world) -> void:
	close_timer = maxf(0.0, close_timer - SimConfig.TICK_DELTA)
	if close_timer > 0.0:
		return
	_enter_lobby(world)

# --- Transitions --------------------------------------------------------------

# The party is over the line: the corridor moves up one.
func _cross(world) -> void:
	rear_row = target_row
	target_row = world.grid.gate_after(rear_row)
	if state == State.LOBBY:
		state = State.RUNNING
		round_clock = 0.0
		reached.clear()

func _begin_scoring(world) -> void:
	state = State.SCORING
	close_timer = SCORE_SECONDS
	board = rank(world)

func _enter_lobby(world) -> void:
	state = State.LOBBY
	round_index += 1
	round_clock = 0.0
	close_timer = 0.0
	reached.clear()
	# Re-asked rather than assumed: the run may have grown since the round began.
	target_row = world.grid.gate_after(_rearmost_row(world))

# --- Predicates ---------------------------------------------------------------

func row_of(world, body) -> int:
	return world.grid.cell_of_world(body.position).y

func _all_at_or_past(world, row: int) -> bool:
	for peer_key in world.players.keys():
		var body: Node = world.players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		if row_of(world, body) < row:
			return false
	return true

func _any_at_or_past(world, row: int) -> bool:
	for peer_key in world.players.keys():
		var body: Node = world.players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		if row_of(world, body) >= row:
			return true
	return false

# Everyone waiting on the drone. THE ROUND ENDS WHEN NOBODY HAS A CHANCE LEFT,
# not when nobody is standing -- the same narrowing the wipe condition already
# went through after a playtest found the run restarting on the tick the last
# player caught a ledge.
func _everyone_is_out(world) -> bool:
	if world.players.is_empty():
		return false
	for peer_key in world.players.keys():
		if not world._returning.has(int(peer_key)):
			return false
	return true

func _mark_arrivals(world) -> void:
	if target_row < 0:
		return
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		var body: Node = world.players[peer]
		if body == null or not is_instance_valid(body):
			continue
		if row_of(world, body) >= target_row:
			reached[peer] = true

func _rearmost_row(world) -> int:
	var worst := 0
	var found := false
	for peer_key in world.players.keys():
		var body: Node = world.players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		var r: int = row_of(world, body)
		if not found or r < worst:
			worst = r
			found = true
	return worst

# --- Scoring ------------------------------------------------------------------

# N HATS > 1 HAT > MADE IT > DIDN'T. The first criterion, and deliberately the
# only one: each future game type gets its own, and the difference between "a
# scorer per mode" and a growing if-chain is decided now, while there is one.
#
# A pure function of (who reached, how many hats), so the ranking is testable as
# a table of cases rather than by playing a round.
static func rank_entries(entries: Array) -> Array:
	var out: Array = entries.duplicate()
	out.sort_custom(func(a, b):
		var ah: int = int(a.get("hats", 0))
		var bh: int = int(b.get("hats", 0))
		if ah != bh:
			return ah > bh
		var ar: bool = bool(a.get("made_it", false))
		var br: bool = bool(b.get("made_it", false))
		if ar != br:
			return ar
		# A STABLE TIE-BREAK, and it has to be something. Peer id is arbitrary but
		# it is the same arbitrary on every machine, which a sort on equal keys is
		# not promised to be -- two clients showing the board in a different order
		# is a disagreement about the round.
		return int(a.get("peer", 0)) < int(b.get("peer", 0)))
	return out

func rank(world) -> Array:
	var entries: Array = []
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		entries.append({
			"peer": peer,
			"name": world.player_name(peer),
			"hats": int(world.hats_worn_by(peer).size()),
			"made_it": bool(reached.get(peer, false)),
		})
	return rank_entries(entries)

# --- Where the walls stand ----------------------------------------------------

# A boundary has two edges and the wall uses both, one at a time:
#
#   THE FRONT WALL is on the UP-BRIDGE edge of the target strip, so the party can
#   stand ON the checker -- which is the whole gesture -- and not pass it.
#   THE REAR WALL is on the DOWN-BRIDGE edge of the strip they came through, so
#   it appears immediately behind them the moment they cross rather than a strip
#   back.
#
# Returned in GRID-LOCAL space. The bridge is pitched four degrees and everything
# built as a child of the grid inherits that for free; a world-space answer would
# have to redo it and would be subtly wrong on every segment above the first.
static func wall_z_local(row: int, up_bridge: bool) -> float:
	# cell_z_world(row) is the CENTRE of the row and up-bridge is -Z.
	var half: float = GridConfig.CELL_SIZE * 0.5
	return GridConfig.cell_z_world(row) + (-half if up_bridge else half)
