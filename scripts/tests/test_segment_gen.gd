extends "res://scripts/test_support/test_case.gd"

# M17 phases 4 and 5: generated lobbies, and the terrain skeleton.
#
# THE SOAK IS THE POINT. A generator is not proved by looking at one output; it
# is proved by producing hundreds and having every one clear the same bar an
# authored segment clears. So this generates across a spread of seeds and floods
# every single one.
#
# The claims:
#   1. EVERY GENERATED LOBBY IS VALID, at least LOBBY_MIN_WIDTH wide, has a
#      boundary band at each end, and carries a rack and hats. It is the pilot
#      generator because being wrong here is cheap -- no hazards, so a bug is a
#      strange room rather than an unfinishable run.
#   2. EVERY GENERATED SECTION IS CROSSABLE BY A LONE PLAYER. Generate, validate,
#      reject, reroll -- never construct-and-hope.
#   3. THE GENERATOR ACTUALLY VARIES. A generator that emits the same flat deck
#      every time would satisfy (2) perfectly, which is why the variation is
#      measured rather than assumed: heights, lengths and gap counts must differ
#      across seeds.
#   4. GENERATED AND AUTHORED SEGMENTS JOIN. The run contract from phase 0 is
#      applied to a mixed sequence.
#   5. IT IS DETERMINISTIC. Same seed, same segment -- the guarantee a joining
#      client rides.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")
const SetPieces = preload("res://scripts/grid/set_pieces.gd")
const SegmentData = preload("res://scripts/grid/segment_data.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const WIDTH := 13

func setup(_main) -> void:
	timeout_seconds = 90.0
	_check_lobbies()
	_check_sections()
	_check_variation()
	_check_joins()
	_check_lifts()
	_check_pieces()
	_check_mazes()
	_check_dressing_keeps_out()
	_check_deterministic()
	finish()

# --- 1. The pilot -------------------------------------------------------------

func _check_lobbies() -> void:
	var built := 0
	for seed_value in [1, 99, 5150, 20260816]:
		for index in 3:
			var seg = SegmentGen.lobby(WIDTH, seed_value, index)
			# A NULL HERE IS THE SHAPE OF THE BUG THIS FILE ALREADY HIT ONCE: a
			# raise inside the generator aborts it and returns null, and every
			# assertion after that is dead code in a green run.
			if seg == null:
				check(false, "the lobby generator returned NULL (seed %d, %d)"
					% [seed_value, index])
				return
			var problems: Array = SegmentValidator.validate(seg)
			if problems.size() > 0:
				check(false, "generated lobby (seed %d, %d) is invalid: %s"
					% [seed_value, index, problems[0]])
				return
			if seg.width < SegmentGen.LOBBY_MIN_WIDTH:
				check(false, "a lobby came out %d wide, under the floor" % seg.width)
				return
			# A band at each end, covering every STANDABLE cell. This is the regroup
			# row the whole run leans on, so it is worth asserting rather than
			# trusting.
			#
			# STANDABLE, NOT EVERY COLUMN (M22 phase C). The canvas is wider than
			# the bridge now, so a lobby has holes either side of it -- and a gate
			# marker on a hole is a boundary floating in the air, which
			# `_check_content_placement` refuses outright. The property the round
			# machine actually needs is that nobody can pass this row without
			# standing on a gate cell, and a hole satisfies that by being a hole.
			var band := 0
			var banded := true
			for x in seg.width:
				if not seg.is_solid(x, 0):
					continue
				band += 1
				if seg.content_at(x, 0) != GridConfig.Content.GATE:
					check(false, "lobby entry band has a gap at x %d" % x)
					banded = false
					break
				if seg.content_at(x, seg.length - 1) != GridConfig.Content.GATE:
					check(false, "lobby exit band has a gap at x %d" % x)
					banded = false
					break
			if not banded:
				return
			# COUNTED, because "every solid cell is a gate" is also true of a row
			# with one solid cell in it -- and with the canvas now wider than the
			# bridge, a lobby that came out a sliver would satisfy the loop above
			# and fail every reason the band exists.
			if not check(band >= SegmentGen.LOBBY_MIN_WIDTH,
					"and the band is a lobby's worth of standing room wide (%d)" % band):
				return
			built += 1
	check(built == 12, "every generated lobby is valid and banded (%d)" % built)

	# THE RESTOCK IS THERE. A lobby without a rack is a corridor.
	var one = SegmentGen.lobby(WIDTH, 7, 0)
	var racked := 0
	var hats := 0
	for z in one.length:
		for x in one.width:
			var c: int = one.content_at(x, z)
			if c == GridConfig.Content.HAT:
				hats += 1
			elif c in [GridConfig.Content.PICKUP, GridConfig.Content.PICKUP_GRENADE,
					GridConfig.Content.PICKUP_MINE, GridConfig.Content.PICKUP_SHIELD,
					GridConfig.Content.PICKUP_ROCKET]:
				racked += 1
	check(racked >= 4, "with a rack of specials to restock from (%d)" % racked)
	check(hats >= 3, "and hats, which are the score (%d)" % hats)

	# WIDER THAN ITS NEIGHBOURS IS FINE, and is the point: a lobby is always at
	# least as wide as everything that connects to it.
	eq(SegmentGen.lobby(3, 7, 0).width, SegmentGen.LOBBY_MIN_WIDTH,
		"a lobby asked to fit a narrow neighbour still gets its own minimum")

# --- 2. Every section is crossable -------------------------------------------

func _check_sections() -> void:
	var made := 0
	var fallbacks := 0
	for seed_value in [3, 11, 777, 20260816, 424242]:
		for index in 6:
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			if seg == null:
				check(false, "the section generator returned NULL (seed %d, %d)"
					% [seed_value, index])
				return
			var problems: Array = SegmentValidator.validate(seg)
			if problems.size() > 0:
				check(false, "generated section (seed %d, %d) is invalid: %s"
					% [seed_value, index, problems[0]])
				return
			if seg.tags.has("fallback"):
				fallbacks += 1
			made += 1
	check(made == 30, "every generated section validates (%d of them)" % made)
	# A fallback is not a failure, but a generator that ALWAYS falls back is one
	# that never really generates -- so the count is printed and bounded.
	print("[gen] %d of %d sections fell back to flat" % [fallbacks, made])
	check(fallbacks < made / 2,
		"and most are really generated rather than falling back (%d of %d)"
			% [fallbacks, made])

# --- 3. It varies ------------------------------------------------------------

func _check_variation() -> void:
	var lengths := {}
	var profiles := {}
	var gap_counts := {}
	for seed_value in [3, 11, 777, 20260816, 424242, 8, 64]:
		for index in 4:
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			lengths[seg.length] = true
			var climb: int = seg.height_at(0, seg.length - 1) - seg.height_at(0, 0)
			profiles[climb] = true
			var gaps := 0
			for z in seg.length:
				for x in seg.width:
					if not seg.is_solid(x, z):
						gaps += 1
			gap_counts[gaps] = true

	# WITHOUT THESE, a generator that emitted one flat deck forever would pass
	# every other assertion in this file.
	check(lengths.size() > 2, "sections vary in length (%d distinct)" % lengths.size())
	check(profiles.size() > 1, "and in how much they climb (%d distinct)" % profiles.size())
	check(gap_counts.size() > 3, "and in how many holes they have (%d distinct)"
		% gap_counts.size())

	# UP NEEDS A RAMP, DOWN NEEDS NOTHING, and both halves are asserted because
	# the generator had neither until a playtest asked about it. With no
	# ascenders every height change has to be ONE unit -- anything taller is a
	# wall a lone player cannot pass -- so the terrain came out as a gentle
	# staircase and could never be anything else. Everything validated the whole
	# time: "accessible" was true, and "interesting" is not something a flood has
	# an opinion about.
	#
	# MEASURED PER CELL, NOT DOWN COLUMN ZERO. The first version sampled x = 0 and
	# broke the moment ramps stopped spanning the full width -- it read the cliff
	# BESIDE a ramp as "a three-unit step up", which is exactly what a cliff is
	# and exactly what this claim is not about.
	var ramp_cells := 0
	var widths := {}
	var narrow_ramps := 0
	var total_ramps := 0
	var biggest_drop := 0
	var worst_ramp_rise := 0
	for seed_value in [3, 11, 777, 20260816, 424242]:
		for index in range(1, 6):
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			for z in seg.length:
				var run := 0
				for x in seg.width:
					if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
						ramp_cells += 1
						run += 1
						# A RAMP NEVER RISES MORE THAN ONE UNIT over the cell
						# behind it: 27 degrees, inside the walk angle. That is the
						# claim the solo budget rests on, and it is about the ramp
						# rather than about the cliff next to it.
						if z > 0 and seg.is_solid(x, z - 1):
							worst_ramp_rise = maxi(worst_ramp_rise, seg.height_at(x, z) - seg.height_at(x, z - 1))
						continue
					if run > 0:
						widths[run] = int(widths.get(run, 0)) + 1
						total_ramps += 1
						if run >= 2 and run <= 3:
							narrow_ramps += 1
						run = 0
				if run > 0:
					widths[run] = int(widths.get(run, 0)) + 1
					total_ramps += 1
					if run >= 2 and run <= 3:
						narrow_ramps += 1
				if z > 0:
					for x in seg.width:
						if seg.is_solid(x, z) and seg.is_solid(x, z - 1):
							biggest_drop = maxi(biggest_drop, seg.height_at(x, z - 1) - seg.height_at(x, z))

	print("[gen] ramp widths seen: %s" % str(widths))
	check(ramp_cells > 40, "climbs are made of RAMPS (%d ramp cells)" % ramp_cells)
	eq(worst_ramp_rise, 1,
		"and a ramp never rises more than one unit per cell, which is what makes a "
		+ "climb solo-passable however tall it is")
	check(biggest_drop > 1,
		"while DROPS are real cliffs (%d units) -- falling is free, which is the "
			% biggest_drop
		+ "asymmetry that makes split level possible at all")

	# EVERY RAMP LEADS SOMEWHERE. Reported from a playtest as "one ramp that led
	# to nothing", and it was two separate faults that both produced it:
	#
	#   the ramp was placed BEFORE the narrowing was decided, so it could climb
	#   into a column that gets cut away two rows later -- 40 of 231 tops;
	#   and a climb could run into the EXIT ROW, which the generator stamps flat
	#   at the height of the plateau BELOW, resetting the ramp's own top -- 23 of
	#   239 after the first fix.
	#
	# Neither was visible to the validator: a ramp into a hole is still a
	# perfectly crossable segment as long as some OTHER route exists, and one
	# usually did. Reachability says the party can get through; it has no opinion
	# on whether a thing you can see and walk up is a lie.
	var dead_tops := 0
	var tops := 0
	for seed_value in [3, 11, 777, 20260816, 424242, 8, 64, 5150]:
		for index in range(1, 6):
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			for z in seg.length:
				for x in seg.width:
					if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
						continue
					# Only the TOP of a ramp run: the cell up-bridge is not ramp.
					if z + 1 < seg.length and seg.kind_at(x, z + 1) == GridConfig.Kind.RAMP:
						continue
					tops += 1
					var lands: bool = z + 1 < seg.length 						and seg.is_solid(x, z + 1) 						and seg.height_at(x, z + 1) >= seg.height_at(x, z)
					if not lands:
						dead_tops += 1
	check(tops > 50, "there are ramps to check (%d tops)" % tops)
	eq(dead_tops, 0,
		"and every one of them LANDS -- on solid ground, at least as high as the "
		+ "ramp reached (%d of %d led nowhere)" % [dead_tops, tops])

	# A RAMP IS NARROW, WHICH IS THE POINT. A full-width ramp reads as the whole
	# bridge tilting: a staircase with no decision in it. Two or three cells of a
	# fifteen-wide deck makes the climb a PLACE the party converges on, with a
	# cliff either side that phase 2 turns into a real face.
	for w in widths.keys():
		check(int(w) >= 1 and int(w) <= 4,
			"no ramp is wider than four cells or narrower than one (saw %d)" % int(w))
	check(float(narrow_ramps) / float(maxi(1, total_ramps)) > 0.5,
		"and most are two or three wide (%d of %d) -- one is a scramble, four is a "
			% [narrow_ramps, total_ramps]
		+ "broad approach, and neither should be the norm")

	# LADDERS ARE NOT USED, and this is the assertion that keeps it that way.
	# ASCENDER_CONTENTS has counted LADDER since M2 but there is no climb mechanic
	# yet, so a generated ladder would produce a run that VALIDATES and cannot be
	# walked -- the worst possible failure for a rejection oracle. Phase 6 makes
	# ladders real; until then this must stay zero.
	var ladders := 0
	for seed_value in [3, 777, 424242]:
		for index in range(1, 6):
			var seg = SegmentGen.section(WIDTH, seed_value, index)
			for z in seg.length:
				for x in seg.width:
					if seg.content_at(x, z) == GridConfig.Content.LADDER:
						ladders += 1
	eq(ladders, 0,
		"and NO ladders are generated: the validator counts them as ascenders and "
		+ "the game has no climb mechanic, so one would validate and be impassable")

# --- 4. Generated and authored join ------------------------------------------

func _check_joins() -> void:
	var authored = SegmentData.from_file("res://segments/run_gaps.seg")
	check(authored.is_valid(), "an authored segment to join against")
	var w: int = authored.width
	var run: Array = [
		SegmentGen.lobby(w, 5, 0),
		SegmentGen.section(w, 5, 1),
		authored,
		SegmentGen.section(w, 5, 3),
		SegmentGen.lobby(w, 5, 4),
	]
	var problems: Array = SegmentValidator.validate_run(run, SegmentValidator.party_of(1))
	check(problems.is_empty(),
		"a run of generated and authored segments connects end to end (%s)"
			% ("" if problems.is_empty() else problems[0]))

# --- 5. Deterministic ---------------------------------------------------------

# --- Lifts (M17 phase 9) ------------------------------------------------------
#
# THE GENERATOR HAS TO ACTUALLY EMIT SOME. A feature nothing places is a feature
# nobody meets, and elevators spent a whole milestone in exactly that state:
# built, tested, replicated, and present in one test fixture and nowhere else.
#
# Rates rather than counts, over a sweep of seeds: the number in any ONE section
# is a dice roll, and asserting it would be asserting the mixer.
func _check_lifts() -> void:
	var sections: int = 0
	var with_lift: int = 0
	var lifts: int = 0
	var bad_rise: int = 0
	var narrowed: int = 0
	var armed: int = 0

	# A WIDE SWEEP, because the narrow one could not fail. At 40 seeds the
	# clearance assertion passed with the rule REMOVED -- none of those sections
	# happened to place a hazard near their lift, so the test was asserting
	# nothing. The bug was found at a seed this loop never visited.
	for i in 250:
		var seed_i: int = 9100 + i * 37
		var seg = SegmentGen.section(WIDTH, seed_i, i)
		if seg == null:
			continue
		# DRESSED FIRST, and the first version of this was not. Hazards are placed
		# by BridgeGrid at LOAD, not inside section() -- so a check run on the raw
		# section is a check run on a map with no hazards in it, and the clearance
		# assertion below passed with its rule deleted. A test on the wrong object
		# cannot fail, however many seeds it sweeps.
		HazardDressing.dress(seg, HazardDressing.theme_for(seed_i, i), seed_i, i)
		sections += 1
		var here: int = 0
		for z in seg.length:
			for x in seg.width:
				if seg.content_at(x, z) != GridConfig.Content.ELEVATOR:
					continue
				here += 1
				lifts += 1
				# A LIFT EARNS ITS WAIT. One unit is a one-row ramp already, so a
				# lift over one is a cost that buys nothing.
				var rise: int = seg.height_at(x, z) - seg.height_at(
					x if x > 0 else 1, z - 1 if z > 0 else 0)
				if rise < 2:
					bad_rise += 1
				# AND YOU CAN STEP OFF IT IN EITHER DIRECTION. A shaft with a
				# hole beside it is somewhere a player falls off while standing
				# still waiting.
				#
				# THE NEIGHBOURS, NOT THE WHOLE ROW (M22). This demanded the entire
				# row be solid, which was the same claim while every generated row
				# was full width and is a far bigger one now the deck varies. It was
				# also the wrong claim: what a rider needs is ground to step onto,
				# and `safe` guarantees that by construction -- a lift only ever
				# sits in the middle columns, and the deepest either edge can be cut
				# still leaves those and their neighbours solid. Demanding the whole
				# row forced the profile flat around every lift, which is the
				# STEEPEST possible width transition at the one place a player is
				# standing still looking at it.
				if not seg.is_solid(maxi(0, x - 1), z) \
						or not seg.is_solid(mini(seg.width - 1, x + 1), z):
					narrowed += 1
				# AND NOTHING THAT HURTS YOU IS NEXT TO IT. Riding is seconds of
				# standing still, elevated, with no cover and no verbs -- a
				# skirmisher in range of that is shooting something that cannot
				# leave. Reported from playtest as "the elevator hurts you", and
				# the elevator had nothing to do with it.
				var r: int = HazardDressing.LIFT_CLEARANCE
				for dz in range(-r, r + 1):
					for dx in range(-r, r + 1):
						if not seg.in_bounds(x + dx, z + dz):
							continue
						var what: int = seg.content_at(x + dx, z + dz)
						if what in [GridConfig.Content.SKIRMISHER,
								GridConfig.Content.TURRET, GridConfig.Content.MOUND,
								GridConfig.Content.SHOOTER, GridConfig.Content.SPIKES]:
							armed += 1
		if here > 0:
			with_lift += 1

	print("[gen lifts] %d lifts across %d sections, %d sections have one"
		% [lifts, sections, with_lift])

	check(lifts > 0,
		"the generator emits lifts at all -- they existed for a whole milestone "
		+ "in one test fixture and nowhere a player could reach")
	# A MINORITY, not a fashion. Every ascent being a lift is a section spent
	# standing still, and a ramp is still what this game is mostly made of.
	check(with_lift < sections,
		"and not in every section (%d of %d) -- a ramp is still the default way "
			% [with_lift, sections]
		+ "up, and a lift is the one that costs time instead of floor space")
	eq(bad_rise, 0,
		"every lift climbs at least two units: below that a ramp does it in one "
		+ "row and the wait buys nothing")
	eq(narrowed, 0,
		"and every lift has solid deck on BOTH sides to step off onto -- waiting "
		+ "beside a hole is falling off while standing still")
	eq(armed, 0,
		"and nothing that can hurt you is within %d cells of one: a rider has no "
			% HazardDressing.LIFT_CLEARANCE
		+ "dodge, no dash and no cover, so a hazard in range of a lift is a "
		+ "hazard aimed at somebody who cannot answer it")

# --- Set-pieces stamped into sections (M18 phase 1) ---------------------------
#
# THE MATCH IS THE ASSERTION. Rather than trusting a flag, every row of a
# suspected placement is compared against the piece's own cells: kinds and
# contents identical, heights identical after ONE constant offset. That is what
# "reserve, then stamp" claims — the piece owns those rows outright — and a
# partial overwrite is exactly the failure it exists to prevent.
static func _piece_at(seg, piece, at: int) -> bool:
	if at < 0 or at + piece.length > seg.length:
		return false
	var offset: int = seg.height_at(0, at) - piece.height_at(0, 0)
	for pz in piece.length:
		for x in piece.width:
			if seg.kind_at(x, at + pz) != piece.kind_at(x, pz):
				return false
			if seg.content_at(x, at + pz) != piece.content_at(x, pz):
				return false
			if seg.height_at(x, at + pz) != piece.height_at(x, pz) + offset:
				return false
	return true

# --- Layer 3 keeps out of a piece (M18 phase 2) -------------------------------
#
# DRESSED FIRST, and this is the fault that made the lift-clearance check
# vacuous twice in M17: hazards are placed by BridgeGrid at LOAD, not inside
# section(), so a check run on the raw output is a check run on a map with no
# hazards in it. The A/B below is what proves this one can fail.
#
# MEASURED AS A DIFF, not as a content scan. Every cell is recorded before
# dressing and compared after: any change inside a piece's rows is layer 3
# editing somebody else's composition, whatever it put there.
# --- The maze section kind ----------------------------------------------------
#
# THE CLAIM THAT MATTERS IS THE BRAID, not that a maze appears. A spanning tree
# over n cells has exactly n-1 links and ONE route between any two of them; every
# link past that is a loop. With a fixed top-down camera a single-route maze is
# not a puzzle, it is a queue -- the whole party walks it in single file and the
# section asks nothing. So the loop count is measured, and it is the assertion
# here that can actually go red on a bad tuning.
func _check_mazes() -> void:
	var w: int = GridConfig.DEFAULT_WIDTH
	var sections: int = 0
	var mazes: int = 0
	var invalid: int = 0
	var undressed: int = 0
	var bad_doors: int = 0
	var wall_cells: int = 0
	var rewards: int = 0
	var hatless: int = 0
	var timed: int = 0
	var spikes: int = 0
	var crowded: int = 0
	var cells: int = 0
	var links: int = 0

	for i in 250:
		var seed_i: int = 6400 + i * 71
		var seg = SegmentGen.section(w, seed_i, i)
		if seg == null:
			continue
		sections += 1
		if not seg.tags.has("maze"):
			continue
		mazes += 1

		# THE SAME BAR AS EVERY OTHER SECTION. A carve that isolated a pocket shows
		# up here as marooned deck, and one that sealed the exit as no way through
		# -- both are things a braid can do and neither is visible by eye.
		if SegmentValidator.validate(seg).size() > 0:
			invalid += 1
		if not seg.no_dress:
			undressed += 1

		# ONE DOOR EACH END. The two rows that are wall-with-an-opening.
		for row in [1, seg.length - 3]:
			var doors: int = 0
			for x in seg.width:
				if seg.is_solid(x, row):
					doors += 1
			if doors != 1:
				bad_doors += 1

		# EVERY MAZE PAYS. Hats are the score, and this is the one section with no
		# hazard in it to drop any -- so a maze with no hat is a section that costs
		# the party time and gives nothing back. It is also the claim most likely to
		# rot silently: the rewards go in the dead ends the braid LEFT, and the
		# braid's whole job is removing dead ends.
		var has_hat := false
		for z in seg.length:
			for x in seg.width:
				if seg.content_at(x, z) == GridConfig.Content.HAT:
					has_hat = true
		if not has_hat:
			hatless += 1

		# Corridors on EVEN columns since 2026-08-17, so the outer lanes sit against
		# the bridge's own parapet instead of an explicit wall column.
		var cols: int = (seg.width + 1) / 2
		var rows: int = (seg.length - 4) / 2
		for j in rows:
			for i2 in cols:
				cells += 1
				var at := Vector2i(2 * i2, 2 + 2 * j)
				# REWARDS ARE HATS AND HEARTS. Counting "any content" swept the
				# floor traps in the moment they were added and turned a reward
				# count of 127 into 331 -- a number that still passed its
				# assertion while having stopped measuring what it named.
				var what: int = seg.content_at(at.x, at.y)
				if what == GridConfig.Content.HAT or what == GridConfig.Content.HEART:
					rewards += 1
				elif what == GridConfig.Content.TIMED:
					timed += 1
				elif what == GridConfig.Content.SPIKES:
					spikes += 1
				# Counted EAST and SOUTH only, so each link is counted once.
				if i2 + 1 < cols and seg.is_solid(at.x + 1, at.y):
					links += 1
				if j + 1 < rows and seg.is_solid(at.x, at.y + 1):
					links += 1
		for z in seg.length:
			for x in seg.width:
				if seg.kind_at(x, z) == GridConfig.Kind.WALL:
					wall_cells += 1

		# NO TRAP TOUCHING ANOTHER TRAP. Spikes beside a timed floor is a hazard
		# aimed at somebody standing still waiting for the floor to come back --
		# the complaint that got hazards banned from beside a lift, arriving by a
		# different route.
		for z in seg.length:
			for x in seg.width:
				if not _is_trap(seg, x, z):
					continue
				for step in [Vector2i(1, 0), Vector2i(0, 1)]:
					if _is_trap(seg, x + step.x, z + step.y):
						crowded += 1


	var loops: int = links - (cells - mazes)      # n-1 links per maze is a tree
	print("[gen maze] %d of %d sections, %d cells, %d links, %d loops, %d rewards"
		% [mazes, sections, cells, links, loops, rewards])

	check(mazes > 0,
		"the generator emits maze sections at all (%d of %d)" % [mazes, sections])
	# A MINORITY. The maze is the one section with no hazard in it, so a run that
	# keeps serving them is a run with nothing in it to survive.
	check(mazes < sections / 2,
		"and they are a minority (%d of %d) -- a maze has no hazard in it, and a "
			% [mazes, sections]
		+ "run made of them is a run with no threat")
	eq(invalid, 0, "every generated maze validates: no marooned pocket, no sealed exit")
	eq(undressed, 0,
		"and every one is marked no_dress -- a hazard budget cannot see a corridor, "
		+ "and the flood cannot see a spike, so a maze with every route spiked "
		+ "would validate as crossable")
	eq(bad_doors, 0, "and has exactly one door at each end")
	check(wall_cells > 0, "mazes are made of WALL cells (%d)" % wall_cells)
	check(rewards > 0, "and the dead ends that survive hold something (%d)" % rewards)
	check(timed > 0, "mazes carry timed floors (%d)" % timed)
	check(spikes > 0, "and spikes (%d)" % spikes)
	eq(crowded, 0, "and no trap is placed against another one")
	# NO ASSERTION THAT SPIKES LEAVE A CLEAR ROUTE, and the one that used to be
	# here was wrong about the game. It flooded the maze with every spike treated
	# as a WALL and demanded a way round -- but a spike is on a 2 s clock, out for
	# 34% of it with a ramp either side, so the cell hurts for 0.48 s in 2.0 and is
	# harmless 76% of the time. Even mid-strike it charges one health of five
	# rather than blocking. A spike on the only route is a timing gate, not a
	# sealed maze.
	#
	# It "caught" 4 of 34 mazes, which was the false model reporting itself.
	eq(hatless, 0,
		"and EVERY maze holds at least one hat: it is the only section with no "
		+ "hazard in it, so nothing else in it drops one -- a maze that pays "
		+ "nothing is time the party spent for no reason")

	# THE BRAID ITSELF. Above one loop per ten cells the maze has real forks;
	# a spanning tree scores exactly zero, which is what this is protecting
	# against -- and it is the number to move if a playtest says single file.
	_check_maze_deepest()

	check(float(loops) / float(maxi(1, cells)) > 0.1,
		"and the carve is BRAIDED rather than a tree: %d loops over %d cells. A "
			% [loops, cells]
		+ "tree is one route between any two points, which under a top-down camera "
		+ "is a queue rather than a decision")

# THE HAT FALLBACK, TESTED DIRECTLY BECAUSE THE SWEEP CANNOT REACH IT.
#
# `_maze_attempt` drops a hat at the deepest cell when the braid leaves no dead
# end at all. A/B'd 2026-08-16 by deleting that branch: 250 sections stayed green,
# because at MAZE_BRAID = 6 every maze keeps at least one dead end. So the branch
# is insurance against the dial moving, and insurance nothing exercises is the
# code most likely to be wrong on the day it is needed.
#
# `_maze_deepest` is the only non-trivial part of it, so it gets a lattice with
# one unambiguous answer: a five-cell L carved through a 3x3, with the rest walled
# off. Furthest from (0,0) is (2,2) at four steps -- and the unreachable cells are
# there to catch a walk that goes through walls, which would answer (0,2).
func _check_maze_deepest() -> void:
	var open_cells: Dictionary = {}
	var path: Array = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(2, 1), Vector2i(2, 2)]
	# CARVED THROUGH THE REAL HELPER, not through the lattice formula written out
	# again here. The first version hardcoded it and broke the day corridors moved
	# from odd columns to even -- a test that restates an implementation detail is
	# a second copy of it, and the copy is the one that goes stale. What is under
	# test is the WALK, not the coordinate mapping.
	for n in range(1, path.size()):
		open_cells[SegmentGen._maze_between(path[n - 1], path[n])] = true

	var deep: Vector2i = SegmentGen._maze_deepest(open_cells, 3, 3, Vector2i(0, 0))
	eq(deep, Vector2i(2, 2),
		"the deepest cell is measured by WALKING distance through the carve, not "
		+ "by straight line: (0,2) is one cell from the entrance across a wall and "
		+ "is not reachable at all")

func _check_dressing_keeps_out() -> void:
	var dressed_sections: int = 0
	var with_piece: int = 0
	var intrusions: int = 0
	var dressed_anything: int = 0
	var w: int = GridConfig.DEFAULT_WIDTH

	for i in 250:
		var seed_i: int = 8800 + i * 61
		var seg = SegmentGen.section(w, seed_i, i)
		if seg == null or seg.piece_rows.is_empty():
			continue
		dressed_sections += 1
		with_piece += 1

		var before: Array = []
		for z in seg.length:
			var row: Array = []
			for x in seg.width:
				row.append(seg.content_at(x, z))
			before.append(row)

		HazardDressing.dress(seg, HazardDressing.theme_for(seed_i, i), seed_i, i)

		for z in seg.length:
			for x in seg.width:
				if seg.content_at(x, z) == before[z][x]:
					continue
				dressed_anything += 1
				if seg.piece_rows.has(z):
					intrusions += 1

	print("[gen keep-out] %d sections with a piece, %d cells dressed, %d intrusions"
		% [with_piece, dressed_anything, intrusions])

	check(with_piece > 0, "the sweep found sections carrying a piece")
	# THE CONTROL: if the pass placed nothing at all, "nothing landed in a piece"
	# would be true for the wrong reason -- the same shape as a hazard test run on
	# an undressed map.
	check(dressed_anything > 0,
		"and layer 3 really dressed them (%d cells) -- without this, zero "
			% dressed_anything
		+ "intrusions is a sentence about a pass that did nothing")
	eq(intrusions, 0,
		"nothing layer 3 places lands inside a piece's rows: the EMPTY cells of a "
		+ "composition are the composition, and a turret in one is somebody else "
		+ "editing it")

func _check_pieces() -> void:
	var sections: int = 0
	var with_piece: int = 0
	var stray_content: int = 0
	var too_late: int = 0
	var bad_exit: int = 0
	# AT THE WIDTH THE GAME ACTUALLY RUNS. The rest of this file sweeps a narrower
	# WIDTH to keep the other checks cheap, and a piece is SKIPPED rather than
	# stretched when the widths differ -- so sweeping 13 here asked whether pieces
	# turn up in sections no piece is eligible for, and got the honest answer.
	var w: int = GridConfig.DEFAULT_WIDTH
	var library: Array = SetPieces.for_width(w)
	check(not library.is_empty(),
		"the library has pieces for the run width (%d)" % w)

	for i in 250:
		var seed_i: int = 7700 + i * 53
		var seg = SegmentGen.section(w, seed_i, i)
		if seg == null:
			continue
		# A MAZE IS THE OTHER SECTION KIND, and it places its own content -- a heart
		# and hats in whichever dead ends the braid left. The stray-content claim
		# below reads "a raw section places nothing of its own, so anything here
		# came from a piece", which was true while there was one kind of section.
		# Excluded rather than the claim weakened: that claim is what catches a
		# piece stamped halfway, and it is worth keeping sharp.
		if seg.tags.has("maze"):
			continue
		sections += 1

		var found_at: int = -1
		var found = null
		for piece in library:
			for at in seg.length:
				if _piece_at(seg, piece, at):
					found_at = at
					found = piece
					break
			if found != null:
				break
		if found == null:
			# NO PIECE HERE MEANS NO CONTENT AT ALL. A raw generated section places
			# no content of its own -- hazards arrive later, from the dressing pass
			# at load -- so anything in the cells came from a piece, and a section
			# with content but no MATCH is a piece that was stamped wrong.
			for z in seg.length:
				for x in seg.width:
					var what: int = seg.content_at(x, z)
					# AN ELEVATOR IS THE GENERATOR'S OWN. Lifts are skeleton, placed
					# by the profile loop in M17 phase 9, so they are the one content
					# a raw section carries without a piece. Anything else in the
					# cells arrived from one.
					if what != GridConfig.Content.NONE 							and what != GridConfig.Content.ELEVATOR:
						stray_content += 1
			continue

		with_piece += 1
		# ROOM TO SPARE AT BOTH ENDS. A piece running into the exit row is the
		# ramp-leading-nowhere bug of M17 wearing a composition: the fixup stamps
		# the exit row flat and takes the top of the piece with it.
		if found_at < 1 or found_at + found.length > seg.length - 1:
			too_late += 1
		# AND THE DECLARED EXIT IS WHAT THE SECTION CARRIED ON FROM.
		var after: int = seg.height_at(0, found_at + found.length)
		var before: int = seg.height_at(0, found_at)
		if after - before != int(found.piece_exit):
			bad_exit += 1

	print("[gen pieces] %d of %d sections carry a piece" % [with_piece, sections])

	check(with_piece > 0,
		"the generator stamps pieces (%d of %d) -- they existed for a whole phase "
			% [with_piece, sections]
		+ "as files nothing placed")
	check(with_piece < sections,
		"and not into every section (%d of %d): a section is 16 rows and a piece "
			% [with_piece, sections]
		+ "is 4 to 8 of them, so mostly-generated terrain is the point")
	eq(stray_content, 0,
		"every content cell in a raw section belongs to a matched piece -- a "
		+ "section with content that matches no piece is one that was stamped "
		+ "partially, which is the exact failure reserve-then-stamp prevents")
	eq(too_late, 0,
		"no piece runs into the entry or exit row -- that is the M17 ramp bug "
		+ "wearing a composition, and the fixup would take the top off it")
	eq(bad_exit, 0,
		"and the section carries on from the height the piece DECLARED, so there "
		+ "is no step on the seam behind it")

func _check_deterministic() -> void:
	var a = SegmentGen.section(WIDTH, 4242, 2)
	var b = SegmentGen.section(WIDTH, 4242, 2)
	eq(a.length, b.length, "the same seed and index generate the same length")
	var same := true
	for z in a.length:
		for x in a.width:
			if a.kind_at(x, z) != b.kind_at(x, z) or a.height_at(x, z) != b.height_at(x, z):
				same = false
	check(same,
		"and the identical terrain -- the guarantee a joining client rides when it "
		+ "is told two numbers instead of a world")

func _is_trap(seg, x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= seg.width or z >= seg.length:
		return false
	var what: int = seg.content_at(x, z)
	return what == GridConfig.Content.TIMED or what == GridConfig.Content.SPIKES
