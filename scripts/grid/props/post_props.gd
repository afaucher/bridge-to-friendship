extends RefCounted

# A KIND OF POST: something standing at a cell that a player walks up to and
# presses E at. The mode selector and the bus post were the same twenty lines
# twice in BridgeGrid -- a cell -> post map, a lazily made root, a spawn, and a
# list for the world's use-key dispatch. Built from grid content, so every machine
# builds its own; nothing about a post crosses the wire except what it SHOWS.

var grid = null
var root: Node3D = null
var posts: Dictionary = {}     # Vector2i -> the post standing there

var post_script: Script = null
var root_name: String = ""
var node_prefix: String = ""

func _init(script: Script = null, root_label: String = "", prefix: String = "") -> void:
	post_script = script
	root_name = root_label
	node_prefix = prefix

func attach(g) -> void:
	grid = g

func spawn(cell: Vector2i) -> void:
	if root == null:
		root = Node3D.new()
		root.name = root_name
		grid.add_child(root)
	var post = post_script.new()
	post.cell = cell
	post.position = grid.cell_surface(cell)
	root.add_child(post)
	post.name = "%s_%d_%d" % [node_prefix, cell.x, cell.y]
	posts[cell] = post

# Every post currently built. The world asks rather than tracking them.
func all() -> Array:
	var out: Array = []
	for cell in posts:
		var post = posts[cell]
		if is_instance_valid(post):
			out.append(post)
	return out
