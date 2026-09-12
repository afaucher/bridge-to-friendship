extends "res://scripts/test_support/test_case.gd"

# NO FENCES IN A RIVER, IN THE AUTHORED MAPS TOO.
#
# The generator's channels are checked by test_generated_water. This is the other
# half of the same claim: a hand-authored `~` that reaches a rail without the
# parapet suppressed grows a railing exactly the same way, and the author gets no
# warning -- the presence is DERIVED, so a file that says nothing produces one.

const SegmentData = preload("res://scripts/grid/segment_data.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")

var done := false

func setup(_m) -> void:
	timeout_seconds = 30.0

func _physics_process(_d: float) -> void:
	if done:
		return
	done = true
	set_physics_process(false)
	var dir = DirAccess.open("res://segments")
	if not check(dir != null, "the segments directory opens"):
		finish()
		return
	var water := 0
	var fenced := 0
	var files := 0
	for name in dir.get_files():
		if not name.ends_with(".seg"):
			continue
		var seg = SegmentData.from_file("res://segments/" + name)
		if seg == null or not seg.errors.is_empty():
			continue
		files += 1
		for z in seg.length:
			for x in seg.width:
				if seg.kind_at(x, z) != GridConfig.Kind.WATER:
					continue
				water += 1
				for d in 4:
					if seg.has_wall(x, z, d):
						fenced += 1
						print("[authored] %s has a fence on water at (%d, %d)"
							% [name, x, z])
	print("[authored] %d files, %d water cells, %d fenced" % [files, water, fenced])
	check(water > 0, "some authored map still has water to check (%d)" % water)
	eq(fenced, 0,
		"no authored water cell carries a parapet (%d) -- the railing is DERIVED, "
			% fenced
		+ "so an author who reaches a rail with `~` and says nothing gets a fence "
		+ "in their river and no warning that they have")
	finish()
