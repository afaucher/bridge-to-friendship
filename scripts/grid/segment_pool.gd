extends RefCounted

# The pool a run is assembled from, and the assembler itself.
#
# THE BRIDGE IS A PURE FUNCTION OF (seed, pool). That is the whole design, and it
# is what makes drop-in affordable: a player joining a run in progress is told the
# seed and how many segments are loaded, builds the identical bridge locally, and
# then only needs a diff of what has MOVED since. Without it, joining would mean
# shipping the whole world down the wire.
#
# It also means the assembler must not touch the global RNG. `randf()` is seeded
# once per launch and consumed by everything else in the game; a run planned from
# it would differ between two machines that had drawn a different number of random
# numbers beforehand. The generator here is local, explicit, and depends on
# nothing but the seed and the index.

const SegmentData = preload("res://scripts/grid/segment_data.gd")

# Listed explicitly rather than scanned from the directory. A DirAccess scan of
# res:// behaves differently in an export than in a dev run, and "the level pool
# is empty in the shipped build" is exactly the class of bug that only shows up
# after packaging.
#
# `difficulty` is a rough rank, used by the curve in M10. `tags` are what a future
# assembler balances on -- avoiding three ramp segments in a row, or deliberately
# stacking them.
# THE LOBBY, which is not in the pool and never should be. It is not a level --
# it is the punctuation between them, and it appears in every run at every odd
# index by construction rather than by a dice roll that might not come up.
const LOBBY := "res://segments/lobby.seg"

# GENERATED SLOTS, named rather than pathed. The plan stays a list of strings so
# nothing that reads it changes; these two markers say "the generator fills this"
# and BridgeGrid.build_run is the only place that knows the difference.
#
# The lobby is generated ALWAYS (M17 phase 4): it is trivially parametric and it
# is the one piece of content where a generation bug is cheap. Sections are
# generated for every slot but the FIRST, so a run still opens on the authored
# playtest bridge -- familiar ground before anything nobody has seen.
const GENERATED_LOBBY := "@lobby"
const GENERATED_SECTION := "@section"

const POOL := [
	{
		"path": "res://segments/playtest_bridge.seg",
		"difficulty": 2,
		"tags": ["ramp", "ladder", "water", "plinko"],
	},
	{
		"path": "res://segments/run_gaps.seg",
		"difficulty": 1,
		"tags": ["gaps", "exposed"],
	},
	{
		"path": "res://segments/run_pillars.seg",
		"difficulty": 2,
		"tags": ["plinko", "pillars"],
	},
	# THE ONE SECTION WITH NO HAZARD IN IT AT ALL, and that is what it is for. Every
	# other thing in the pool asks the party to survive something; this one asks
	# them to agree on a route while spread out where they cannot help each other.
	# Difficulty 1 as a threat and not at all easy as a section.
	{
		"path": "res://segments/run_maze.seg",
		"difficulty": 1,
		"tags": ["maze", "walls", "navigation"],
	},
]

# A small deterministic generator. Deliberately NOT the global RNG -- see above.
# Any stable hash would do; this one is a well-known integer mixer and is used
# only to pick indices.
static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)

# The ordered list of segment paths for a run. Same seed and same index always
# give the same segment, on every machine, forever.
#
# HOW MANY SEGMENTS OF BRIDGE ARE IN ONE ROUND.
#
# FIVE, up from one on 2026-08-15: the first build put a single pool segment
# between lobbies and it played about five times too short. The pool's segments
# are 16 to 30 rows -- 32 to 60 m -- so a round is now roughly 200 m of bridge
# and, more to the point, five segments' worth of the things IN them, which is
# what a round's length is actually made of.
#
# A KNOB RATHER THAN A RESHAPED SEGMENT, deliberately. The alternative was
# authoring five-times-longer segments, which would have thrown away the three
# that exist and made every future one a bigger commitment. The pool stays a set
# of small pieces and the ROUND decides how many to string together -- so this
# number is the length dial for the whole game, and re-tuning it after a playtest
# costs one edit rather than a re-authoring pass.
const SECTIONS_PER_ROUND := 5

# LOBBY, then SECTIONS_PER_ROUND sections, then LOBBY (M16). A run OPENS on a
# lobby, because the first thing that should happen in a session is the party
# standing together deciding to start -- and because the lobby's entry band is
# what gives the round machine a rear boundary to hang the first corridor off.
#
# THE SECTION IS A SLOT FILLED BY NAME. `section_for` is the only thing that
# decides which level comes next, and it is a pure function of (seed, index)
# today. When players vote for the next one, this is where the vote is READ --
# a value change, not a structural one, which is the entire reason the loop is
# expressed this way rather than as "append whatever is next".
# A SEED PER ROUND, tolerantly. `seeds` is the same shape as the mode array --
# one entry per round, replicated on the same message -- and an empty one, or a
# round past its end, falls back to the run seed. That is the pre-M27 behaviour
# exactly, which is what every existing caller and every older host gets.
static func slot_seed(run_seed: int, seeds: Array, i: int) -> int:
	var round_index: int = round_of_slot(i)
	if round_index < 0 or round_index >= seeds.size():
		return run_seed
	return int(seeds[round_index])

static func plan(run_seed: int, count: int, seeds: Array = []) -> Array:
	var out: Array = []
	if POOL.is_empty():
		return out
	var cycle: int = SECTIONS_PER_ROUND + 1
	for i in count:
		if i % cycle == 0:
			out.append(GENERATED_LOBBY)
		else:
			out.append(section_for(slot_seed(run_seed, seeds, i), i))
	return out

# HOW MANY ROUNDS A PLAN OF THIS MANY SEGMENTS COVERS. The cycle length lives in
# one place for the same reason `is_lobby_slot` does: a caller that re-derives it
# from SECTIONS_PER_ROUND gets it off by one, and M25 indexes its mode array by
# round, so an off-by-one here is a round played in the wrong mode.
static func rounds_in(segments: int) -> int:
	if segments <= 0:
		return 0
	return (segments - 1) / (SECTIONS_PER_ROUND + 1) + 1

# HOW MANY SEGMENTS COVER EVERYTHING UP TO AND INCLUDING ROUND `index`'S LOBBY.
#
# WHAT A SPECULATIVE REBUILD KEEPS, and the distinction is a whole round wide.
# `round_index` is incremented on ENTERING a lobby, so a party standing in a lobby
# is standing in round N and choosing what round N's SECTIONS will be -- those
# sections are ahead of them and unplayed. Keeping "through round N" would have
# kept the very ground the choice is about, and the choice would have done
# nothing to the corridor while appearing to be taken up.
static func segments_through_lobby(index: int) -> int:
	return index * (SECTIONS_PER_ROUND + 1) + 1

# HOW MANY SEGMENTS COVER EVERY ROUND UP TO AND INCLUDING `index`. What a
# speculative rebuild KEEPS: the ground already played, plus the round the party
# is standing in. Everything past it is what nobody has seen yet.
static func segments_through_round(index: int) -> int:
	return (index + 1) * (SECTIONS_PER_ROUND + 1)

# Which round slot `i` belongs to. Its lobby and its sections are one round.
static func round_of_slot(i: int) -> int:
	return i / (SECTIONS_PER_ROUND + 1)

# True if slot `i` of a plan is a lobby. The cycle length lives in one place so
# a caller never re-derives it from SECTIONS_PER_ROUND and gets it off by one.
static func is_lobby_slot(i: int) -> bool:
	return i % (SECTIONS_PER_ROUND + 1) == 0

# Which section fills slot `i`. The first one is always the same, so every run
# opens on familiar ground and nobody is dropped straight into the hardest thing
# the pool has.
static func section_for(run_seed: int, i: int) -> String:
	if POOL.is_empty():
		return LOBBY
	# THE PLAYTEST BRIDGE IS NO LONGER PINNED TO THE FIRST SLOT (2026-08-16).
	#
	# It was, so every run opened on ground somebody designed. That was right
	# while generated terrain was new and bare, and stopped being right once the
	# generator had ramps, lifts, mutable ground and SET-PIECES in it: pinning
	# meant the first thing anybody saw was the one section guaranteed to contain
	# none of the work, and a playtest had to walk past a whole authored level to
	# reach what it was for.
	#
	# The pool is still in the mix at the same rate, so an authored section still
	# turns up every few slots -- what changed is that it is no longer ALWAYS the
	# opener, and `playtest_bridge` is still loadable directly as a fixture.
	#
	# THIS WAS BLOCKED FOR AN HOUR BY A TEST, NOT BY A BUG. Removing the pin
	# failed test_checkpoint_return at 99 rows against an allowance of 84, which
	# read as "the return has lost track of the lobby". It had not: that
	# assertion allowed a rewind of two segment lengths, and a return is not
	# bounded by a segment -- it goes to the ROUND's rear strip, so the distance
	# back is however far the party has walked since the last strip they crossed.
	# The test teleports its body and never completes a round, so the answer was
	# correctly the first lobby every time. See the note on that assertion.
	if _mix(run_seed + i * 104729) % 3 == 0:
		return String(POOL[_mix(run_seed + i * 7919) % POOL.size()]["path"])
	return GENERATED_SECTION

static func entry_for(path: String) -> Dictionary:
	for entry in POOL:
		if String(entry["path"]) == path:
			return entry
	return {}
