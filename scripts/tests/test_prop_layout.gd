extends "res://scripts/test_support/test_case.gd"

# A PROP THE PARTY ALREADY CONSUMED DOES NOT COME BACK FOR A JOINER.
#
# A joiner is sent every "already spent" layout on arrival and builds the run from
# the seed -- so a segment that streams in AFTER those layouts arrived spawns its
# props from scratch. The grave and the merchant checked their spent records at
# spawn; the mound, the heart and the plinko shooter did not, so a heart the party
# had eaten was back on the deck on the joiner's screen, and a mound that had
# already woken its rusher sat there waiting to wake another.
#
# All five kinds share consumable_props.gd now, and `spawn` asks. This asserts it
# per kind -- the layout first, the spawn second, which is the order a joiner meets
# them in -- and then the ordinary order, so the check cannot pass by refusing
# every spawn.

const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")

func setup(main) -> void:
	var grid := Node3D.new()
	grid.set_script(BridgeGridScript)
	main.add_child(grid)
	grid.load_segment_file("res://segments/test_flat.seg")
	var here := Vector2i(7, 4)
	var there := Vector2i(9, 6)
	var layout := PackedInt32Array([here.x, here.y])

	var kinds := {
		"mound": [grid._spawn_mound, grid.apply_spent_mounds, grid.mound_count],
		"grave": [grid._spawn_grave, grid.apply_spent_graves, grid.grave_count],
		"heart": [grid._spawn_heart, grid.apply_taken_hearts, grid.heart_count],
		"shooter": [grid._spawn_shooter, grid.apply_spent_shooters,
			func() -> int: return grid.shooters.count()],
	}
	for label in kinds:
		var spawn: Callable = kinds[label][0]
		var apply: Callable = kinds[label][1]
		var count: Callable = kinds[label][2]
		var before: int = int(count.call())
		apply.call(layout)
		spawn.call(here)
		eq(int(count.call()), before,
			"a %s the host already spent is not spawned for a joiner" % label)
		spawn.call(there)
		eq(int(count.call()), before + 1, "while an unspent %s still is" % label)

	# The merchant is BUILT when spent -- he stands there sold out -- and marked.
	grid.apply_spent_merchants(layout)
	grid._spawn_merchant(here)
	var merchant: Node = grid.merchant_at_cell(here)
	if check(merchant != null, "a sold-out merchant still stands"):
		check(not merchant.can_trade(), "and has nothing left to sell")
	grid.queue_free()
	finish()
