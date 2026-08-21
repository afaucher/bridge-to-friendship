extends "res://scripts/test_support/test_case.gd"

# WHERE THE MERCHANT STANDS. See design_ideas/merchant.md, "Where he stands".
#
# The claims:
#   1. He appears at all, in a MINORITY of sections. Rare enough to be an event,
#      common enough that a session sees one or two.
#   2. NOTHING DANGEROUS WITHIN MERCHANT_CLEARANCE OF HIM. This is the rule the
#      whole file is for, and it is the one rule in the dressing pass that runs
#      backwards: every other kind asks where it wants to be, and the hazards have
#      to ask about him.
#   3. He is never beside a lift -- the same exclusion the hazards get, for the
#      opposite reason. A rider carried past him is a hat spent by the terrain.
#   4. He never stands on a ramp, on a hole, or on top of authored content.
#   5. Never more than one to a section: two shopkeepers in sixty metres is a
#      shop, and the item is sold on being rare.
#
# WHY CLAIM 2 MATTERS MORE THAN IT LOOKS: A DASH IS ALSO HOW YOU FIGHT. A merchant
# three cells from a rusher means a player dashing AT the rusher clips the
# shopkeeper and spends a hat on a trade they never made -- and the report will say
# THE RUSHER TOOK MY HAT, because that is the only attribution available from
# inside the game. The 2026-08-16 spike block two cells from a lift is the same
# shape and was reported for three rounds as "the elevator hurts you".
#
# DRESSED BEFORE INSPECTING, and this is the trap this file exists downstream of.
# Hazards are placed by BridgeGrid at LOAD, not by SegmentGen.section() -- so a
# sweep run on the raw generator output is a sweep over a map with no hazards in
# it, and the clearance assertion passes with its own rule deleted at 40 seeds and
# again at 250. A test run on the wrong object cannot fail however many samples it
# takes. This one has been A/B'd with the rule removed; it goes red.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")
const SegmentValidator = preload("res://scripts/grid/segment_validator.gd")

const WIDTH := 15
const SECTIONS := 400

# What "dangerous" means here, spelled out rather than read from
# HazardDressing.DANGEROUS_KINDS, so that a kind quietly dropped from that list
# does not quietly drop out of this assertion too.
const DANGEROUS := [
	GridConfig.Content.SKIRMISHER, GridConfig.Content.TURRET,
	GridConfig.Content.MOUND, GridConfig.Content.SHOOTER,
	GridConfig.Content.SPIKES, GridConfig.Content.CRUMBLE,
	GridConfig.Content.TIMED,
]

func setup(_main) -> void:
	timeout_seconds = 120.0

	var sections := 0
	var with_merchant := 0
	var merchants := 0
	var crowded := 0
	var by_a_lift := 0
	var on_a_ramp := 0
	var on_a_hole := 0
	var doubled := 0
	var closest: int = 1 << 30
	var worst := ""

	for i in SECTIONS:
		var seed_i: int = 4400 + i * 53
		var seg = SegmentGen.section(WIDTH, seed_i, i)
		if seg == null:
			continue
		# THE OBJECT THE PLAYER MEETS. See the header: undressed, this sweep is a
		# sweep over a map with no hazards in it.
		HazardDressing.dress(seg, HazardDressing.theme_for(seed_i, i), seed_i, i)
		sections += 1

		var here := 0
		for z in seg.length:
			for x in seg.width:
				if seg.content_at(x, z) != GridConfig.Content.MERCHANT:
					continue
				here += 1
				merchants += 1

				if not seg.is_solid(x, z):
					on_a_hole += 1
				if seg.kind_at(x, z) == GridConfig.Kind.RAMP:
					on_a_ramp += 1

				# THE CLEARANCE, measured as a ring around HIM rather than as a
				# property of each hazard: the claim is about what a player standing
				# at his feet can reach with a dash, and that is a distance.
				var r: int = SimConfig.MERCHANT_CLEARANCE
				for dz in range(-r, r + 1):
					for dx in range(-r, r + 1):
						if not seg.in_bounds(x + dx, z + dz):
							continue
						var what: int = seg.content_at(x + dx, z + dz)
						if what == GridConfig.Content.ELEVATOR:
							by_a_lift += 1
						if what in DANGEROUS:
							crowded += 1
							var d: int = maxi(absi(dx), absi(dz))
							if d < closest:
								closest = d
								worst = "%s at (%d,%d), %d cells from the merchant at (%d,%d) in section %d" % [
									_name_of(what), x + dx, z + dz, d, x, z, i]
		if here > 0:
			with_merchant += 1
		if here > 1:
			doubled += 1

	print("[merchant] %d merchants across %d sections, %d sections have one (1 in %.1f)"
		% [merchants, sections, with_merchant,
			float(sections) / maxf(1.0, float(with_merchant))])

	# --- 1. He exists, and he is rare ---------------------------------------
	#
	# THE CONTROL, AND IT HAS TO BE ABLE TO SUCCEED. Every "nothing dangerous near
	# a merchant" count below is trivially zero in a run with no merchants in it,
	# so this assertion is what makes the rest of the file evidence.
	check(merchants > 0,
		"the dressing pass places merchants at all -- without this every clearance "
		+ "count below is zero for the most boring possible reason")
	check(with_merchant < sections / 2,
		"and in a MINORITY of sections (%d of %d): he is sold on being an event, "
			% [with_merchant, sections]
		+ "and a shopkeeper in every section is a vending machine")
	# The rarity is 1-in-N through a mixer rather than a float roll, so it is not
	# exactly N -- asserted as a band, because a mixer that came out exactly right
	# would be the surprising result.
	var rate: float = float(sections) / maxf(1.0, float(with_merchant))
	check(rate > float(SimConfig.MERCHANT_RARITY) * 0.5
			and rate < float(SimConfig.MERCHANT_RARITY) * 2.0,
		"at roughly MERCHANT_RARITY (1 in %.1f against a target of 1 in %d)"
			% [rate, SimConfig.MERCHANT_RARITY])
	eq(doubled, 0,
		"and never two in one section -- sixty metres with two shopkeepers in it "
		+ "is a shop, and the trade is meant to be a thing you go and find")

	# --- 2. The rule this file is for ---------------------------------------
	eq(crowded, 0,
		("NOTHING DANGEROUS within %d cells of a merchant. A dash is also how you "
			+ "fight, so a hazard inside his reach is a hat spent on a trade the "
			+ "player never made -- and they would report it as the hazard taking "
			+ "their hat, which is the only attribution available from inside the "
			+ "game. Worst: %s")
			% [SimConfig.MERCHANT_CLEARANCE, worst if worst != "" else "none"])

	# --- 3 + 4. The rest ----------------------------------------------------
	eq(by_a_lift, 0,
		"and no merchant within %d cells of a lift: a rider carried past him is a "
			% SimConfig.MERCHANT_CLEARANCE
		+ "hat spent by the terrain, which is a trade with no decision in it")
	eq(on_a_ramp, 0,
		"and none on a ramp -- you buy from him by dashing into him, and a dash up "
		+ "a slope is not the same move as a dash along the deck")
	eq(on_a_hole, 0, "and none standing on a hole")

	_check_the_validator_agrees()
	finish()

# THE LINT AND THE PLACEMENT RULE ARE TWO DIFFERENT CLAIMS, and the sweep above
# only shows that the generator never happens to break one of them. An AUTHORED
# segment can still put a shopkeeper on a hillside by hand, which is what the
# validator is for -- so it is asserted directly, on a segment built to be wrong.
func _check_the_validator_agrees() -> void:
	# A SEED THAT HAPPENS TO HOLD A RAMP, SEARCHED FOR RATHER THAN ASSUMED.
	#
	# This named one seed and required it to contain a ramp, which made a test
	# about the VALIDATOR fail whenever the GENERATOR changed what that seed
	# produces -- and it did, the day patches got their own roll. The claim has
	# nothing to do with seed 991; it needs any section with a ramp in it.
	for attempt in 40:
		var seg = SegmentGen.section(WIDTH, 991 + attempt * 733, 3)
		if seg == null:
			continue
		for z in seg.length:
			for x in seg.width:
				if seg.kind_at(x, z) != GridConfig.Kind.RAMP:
					continue
				seg.contents[z][x] = GridConfig.Content.MERCHANT
				var problems: Array = SegmentValidator.validate(seg)
				var named := false
				for p in problems:
					if String(p).contains("merchant") and String(p).contains("ramp"):
						named = true
				check(named,
					"the validator refuses a merchant authored onto a ramp, and "
					+ "says so by name -- it reported: %s" % str(problems))
				return
	# No ramp in forty sections is not a failure of the merchant; say so rather
	# than passing silently on a sample that could not have shown anything.
	fail("no ramp cell found in 40 sections to test the lint against -- the assertion above never ran")

func _name_of(content: int) -> String:
	for glyph in GridConfig.CONTENT_GLYPHS:
		if int(GridConfig.CONTENT_GLYPHS[glyph]) == content:
			return "`%s`" % glyph
	return str(content)
