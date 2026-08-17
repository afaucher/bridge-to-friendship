extends "res://scripts/test_support/test_case.gd"

# M19 PHASE 1: where the counters SIT.
#
# test_round_stats covers the arithmetic as a table. This covers the one thing a
# table cannot: that each `_bump` is at the right line. Every claim here is about
# a place rather than a value, so every one of them has to be played.
#
# THE HEADLINE CLAIM IS SHOTS VERSUS HITS. CLAUDE.md's rule is that "attempted" is
# not "delivered", and it was learned from a send function that returned a
# sequence number whether or not anyone was listening -- producing a "12/12
# landed" counter that was measuring sends. A hit counter at the muzzle is exactly
# that bug: it would read 100% accuracy for somebody firing into a wall.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const StatRegistry = preload("res://scripts/sim/stat_registry.gd")
const Hit = preload("res://scripts/sim/hit.gd")

const SHOOTER := 1
const VICTIM := 2

var world: Node3D = null
var shooter: CharacterBody3D = null
var victim: CharacterBody3D = null
var frames: int = 0
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "StatWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(SHOOTER, 0)
	world._spawn_player(VICTIM, 1)
	shooter = world.player_body(SHOOTER)
	victim = world.player_body(VICTIM)

func _stat(peer: int, key: String) -> int:
	return int(world.stats_of(peer).get(key, 0))

func _physics_process(_delta: float) -> void:
	if done or shooter == null:
		return
	frames += 1
	if frames < 3:
		return
	done = true

	_test_a_hit_that_lands()
	_test_a_shot_that_misses()
	_test_friendly_versus_enemy()
	_test_a_blocked_hit_delivers_nothing()
	_test_scenery_is_not_a_hit()
	_test_your_own_grenade()
	_test_distance_ignores_teleports()
	_test_a_peak_is_not_a_total()
	_test_a_boost()
	_test_the_reset()
	finish()

# --- Delivered damage, and who it is attributed to -----------------------------

func _test_a_hit_that_lands() -> void:
	world.clear_round_stats()
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	world._deliver(victim, Hit.make(Hit.Kind.BULLET, 2,
		victim.global_position + Vector3(6.0, 0.0, 0.0), 0.0, 0.0, SHOOTER))

	eq(_stat(SHOOTER, "hits"), 1, "a hit that lands is counted, on the shooter")
	eq(_stat(SHOOTER, "friendly_damage"), 2,
		"and the damage with it -- health actually removed, which is what makes "
		+ "this a measurement rather than a restatement of the hit's `amount`")
	eq(_stat(VICTIM, "hits"), 0, "the person who was shot did not fire anything")

# --- Attempted is not delivered ------------------------------------------------

func _test_a_shot_that_misses() -> void:
	world.clear_round_stats()
	# A ROUND THAT REACHES NOBODY. _spawn_round is the one line every round in the
	# game comes through, so firing into empty air is exactly a shot with no hit --
	# no target, therefore no _deliver, therefore no `hits`.
	world._spawn_round(shooter.global_position + Vector3(0.0, 1.0, -3.0),
		Vector3(0.0, 0.0, -1.0), SHOOTER, shooter.get_rid())

	eq(_stat(SHOOTER, "shots_fired"), 1, "firing counts a shot")
	eq(_stat(SHOOTER, "hits"), 0,
		"and a round that reached nobody counts NO hit. This is the whole reason "
		+ "the two counters live at different lines: a hit counted at the muzzle "
		+ "would read 100%% accuracy for somebody shooting into a wall")
	eq(StatRegistry.percent_text(_stat(SHOOTER, "hits"), _stat(SHOOTER, "shots_fired")),
		"0%", "so the accuracy is honestly zero rather than unmeasured")

# --- The target decides whether it was a mistake -------------------------------

func _test_friendly_versus_enemy() -> void:
	world.clear_round_stats()
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	world._deliver(victim, Hit.make(Hit.Kind.BULLET, 1,
		victim.global_position + Vector3(6.0, 0.0, 0.0), 0.0, 0.0, SHOOTER))
	eq(_stat(SHOOTER, "friendly_damage"), 1,
		"shooting a teammate is FRIENDLY damage -- decided by what caught it, not "
		+ "by who fired")
	eq(_stat(SHOOTER, "enemy_damage"), 0, "and is not counted as enemy damage")

# --- A shield that blocks delivers nothing -------------------------------------

func _test_a_blocked_hit_delivers_nothing() -> void:
	world.clear_round_stats()
	var before: int = victim.health
	victim.invulnerable = 999.0     # the simplest total refusal the body has
	world._deliver(victim, Hit.make(Hit.Kind.BULLET, 3,
		victim.global_position + Vector3(6.0, 0.0, 0.0), 0.0, 0.0, SHOOTER))
	victim.invulnerable = 0.0

	eq(victim.health, before, "the rig really did stop the damage")
	eq(_stat(SHOOTER, "friendly_damage"), 0,
		"a hit that removed no health records no damage -- `hit.amount` would have "
		+ "recorded three, which is the number the shooter ASKED for")

# --- A hit is something that bleeds ---------------------------------------------
#
# Deck and parapet were always excluded for free: no `receive_hit`, so the round
# never reaches the counter. What was NOT excluded is everything else in the world
# that does answer -- a stone, a ball, a loose hat, a dropped special. Shooting a
# stone is a legitimate thing to do and it is not marksmanship, and counting it
# made accuracy a number you could inflate by firing at the furniture.
#
# A LOOSE HAT IS THE CASE, and it has to be hit with a BLAST. HatBody refuses a
# BULLET outright -- the first version of this test shot one and asserted about a
# hit that never happened, which is a control that cannot succeed and would have
# "proved" the rule while measuring nothing. `took` below is what says the
# difference.
func _test_scenery_is_not_a_hit() -> void:
	world.clear_round_stats()
	var hat: Node = world._hats.spawn_loose(
		shooter.global_position + Vector3(3.0, 1.0, 0.0))
	if not check(hat != null, "the rig produced a loose hat to shoot at"):
		return
	var took: bool = world._deliver(hat, Hit.make(Hit.Kind.EXPLOSIVE, 2,
		hat.global_position + Vector3(4.0, 0.0, 0.0), 4.0, 2.0, SHOOTER))

	check(took, "and the hat really answered the hit, so this is not a no-op")
	eq(_stat(SHOOTER, "hits"), 0,
		"but shooting scenery is NOT a hit -- accuracy is a claim about hitting "
		+ "people, and a counter that takes furniture is one you inflate by firing "
		+ "at the deck furniture instead of at anything dangerous")
	eq(_stat(SHOOTER, "enemy_damage"), 0,
		"and damage to it is not damage to the opposition")
	eq(_stat(SHOOTER, "enemy_kills"), 0,
		"and destroying it is not a KILL, which is the loudest version of the same "
		+ "fault: 'friendly if a player, enemy otherwise' has three answers, and "
		+ "the third is 'that was scenery'")

# --- Your own grenade is not friendly fire --------------------------------------
#
# Both are "a player hurt a player" and they are completely different stories: one
# is a mistake that cost somebody else, the other is a mistake that only cost you.
# The split matters most for the badge, because "most friendly fire" is the funniest
# thing on the board and it should not be won by somebody who only ever blew
# themselves up.
func _test_your_own_grenade() -> void:
	world.clear_round_stats()
	shooter.health = SimConfig.MAX_HEALTH
	shooter.invulnerable = 0.0
	world._deliver(shooter, Hit.make(Hit.Kind.EXPLOSIVE, 2,
		shooter.global_position + Vector3(1.0, 0.0, 0.0), 0.0, 0.0, SHOOTER))

	eq(_stat(SHOOTER, "self_damage"), 2, "hurting yourself is SELF damage")
	eq(_stat(SHOOTER, "friendly_damage"), 0,
		"and is not friendly fire, which is a claim about hurting somebody ELSE")

# --- Distance is travelled, not teleported --------------------------------------
#
# THE GUARD IS THE WHOLE FEATURE. Without it the number measures the opposite of
# what it says: a wipe returns the party hundreds of metres backwards in one
# frame, and the leash MOVES a straggler outright -- so a player who died twice
# would out-"walk" one who played the whole round, and the badge would go to
# whoever failed most.
#
# Asserted against the constant rather than against a distance, because what is
# under test is the RULE: one tick's step is either plausible movement or it is a
# teleport, and the threshold is the only thing that decides.
func _test_distance_ignores_teleports() -> void:
	var cap: float = float(GameWorldScript.TELEPORT_TICK_DISTANCE)
	check(cap > SimConfig.SHOVE_SPEED * SimConfig.TICK_DELTA,
		"the teleport threshold (%.2f m) is above the furthest a body can move in "
			% cap
		+ "one tick under its own power -- a dash is %.2f m, and a bound below "
			% (SimConfig.SHOVE_SPEED * SimConfig.TICK_DELTA)
		+ "that would silently stop counting the fastest thing in the game")
	# AND FAR BELOW ANY REAL TELEPORT. A lobby return is the shortest one in the
	# game and it crosses a whole round of bridge.
	check(cap < 10.0,
		"and far under any teleport in the game (%.2f m) -- the nearest is a lobby "
			% cap
		+ "return, and no round is ten metres long")

# --- A peak is not a total ------------------------------------------------------
#
# The tallest tower is sampled every tick, so the failure mode if it were written
# with the ordinary `_bump` is not "slightly wrong" -- it would ADD the stack size
# sixty times a second and a player standing still with two hats would score
# thousands. Fed a falling sequence on purpose: the answer has to be the high
# water mark rather than the last thing seen.
func _test_a_peak_is_not_a_total() -> void:
	world.clear_round_stats()
	for value in [1, 4, 2, 3, 2]:
		world._bump_max(SHOOTER, "hats_worn", value)
	eq(_stat(SHOOTER, "hats_worn"), 4,
		"the tallest tower is the HIGHEST the stack ever got (4), not the last "
		+ "reading (2) and not the sum (12) -- which is what a per-tick sample "
		+ "through the ordinary counter would have produced")

# --- The verb the game is named after -------------------------------------------

func _test_a_boost() -> void:
	world.clear_round_stats()
	world.resolve_shove_contact(shooter, victim, 0.0)
	eq(_stat(SHOOTER, "boosts"), 1, "shoving a teammate is a boost, on the shover")
	eq(_stat(VICTIM, "boosts"), 0, "and not on the person who was launched")

	# NOT EVERY SHOVE IS A BOOST. Dashing into a stone rearranges the bridge and is
	# a different verb; only a body that can BE launched counts, which is what
	# `receive_shove` being on PlayerBody and nothing else already says.
	world.clear_round_stats()
	world.resolve_shove_contact(shooter, shooter, 0.0)
	eq(_stat(SHOOTER, "boosts"), 0, "and you cannot boost yourself")

# --- One round, one scoreboard --------------------------------------------------

func _test_the_reset() -> void:
	world._bump(SHOOTER, "dashes", 5)
	check(_stat(SHOOTER, "dashes") > 0, "something is counted")
	world.clear_round_stats()
	eq(_stat(SHOOTER, "dashes"), 0,
		"and a new round starts from nothing -- a reset at the wrong moment gives "
		+ "a scoreboard covering two rounds, which nobody would catch by looking")
