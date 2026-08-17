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
		"help": "Counted on the RECEIVING side. A round that is stopped by cover was fired and did not hit, and a counter that lives at the muzzle cannot tell the difference.",
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
		"help": "Counted on the rising edge of being out of play, so every cause counts and none counts twice.",
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

	var order: Array = keys()
	for index in order.size():
		var key: String = str(order[index])
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
