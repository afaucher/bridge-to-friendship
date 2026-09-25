extends RefCounted

# THE RACE CIRCUIT'S CHECKPOINTS, as the grid knows them: which gate is under
# each cell, and the deck square that is its face. LapTracker asks; the grid only
# records.
#
# `lap_` ON EVERY NAME, because "gate" was already taken. `gate_at_or_before` and
# `gate_after` are about the ROUND BOUNDARY -- the strip between a section and a
# lobby -- and a lap checkpoint is a completely different object that happens to
# be called the same thing in English.

var grid = null

# cell -> gate index, in RUN coordinates.
var cells: Dictionary = {}

# Every gate's DECK SQUARE, as cell -> MeshInstance3D. The world tints them; the
# grid does not know what the colours mean. They are the deck's own meshes,
# handed over by the builder, so they are owned by the segment and go when it is
# truncated.
var marks: Dictionary = {}

func attach(g) -> void:
	grid = g

# KEPT RATHER THAN TAKEN. Every other authored record is drained once by the
# world and turned into a body; a gate is not a body. It is a question asked on
# every tick of every player -- "am I standing on a gate, and which".
func record(run_cell: Vector2i, index: int, square) -> void:
	cells[run_cell] = index
	# A gate whose mesh is missing -- a cell the deck pass skipped, an elevator or
	# a mutable slab -- simply is not in the map, and the tint pass walks what is
	# there.
	if square != null and is_instance_valid(square):
		marks[run_cell] = square

func at(cell: Vector2i) -> int:
	return int(cells.get(cell, -1))

func count() -> int:
	var seen: Dictionary = {}
	for cell in cells:
		seen[int(cells[cell])] = true
	return seen.size()
