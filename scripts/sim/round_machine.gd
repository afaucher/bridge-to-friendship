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
const StatRegistry = preload("res://scripts/sim/stat_registry.gd")

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

	advance_clocks()

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

# THE CLOCKS, AND NOTHING THAT DECIDES ANYTHING. Split out of the three `_step_`
# functions on 2026-08-23, from a playtest report that the closing countdown sat
# at 30 s for everyone but the host.
#
# It did. `step()` runs from `_host_tick` only, so a client's copy was written
# once by `_round_sync` at the moment CLOSING began and never moved again -- and
# `hud_model` faithfully showed the stale number. THE FIX WAS ALREADY WRITTEN
# DOWN: `_on_round_state_changed` says "a client ticking its own copy down between
# those is right to within a frame", and nothing ticked it.
#
# ITS TWIN WAS FROZEN TOO and nobody had reported it: `round_clock` accumulates in
# the same two places, so a client's round timer was stopped as well. A clock
# counting UP from zero looks perfectly plausible while it is wrong, which is the
# whole reason to fix them together rather than the one that was noticed.
#
# ONE ARITHMETIC, CALLED FROM BOTH SIDES. A client that advanced its clocks with
# its own copy of these three lines would be two implementations of one fact, and
# this project has paid for that twice. The host reaches it through `step()`
# before any transition is evaluated, which is exactly the order the three
# functions had it in.
func advance_clocks() -> void:
	match state:
		State.RUNNING:
			round_clock += SimConfig.TICK_DELTA
		State.CLOSING:
			round_clock += SimConfig.TICK_DELTA
			close_timer = maxf(0.0, close_timer - SimConfig.TICK_DELTA)
		State.SCORING:
			close_timer = maxf(0.0, close_timer - SimConfig.TICK_DELTA)

func _step_running(world) -> void:
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
	# EVERY TICK OF THE WINDOW, not at its end. Anyone who gets over the line
	# while the clock runs has made it, and marking them here is what makes that
	# true of the last tick as well as the first.
	_mark_arrivals(world)
	if _everyone_is_out(world):
		_begin_scoring(world)
		return
	# EVERYBODY IS HERE, SO STOP COUNTING. The thirty seconds exist to give
	# stragglers a chance, and once there are no stragglers the clock is only
	# making the people who made it stand and watch it. Asked for after the first
	# playtest, and it is the same predicate the lobby opens on -- a round both
	# begins and ends the moment the party is together on a strip.
	if close_timer > 0.0 and not _all_at_or_past(world, target_row):
		return
	_cross(world)
	_begin_scoring(world)

func _step_scoring(world) -> void:
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
		# ONE DEFINITION OF "THIS ROUND" (M19). Hung off the same line that zeroes
		# the clock and clears the arrivals rather than given its own trigger: two
		# resets a tick apart produce a scoreboard covering slightly different
		# spans, which is not something anybody would catch by looking at it.
		world.clear_round_stats()

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
	# BOTH ENDS, RE-ASKED FROM WHERE THE PARTY ACTUALLY IS.
	#
	# Only `target_row` was re-derived here, and `rear_row` was left holding the
	# strip the party crossed to START the round they just lost -- which is not the
	# corridor they are standing in once a wipe has carried them backwards. The two
	# numbers could then describe a corridor spanning a whole round, and every rule
	# in this file is expressed against them.
	#
	# The corridor is defined at the top of this file as "the strip they came
	# through and the strip they are heading for". That is a statement about a
	# PLACE, so the only honest way to answer it after bodies have been moved is to
	# ask the grid where they ended up. Deriving one end and remembering the other
	# is what let them disagree.
	#
	# This alone does not fix the flip and `_lobby_point` alone does not either --
	# A/B'd separately 2026-08-16. With only this, the party is still standing ON
	# the exit band, so `gate_at_or_before` answers with that band and the corridor
	# is still the whole round. With only that, the party is back in the lobby but
	# `rear_row` still points at its exit, so rear and target land on the SAME row
	# and the rear wall stands between the player and the strip they have to cross.
	var rearmost: int = _rearmost_row(world)
	rear_row = world.grid.gate_at_or_before(rearmost)
	target_row = world.grid.gate_after(rearmost)

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

# N HATS > TALLER TOWER > MADE IT > DIDN'T. The first criterion, and deliberately
# nearly the only one: each future game type gets its own, and the difference
# between "a scorer per mode" and a growing if-chain is decided now, while there
# is one.
#
# HEIGHT BREAKS A TIE ON COUNT (playtest 2026-08-23), and it is a real distinction
# rather than a restatement only because of the merchant: HatStyle.slot_height
# gives a trophy TALL_HAT_SLOTS (3.5) against an ordinary hat's 1. So three hats
# including a trophy stands visibly taller than three ordinary ones, and this is
# what makes the board agree with what the players can already see from across the
# bridge.
#
# IT IS SECOND, NOT FIRST. Four hats still beats one trophy: the count is what the
# round is about and the height is what settles an argument between two people who
# did equally well at it.
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
		# In centimetres, so the comparison is exact and the wire carries an int
		# like every other field on the board.
		var at: int = int(a.get("hat_height", 0))
		var bt: int = int(b.get("hat_height", 0))
		if at != bt:
			return at > bt
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

# THE RANK SHOWN, WHICH IS NOT THE ORDER (M19).
#
# `rank_entries` returns a TOTAL order and has to: two clients showing the board
# in a different sequence is a disagreement about the round, which is why it falls
# back to peer id on equal scores. But that tie-break exists to make the LIST
# deterministic, not to invent a winner -- and printing "1st" and "2nd" beside two
# identical rows states something untrue.
#
# So the number is a second pass over the already-ordered list: a row scores the
# same as the row above it, so it gets the same rank. Standard competition
# numbering, so two joint firsts are followed by THIRD -- the gap is what says the
# tie happened.
#
# Keeping these two apart is the whole trick. Folding ties into the sort would
# mean a comparator that answers "equal" for two rows, and a sort on equal keys is
# not promised to be stable across machines.
static func display_ranks(ordered: Array) -> Array:
	var out: Array = []
	for i in ordered.size():
		if i == 0:
			out.append(1)
			continue
		var here: Dictionary = ordered[i]
		var above: Dictionary = ordered[i - 1]
		# EVERY KEY THE SORT USES, or the list is ordered by one rule and numbered
		# by another -- two players separated by tower height would be printed as
		# joint first while sitting in a deliberate order.
		var same: bool = int(here.get("hats", 0)) == int(above.get("hats", 0)) \
			and int(here.get("hat_height", 0)) == int(above.get("hat_height", 0)) \
			and bool(here.get("made_it", false)) == bool(above.get("made_it", false))
		out.append(int(out[i - 1]) if same else i + 1)
	return out

# HOW TALL THE TOWER ACTUALLY IS, asked of the same function that SPACES it.
# HatStyle.slot_height is what HatPool.pose_stack and the worn hit column both
# use, so a board that measured height any other way would be a third opinion
# about one fact -- and CLAUDE.md records what the last two cost.
static func _tower_cm(world, peer: int) -> int:
	var total: float = 0.0
	for hat in world.hats_worn_by(peer):
		if is_instance_valid(hat):
			total += float(hat.slot_height())
	return int(round(total * 100.0))

func rank(world) -> Array:
	var entries: Array = []
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		entries.append({
			"peer": peer,
			"name": world.player_name(peer),
			"steam_id": int(world.player_steam_id(peer)),
			"hats": int(world.hats_worn_by(peer).size()),
			"hat_height": _tower_cm(world, peer),
			"made_it": bool(reached.get(peer, false)),
			# THE ROUND'S NUMBERS RIDE THE BOARD. It already goes out reliably on
			# every state change, so a separate stats RPC would only add a way for
			# the board and the numbers describing it to arrive out of step.
			"stats": world.stats_of(peer),
		})
	var ordered: Array = rank_entries(entries)
	var ranks: Array = display_ranks(ordered)
	for i in ordered.size():
		ordered[i]["rank"] = int(ranks[i])
	# THE BADGES ARE COMPUTED ONCE, ON THE HOST, and shipped. A client working them
	# out for itself would be deriving them from numbers it was handed anyway, and
	# any disagreement -- a dropped field, a different registry order after an
	# upgrade -- would show as two players seeing different awards.
	var by_peer: Dictionary = {}
	for entry in ordered:
		by_peer[int(entry["peer"])] = entry.get("stats", {})
	var badges: Dictionary = StatRegistry.superlatives(by_peer)
	for entry in ordered:
		entry["badges"] = badges.get(int(entry["peer"]), [])
	return ordered

# --- Where the walls stand ----------------------------------------------------

# A boundary is a BAND and the wall uses its two outer edges, one at a time:
#
#   THE FRONT WALL is past the UP-BRIDGE end of the target band, so the party can
#   stand anywhere ON the checker -- which is the whole gesture -- and not pass.
#   THE REAR WALL is on the DOWN-BRIDGE edge of the band they came through, so it
#   appears immediately behind them the moment they cross rather than a band back.
#
# `row` is the band's first row and `span` how many rows it covers, so a two-deep
# strip puts the front wall two metres further up than a one-deep one and the
# party gets the room the band was widened to give them.
#
# Returned in GRID-LOCAL space. The bridge is pitched four degrees and everything
# built as a child of the grid inherits that for free; a world-space answer would
# have to redo it and would be subtly wrong on every segment above the first.
static func wall_z_local(row: int, up_bridge: bool, span: int = 1) -> float:
	# cell_z_world(row) is the CENTRE of the row and up-bridge is -Z.
	var half: float = GridConfig.CELL_SIZE * 0.5
	if up_bridge:
		return GridConfig.cell_z_world(row + maxi(span, 1) - 1) - half
	return GridConfig.cell_z_world(row) + half
