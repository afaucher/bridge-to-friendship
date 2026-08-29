extends RefCounted

# THE STAT REGISTRY, and the arithmetic over it. M19 phases 0 and 2.
#
# TO ADD A STAT: append ONE entry to STATS and put ONE `_bump` at the line where
# the thing happens. Nothing else -- no wire change, no scoreboard change, no
# per-stat replication code. The board renders whatever is in here and the round
# sync sends whatever is in here. That property is the whole reason this file
# exists rather than fifteen named fields, and it is the same bargain
# DebugSettings.OPTIONS already makes for debug knobs.
#
# NOTHING IN HERE TOUCHES THE WORLD. `superlatives` is arithmetic over a table of
# dictionaries, which is what makes it testable as a table of cases rather than by
# playing a round -- the property RoundMachine.rank_entries already has and the
# reason it has never been wrong.

# WHICH END IS GOOD. Not decoration: it is what decides whether a zero is a
# non-result ("most dashes: 0" is nothing) or the best score available ("fewest
# deaths: 0" is the thing worth saying).
const SimConfig = preload("res://scripts/sim/sim_config.gd")

const MOST := 0
const LEAST := 1

# HOW MANY BADGES A PLAYER CAN HOLD. Three, from the ask. Above about four the
# board stops reading as "here is what you were good at" and starts reading as a
# dump of everything that was measured.
const BADGE_LIMIT := 3

# THE ORDER OF THIS DICTIONARY IS PART OF THE OUTPUT. GDScript preserves
# insertion order, and `superlatives` uses the index as its final tie-break so
# that two clients handed the same numbers pick the same badges. Same reasoning as
# rank_entries falling back to peer id, and the same reasoning as SetPieces.LIBRARY
# being a list rather than a directory scan: a disagreement here is two players
# looking at two different scoreboards with no error anywhere.
#
# APPEND, DO NOT REORDER.
const STATS := {
	# --- The common block: shown for every player, every round -----------------
	"shots_fired": {
		"label": "Shots fired", "best": MOST, "common": true,
		"help": "Counted where the round is SPAWNED, on the host.",
	},
	"hits": {
		"label": "Hits", "best": MOST, "common": true, "percent_of": "shots_fired",
		"help": "Counted on the RECEIVING side, and only against a person or an enemy. A round stopped by cover was fired and did not hit, and a counter at the muzzle cannot tell the difference; a round that knocked a stone about was neither a miss nor marksmanship.",
	},
	"enemy_damage": {
		"label": "Enemy damage", "best": MOST, "common": true,
		"help": "Health actually removed, not the amount the hit asked for.",
	},
	"enemy_kills": {
		"label": "Kills", "best": MOST, "common": true,
		"help": "To whoever delivered the last point.",
	},
	"deaths": {
		"label": "Deaths", "best": LEAST, "common": true,
		"help": "Being put on the drone: counted at that line, once, whatever put you there. If a teammate reached you in time you did not die -- so this and `rescued` are a matched pair, the times nobody got there and the times somebody did.",
	},
	"friendly_damage": {
		"label": "Friendly fire", "best": MOST, "common": true,
		"help": "Same measurement as enemy damage; the target is a teammate.",
	},
	"rescues": {
		"label": "Rescues", "best": MOST, "common": true,
		"help": "Counted on the rescuER, at the line that revives somebody.",
	},

	# --- The tail: badge material ----------------------------------------------
	#
	# EVERY KEY HERE IS WIRED TO A LINE THAT INCREMENTS IT. Registering a stat
	# nothing counts would put a permanent zero in the table, and a permanent zero
	# is invisible: the default-value rule below drops it from every badge list, so
	# it would never appear and never be missed. That is a stat that silently does
	# not exist. The rest of the ask's list -- hats worn, hats lost, specials used
	# -- lands here in phase 4, one entry and one `_bump` at a time.
	"dashes": {"label": "Most dashes", "best": MOST},
	"healed": {"label": "Most health picked up", "best": MOST},
	"rescued": {"label": "Most often rescued", "best": MOST},
	"self_damage": {"label": "Most self-inflicted", "best": MOST},
	# A PEAK, so it is written by _bump_max rather than accumulated. Deliberately
	# NOT the same number as the hats you finish with -- that one is the ranking
	# key, and "carried six, kept one" is a better story than either half.
	"hats_worn": {"label": "Tallest tower", "best": MOST},
	"boosts": {"label": "Most boosts given", "best": MOST},
	"hats_lost": {"label": "Most hats lost", "best": MOST},
	# STORED AS TICKS, SHOWN AS TIME. The table is ints throughout -- one type on
	# the wire, one type in the comparison -- so a duration is counted in the unit
	# the simulation actually has and converted at the last moment.
	#
	# WORTH KNOWING WHAT THIS BADGE DOES. If nobody dies, everybody ties at the
	# full round and the party-wide rule drops it, which is right. If one of four
	# dies, the other THREE tie at the maximum and all three get the badge -- a
	# superlative three quarters of the party holds. It is the honest consequence
	# of "most" on a stat with a ceiling everybody reaches; inverting it to time
	# spent DOWN, with LEAST best, would name the same fact about one person
	# instead. One line either way if it reads badly in play.
	"time_alive": {"label": "Longest alive", "best": MOST, "format": "seconds"},
	# STORED IN CENTIMETRES for the same reason -- and see _count_edges for the
	# teleport guard, which is the whole difficulty in this one.
	"distance": {"label": "Furthest travelled", "best": MOST, "format": "metres"},

	# --- The silly block (playtest 2026-08-23) ---------------------------------
	#
	# ASKED FOR AS A GROUP, and the group is the point: every stat above is
	# something you were trying to do. These are things that merely HAPPENED to
	# you, and a board with only virtues on it reads like a report card.
	#
	# "Most hats lost" was on the list and was already here -- registered in phase
	# 4 with two live bump sites. Left where it is rather than moved down, since
	# the order of this dictionary is part of the output.

	# GROUND GIVEN UP, and it is NOT counted in "steps" -- the ask said steps and
	# this game has no such unit, so it is the down-bridge component of the same
	# per-tick travel `distance` measures, sharing its teleport guard.
	"backwards": {"label": "Furthest backwards", "best": MOST, "format": "metres"},

	# ALTITUDE, MEASURED IN THE GRID'S OWN FRAME rather than in world Y, and that
	# is the whole difficulty. The bridge is pitched BRIDGE_PITCH_DEG, so a player
	# who only ever walks forwards gains height for free and the badge would go to
	# whoever travelled furthest -- which `distance` already says. Grid-local Y has
	# the pitch divided out by construction, so this counts ramps, lifts, ladders
	# and towers and nothing else. It also survives the bridge being untilted,
	# which is on the table from the same playtest.
	"climbed": {"label": "Most altitude gained", "best": MOST, "format": "metres"},

	# SHOTS TAKEN ON THE MOVE. "Walking" is not a state in this game -- it is the
	# absence of the others -- so the predicate is SPEED, at half a walk. A player
	# shuffling on the spot to farm it has to actually be going somewhere.
	"walking_shots": {"label": "Most shots on the move", "best": MOST},

	# GOT THEMSELVES OUT. Counted where the minigame is won rather than beside
	# `rescued`, which is about somebody coming for you -- the whole point of the
	# self-revive is that nobody did.
	"self_revives": {"label": "Most self-rescues", "best": MOST},

	# THE FASTEST ANYBODY WENT. Badge material, deliberately not `common`: it is
	# not one of the seven things every player wants to know every round, and the
	# common block is already at the width the board can carry.
	#
	# STORED IN CENTIMETRES PER SECOND, for the reason the whole table is ints --
	# one type on the wire and one type in the comparison. `format_value` is the
	# only place that knows.
	#
	# MEASURED FROM THE SAME PER-TICK STEP `distance` USES, AND INSIDE THE SAME
	# TELEPORT GUARD, which is the entire difficulty. A speed derived from a
	# position delta cannot tell travel from being MOVED: a drone return, a
	# checkpoint rewind or a straggler leash covers tens of metres in one tick,
	# and this badge would go permanently to whoever died furthest from the party
	# at something like 2000 m/s. The guard `distance` already carries for exactly
	# that reason is what makes the number mean anything.
	#
	# NOT COUNTED WHILE YOU ARE BEING MOVED, which is the difference between a
	# badge and a tie. A dash is SHOVE_SPEED, 56 m/s -- nine times a walk and four
	# times the bus -- so with dashes counted every player who has ever dashed
	# posts exactly 56.0 and the superlative goes to all of them. Same for a
	# tumble, which is as fast as whatever threw you. See the guard in the world.
	#
	# AND IT WILL USUALLY NAME A DRIVER, which is a feature: a walk is 6 m/s and
	# the bus does 13, so "top speed" is a thing you go and do rather than a thing
	# that accrues. Riders are POSED onto their seat rather than stepping, and the
	# step here is a position delta, so a passenger is credited with the bus's
	# speed too -- everybody aboard went that fast, which is true.
	"top_speed": {"label": "Top speed", "best": MOST, "format": "speed"},
}

static func keys() -> Array:
	return STATS.keys()

static func common_keys() -> Array:
	var out: Array = []
	for key in STATS:
		if bool(STATS[key].get("common", false)):
			out.append(str(key))
	return out

static func label_of(key: String) -> String:
	return str(STATS.get(key, {}).get("label", key))

static func best_of(key: String) -> int:
	return int(STATS.get(key, {}).get("best", MOST))

static func default_of(key: String) -> int:
	return int(STATS.get(key, {}).get("default", 0))

static func percent_of(key: String) -> String:
	return str(STATS.get(key, {}).get("percent_of", ""))

# --- Superlatives -------------------------------------------------------------

# WHO WON WHAT, up to `limit` each. `stats_by_peer` is {peer: {key: int}} and the
# answer is {peer: [{key, value, tie}]}, ordered best-badge-first.
#
# THE FOUR RULES, and each is a decision rather than an implementation detail:
#
#   TIES ALL WIN. The ask is "won or tied for first", so equal values are equal
#   badges. `tie` carries how many shared it, because "most kills (tied)" is a
#   different sentence from "most kills" and the screen should be able to say so.
#
#   A WIN ON THE DEFAULT VALUE IS NOT A WIN, unless LEAST is the good end. Nobody
#   wants a badge for "most dashes: 0". "Fewest deaths: 0" is the best score in
#   the game and is exactly the thing worth saying, which is why `best` exists.
#
#   A WIN THE WHOLE PARTY SHARES IS NOT A WIN. If everybody tied then nothing
#   distinguishes anybody, and four identical badges is noise wearing the costume
#   of an achievement -- a badge is a COMPARISON, and with nobody to compare
#   against there is nothing being said. Its consequence is deliberate and is
#   written down in the plan: a SOLO scoreboard shows no badges at all. The common
#   block still shows a lone player their numbers, which is the part that means
#   anything when there is nobody to beat.
#
#   RAREST FIRST. A stat won outright beats one tied two ways, which beats one
#   tied three ways -- so the three that survive the cap are the three that say
#   the most. Registry order breaks the remaining ties, for determinism.
static func superlatives(stats_by_peer: Dictionary, limit: int = BADGE_LIMIT) -> Dictionary:
	var out: Dictionary = {}
	var peers: Array = stats_by_peer.keys()
	peers.sort()
	for peer in peers:
		out[peer] = []
	if peers.size() < 2:
		# ONE PLAYER WINS EVERYTHING, WHICH IS TO SAY NOTHING. Handled up front
		# rather than falling out of the party-wide rule below, because it is worth
		# being able to read the reason here.
		return out

	# THE COMMON BLOCK IS ALREADY ON THE BOARD, so a badge for one of those seven
	# stats would repeat a row the player is already looking at -- "Most kills" as
	# a badge, directly under a KILLS column that already says who won it. Badges
	# are for what did NOT get a pinned row of its own.
	var order: Array = keys()
	for index in order.size():
		var key: String = str(order[index])
		if bool(STATS[key].get("common", false)):
			continue
		var direction: int = best_of(key)

		var best: int = 0
		var first := true
		for peer in peers:
			var value: int = _value_of(stats_by_peer, peer, key)
			if first:
				best = value
				first = false
			elif direction == LEAST:
				best = mini(best, value)
			else:
				best = maxi(best, value)

		# A ZERO IS ONLY A RESULT WHEN LESS IS BETTER.
		if direction == MOST and best == default_of(key):
			continue

		var winners: Array = []
		for peer in peers:
			if _value_of(stats_by_peer, peer, key) == best:
				winners.append(peer)
		# EVERYBODY, THEREFORE NOBODY.
		if winners.size() >= peers.size():
			continue

		for peer in winners:
			out[peer].append({
				"key": key, "value": best, "tie": winners.size(), "order": index,
			})

	for peer in peers:
		var badges: Array = out[peer]
		badges.sort_custom(func(a, b):
			if int(a["tie"]) != int(b["tie"]):
				return int(a["tie"]) < int(b["tie"])
			return int(a["order"]) < int(b["order"]))
		out[peer] = badges.slice(0, maxi(0, limit))
	return out

static func _value_of(stats_by_peer: Dictionary, peer, key: String) -> int:
	var row: Dictionary = stats_by_peer.get(peer, {})
	return int(row.get(key, default_of(key)))

# --- Formatting ---------------------------------------------------------------

# HITS WITH NO SHOTS IS NOT 0%. A player who never fired has no accuracy, and
# printing 0% beside their name says they missed everything they tried.
static func percent_text(hits: int, shots: int) -> String:
	if shots <= 0:
		return "--"
	return "%d%%" % int(round(100.0 * float(hits) / float(shots)))

# --- The round, as text -------------------------------------------------------

# WHAT GOES IN THE LOG AT THE END OF A ROUND, built from the BOARD rather than
# from the live counters -- so what is written down is exactly what the players
# were shown. If the log and the screen could disagree, a playtest report about a
# number would be unanswerable.
#
# A PURE FUNCTION, so the thing worth asserting can be asserted: that EVERY
# registered stat reaches the line. The registry's promise is that adding a stat
# is one entry and one bump, and a log with a hand-written list of columns quietly
# breaks it -- the new stat is on the screen and missing from the record of the
# session, which is the half you still have a week later.
static func log_lines(board: Array, round_index: int) -> Array:
	var out: Array = ["[round %d] %d players" % [round_index, board.size()]]
	for entry in board:
		var parts: Array = []
		var stats: Dictionary = entry.get("stats", {})
		for key in keys():
			var name: String = str(key)
			parts.append("%s=%s" % [name, format_value(name, int(stats.get(name, 0)))])
		out.append("[round %d] #%d %s hats=%d made_it=%s | %s" % [
			round_index, int(entry.get("rank", 0)), str(entry.get("name", "?")),
			int(entry.get("hats", 0)), str(bool(entry.get("made_it", false))),
			" ".join(parts)])
		var badges: Array = entry.get("badges", [])
		if not badges.is_empty():
			var won: Array = []
			for badge in badges:
				var badge_key: String = str(badge.get("key", ""))
				won.append("%s (%s%s)" % [label_of(badge_key),
					format_value(badge_key, int(badge.get("value", 0))),
					", tied" if int(badge.get("tie", 1)) > 1 else ""])
			out.append("[round %d]    badges: %s" % [round_index, "; ".join(won)])
	return out

# COUNTED IN ONE UNIT, SHOWN IN ANOTHER. Everything in the table is an int, which
# keeps the wire and the comparisons a single type; a duration is therefore ticks
# and a distance is centimetres, and this is the only place that knows.
static func format_value(key: String, value: int) -> String:
	match str(STATS.get(key, {}).get("format", "count")):
		"seconds":
			var total: int = int(round(float(value) * SimConfig.TICK_DELTA))
			return "%d:%02d" % [total / 60, total % 60]
		"metres":
			return "%.0f m" % (float(value) / 100.0)
		"speed":
			return "%.1f m/s" % (float(value) / 100.0)
	return str(value)
