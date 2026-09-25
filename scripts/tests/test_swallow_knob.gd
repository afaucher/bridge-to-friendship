extends "res://scripts/test_support/test_case.gd"

# THE KNOBS THAT LET YOU FIND ONE.
#
# A swallow needs water, and water is one generated section in three -- so on the
# defaults you are waiting on two rolls and meeting one about every twelfth
# section. That is correct for play and useless for judging the thing, which is
# exactly the problem `merchant_rarity` was added to solve.
#
# THE CLAIM IS THAT THE KNOBS REACH THE WORLD, not that they exist. A setting
# nothing reads is the shape this project keeps finding: a value written, mirrored
# into a menu, and never once consulted by the code it names.

const SegmentGen = preload("res://scripts/level/segment_gen.gd")
const HazardDressing = preload("res://scripts/level/hazard_dressing.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")

var done := false

func setup(_m) -> void:
	timeout_seconds = 90.0

func _count(samples: int) -> Array:
	var wet := 0
	var swallows := 0
	for i in samples:
		var seg = SegmentGen.section(21, 8800 + i * 23, i + 1)
		if seg == null:
			continue
		var has_water := false
		for z in seg.length:
			for x in seg.width:
				if seg.kind_at(x, z) == GridConfig.Kind.WATER:
					has_water = true
					break
			if has_water:
				break
		if has_water:
			wet += 1
		HazardDressing.dress(seg, "environmental", 8800 + i * 23, i)
		swallows += seg.water_spawn_cells.size()
	return [wet, swallows]

func _physics_process(_d: float) -> void:
	if done:
		return
	done = true
	set_physics_process(false)

	var before: Array = _count(40)
	print("[knob] defaults: %d of 40 sections wet, %d swallows" % [before[0], before[1]])

	DebugSettings.set_value("channel_rarity", 1)
	DebugSettings.set_value("swallow_rarity", 1)
	var after: Array = _count(40)
	print("[knob] both at 1: %d of 40 sections wet, %d swallows" % [after[0], after[1]])

	check(int(after[0]) > int(before[0]),
		"turning the channel knob to 1 puts water in more sections (%d against "
			% int(after[0])
		+ "%d) -- a knob that names a generator input and does not reach it is "
			% int(before[0])
		+ "the shape this project keeps finding")
	check(int(after[1]) > int(before[1]),
		"and swallows follow the water (%d against %d) -- the swallow knob cannot "
			% [int(after[1]), int(before[1])]
		+ "conjure any, which is why both are needed to go looking on purpose")
	# AND THE PLACEMENT RULES STILL HOLD AT 1. A knob that finds one by breaking
	# the rule that keeps it fair has found something else.
	check(int(after[1]) <= int(after[0]),
		"still at most one to a body of water even at 1 in 1 (%d swallows over %d "
			% [int(after[1]), int(after[0])]
		+ "wet sections) -- the knob changes how often, not how many")
	DebugSettings.set_value("channel_rarity", 3)
	DebugSettings.set_value("swallow_rarity", 2)
	finish()
