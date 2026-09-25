extends "res://scripts/sim/world/world_system.gd"

# A WORLD SYSTEM THAT HOLDS BODIES AND REPLICATES THEM BY SNAPSHOT.
#
# Everything a pool of rushers, zombies or gunners shared, once: the list, the
# root node they live under, the id counter, the delta-encoded snapshot, the
# applier that builds what a client is told about and frees what it stops being
# told about, and the two ways a whole pool goes away.
#
# THE APPLIER IS SELF-HEALING BY CONSTRUCTION: a client never destroys anything
# on an event, it destroys what the host has STOPPED MENTIONING. A dropped packet
# costs a frame of staleness rather than an enemy that exists forever on one
# machine. That is only safe for things that die quickly or are mentioned every
# tick -- see CLAUDE.md, "existence must not ride the unreliable channel", which
# is why buses and swallows are NOT entity pools.
#
# A BODY IN A POOL HAS `id`, `capture_state()` (entry[0] is the id) and
# `apply_state()`. EnemyBody provides the first; each kind the other two.

const SnapshotDelta = preload("res://scripts/net/snapshot_delta.gd")

var items: Array = []
var root: Node3D = null
var next_id: int = 0

# What the root node is called, and what each body is named after.
var root_name: String = ""
var node_prefix: String = ""

func _attached() -> void:
	root = Node3D.new()
	root.name = root_name
	world.add_child(root)

# --- Subclass hooks -----------------------------------------------------------

# A fresh body for a client to put a snapshot entry into. Defaults to `_instantiate`.
func _build_for(_entry: Array) -> Node:
	return _instantiate()

func _instantiate() -> Node:
	return null

# --- Adding and finding -------------------------------------------------------

# Give `body` the next id and put it in the world. NAMED AFTER THE ADD, because a
# name set before add_child is discarded when a sibling already has it (CLAUDE.md,
# 2026-08-22) and the node becomes `@Node3D@342`.
func add(body: Node) -> Node:
	next_id += 1
	body.id = next_id
	root.add_child(body)
	body.name = "%s_%d" % [node_prefix, next_id]
	items.append(body)
	return body

func by_id(id: int) -> Node:
	for body in items:
		if is_instance_valid(body) and int(body.id) == id:
			return body
	return null

func count() -> int:
	return items.size()

# Out of the list (if it is still in it), without freeing it.
func forget(body: Node) -> void:
	var index: int = items.find(body)
	if index >= 0:
		items.remove_at(index)

# --- The snapshot -------------------------------------------------------------

func snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for body in items:
		if is_instance_valid(body):
			out.append(body.capture_state())
	return SnapshotDelta.encode(out, world._section(section_name), keyframe)

# Build what is new, update what changed, free what the host stopped mentioning.
func apply_snapshot(section: Array) -> void:
	var seen: Dictionary = world._seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var body: Node = by_id(id)
		if body == null:
			body = _build_for(entry)
			if body == null:
				continue
			body.id = id
			root.add_child(body)
			body.name = "%s_%d" % [node_prefix, id]
			items.append(body)
		body.apply_state(entry)
	for i in range(items.size() - 1, -1, -1):
		var existing = items[i]
		if not is_instance_valid(existing) or not seen.has(int(existing.id)):
			items.remove_at(i)
			if is_instance_valid(existing):
				existing.queue_free()

# --- Going away ---------------------------------------------------------------

func clear() -> void:
	for body in items:
		if is_instance_valid(body):
			body.queue_free()
	items.clear()

func discard_from_row(cut_row: int) -> void:
	for i in range(items.size() - 1, -1, -1):
		var body = items[i]
		if not is_instance_valid(body):
			items.remove_at(i)
			continue
		if world.grid.cell_of_world(body.global_position).y >= cut_row:
			items.remove_at(i)
			body.queue_free()
