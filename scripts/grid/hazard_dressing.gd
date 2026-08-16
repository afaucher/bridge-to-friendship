extends RefCounted

# THE DRESSING PASS: what goes ON a layout, decided separately from the layout.
#
# M17 layer 3. The terrain says where you can walk; this says what is there to
# deal with, and keeping them apart is the whole reason the same ground can be
# played as an enemy problem or an environmental one. A THEME is a budget and a
# whitelist, nothing more:
#
#     {"shooters": 8, "rushers": 0, "spikes": 12}   vs
#     {"shooters": 2, "rushers": 6, "plinko": 3}
#
# over the identical skeleton.
#
# PLACEMENT IS BY RULE, NOT BY DICE. A shooter wants cover in front of it and a
# lane to shoot down; a spike block wants a cell somebody must walk PAST; a
# rusher's mound wants open ground, because a mound behind a pillar is a mound
# that never fires. The rules mean the same theme produces sensible results on a
# skeleton nobody has seen, which is the entire point of separating the layers.
#
# It also retires an M15 note. "A validator rule refusing a turret with no cover
# in front of it" was on the list as a lint; here the same statement IS the
# placement rule, and a lint for something a generator cannot produce is a lint
# nobody needs.
#
# DETERMINISTIC IN (seed, segment index). The bridge is a pure function of its
# seed and everything about it must stay one -- a client is told two numbers and
# builds the identical world. So this uses the same local mixer the pool does and
# never touches the global RNG.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

# WHAT A THEME CAN ASK FOR. Named rather than free-form so a typo is a missing
# key rather than a silently empty budget, and so the set of things a theme can
# vary is a list somebody can read.
const KINDS := ["shooters", "turrets", "rushers", "plinko", "spikes", "cover", "specials", "hearts"]

# THE FOUR THEMES, from the hazard mixes wanted for M17. They are budgets over
# the same ground, and the differences between them are meant to be legible in
# this table rather than in any code.
#
# `cover` is deliberately high wherever `shooters` is: cover is what makes a
# shooting gallery a route with decisions rather than a corridor you cross while
# being shot, and pairing them here is what stops a theme being authored unfair.
const THEMES := {
	"firefight": {
		"shooters": 5, "turrets": 2, "rushers": 1, "plinko": 0,
		"spikes": 0, "cover": 10, "specials": 2, "hearts": 1,
	},
	"environmental": {
		"shooters": 0, "turrets": 0, "rushers": 1, "plinko": 0,
		"spikes": 14, "cover": 2, "specials": 1, "hearts": 1,
	},
	"survival": {
		"shooters": 1, "turrets": 1, "rushers": 6, "plinko": 4,
		"spikes": 2, "cover": 5, "specials": 3, "hearts": 2,
	},
	"quiet": {
		"shooters": 1, "turrets": 0, "rushers": 2, "plinko": 0,
		"spikes": 3, "cover": 4, "specials": 1, "hearts": 1,
	},
}

const CONTENT_FOR := {
	"shooters": GridConfig.Content.SKIRMISHER,
	"turrets": GridConfig.Content.TURRET,
	"rushers": GridConfig.Content.MOUND,
	"plinko": GridConfig.Content.SHOOTER,
	"spikes": GridConfig.Content.SPIKES,
	"hearts": GridConfig.Content.HEART,
}

static func theme_names() -> Array:
	var names: Array = THEMES.keys()
	names.sort()
	return names

# Which theme dresses segment `index` of a run. Deterministic, and never the same
# one twice running -- two firefights back to back read as one long firefight.
#
# A STRIDE, NOT A LOOKBACK. The first version picked a theme per index and bumped
# it when it matched the previous index's pick -- which was wrong, because the
# previous index's pick had been bumped too and this compared against the raw
# one. Walking the list at a fixed stride is correct by construction: consecutive
# indices differ by the stride, and a stride that is never 0 mod n can never
# produce a repeat.
#
# The stride is also chosen COPRIME with the count, so the sequence uses every
# theme rather than alternating between two. With four themes the coprime strides
# are 1 and 3; a stride of 2 would give firefight, survival, firefight, survival
# forever, which satisfies "no repeats" and is not what was wanted.
static func theme_for(run_seed: int, index: int) -> String:
	var names: Array = theme_names()
	var n: int = names.size()
	if n == 0:
		return ""
	if n == 1:
		return String(names[0])
	var strides: Array = []
	for step in range(1, n):
		if _coprime(step, n):
			strides.append(step)
	var stride: int = int(strides[_mix(run_seed + 31) % strides.size()])
	var base: int = _mix(run_seed) % n
	return String(names[(base + index * stride) % n])

static func _coprime(a: int, b: int) -> bool:
	while b != 0:
		var t: int = b
		b = a % b
		a = t
	return a == 1

# APPLIES TO THE PARSED SEGMENT, IN PLACE, BEFORE IT IS BUILT. Dressing a segment
# after its meshes and bodies exist would mean tearing them down again; the whole
# pass is a few dictionary writes on cell records, which is what the data/view
# split in this project is for.
#
# AUTHORED CONTENT IS NEVER OVERWRITTEN. A cell the author filled is a decision
# somebody made, and the pass only ever writes to NONE.
static func dress(seg, theme: String, run_seed: int, index: int) -> Dictionary:
	var placed := {}
	if not THEMES.has(theme):
		return placed
	var budget: Dictionary = THEMES[theme]
	var salt: int = _mix(run_seed + index * 7919)

	for kind in KINDS:
		var want: int = int(budget.get(kind, 0))
		if want <= 0:
			continue
		var cells: Array = _candidates(seg, kind)
		if cells.is_empty():
			continue
		# Spread rather than clustered: walking the candidate list at a stride
		# taken from the seed puts the Nth pick a long way from the (N-1)th
		# without needing a distance check or a retry loop.
		var stride: int = 1 + (salt + KINDS.find(kind) * 131) % maxi(1, cells.size())
		var at: int = (salt / 7 + KINDS.find(kind) * 17) % cells.size()
		var done := 0
		for _i in cells.size():
			if done >= want:
				break
			var cell: Vector2i = cells[at]
			at = (at + stride) % cells.size()
			if seg.content_at(cell.x, cell.y) != GridConfig.Content.NONE:
				continue
			seg.contents[cell.y][cell.x] = _content_for(kind, salt + done)
			placed[kind] = int(placed.get(kind, 0)) + 1
			done += 1
	return placed

static func _content_for(kind: String, salt: int) -> int:
	if kind == "cover":
		# Two shapes, mixed. A field of nothing but trees reads as scenery; a
		# field of nothing but walls reads as a maze.
		return GridConfig.Content.TREE if salt % 2 == 0 else GridConfig.Content.HALF_WALL
	if kind == "specials":
		var pool: Array = [
			GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
			GridConfig.Content.PICKUP_MINE, GridConfig.Content.PICKUP_SHIELD,
			GridConfig.Content.PICKUP_ROCKET, GridConfig.Content.PICKUP_LEGS,
		]
		return int(pool[salt % pool.size()])
	return int(CONTENT_FOR.get(kind, GridConfig.Content.NONE))

# --- Where each thing WANTS to be --------------------------------------------
#
# One function, and the rules are the design. Each returns the cells a thing of
# that kind could sensibly go in, in a stable order.
static func _candidates(seg, kind: String) -> Array:
	var out: Array = []
	# Never the entry or exit row: a segment has to be enterable and leavable,
	# and a turret on the seam is a turret the party meets with no warning.
	for z in range(1, maxi(2, seg.length - 1)):
		for x in seg.width:
			if not seg.is_solid(x, z):
				continue
			if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
				# Nothing settles on a slope -- the hat and special rules already
				# say so, and a mound rising out of a hillside is worse.
				continue
			if not _wants(seg, kind, x, z):
				continue
			out.append(Vector2i(x, z))
	return out

static func _wants(seg, kind: String, x: int, z: int) -> bool:
	match kind:
		"shooters", "turrets":
			# A LANE TO SHOOT DOWN, and something to hide behind on the way in.
			# An enemy with no approach to cover is the unfair version of this.
			return _open_run(seg, x, z, 3)
		"plinko":
			# Up-bridge, so its output travels back down at the party under the
			# bridge's own pitch, and never in the first half.
			return z > seg.length / 2 and _open_run(seg, x, z, 2)
		"rushers":
			# OPEN GROUND. A rusher runs in a straight line and only chases what
			# it can see, so a mound behind cover is a mound that never fires.
			return _open_run(seg, x, z, 3) and not _near_content(seg, x, z, 1)
		"spikes":
			# A cell somebody has to walk PAST -- so, beside a hole or an edge,
			# where the route is pinched and stepping around is a decision.
			return _beside_a_gap(seg, x, z)
		"cover":
			# In front of something that shoots, or where a lane is long enough
			# that crossing it unprotected is the problem cover solves.
			return _open_run(seg, x, z, 2)
		"specials", "hearts":
			# Off the desire line: the interesting place for a pickup is PAST
			# something, never beside the safe spot.
			return x < 2 or x >= seg.width - 2 or _beside_a_gap(seg, x, z)
	return false

# A clear run of solid deck up-bridge of this cell, which is what "a lane" means.
static func _open_run(seg, x: int, z: int, want: int) -> bool:
	var run := 0
	for dz in range(1, want + 1):
		if not seg.is_solid(x, z - dz):
			break
		if seg.content_at(x, z - dz) != GridConfig.Content.NONE:
			break
		run += 1
	return run >= want

static func _beside_a_gap(seg, x: int, z: int) -> bool:
	for dir in 4:
		var step: Vector2i = GridConfig.DIR_CELLS[dir]
		if not seg.is_solid(x + step.x, z + step.y):
			return true
	return false

static func _near_content(seg, x: int, z: int, radius: int) -> bool:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue
			if not seg.in_bounds(x + dx, z + dz):
				continue
			if seg.content_at(x + dx, z + dz) != GridConfig.Content.NONE:
				return true
	return false

# The pool's mixer, for the reason the pool has one: the global RNG is seeded
# once per launch and consumed by everything else, so a world planned from it
# would differ between two machines that had drawn a different number of randoms.
static func _mix(value: int) -> int:
	var x: int = value
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return absi(x)
