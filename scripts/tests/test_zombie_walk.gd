extends "res://scripts/test_support/test_case.gd"

# THREES AND ONES: the walk itself, measured directly off the machine that makes
# it. The pack, the bite and the grave are test_zombie.gd's business.
#
# WHY THIS IS A SEPARATE FILE AND NOT A PHASE. Every claim here is about a pure
# decision -- given a target over there, what heading and what distance -- and the
# honest way to measure a decision is to ask for a few hundred of them and look at
# the distribution. That does not fit inside a frame-driven phase machine, and
# CLAUDE.md's note about a max answering "did it ever" rather than "does it
# usually" is exactly this distinction: one sampled move would tell you a branch
# exists, which is not the claim.
#
# The claims, in the order they matter:
#
#   1. There are exactly two moves, and they are a ONE and a THREE -- the budgets
#      are ZOMBIE_STEP and three of it.
#   2. The angles are 60 degrees off the line to you for a shuffle and 20 for a
#      lunge, and BOTH SIDES occur.
#   3. Even odds between them, over enough draws to mean something.
#   4. It COMMITS: the heading is frozen when the move begins and does not follow
#      a target that moves.
#   5. Despite all of that, it closes on you. A zigzag that made no progress
#      would satisfy every assertion above.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const ZombieBody = preload("res://scripts/sim/zombie_body.gd")
const ZombieScene = preload("res://scenes/zombie.tscn")

const SAMPLES := 600

var _rig: Node3D = null

func setup(main) -> void:
	# A ROOM OF ITS OWN, a kilometre from anything else. Two worlds in one process
	# share a single physics space (CLAUDE.md), and the gate runs tests as parallel
	# PROCESSES but a single test can still have several things in its tree.
	_rig = Node3D.new()
	_rig.name = "ZombieWalkRig"
	_rig.position = Vector3(3000.0, 0.0, 0.0)
	main.add_child(_rig)

	_test_two_moves_a_one_and_a_three()
	_test_the_angles_and_both_sides()
	_test_even_odds()
	_test_it_commits_to_a_heading()
	_test_it_still_closes_on_you()
	finish()

# A zombie standing at the origin of the rig, out of the tree's way and doing
# nothing until it is asked a question.
func _subject(id: int) -> Node3D:
	var zombie: Node3D = ZombieScene.instantiate()
	zombie.zombie_id = id
	zombie.name = "Walker_%d" % id
	_rig.add_child(zombie)
	zombie.position = Vector3.ZERO
	return zombie

# --- 1. Two moves, a one and a three ------------------------------------------

func _test_two_moves_a_one_and_a_three() -> void:
	var zombie: Node3D = _subject(1)
	var target := Vector3(0.0, 0.0, -10.0)
	var shuffle_budget := -1.0
	var lunge_budget := -1.0
	for i in SAMPLES:
		zombie._begin_move(target)
		if zombie.move_kind == ZombieBody.Move.SHUFFLE:
			shuffle_budget = zombie._budget
		else:
			lunge_budget = zombie._budget
	check(shuffle_budget > 0.0 and lunge_budget > 0.0,
		"both moves occur at all (%.2f / %.2f)" % [shuffle_budget, lunge_budget])
	near(shuffle_budget, SimConfig.ZOMBIE_STEP, 0.001, "a ONE is one step")
	near(lunge_budget, SimConfig.ZOMBIE_STEP * 3.0, 0.001, "a THREE is three of them")
	# THE RATIO IS THE DESIGN, and asserting it separately is not redundant with
	# the two lines above: those pin the numbers to the constants, and this pins
	# the constants to each other. If somebody retunes ZOMBIE_STEP both of them
	# still pass and the enemy is unchanged; if somebody makes a lunge two steps,
	# this is the line that says the shape moved.
	near(lunge_budget / shuffle_budget, 3.0, 0.001, "and a three is three ones")
	zombie.queue_free()

# --- 2. The angles, and both sides --------------------------------------------

func _test_the_angles_and_both_sides() -> void:
	var zombie: Node3D = _subject(2)
	# DELIBERATELY NOT DOWN AN AXIS. A target at (0,0,-10) makes every heading come
	# out of the maths symmetrically about a cardinal direction, which is the one
	# arrangement where a sign error in the rotation is invisible.
	var target := Vector3(6.0, 0.0, -8.0)
	var toward: Vector3 = (target - Vector3.ZERO).normalized()

	var seen := {"shuffle_left": 0, "shuffle_right": 0, "lunge_left": 0, "lunge_right": 0}
	var worst_shuffle := 0.0
	var worst_lunge := 0.0

	for i in SAMPLES:
		zombie._begin_move(target)
		var heading: Vector3 = zombie._heading
		var degrees: float = rad_to_deg(toward.angle_to(heading))
		# WHICH SIDE, from the sign of the cross product about UP. An angle_to is a
		# magnitude and has no opinion about direction -- CLAUDE.md records three
		# shipped sign errors that a distance assertion could not see, and this is
		# the same shape one layer up.
		var side: String = "left" if toward.cross(heading).y > 0.0 else "right"
		if zombie.move_kind == ZombieBody.Move.SHUFFLE:
			worst_shuffle = maxf(worst_shuffle, absf(degrees - SimConfig.ZOMBIE_SHUFFLE_DEG))
			seen["shuffle_" + side] += 1
		else:
			worst_lunge = maxf(worst_lunge, absf(degrees - SimConfig.ZOMBIE_LUNGE_DEG))
			seen["lunge_" + side] += 1

	# WORST CASE ACROSS EVERY SAMPLE, not the last one. A single reading would pass
	# against a machine that got it right once.
	check(worst_shuffle < 0.01,
		"every shuffle is %.0f degrees off the line to you (worst error %.4f)"
			% [SimConfig.ZOMBIE_SHUFFLE_DEG, worst_shuffle])
	check(worst_lunge < 0.01,
		"every lunge is %.0f degrees off it (worst error %.4f)"
			% [SimConfig.ZOMBIE_LUNGE_DEG, worst_lunge])

	# AND BOTH SIDES, FOR BOTH MOVES. Four counters rather than two, because "the
	# side is a fresh coin" is a claim about each move independently -- a machine
	# that leaned every lunge left and every shuffle right would satisfy a
	# left-and-right check that did not separate them.
	for key in seen.keys():
		check(int(seen[key]) > 0, "%s happens (%d of %d)" % [key, seen[key], SAMPLES])

	# BOTH ANGLES ARE INSIDE A RIGHT ANGLE, which is what makes every move close the
	# distance rather than merely rearrange it. Stated here because it is the
	# property the whole "it arrives, just not predictably" design rests on, and
	# nothing else in the file would notice a 120-degree shuffle.
	check(SimConfig.ZOMBIE_SHUFFLE_DEG < 90.0 and SimConfig.ZOMBIE_LUNGE_DEG < 90.0,
		"both angles are inside a right angle, so every move is progress")
	zombie.queue_free()

# --- 3. Even odds -------------------------------------------------------------

func _test_even_odds() -> void:
	# SEVERAL DISTINCT ZOMBIES, not one asked six hundred times. Each draws off its
	# own id-salted stream, and a pack rising in one tick is exactly the case where
	# those streams could turn out to be the same stream with an offset -- which
	# would show up as five bodies performing one choreography, and would be
	# invisible to a single-subject test.
	var lunges := 0
	var total := 0
	var per_zombie: Array = []
	for id in range(1, 7):
		var zombie: Node3D = _subject(100 + id)
		var mine := 0
		for i in 200:
			zombie._begin_move(Vector3(0.0, 0.0, -10.0))
			if zombie.move_kind == ZombieBody.Move.LUNGE:
				mine += 1
				lunges += 1
			total += 1
		per_zombie.append(mine)
		zombie.queue_free()

	var share: float = float(lunges) / float(total)
	# A GENEROUS BAND. The claim is "even odds", not "a perfect hash": a binomial at
	# n=1200 has a standard deviation of about 1.4 percentage points, so 0.42-0.58
	# is roughly eleven sigma and this cannot flake. It would still catch a
	# constant, an off-by-one that made one branch unreachable, or a comparison
	# written the wrong way round.
	check(share > 0.42 and share < 0.58,
		"threes and ones come up about evenly -- %.3f lunges over %d moves"
			% [share, total])

	# AND NO TWO OF THEM WALKED THE SAME WALK. The sum being even says nothing about
	# whether the six streams were independent; six identical counts would be the
	# tell that they are one stream.
	var identical := 0
	for i in per_zombie.size():
		for j in range(i + 1, per_zombie.size()):
			if int(per_zombie[i]) == int(per_zombie[j]):
				identical += 1
	check(identical <= 2,
		"and six zombies drew six different sequences -- counts %s" % [per_zombie])

# --- 4. It commits ------------------------------------------------------------
#
# THE LOAD-BEARING CLAIM OF THE WHOLE ENEMY. A heading that quietly re-aimed each
# tick would be a rusher with a wobble: it could not be baited, a lunge could never
# be made to end past an edge, and the free answer a weaponless player has against
# a pack would not exist.
#
# It is also the claim most likely to be broken by a well-meaning edit, because
# "follow the target" is what every other pursuer in this codebase does.

func _test_it_commits_to_a_heading() -> void:
	var zombie: Node3D = _subject(3)
	zombie.state = ZombieBody.State.WALK
	zombie._begin_move(Vector3(0.0, 0.0, -10.0))
	var committed: Vector3 = zombie._heading
	var kind: int = zombie.move_kind

	# The target walks a long way round -- to the OPPOSITE side -- and the zombie is
	# stepped repeatedly while it does. If anything re-aimed, this would move it.
	#
	# TWENTY TICKS, AND THE NUMBER MATTERS. The shorter move is a shuffle, which
	# covers its 1.4 m in about 38 ticks at 2.2 m/s; running past that would see the
	# move legitimately END and a fresh heading picked, which is the design working
	# and would read as this assertion failing. Comfortably inside the shorter of
	# the two is the only safe window.
	for i in 20:
		zombie.step(Vector3(0.0, 0.0, 10.0), true)

	check(zombie._heading.is_equal_approx(committed),
		"a move in progress keeps the heading it started with -- %s against %s"
			% [zombie._heading, committed])
	eq(zombie.move_kind, kind, "and does not change its mind about which move it is")

	# AND IT DOES EVENTUALLY LET GO. Without this the assertion above passes just as
	# well against a zombie frozen on its first heading forever, which is the
	# opposite failure and is not obviously worse.
	zombie._travelled = zombie._budget + 1.0
	zombie.state = ZombieBody.State.WALK
	zombie.step(Vector3(0.0, 0.0, 10.0), true)
	check(not zombie._heading.is_equal_approx(committed),
		"and picks a new one once the ground is covered")
	zombie.queue_free()

# --- 5. It still closes on you ------------------------------------------------
#
# Everything above is satisfied by a machine that shuffles in a circle. This is the
# assertion that says the zigzag ARRIVES -- and it is deliberately computed from
# the headings rather than by walking a body, because a body walking is a physics
# question and this is an arithmetic one.

func _test_it_still_closes_on_you() -> void:
	var zombie: Node3D = _subject(4)
	var target := Vector3(0.0, 0.0, -40.0)
	var at := Vector3.ZERO
	var start: float = at.distance_to(target)

	for i in 40:
		zombie.position = at
		zombie._begin_move(target)
		at += zombie._heading * zombie._budget

	var closed: float = start - at.distance_to(target)
	# WELL OVER HALF THE GROUND, which is the honest floor for the worst mix. A
	# shuffle at 60 degrees banks cos(60) = 0.50 of its step and a lunge at 20
	# banks cos(20) = 0.94 of three; at even odds the expected haul is about 0.80
	# of the distance walked. All-shuffles would still be 0.50.
	check(closed > start * 0.5,
		"the zigzag still arrives -- %.1f m closed of %.1f m in forty moves"
			% [closed, start])
	# AND IT IS A ZIGZAG, NOT A LINE DRESSED UP AS ONE. Without this the assertion
	# above is satisfied by a machine that ignores both angles and walks straight at
	# you -- which is a rusher, and is the single most likely way for this enemy to
	# be quietly broken by an edit. A perfect line would bank 100% of the ground
	# walked; even odds banks about 80%.
	var walked: float = 0.0
	for i in 40:
		walked += SimConfig.ZOMBIE_STEP     # a floor: every move is at least a one
	check(closed < start * 0.95,
		"but not in a straight line -- %.1f m closed of %.1f m to cover, over at "
			% [closed, start] + "least %.1f m of walking" % walked)
	zombie.queue_free()
