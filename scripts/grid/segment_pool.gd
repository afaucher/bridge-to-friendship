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
static func plan(run_seed: int, count: int) -> Array:
	var out: Array = []
	if POOL.is_empty():
		return out
	for i in count:
		# The first segment is always the same one, so every run opens on
		# familiar ground and a player is never dropped straight into the
		# hardest thing the pool has.
		var index: int = 0 if i == 0 else _mix(run_seed + i * 7919) % POOL.size()
		out.append(String(POOL[index]["path"]))
	return out

static func entry_for(path: String) -> Dictionary:
	for entry in POOL:
		if String(entry["path"]) == path:
			return entry
	return {}
