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
static func plan(run_seed: int, count: int) -> Array:
	var out: Array = []
	if POOL.is_empty():
		return out
	var cycle: int = SECTIONS_PER_ROUND + 1
	for i in count:
		if i % cycle == 0:
			out.append(GENERATED_LOBBY)
		else:
			out.append(section_for(run_seed, i))
	return out

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
	# UNPINNING THIS IS BLOCKED ON A REAL BUG (2026-08-16), not on the argument.
	#
	# The argument is settled: pinning meant every run opened on the one section
	# guaranteed to contain none of the generator's work, and a playtest had to
	# walk past a whole authored level to reach what it was for.
	#
	# Removing the pin failed test_checkpoint_return, and NOT on a margin. From
	# row 110 the return landed at row 11 -- the FIRST lobby, ignoring every lobby
	# between -- which is precisely the failure that assertion was written to
	# catch: "a return that has lost track of the lobby entirely". The pin was
	# hiding it, because with slot 0 fixed the lookup happened to agree.
	#
	# Left pinned until the lookup is fixed. Unpinning is one line and the bug is
	# not; shipping them together would have been a level-layout change that
	# silently sends fallen players 99 rows back.
	if i <= 1:
		return String(POOL[0]["path"])
	if _mix(run_seed + i * 104729) % 3 == 0:
		return String(POOL[_mix(run_seed + i * 7919) % POOL.size()]["path"])
	return GENERATED_SECTION

static func entry_for(path: String) -> Dictionary:
	for entry in POOL:
		if String(entry["path"]) == path:
			return entry
	return {}
