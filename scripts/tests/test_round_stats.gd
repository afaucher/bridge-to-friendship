extends "res://scripts/test_support/test_case.gd"

# M19 PHASE 2: the arithmetic, as a table.
#
# `superlatives` and `display_ranks` are pure functions over arrays of
# dictionaries, which is deliberate and is the same shape `rank_entries` already
# has -- the reason that one has never been wrong. Every rule the plan states can
# therefore be asserted as a case rather than by playing a round and hoping the
# situation came up.
#
# The four badge rules, each with a case that FAILS if the rule is removed:
#   ties all win, and are marked as ties
#   a win on the default value is not a win -- unless LEAST is the good end
#   a win the whole party shares is not a win (and so solo gets nothing)
#   rarest first, capped at three

const StatRegistry = preload("res://scripts/sim/stat_registry.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")

func setup(_main) -> void:
	_test_registry_is_wired()
	_test_ties_all_win()
	_test_zero_is_not_an_achievement()
	_test_fewest_is()
	_test_party_wide_is_nothing()
	_test_solo()
	_test_two_players_have_no_ties()
	_test_rarest_first_and_capped()
	_test_percent()
	_test_display_ranks()
	_test_log_lines()
	finish()

func _keys_for(result: Dictionary, peer: int) -> Array:
	var out: Array = []
	for badge in result.get(peer, []):
		out.append(str(badge["key"]))
	return out

# --- The registry itself ------------------------------------------------------

func _test_registry_is_wired() -> void:
	for key in StatRegistry.STATS:
		var entry: Dictionary = StatRegistry.STATS[key]
		check(entry.has("label"), "%s has a label for the board" % key)
		check(int(entry.get("best", -1)) in [StatRegistry.MOST, StatRegistry.LEAST],
			"%s says which end is good -- it is what decides whether a zero is a "
				% key
			+ "non-result or the best score available")
	check(StatRegistry.common_keys().size() == 7,
		"the common block is the seven stats asked for (%d)"
			% StatRegistry.common_keys().size())
	# THE ORDER IS PART OF THE OUTPUT. It is the final tie-break in `superlatives`,
	# so two clients handed the same numbers pick the same badges -- the same
	# reason rank_entries falls back to peer id.
	eq(StatRegistry.keys(), StatRegistry.STATS.keys(),
		"and the key order is the registry's own, which is what makes the badge "
		+ "choice deterministic across machines")

# --- The four rules -----------------------------------------------------------

func _test_ties_all_win() -> void:
	var table := {
		1: {"dashes": 4},
		2: {"dashes": 4},
		3: {"dashes": 1},
	}
	var out: Dictionary = StatRegistry.superlatives(table)
	check(_keys_for(out, 1).has("dashes"), "a tied leader still wins the badge")
	check(_keys_for(out, 2).has("dashes"), "and so does the other one")
	check(not _keys_for(out, 3).has("dashes"), "the player who lost does not")
	eq(int(out[1][0]["tie"]), 2,
		"and the badge carries how many shared it, because 'most dashes (tied)' "
		+ "is a different sentence from 'most dashes'")

func _test_zero_is_not_an_achievement() -> void:
	# Everybody on zero dashes except nobody: one player is simply less bad at a
	# thing nobody did. There is no achievement here to report.
	var table := {1: {"dashes": 0}, 2: {"dashes": 0}, 3: {"dashes": 0}}
	var out: Dictionary = StatRegistry.superlatives(table)
	eq(_keys_for(out, 1).size(), 0,
		"nobody gets 'most dashes: 0' -- a win on the default value is not a win")

func _test_fewest_is() -> void:
	# DEATHS NEVER BADGES, EVEN AT ITS BEST VALUE -- because it is one of the seven
	# common stats and already has a pinned row on the board. A badge under a
	# COMMON column that already says who won it is the repeat this rule exists to
	# refuse. Checked at the value that used to earn it one (zero, the best a LEAST
	# stat can score) so this is a real test of the exclusion and not a case that
	# happened not to trigger it.
	var table := {1: {"deaths": 0}, 2: {"deaths": 2}, 3: {"deaths": 3}}
	var out: Dictionary = StatRegistry.superlatives(table)
	check(not _keys_for(out, 1).has("deaths"),
		"fewest deaths at ZERO is still not a badge -- it is a common stat, and "
		+ "the common block on screen already says who has the fewest")
	check(not _keys_for(out, 3).has("deaths"), "and the most deaths never was one")

	# THE ARITHMETIC ITSELF, checked directly rather than through superlatives.
	# `deaths` is the ONLY least-direction stat in the registry, and it is common,
	# so the LEAST branch inside superlatives has no live path to it today -- any
	# future least-direction badge stat exercises the same best_of/default_of pair
	# this pins. Same shape as _maze_deepest: insurance for a branch nothing
	# currently reaches, unit-tested directly so it is not untested.
	eq(StatRegistry.best_of("deaths"), StatRegistry.LEAST,
		"deaths is scored LEAST-is-best")
	eq(StatRegistry.default_of("deaths"), 0,
		"and its default is zero, which IS the best score a LEAST stat can have")

func _test_party_wide_is_nothing() -> void:
	var table := {
		1: {"deaths": 1, "dashes": 3},
		2: {"deaths": 1, "dashes": 3},
		3: {"deaths": 1, "dashes": 3},
	}
	var out: Dictionary = StatRegistry.superlatives(table)
	eq(_keys_for(out, 1).size(), 0,
		"a superlative the WHOLE party shares is not a superlative -- a badge is a "
		+ "comparison, and with nobody to compare against there is nothing said")

func _test_solo() -> void:
	# THE DELIBERATE CONSEQUENCE of the rule above, asserted so nobody later reads
	# it as a bug and 'fixes' it. A lone player wins every stat in the game by
	# default; the common block still shows them their numbers.
	var out: Dictionary = StatRegistry.superlatives({7: {"dashes": 9, "deaths": 0}})
	eq(_keys_for(out, 7).size(), 0,
		"a solo scoreboard shows no badges at all, which is the intended "
		+ "consequence of a badge being a comparison")

func _test_two_players_have_no_ties() -> void:
	# A CONSEQUENCE OF THE PARTY-WIDE RULE, and it caught the first version of the
	# test below: with two players, ANY tie is shared by everybody, so a two-hander
	# can only ever produce badges that somebody won outright. Ties do not start
	# producing badges until there are three of you.
	var table := {1: {"dashes": 4, "healed": 3}, 2: {"dashes": 4, "healed": 1}}
	var out: Dictionary = StatRegistry.superlatives(table)
	check(not _keys_for(out, 1).has("dashes"),
		"in a party of two a tie is party-wide by definition, so it is dropped")
	check(_keys_for(out, 1).has("healed"),
		"while an outright win in the same table still lands")

func _test_rarest_first_and_capped() -> void:
	# THREE PLAYERS, so a two-way tie is a real tie rather than the whole party.
	# Every stat here is non-common on purpose: rescues, shots_fired and deaths
	# were doing this job until the common-exclusion made them ineligible, which is
	# what _test_fewest_is now covers. Peer 1 wins four badge-eligible things --
	# three outright, one shared with peer 2 -- and the cap is three, so the
	# outright wins have to survive it.
	var table := {
		1: {"dashes": 9, "healed": 9, "hats_worn": 9, "boosts": 5, "self_damage": 0},
		2: {"dashes": 1, "healed": 1, "hats_worn": 1, "boosts": 5, "self_damage": 9},
		3: {"dashes": 0, "healed": 0, "hats_worn": 0, "boosts": 0, "self_damage": 0},
	}
	var out: Dictionary = StatRegistry.superlatives(table)
	var badges: Array = out[1]
	eq(badges.size(), StatRegistry.BADGE_LIMIT,
		"a player holds at most three badges (%d)" % badges.size())
	eq(int(badges[0]["tie"]), 1, "and the first is one they won OUTRIGHT")
	eq(int(badges[1]["tie"]), 1, "and so is the second")
	for badge in badges:
		check(int(badge["tie"]) <= 2, "rarest first, so a tie never displaces a "
			+ "solo win (%s tied %d)" % [badge["key"], int(badge["tie"])])
	check(_keys_for(out, 1).has("dashes") and _keys_for(out, 1).has("healed")
			and _keys_for(out, 1).has("hats_worn"),
		"specifically all THREE outright wins are kept, not the tied fourth")
	# self_damage: peer 2 alone at 9 beats peer 1 and peer 3 at 0.
	check(_keys_for(out, 2).has("self_damage"),
		"and the other player's own outright win is theirs")

func _test_percent() -> void:
	eq(StatRegistry.percent_text(1, 4), "25%", "a hit rate reads as a percentage")
	eq(StatRegistry.percent_text(0, 0), "--",
		"and a player who never fired has NO accuracy -- printing 0% beside their "
		+ "name says they missed everything they tried")

# --- What goes in the log -----------------------------------------------------
#
# THE ASSERTION THAT CANNOT ROT: every registered stat reaches the line, checked
# by walking the REGISTRY rather than a list written here. The registry's whole
# promise is that adding a stat is one entry and one bump; a log with hand-written
# columns quietly breaks it, and the way you find out is a week later when the
# number you wanted is on nobody's screen and in nobody's file.
func _test_log_lines() -> void:
	var board: Array = [{
		"peer": 1, "name": "duckbob", "rank": 1, "hats": 3, "made_it": true,
		"stats": {"shots_fired": 48, "hits": 19, "time_alive": 7200, "distance": 34000},
		"badges": [{"key": "dashes", "value": 7, "tie": 1}],
	}]
	var lines: Array = StatRegistry.log_lines(board, 3)
	var blob: String = "\n".join(lines)

	check(lines.size() >= 2, "a round writes a header and a line per player")
	check(blob.contains("[round 3]"),
		"tagged with the round, so a session log can be read back per round")
	check(blob.contains("duckbob"), "and names the player")

	var missing: Array = []
	for key in StatRegistry.keys():
		if not blob.contains("%s=" % str(key)):
			missing.append(str(key))
	eq(missing.size(), 0,
		"EVERY registered stat is written down: missing %s. Walked from the "
			% str(missing)
		+ "registry rather than from a list here, so a stat added tomorrow is in "
		+ "the log tomorrow without anybody remembering to add it")

	# THE UNITS ARE THE READABLE ONES. A log full of tick counts and centimetres is
	# a log somebody has to do arithmetic on before they can report anything.
	check(blob.contains("time_alive=2:00"),
		"a duration is written as time, not as 7200 ticks")
	check(blob.contains("distance=340 m"),
		"and a distance in metres, not as 34000 centimetres")
	check(blob.contains("Most dashes"), "and the badges are written out too")

# --- Display ranks ------------------------------------------------------------

func _test_display_ranks() -> void:
	# The list is already ordered; this is only about the NUMBER shown.
	var clear: Array = [
		{"hats": 3, "made_it": true}, {"hats": 2, "made_it": true},
		{"hats": 1, "made_it": true}, {"hats": 0, "made_it": false},
	]
	eq(RoundMachine.display_ranks(clear), [1, 2, 3, 4],
		"with no tie the ranks are 1 2 3 4")

	var tied: Array = [
		{"hats": 3, "made_it": true}, {"hats": 3, "made_it": true},
		{"hats": 1, "made_it": true},
	]
	eq(RoundMachine.display_ranks(tied), [1, 1, 3],
		"two identical scores are JOINT first, and the next is THIRD -- standard "
		+ "competition numbering, where the gap is what says the tie happened")

	var all_same: Array = [
		{"hats": 0, "made_it": true}, {"hats": 0, "made_it": true},
		{"hats": 0, "made_it": true}, {"hats": 0, "made_it": true},
	]
	eq(RoundMachine.display_ranks(all_same), [1, 1, 1, 1],
		"and a four-way tie is four firsts")

	# SURVIVAL SEPARATES EQUAL HATS. Both halves of the ranking key have to be
	# compared or a player who was left behind reads as joint first with one who
	# made it on the same hats.
	var by_survival: Array = [
		{"hats": 1, "made_it": true}, {"hats": 1, "made_it": false},
	]
	eq(RoundMachine.display_ranks(by_survival), [1, 2],
		"equal hats but one was left behind is NOT a tie")

	# HEIGHT SEPARATES EQUAL COUNTS (playtest 2026-08-23), and the ORDER and the
	# NUMBER have to learn it together. `rank_entries` sorting on a key that
	# `display_ranks` does not compare is a list in a deliberate order with two
	# joint firsts printed on it -- which is worse than either rule alone, because
	# it looks like a bug in the sort.
	var by_height: Array = [
		{"hats": 3, "hat_height": 550, "made_it": true},
		{"hats": 3, "hat_height": 105, "made_it": true},
	]
	eq(RoundMachine.display_ranks(by_height), [1, 2],
		"three hats including a trophy is not a tie with three ordinary ones")
	eq(RoundMachine.display_ranks([
			{"hats": 2, "hat_height": 70, "made_it": true},
			{"hats": 2, "hat_height": 70, "made_it": true}]), [1, 1],
		"but equal counts at equal height still are")

	# ...AND THE SORT AGREES WITH THE NUMBER. Same table through rank_entries: the
	# taller tower comes first, and COUNT still outranks HEIGHT, because the count
	# is what the round is about and the height only settles an argument between
	# two people who did equally well at it.
	var ordered: Array = RoundMachine.rank_entries([
		{"peer": 1, "hats": 3, "hat_height": 105, "made_it": true},
		{"peer": 2, "hats": 3, "hat_height": 550, "made_it": true},
		{"peer": 3, "hats": 4, "hat_height": 140, "made_it": true},
	])
	var order: Array = []
	for e in ordered:
		order.append(int(e["peer"]))
	eq(order, [3, 2, 1],
		"four short hats beat one trophy, and the trophy beats three short ones")
