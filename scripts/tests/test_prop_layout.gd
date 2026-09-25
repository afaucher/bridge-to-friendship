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
	_the_sweep_reaches_every_component(main)
	finish()

# AND A TRUNCATED CORRIDOR TAKES ITS PROPS' RECORDS WITH IT, in every component.
#
# truncate_run finds cell records by reflection rather than by name, which is the
# only reason moving the props out of BridgeGrid was safe -- and the only way it
# stays safe is if the reflection is pointed at every component. So after a real
# cut, no component holds a cell past it. Asserted generically, over every
# Dictionary and Array a component has, so the next prop kind is covered the day
# it is added to prop_components().
func _the_sweep_reaches_every_component(main) -> void:
	var grid := Node3D.new()
	grid.set_script(BridgeGridScript)
	main.add_child(grid)
	grid.dress_hazards = true
	grid.build_run(2026, 13)
	var keep: int = 7
	var cut_row: int = grid.first_row_of_segment(keep)
	var before: int = _cells_past(grid, cut_row)
	check(before > 0, "the run had prop records past the cut to sweep (%d)" % before)
	grid.truncate_run(keep)
	eq(_cells_past(grid, cut_row), 0, "and after the cut no component keeps one")
	grid.queue_free()

func _cells_past(grid: Node, cut_row: int) -> int:
	var n := 0
	for holder in grid.prop_components():
		for entry in holder.get_property_list():
			var value = holder.get(str(entry.get("name", "")))
			if value is Dictionary:
				for k in value:
					if k is Vector2i and (k as Vector2i).y >= cut_row:
						n += 1
			elif value is Array:
				for item in value:
					var cell = item[0] if item is Array and (item as Array).size() > 0 else item
					if cell is Vector2i and (cell as Vector2i).y >= cut_row:
						n += 1
	return n
