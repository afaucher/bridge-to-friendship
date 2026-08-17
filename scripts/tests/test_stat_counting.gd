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

# --- One round, one scoreboard --------------------------------------------------

func _test_the_reset() -> void:
	world._bump(SHOOTER, "dashes", 5)
	check(_stat(SHOOTER, "dashes") > 0, "something is counted")
	world.clear_round_stats()
	eq(_stat(SHOOTER, "dashes"), 0,
		"and a new round starts from nothing -- a reset at the wrong moment gives "
		+ "a scoreboard covering two rounds, which nobody would catch by looking")
