extends "res://scripts/test_support/test_case.gd"

# THE SET PIECES AND THE HAZARDS AROUND THEM COME FROM ONE THEME.
#
# A generated section's pieces are drawn from `theme_for(seed, index)` and so is
# its hazard budget -- and the two were asked with DIFFERENT seeds. The generator
# is handed the slot's own seed (a round the selector re-picked has one), the
# dressing pass asked with the run seed. While every round used the run seed the
# two agreed by coincidence; from the first re-pick a `quiet` section could get a
# rusher pit's pieces and a survival budget, or the other way round.
#
# SO THE RUN IS BUILT WITH PER-ROUND SEEDS THAT DIFFER FROM THE RUN SEED, which is
# the only condition under which the old code could be wrong. A test on a default
# run would pass against the bug forever.
#
# And the claim is asserted against BOTH things it has to agree with: the theme
# the generator recorded, and the theme the slot's seed names. The first alone
# would pass a grid that ignored the seed; the second alone would pass a
# generator that never recorded anything.

const BridgeGridScript = preload("res://scripts/level/bridge_grid.gd")
const SegmentPool = preload("res://scripts/level/segment_pool.gd")
const HazardDressing = preload("res://scripts/level/hazard_dressing.gd")

const RUN_SEED := 31337
# Chosen so that every round's seed is far from the run seed. Any values work;
# what matters is that they are not RUN_SEED.
const ROUND_SEEDS := [9001, 424242, 7, 123456789]

func setup(main) -> void:
	timeout_seconds = 60.0
	var grid := Node3D.new()
	grid.name = "ThemeGrid"
	grid.set_script(BridgeGridScript)
	main.add_child(grid)
	grid.dress_hazards = true
	var count: int = SegmentPool.segments_through_lobby(ROUND_SEEDS.size() - 1)
	grid.build_run(RUN_SEED, count, [], ROUND_SEEDS)

	var themed := 0
	var differs_from_run_seed := 0
	for i in grid.segment_count():
		var seg = grid.segment_data(i)
		if seg == null or seg.theme == "":
			continue
		themed += 1
		var slot_seed: int = SegmentPool.slot_seed(RUN_SEED, ROUND_SEEDS, i)
		var want: String = HazardDressing.theme_for(slot_seed, i)
		eq(grid.dressed_theme_of(i), seg.theme,
			"slot %d: dressed with the theme its pieces came from" % i)
		eq(seg.theme, want, "slot %d: and that is the theme its own seed names" % i)
		if HazardDressing.theme_for(RUN_SEED, i) != want:
			differs_from_run_seed += 1
	# THE PRESENCE COUNTS, which are what stop this passing over an empty set.
	check(themed > 0, "some generated sections were themed (%d)" % themed)
	check(differs_from_run_seed > 0,
		"and in some of them the run seed would have named a DIFFERENT theme (%d) -- "
		% differs_from_run_seed + "otherwise this run cannot tell the two seeds apart")
	grid.queue_free()
	finish()
