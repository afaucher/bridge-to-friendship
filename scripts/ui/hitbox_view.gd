extends RefCounted

# Draws every collision shape as a wireframe, for the `show_hitboxes` knob.
#
# WHY THIS EXISTS AT ALL: Godot's own `debug_collisions_hint` is read when a shape
# ENTERS THE TREE and does nothing afterwards, so the engine's built-in view
# cannot be toggled in a running game. This is the runtime version.
#
# It is the first entry in the debug console for a reason. Two items in the
# 2026-08-13 playtest -- "pillars catch you going around them" and "plinko balls
# hit you from a distance" -- are both claims that a COLLIDER DOES NOT MATCH WHAT
# IS DRAWN, and one of them is already known to be a 2.0 m test radius against
# 1.0 m of geometry. Being able to see that in the running game is worth more than
# the number in the report.

# Everything it builds hangs off the shape it describes, under this name, so
# clearing up is a search rather than a bookkeeping list that can go stale.
const MARKER := "__hitbox"

static func _material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.2, 1.0, 0.45, 0.9)
	# NO DEPTH TEST, deliberately. A hitbox is nearly always INSIDE the mesh it
	# belongs to, so one that respects depth is one you cannot see -- which is the
	# entire failure mode this is here to diagnose. Same reason the status bar
	# uses it.
	m.no_depth_test = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# Bring the whole tree under `root` into line with `on`. Cheap enough to call
# whenever the knob changes, and idempotent, which is what lets the same function
# serve "the setting changed" and "a body was just spawned".
static func apply(root: Node, on: bool) -> void:
	if root == null:
		return
	for shape in _collision_shapes(root):
		var existing: Node = shape.get_node_or_null(MARKER)
		if on:
			if existing == null:
				_attach(shape)
		elif existing != null:
			existing.queue_free()

static func _attach(shape: CollisionShape3D) -> void:
	if shape.shape == null:
		return
	var mesh := MeshInstance3D.new()
	mesh.name = MARKER
	# get_debug_mesh() is the same wireframe the engine draws for itself, so a
	# hand-rolled approximation cannot disagree with the real shape -- which would
	# be the worst possible bug in a tool built to be believed.
	mesh.mesh = shape.shape.get_debug_mesh()
	mesh.material_override = _material()
	# Visible even when the body it belongs to is not: a hidden body is exactly
	# the case somebody is trying to see (a drone-returned player, a frozen hat).
	mesh.visible = true
	shape.add_child(mesh)

static func _collision_shapes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var node: Node = stack.pop_back()
		if node is CollisionShape3D:
			out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out
