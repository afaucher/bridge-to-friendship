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
	# THE EXCEPTION, and the reason `best` exists at all. Zero deaths is the best
	# score in the game, so the default-value rule must not eat it.
	var table := {1: {"deaths": 0}, 2: {"deaths": 2}, 3: {"deaths": 3}}
	var out: Dictionary = StatRegistry.superlatives(table)
	check(_keys_for(out, 1).has("deaths"),
		"fewest deaths at ZERO is a badge: the default-value rule is about MOST, "
		+ "and for LEAST the default is the best score available")
	check(not _keys_for(out, 3).has("deaths"), "and the most deaths is not one")

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
	# Peer 1 wins four things: two outright, two shared with peer 2. The cap is
	# three and the outright wins must survive it.
	var table := {
		1: {"dashes": 9, "healed": 9, "rescues": 5, "shots_fired": 5, "deaths": 4},
		2: {"dashes": 1, "healed": 1, "rescues": 5, "shots_fired": 5, "deaths": 0},
		3: {"dashes": 0, "healed": 0, "rescues": 0, "shots_fired": 0, "deaths": 2},
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
	check(_keys_for(out, 1).has("dashes") and _keys_for(out, 1).has("healed"),
		"specifically the two outright wins are both kept")
	# Deaths: 0 beats 4, and LEAST is the good end, so peer 2 takes it.
	check(_keys_for(out, 2).has("deaths"),
		"and the other player's own outright win is theirs")

func _test_percent() -> void:
	eq(StatRegistry.percent_text(1, 4), "25%", "a hit rate reads as a percentage")
	eq(StatRegistry.percent_text(0, 0), "--",
		"and a player who never fired has NO accuracy -- printing 0% beside their "
		+ "name says they missed everything they tried")

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
