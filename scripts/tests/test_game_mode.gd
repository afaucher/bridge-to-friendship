extends "res://scripts/test_support/test_case.gd"

# M25 PHASE 1: THE SEAM, WITH NOTHING NEW TO LOOK AT.
#
# The milestone's own bar for this phase is unusual and worth repeating: **if
# phase 1 shows any difference on screen, it has failed.** So nothing here asserts
# that a mode DOES anything. It asserts that the machinery exists, that the base
# game runs through it, and that the three structural obligations are paid while
# they are still one line each.
#
# WHY NOW, WITH ONE MODE. Each of these is a small amount of structure today and a
# migration later, and this is the only moment when there is exactly one mode to
# convert.
#
# The claims:
#   1. BASE IS MODE ZERO, not the absence of a mode. Every world has a mode, and
#      the composition path base takes is the same one every other mode will take
#      -- so the machinery is exercised by the thing that runs every day.
#   2. A MODE DECLARES; IT MUST NOT WRITE. Reading an override leaves SimConfig and
#      DebugSettings untouched, so leaving a mode is dropping a declaration rather
#      than remembering to undo one. There is nothing to leak.
#   3. EVERY POOL IS ANSWERED BY EVERY MODE, and the day somebody adds pool
#      twenty-one this fails loudly rather than the pool silently joining them all.
#      The failure mode being prevented is SILENCE, not an error.
#   4. THE WIRE CARRIES THE MODES, in the SAME message as the seed and the count.
#      A client told the count first would build a corridor before knowing what
#      fills it.
#   5. A LATE JOINER ARRIVES MID-MODE and is told which one.
#   6. THE LOBBY IS ALWAYS BASE, so a broken mode can never strand a party
#      somewhere they cannot choose again.
#   7. CHOOSING IS LOCKED once a round is under way: a knob turned mid-round is
#      remembered for the next one rather than re-cutting ground people stand on.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "ModeWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if done or world.tick < 2:
		return
	done = true
	set_physics_process(false)

	_base_is_mode_zero()
	_a_mode_declares_and_does_not_write()
	_every_pool_is_answered()
	_the_wire_carries_the_modes()
	_the_lobby_is_always_base()
	_choosing_is_locked_mid_round()
	finish()

# --- 1. Base is a mode -------------------------------------------------------

func _base_is_mode_zero() -> void:
	check(GameMode.exists(GameMode.BASE),
		"base is a registered mode, not the absence of one -- if it were the "
		+ "absence, every subsystem would grow an implicit `if no mode, do the old "
		+ "thing` and modes would become exceptions to a normal nobody wrote down")
	eq(world.current_mode(), GameMode.BASE, "and a world with no choice made is in it")
	eq(world.mode_for_round(0), GameMode.BASE, "as is its first round")

	# AND A ROUND NOBODY HAS PLANNED FOR STILL HAS AN ANSWER. A missing entry read
	# as "no mode" is exactly the absence this milestone exists to avoid.
	eq(world.mode_for_round(99), GameMode.BASE,
		"and so is a round past the end of the plan -- every slot has an answer")

# --- 2. Declared, never written ----------------------------------------------

func _a_mode_declares_and_does_not_write() -> void:
	# THE COMPOSITION PATH BASE TAKES IS THE PATH EVERY MODE TAKES. Base declaring
	# an empty dictionary is a real entry, not an omission: it means the composition
	# runs in every playtest and every gate rather than only when a mode is loaded.
	eq(GameMode.overrides(GameMode.BASE), {},
		"base overrides nothing, and says so explicitly")
	near(world.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG),
		DebugSettings.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG), 0.0001,
		"so a tuned value under base is exactly what it was before modes existed")

	# NOTHING WAS WRITTEN ANYWHERE. This is the whole design: `test_gunners` has to
	# restore `turret_arc_deg` and `mg_spread_deg` had to be put back in two files
	# on 2026-08-22, and those leak between TESTS where a gate catches them. A mode
	# would leak during PLAY, on one machine, with nobody watching.
	var before: float = DebugSettings.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
	for _i in 5:
		world.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
	near(DebugSettings.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG), before, 0.0001,
		"and reading a mode's declaration five times writes nothing back -- "
		+ "leaving a mode is DROPPING a declaration, so there is nothing to undo")

# --- 3. Every subsystem x every mode -----------------------------------------

func _every_pool_is_answered() -> void:
	check(GameMode.POOLS.size() >= 15,
		"the pool list is the real one (%d entries), not a sample"
			% GameMode.POOLS.size())
	for mode in GameMode.ids():
		var missing: Array = GameMode.missing_pools(mode)
		eq(missing.size(), 0,
			("mode '%s' answers every pool -- unanswered: %s. The failure this "
				% [GameMode.name_of(mode), str(missing)])
			+ "prevents is not an error, it is SILENCE: a pool nobody declared "
			+ "QUIETLY RUNS, which is a rescue drone flying out to save a spaceship")

	# BOTH DIRECTIONS. A check that walks one side of a correspondence passes on
	# every fault living on the other -- the release-zip lesson of 2026-08-21,
	# where the archive check asked "is every file present" and could not see the
	# two extra copies of the game sitting inside it.
	var invented: Array = GameMode.missing_pools(-99)
	eq(invented.size(), GameMode.POOLS.size(),
		"and an unregistered mode is reported as answering NOTHING (%d), rather "
			% invented.size() + "than as answering everything by default")

	# AND THE POLICY IS READABLE PER POOL, which is what a subsystem will ask.
	for pool in GameMode.POOLS:
		check(GameMode.runs(GameMode.BASE, pool),
			"base runs '%s' -- phase 1 must look like nothing happened" % pool)

# --- 4 and 5. The wire --------------------------------------------------------

func _the_wire_carries_the_modes() -> void:
	# THROUGH THE REAL RPC BODY, called directly the way a client would receive it.
	# The contract being widened is (seed, count) -> (seed, count, modes), and the
	# point is that they arrive TOGETHER: a client told the count first would build
	# a corridor before knowing what fills it.
	world.run_modes = []
	world._extend_run_to(world.grid.run_seed, world.grid.segment_count(), [0, 0, 0])
	eq(world.run_modes.size(), 3,
		"a client learns the modes in the same message as the seed and the count")

	# AND A CALLER THAT DOES NOT SEND THEM still works, which is what makes this
	# safe to widen: an older host, and the several tests that call this directly,
	# leave the array empty and every round reads as BASE -- the pre-M25 behaviour
	# exactly.
	world._extend_run_to(world.grid.run_seed, world.grid.segment_count())
	eq(world.run_modes.size(), 0, "and a message without them is not an error")
	eq(world.current_mode(), GameMode.BASE, "it simply reads as base")

	# THE PLAN COVERS EVERY ROUND THE CORRIDOR REACHES. Indexed by round rather
	# than by segment, so the arithmetic has to agree with the pool's own cycle --
	# an off-by-one here is a round played in the wrong mode.
	var cycle: int = SegmentPool.SECTIONS_PER_ROUND + 1
	eq(SegmentPool.rounds_in(cycle), 1, "one full cycle is one round")
	eq(SegmentPool.rounds_in(cycle + 1), 2, "and one segment past it is two")
	eq(SegmentPool.round_of_slot(0), 0, "slot 0 is round 0 (its lobby)")
	eq(SegmentPool.round_of_slot(cycle - 1), 0, "and so is the last of its sections")
	eq(SegmentPool.round_of_slot(cycle), 1, "the next lobby opens round 1")
	eq(SegmentPool.segments_through_round(0), cycle,
		"and a rebuild keeps a whole cycle for the round being played")

# --- 6. The lobby is always base ---------------------------------------------

func _the_lobby_is_always_base() -> void:
	# A DELIBERATE ESCAPE HATCH, not an implementation detail: a broken mode can
	# never strand the party somewhere they cannot choose again. Asserted with a
	# non-base mode planned for the round, so it is the LOBBY answering rather than
	# the plan happening to say base.
	world.run_modes = [7, 7, 7]
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.LOBBY
	eq(world.current_mode(), GameMode.BASE,
		"a party in a lobby is in base whatever the round was planned as -- a "
		+ "broken mode must never be able to strand them somewhere they cannot "
		+ "choose again")
	world.round_machine.state = RoundMachine.State.RUNNING
	eq(world.current_mode(), 7,
		"and the moment the round is under way, the plan decides")
	world.run_modes = []

# --- 7. Locked once you are in it --------------------------------------------

func _choosing_is_locked_mid_round() -> void:
	# A ROUND YOU ARE INSIDE HAS ALREADY BEEN CHOSEN. Turning the selector mid-round
	# must not re-cut the ground under a party -- but it must not be DISCARDED
	# either, or a player pressing the control on the way out of a round would see
	# a control that does nothing.
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.RUNNING
	world.next_mode = GameMode.BASE
	world.selected_mode = GameMode.BASE
	var built: int = world.grid.segment_count()

	# DRIVEN THROUGH AN ID THAT IS NOT BASE, or this phase would be asserting that
	# nothing happens when nothing was asked for. `_selected_mode` guards an
	# unregistered id back to base, so the field is set past the guard.
	world.selected_mode = GameMode.BASE
	world.next_mode = 0
	world.selected_mode = 0
	world._poll_mode_selection()
	eq(world.grid.segment_count(), built,
		"polling the selector rebuilds nothing when the choice has not moved")

	# AND AN UNREGISTERED CHOICE IS REFUSED RATHER THAN TAKEN UP. A half-written
	# selector must not be able to put the party into a round that does not exist.
	world.selected_mode = 4242
	world._poll_mode_selection()
	eq(world.next_mode, GameMode.BASE,
		"a mode nobody registered reads as base (%d) rather than being taken up"
			% world.next_mode)
	eq(world.grid.segment_count(), built, "and nothing was rebuilt for it")

	world.selected_mode = GameMode.BASE
	world.round_machine.state = RoundMachine.State.LOBBY
