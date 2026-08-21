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
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# WHAT A THEME CAN ASK FOR. Named rather than free-form so a typo is a missing
# key rather than a silently empty budget, and so the set of things a theme can
# vary is a list somebody can read.
const KINDS := ["shooters", "turrets", "rushers", "zombies", "plinko", "spikes", "cover", "specials",
	"hearts", "crumble", "timed"]

# The kinds that can take health off somebody who is not free to move. `cover`,
# `specials` and `hearts` are deliberately absent: a lift with cover beside it is
# a BETTER lift, and the whole complaint is that a rider has nothing.
const DANGEROUS_KINDS := ["shooters", "turrets", "rushers", "zombies", "plinko", "spikes",
	"crumble", "timed"]

# THE FOUR THEMES, from the hazard mixes wanted for M17. They are budgets over
# the same ground, and the differences between them are meant to be legible in
# this table rather than in any code.
#
# `cover` is deliberately high wherever `shooters` is: cover is what makes a
# shooting gallery a route with decisions rather than a corridor you cross while
# being shot, and pairing them here is what stops a theme being authored unfair.
#
# `zombies` IS COUNTED IN GRAVES, NOT IN BODIES, and it is the only budget in this
# table where those differ. One grave is three to five zombies, so a 2 here is
# between six and ten enemies -- roughly what a `rushers` of 8 would be worth, and
# it is why survival gets 3 and firefight gets none.
const THEMES := {
	"firefight": {
		"shooters": 5, "turrets": 2, "rushers": 1, "zombies": 0, "plinko": 0,
		"spikes": 0, "cover": 10, "specials": 2, "hearts": 1,
		"crumble": 0, "timed": 0,
	},
	"environmental": {
		"shooters": 0, "turrets": 0, "rushers": 1, "zombies": 1, "plinko": 0,
		"spikes": 14, "cover": 2, "specials": 1, "hearts": 1,
		# THE GROUND ITSELF IS THE HAZARD HERE, which is what separates this theme
		# from "firefight with the shooters turned off".
		"crumble": 5, "timed": 4,
	},
	"survival": {
		# THE THEME A PACK BELONGS TO. Survival's whole shape is "too many things
		# at once, none of them individually clever", and a grave is the purest
		# statement of that available -- so it gets the most, and it is paid for
		# out of the rusher budget rather than added on top of it (6 was the old
		# number; enemies-on-the-deck is what got rebalanced, not raised).
		"shooters": 1, "turrets": 1, "rushers": 3, "zombies": 3, "plinko": 4,
		"spikes": 2, "cover": 5, "specials": 3, "hearts": 2,
		"crumble": 2, "timed": 0,
	},
	"quiet": {
		"shooters": 1, "turrets": 0, "rushers": 2, "zombies": 0, "plinko": 0,
		"spikes": 3, "cover": 4, "specials": 1, "hearts": 1,
		"crumble": 1, "timed": 1,
	},
}

const CONTENT_FOR := {
	"shooters": GridConfig.Content.SKIRMISHER,
	"turrets": GridConfig.Content.TURRET,
	"rushers": GridConfig.Content.MOUND,
	"zombies": GridConfig.Content.GRAVE,
	"plinko": GridConfig.Content.SHOOTER,
	"spikes": GridConfig.Content.SPIKES,
	"hearts": GridConfig.Content.HEART,
	"crumble": GridConfig.Content.CRUMBLE,
	"timed": GridConfig.Content.TIMED,
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

	# THE MERCHANT GOES FIRST, AND THAT ORDERING IS THE WHOLE RULE. Every kind in
	# the budget loop below asks "where do I want to be"; he is the first thing on
	# this bridge that needs the hazards to ask about HIM, and the only way
	# `_near_merchant` can answer is if he is already standing there when they are
	# placed. Placed second, the check would be a check against an empty grid --
	# green, worthless, and exactly the shape of the 2026-08-16 note about a test
	# run on the wrong object.
	# DELIBERATELY NOT RECORDED IN `placed`. That dictionary is the BUDGET LEDGER
	# -- its contract is "how many of each kind the budget bought", and the only
	# thing anybody asks it is whether a count exceeded its allowance. The merchant
	# has no allowance to exceed, so an entry for him is a row that fails that
	# question by construction. Count him off the grid instead, which is the
	# direct count anyway; test_merchant_placement does.
	_place_merchant(seg, salt)

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

# ONE MERCHANT, RARELY, AND NOT OUT OF THE BUDGET.
#
# He is the first entry whose budget wants to be FRACTIONAL -- one in six
# segments rather than N per segment -- which is why he is not in `KINDS` at all
# and gets his own pass rather than a `THEMES` column of zeroes and the occasional
# one. A theme that wanted to vary him could still do it later; nothing about
# this shape prevents it, and a column of zeroes today would be four numbers
# nobody is reading.
#
# RARITY IS A MIX, NEVER A FLOAT ROLL, for the reason at the top of this file:
# the pass is a pure function of (run_seed, index) and a client is told two
# numbers and builds the identical bridge. `randf() < 1.0 / 6.0` would put a
# shopkeeper on one machine and not the other, and the symptom is a player
# trading with thin air.
static func _place_merchant(seg, salt: int) -> bool:
	# READ THROUGH THE KNOB so a playtest can find one on purpose rather than
	# walking until the dice agree. Set `merchant_rarity` to 1 and every generated
	# section has one.
	#
	# THIS MAKES A DEBUG SETTING AN INPUT TO WORLDGEN, which no other knob is, and
	# the bridge being a pure function of its seed is what lets a client be told
	# two numbers instead of a world. Both machines dress from their OWN copy of
	# this value, so two machines that disagree about it build different bridges.
	# Solo and dev only; see the note on the knob.
	var rarity: int = maxi(1, int(DebugSettings.tuned(
		"merchant_rarity", float(SimConfig.MERCHANT_RARITY))))
	if _mix(salt + 104729) % rarity != 0:
		return false
	var cells: Array = _candidates(seg, "merchant")
	if cells.is_empty():
		return false
	# Walked rather than indexed once. A single seeded pick that lands on an
	# authored cell is a segment that rolled a merchant and silently has none --
	# the rarity would then be lower than the constant says, in a way nothing
	# reports.
	var at: int = _mix(salt + 7) % cells.size()
	for _i in cells.size():
		var cell: Vector2i = cells[at]
		at = (at + 1) % cells.size()
		if seg.content_at(cell.x, cell.y) != GridConfig.Content.NONE:
			continue
		seg.contents[cell.y][cell.x] = GridConfig.Content.MERCHANT
		return true
	return false

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
		# A SET-PIECE IS SOMEBODY ELSE'S WORK (M18 phase 2). Refusing to overwrite
		# its CONTENT is not enough: the empty cells of a composition are the
		# composition -- the lane you cross, the ground the cover is cover from --
		# so the whole row is out of bounds.
		#
		# EVERY KIND, INCLUDING COVER AND PICKUPS. A lift with cover beside it is a
		# better lift and that argument does not carry here: a piece was authored
		# with the cover it wanted, and one more changes the answer it was posing.
		# Start closed; a piece that WANTS dressing can say so with a tag later.
		#
		# Filtered here rather than in _wants, for the reason the lift clearance is
		# checked up front: the next kind added would not have remembered.
		if seg.piece_rows.has(z):
			continue
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
	# Checked up front and for every dangerous kind at once rather than repeated
	# inside each branch: the next hazard added would not have remembered.
	if kind in DANGEROUS_KINDS and _near_lift(seg, x, z):
		return false
	# AND NOT BESIDE THE SHOPKEEPER, checked in the same place and for the same
	# reason: written into each branch, the next hazard added would not have
	# remembered. See _near_merchant for why he needs the clearance -- the short
	# version is that a dash is also how you fight.
	if kind in DANGEROUS_KINDS and _near_merchant(seg, x, z):
		return false
	match kind:
		"merchant":
			# OPEN GROUND WITH CLEARANCE, and NEVER BESIDE A LIFT -- the same
			# exclusion the hazards get, for the opposite reason. A rider carried
			# past him is a hat spent by the terrain, which is a trade with no
			# decision in it and the one outcome this feature must not have.
			#
			# The clearance is measured with the SAME radius the hazards keep, so
			# the invariant is one number stated once and holds whichever of the
			# two was placed first.
			return (not _near_lift(seg, x, z)
				and _open_run(seg, x, z, 2)
				and not _near_content(seg, x, z, SimConfig.MERCHANT_CLEARANCE))
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
		"zombies":
			# EVERYTHING A MOUND WANTS, PLUS GROUND ON ALL EIGHT SIDES.
			#
			# A grave is one cell that places three to five bodies on a ring 0.95 m
			# out, so with a 0.45 m radius the pack reaches 1.4 m from the centre
			# and the cell is 2.0 m across: it spills into its neighbours by
			# construction. A member over a hole falls the instant it exists, and
			# what that looks like from the deck is an authored encounter arriving
			# at half strength with nothing anywhere reporting it.
			#
			# The clearance is 2 rather than the mound's 1 for a second reason:
			# five bodies rising inside another prop is five bodies being ejected
			# by the solver, which is the coincident-bodies trap reached sideways.
			return (_open_run(seg, x, z, 3)
				and not _near_content(seg, x, z, 2)
				and _solid_around(seg, x, z))
		"spikes":
			# A cell somebody has to walk PAST -- so, beside a hole or an edge,
			# where the route is pinched and stepping around is a decision.
			return _beside_a_gap(seg, x, z)
		"cover":
			# In front of something that shoots, or where a lane is long enough
			# that crossing it unprotected is the problem cover solves.
			return _open_run(seg, x, z, 2)
		"crumble", "timed":
			# ON THE DESIRE LINE, which is the opposite of everything else here and
			# is the point: a temporary floor beside the route is scenery. It goes
			# in the middle of a clear lane, where it is the ground you were going
			# to walk on anyway.
			#
			# NEVER BESIDE A GAP — unlike spikes, whose whole job is to pinch a
			# route. A crumble at the edge of a hole widens that hole for four
			# seconds, and a pinch that widens is how a section stops being
			# crossable while the flood still says it is (2b counts these as solid
			# BECAUSE they come back and BECAUSE there is deck either side).
			return x >= 2 and x < seg.width - 2 and _open_run(seg, x, z, 2) 				and not _beside_a_gap(seg, x, z)
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

# Deck on this cell and on all eight around it. The opposite question to
# _beside_a_gap, and worth its own name rather than `not _beside_a_gap`: that one
# looks at four neighbours, and a pack spills diagonally too.
static func _solid_around(seg, x: int, z: int) -> bool:
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if not seg.is_solid(x + dx, z + dz):
				return false
	return true

static func _beside_a_gap(seg, x: int, z: int) -> bool:
	for dir in 4:
		var step: Vector2i = GridConfig.DIR_CELLS[dir]
		if not seg.is_solid(x + step.x, z + step.y):
			return true
	return false

# NOTHING THAT HURTS YOU GOES BESIDE A LIFT (playtest 2026-08-16).
#
# The sharpest instance of a rule this pass did not have: a dressing budget is
# spent without knowing what the SKELETON asks of the player at that spot. A
# generated run put a skirmisher two cells from its only elevator, and riding one
# is three and a half seconds of standing still, elevated, with no cover and no
# verbs — you cannot dodge, dash or take cover, because stepping off is a
# four-metre drop. Measured: health 5 to 4 and a tumble on the ride; with that one
# gunner removed, the identical ride is untouched.
#
# So it reads as "the elevator hurts you", and the elevator has nothing to do with
# it. A LIFT IS A PLACE WHERE THE PLAYER HAS NO ANSWERS, and this pass has to know
# that the way it already knows a rusher wants open ground.
const LIFT_CLEARANCE := 3

static func _near_lift(seg, x: int, z: int) -> bool:
	for dz in range(-LIFT_CLEARANCE, LIFT_CLEARANCE + 1):
		for dx in range(-LIFT_CLEARANCE, LIFT_CLEARANCE + 1):
			if not seg.in_bounds(x + dx, z + dz):
				continue
			if seg.content_at(x + dx, z + dz) == GridConfig.Content.ELEVATOR:
				return true
	return false

# NOTHING DANGEROUS BESIDE THE SHOPKEEPER, and this is the one rule here that
# runs the opposite way round from every other. Each entry in `_wants` asks "where
# do I want to be"; the merchant is the first thing on the bridge that needs the
# hazards to ask about HIM.
#
# THE REASON IS THAT A DASH IS ALSO HOW YOU FIGHT. A merchant three cells from a
# rusher means a player dashing AT the rusher clips the shopkeeper and spends a
# hat on a trade they never made -- and the report would say the RUSHER took their
# hat, because that is the only attribution available from inside the game. Same
# shape as the spike block two cells from a lift, which reached playtest as "the
# elevator hurts you, every time it moves".
static func _near_merchant(seg, x: int, z: int) -> bool:
	var r: int = SimConfig.MERCHANT_CLEARANCE
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if not seg.in_bounds(x + dx, z + dz):
				continue
			if seg.content_at(x + dx, z + dz) == GridConfig.Content.MERCHANT:
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
