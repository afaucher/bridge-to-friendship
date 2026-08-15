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
# LOBBY, SECTION, LOBBY, SECTION (M16). A run OPENS on a lobby, because the first
# thing that should happen in a session is the party standing together deciding
# to start -- and because the lobby's entry strip is what gives the round machine
# a rear boundary to hang the first corridor off.
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
	for i in count:
		out.append(LOBBY if i % 2 == 0 else section_for(run_seed, i))
	return out

# Which section fills slot `i`. The first one is always the same, so every run
# opens on familiar ground and nobody is dropped straight into the hardest thing
# the pool has.
static func section_for(run_seed: int, i: int) -> String:
	if POOL.is_empty():
		return LOBBY
	var index: int = 0 if i <= 1 else _mix(run_seed + i * 7919) % POOL.size()
	return String(POOL[index]["path"])

static func entry_for(path: String) -> Dictionary:
	for entry in POOL:
		if String(entry["path"]) == path:
			return entry
	return {}
