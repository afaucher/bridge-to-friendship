extends "res://scripts/test_support/test_case.gd"

# M13 item 6. Send only what changed.
#
# The claims:
#   1. A settled body is NOT re-sent every tick. Measured, because "it still
#      works" is equally true of a delta that never elides anything.
#   2. It is still MENTIONED. The manifest is the whole design -- every applier
#      destroys what it is not told about, so an omitted entry must still appear
#      in the id list or the delta becomes a data-loss bug.
#   3. A body the host really stops mentioning IS destroyed. The property the
#      manifest exists to preserve, and the one a careless delta breaks.
#   4. A keyframe re-sends everything, so a client that missed a change recovers
#      within half a second instead of never.
#
# CLAIM 1 IS THE ONE CARRYING THE WORK and claim 3 is the one carrying the safety.
# Everything here runs on the host's own builders rather than over a socket: what
# is being tested is what goes ON the wire, and a real client would only confirm
# that the two halves of an encoder agree with each other.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SnapshotDelta = preload("res://scripts/net/snapshot_delta.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "DeltaWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	# Sixteen hats lying still. Deliberately the section the measurement found at
	# 0.2% changed -- if anything deltas, this does.
	for i in 16:
		world._hats.spawn_loose(world.grid.cell_surface_world(Vector2i(2, 4 + i))
			+ Vector3(0.0, 0.4, 0.0))

	_test_settled_bodies_are_not_resent()
	_test_absence_still_destroys()
	_test_keyframe_resends()
	finish()

# --- 1 and 2. Elided from the payload, kept in the manifest --------------------

func _test_settled_bodies_are_not_resent() -> void:
	# First encode is a keyframe by definition -- nothing has been sent before, so
	# every entry differs from nothing.
	var first: Array = world._hat_snapshot(false)
	eq(SnapshotDelta.changed_of(first).size(), 16,
		"the first snapshot carries every hat, because none has been sent yet")
	eq(SnapshotDelta.ids_of(first).size(), 16, "and names all sixteen")

	# Let them settle. A freshly spawned RigidBody3D is still moving.
	for i in 90:
		world._physics_process(SimConfig.TICK_DELTA)

	# Two encodes back to back with nothing moving in between.
	world._hat_snapshot(false)
	var second: Array = world._hat_snapshot(false)

	# THE CLAIM. A settled hat is not in the payload at all.
	check(SnapshotDelta.changed_of(second).size() <= 1,
		"a settled hat is not re-sent: %d of 16 in the payload"
			% SnapshotDelta.changed_of(second).size())

	# ...AND IS STILL NAMED. Without this the appliers delete all sixteen.
	eq(SnapshotDelta.ids_of(second).size(), 16,
		"but all sixteen are still in the manifest, or every applier destroys them")

# --- 3. Absence still means gone ----------------------------------------------

func _test_absence_still_destroys() -> void:
	var doomed: Node = world._hats.all()[0]
	var id: int = doomed.hat_id
	world._hats.destroy(doomed)

	var section: Array = world._hat_snapshot(false)
	var ids: PackedInt32Array = SnapshotDelta.ids_of(section)
	eq(ids.size(), 15, "a destroyed hat leaves the manifest")
	check(not (id in ids), "and specifically that id is gone")

	# The applier's own rule, exercised on a client-shaped world rather than
	# asserted about: what is absent from the manifest is destroyed, and what is
	# merely absent from the PAYLOAD is not.
	var client := Node3D.new()
	client.name = "DeltaClient"
	client.set_script(GameWorldScript)
	world.get_parent().add_child(client)
	client.start(false, 2, false)
	# Give it every hat, then hand it a section that omits one.
	client._apply_hat_snapshot(_full_from(world))
	eq(client._hats.count(), 15, "a client builds what the manifest names")

	var thinned: Array = [SnapshotDelta.ids_of(section), []]
	client._apply_hat_snapshot(thinned)
	eq(client._hats.count(), 15,
		"an entry omitted because it did not CHANGE survives -- this is the trap")

	var emptied: Array = [PackedInt32Array(), []]
	client._apply_hat_snapshot(emptied)
	eq(client._hats.count(), 0,
		"but an id dropped from the MANIFEST is destroyed, exactly as before")
	client.queue_free()

# --- 4. A keyframe puts everything back ---------------------------------------

func _test_keyframe_resends() -> void:
	world._hat_snapshot(false)
	var quiet: Array = world._hat_snapshot(false)
	check(SnapshotDelta.changed_of(quiet).size() <= 1, "nothing is moving")

	var key: Array = world._hat_snapshot(true)
	eq(SnapshotDelta.changed_of(key).size(), SnapshotDelta.ids_of(key).size(),
		"a keyframe re-sends every hat it names, so a missed change self-heals")

# A full section built from the world's own hats, for seeding a client.
func _full_from(source: Node) -> Array:
	var out: Array = []
	var ids := PackedInt32Array()
	for hat in source._hats.all():
		if is_instance_valid(hat):
			out.append([hat.hat_id, hat.style_id, hat.mode, hat.position])
			ids.append(hat.hat_id)
	return [ids, out]
