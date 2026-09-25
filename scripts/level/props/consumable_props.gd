extends RefCounted

# A KIND OF PROP THE LEVEL PLACES AT A CELL AND THE GAME CONSUMES ONCE: a mound
# that wakes a rusher, a grave that raises a pack, a heart that is eaten, a plinko
# shooter that is blasted, a merchant who sells. Each was the same forty lines in
# BridgeGrid -- a cell -> node map, a root, a list of the ones already consumed,
# spawn, take, a blast radius, and a layout a late joiner is sent -- written five
# times, and the copies had drifted in the one way that matters:
#
# ONLY THE GRAVE AND THE MERCHANT CHECKED THE CONSUMED LIST WHEN SPAWNING. A
# joiner is sent the layout on arrival and builds the run from the seed, so a
# segment that streams in AFTER the layout arrived spawned its mounds, hearts and
# shooters fresh -- a heart the party ate, back on the deck on one machine. Here
# `spawn` asks, for every kind.
#
# THE ROOT NODES LIVE UNDER THE GRID, so truncate_run's node sweep still frees
# them, and its reflection sweep walks every prop component's properties the way
# it walks its own -- so `nodes` and `spent` are forgotten past a cut without
# anything here having to know about it (test_prop_layout).

var grid = null
var root: Node3D = null
var nodes: Dictionary = {}     # Vector2i -> the node standing there
var spent: Array = []          # Vector2i, in the order they were consumed

var root_name: String = ""
var node_prefix: String = ""

func attach(g) -> void:
	grid = g

# --- A kind says ----------------------------------------------------------------

func _build(_cell: Vector2i) -> Node3D:
	return null

# Where it counts as being for a blast, and for anything that asks where it is.
func surface_world(cell: Vector2i) -> Vector3:
	return grid.cell_surface_world(cell)

func _on_taken(_cell: Vector2i) -> void:
	pass

# --- Placing and consuming --------------------------------------------------------

func spawn(cell: Vector2i) -> void:
	if spent.has(cell):
		return
	if root == null:
		root = Node3D.new()
		root.name = root_name
		grid.add_child(root)
	var node: Node3D = _build(cell)
	node.name = "%s_%d_%d" % [node_prefix, cell.x, cell.y]
	root.add_child(node)
	nodes[cell] = node

func count() -> int:
	return nodes.size()

# A copy: `take` erases from the map being iterated.
func cells() -> Array:
	return nodes.keys()

func at(cell: Vector2i) -> Node:
	var node = nodes.get(cell)
	return node if is_instance_valid(node) else null

# Consumed. Returns whether it was still there to consume.
func take(cell: Vector2i) -> bool:
	if not nodes.has(cell):
		return false
	var node = nodes[cell]
	nodes.erase(cell)
	mark_spent(cell)
	if is_instance_valid(node):
		node.queue_free()
	_on_taken(cell)
	return true

func mark_spent(cell: Vector2i) -> void:
	if not spent.has(cell):
		spent.append(cell)

func blast(centre: Vector3, radius: float) -> int:
	var removed := 0
	for cell in cells():
		if surface_world(cell).distance_to(centre) <= radius and take(cell):
			removed += 1
	return removed

# --- Across the wire ------------------------------------------------------------

func layout() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in spent:
		out.append(cell.x)
		out.append(cell.y)
	return out

# RECORDED EVEN WHEN THE CELL IS NOT BUILT YET, so `spawn` refuses it later -- see
# the header. Then taken, for the ones that are.
func apply_layout(data: PackedInt32Array) -> void:
	var i := 0
	while i + 1 < data.size():
		var cell := Vector2i(data[i], data[i + 1])
		mark_spent(cell)
		take(cell)
		i += 2
