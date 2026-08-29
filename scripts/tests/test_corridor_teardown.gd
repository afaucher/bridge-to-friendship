extends "res://scripts/test_support/test_case.gd"

# CHANGING YOUR MIND RE-CUTS THE CORRIDOR. M25 phase 2's prerequisite.
#
# The corridor past the lobby is built speculatively as soon as a mode is chosen,
# so changing the choice has to throw it away. The party is standing in a lobby
# by definition while that happens, behind a front wall at the lobby's far band,
# so the rebuild is never seen.
#
# THE LOAD-BEARING CLAIM IS COMPLETENESS, NOT CORRECTNESS. Loading a segment
# accumulates into roughly thirty containers, and a teardown that misses ONE
# leaves a cell key pointing at a freed node -- which does not fail here, it fails
# minutes later somewhere else. So this does not check a list of kinds. It checks
# that NOTHING of any kind survives past the cut:
#
#   * no node stands on ground that no longer exists, asked of every child of
#     every prop root rather than of a list of prop kinds;
#   * no cell key names a row past the cut, found by walking the grid's own
#     properties -- so a container added next month is covered by this test on the
#     day it is added, without anybody remembering to come back here.
#
# That is the same reason the teardown itself sweeps rather than enumerates. A
# test that named the kinds would go stale in exactly the way the code would.
#
# The claims:
#   1. THE CUT HAPPENS: segments past it are gone, and the ones before are not.
#   2. NOTHING SURVIVES IT -- no node, no cell, of any kind.
#   3. THE HEIGHT ACCUMULATOR IS RESTORED, so the rebuilt corridor joins the kept
#      ground rather than floating above it. It is the one piece of state that is
#      neither a node nor a cell, and therefore the one the sweeps cannot catch.
#   4. IT REBUILDS, AND WITH THE NEW CHOICE. A teardown that left the corridor
#      short would strand the party at a cliff edge.
#   5. THE PLAYED GROUND IS UNTOUCHED, which is what makes it safe at all.
#   6. AND THE PARTY'S THINGS SURVIVE, WHATEVER GROUND THEY ARE OVER. The line the
#      teardown draws is not "everything in the world". It is between what belongs
#      to the LEVEL -- rushers, gunners, zombies, balls, put there by the ground
#      they stand on -- and what belongs to the PARTY: the players, their hats,
#      their specials. A hat is the score of this game and there is no undo for
#      one, so a mode change that ate a hat because it happened to be lying past
#      the cut would be unrecoverable and indistinguishable from a bug.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const Deployable = preload("res://scripts/sim/deployable.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")

const WIDTH := 21
const SEED := 20260825

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "TeardownWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world_under_test(world)

func _physics_process(_delta: float) -> void:
	if done or world.tick < 2:
		return
	done = true
	set_physics_process(false)

	_it_cuts_and_nothing_survives()
	_it_rebuilds_with_the_new_choice()
	_the_level_goes_and_the_party_stays()
	finish()

# --- 1, 2, 3. The cut ---------------------------------------------------------

func _it_cuts_and_nothing_survives() -> void:
	var cycle: int = SegmentPool.SECTIONS_PER_ROUND + 1
	var grid = BridgeGridScript.new()
	grid.name = "CutRun"
	world.add_child(grid)
	grid.width = WIDTH
	# DRESSED, because an undressed run has far less in it and the whole point of
	# this file is the THINGS a segment leaves behind. A teardown tested on empty
	# ground is a teardown tested on nothing.
	grid.dress_hazards = true
	grid.build_run(SEED, cycle * 3)

	var before_segments: int = grid.segment_count()
	var before_props: int = _props(grid)
	var before_cells: int = _cells(grid)
	check(before_segments >= cycle * 3,
		"the run really was built (%d segments)" % before_segments)
	check(before_props > 20,
		"and there is something standing on it (%d props) -- a teardown measured "
			% before_props + "on bare ground proves nothing")
	check(before_cells > 20, "and cells recorded for them (%d)" % before_cells)

	var keep: int = SegmentPool.segments_through_round(0)
	var cut_row: int = _row_of_segment(grid, keep)
	var kept_height: int = grid.total_length()

	grid.truncate_run(keep)

	# --- 1. The cut happened -------------------------------------------------
	eq(grid.segment_count(), keep,
		"the run is cut to the round being played (%d of %d segments)"
			% [grid.segment_count(), before_segments])
	check(grid.total_length() < kept_height,
		"and it really is shorter (%d rows, was %d)"
			% [grid.total_length(), kept_height])
	check(grid.segment_data(0) != null, "while the first segment is untouched")

	# --- 2. And nothing of any kind survived it ------------------------------
	var late_props: Array = _props_past(grid, cut_row)
	print("[teardown] cut at row %d: %d props before, %d after, %d stragglers"
		% [cut_row, before_props, _props(grid), late_props.size()])
	eq(late_props.size(), 0,
		("nothing stands past the cut -- %s. Asked of every prop root rather than "
			% str(late_props))
		+ "of a list of kinds, so a prop kind added next month is covered without "
		+ "anybody remembering to come back here")

	var late_cells: Array = _cells_past(grid, cut_row)
	print("[teardown] %d cells before, %d after, %d past the cut"
		% [before_cells, _cells(grid), late_cells.size()])
	eq(late_cells.size(), 0,
		("no cell record names a row past the cut -- %s. A missed container is a "
			% str(late_cells))
		+ "key pointing at a freed node, which does not fail here: it fails "
		+ "minutes later somewhere else")

	# --- 3. ...including the one that is neither ------------------------------
	#
	# The height accumulator is not a node and not a cell, so both sweeps miss it
	# by construction -- which is exactly why it is worth its own claim. Left
	# alone, the rebuilt corridor would start at the height the DISCARDED ground
	# finished at and float above the join.
	var rebuilt_from: int = grid.next_height() if grid.has_method("next_height") else -1
	if rebuilt_from >= 0:
		var expected: int = _exit_height_through(grid, keep)
		eq(rebuilt_from, expected,
			"the height accumulator is back to where the KEPT ground finishes "
			+ "(%d, not the discarded ground's %d)" % [rebuilt_from, expected])
	grid.queue_free()

# --- 4, 5. It builds again ----------------------------------------------------

func _it_rebuilds_with_the_new_choice() -> void:
	# THROUGH THE WORLD, which is the caller phase 2's control will use. Everything
	# above is about the grid; this is about the decision reaching it.
	world.assemble_run = true
	world.run_seed = SEED
	world.grid.dress_hazards = true
	# BUILT PAST THE ROUND IN PLAY BY HAND, because `_extend_run` keeps segments
	# ahead of the PARTY rather than ahead of the round -- with everybody standing
	# at the start there is nothing speculative yet, and this phase would then be
	# asserting a teardown of nothing. The first version did exactly that and
	# reported "6 segments", which is round 0 and not a segment more.
	var cycle: int = SegmentPool.SECTIONS_PER_ROUND + 1
	world.grid.build_run(SEED, cycle * 2)
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.LOBBY
	world.run_modes = [GameMode.BASE, GameMode.BASE]
	world.next_mode = GameMode.BASE
	var speculative: int = world.grid.segment_count()
	check(speculative > SegmentPool.segments_through_lobby(0),
		"there is corridor past the round in play to discard (%d segments)"
			% speculative)

	# THE CHOICE CHANGES. The selector is a field until phase 2 attaches a control
	# to it; the machinery under test is the same either way.
	world.selected_mode = GameMode.BLANK
	world._poll_mode_selection()

	eq(world.next_mode, GameMode.BLANK, "the choice is taken up in a lobby")
	# REBUILT TO WHAT THE LOOKAHEAD WANTS, which is not necessarily back to what
	# was discarded -- `_extend_run` keeps RUN_LOOKAHEAD_SEGMENTS ahead of the
	# PARTY, and the corridor above was over-built by hand. The claim is that the
	# ground the party can reach exists, not that a number was restored.
	check(world.grid.segment_count() > SegmentPool.segments_through_lobby(0),
		"and the corridor is rebuilt past the lobby rather than left short (%d "
			% world.grid.segment_count()
		+ "segments) -- a teardown that did not build again would strand the party "
		+ "at a cliff edge the moment the wall dropped")

	# AND IT IS THE NEW CHOICE THAT WAS BUILT. Without this the test would pass on
	# a teardown that rebuilt exactly what it had just discarded.
	# ROUND 0's OWN SECTIONS, because a party standing in round 0's lobby is
	# choosing round 0 -- `round_index` is incremented on ENTERING a lobby, so the
	# sections ahead of them belong to the round they are already counted as being
	# in. The first version of this looked at round 1 and found nothing, which is
	# the same off-by-a-round the keep line had.
	var blank := 0
	var sections := 0
	for i in world.grid.segment_count():
		if SegmentPool.is_lobby_slot(i) or SegmentPool.round_of_slot(i) != 0:
			continue
		var seg = world.grid.segment_data(i)
		if seg == null:
			continue
		sections += 1
		blank += 1 if seg.tags.has("blank") else 0
	print("[teardown] after re-cutting, round 0 is %d/%d blank" % [blank, sections])
	check(sections > 0, "round 0 has sections to check (%d)" % sections)
	eq(blank, sections,
		"and every one of them is the newly chosen mode (%d of %d) -- a rebuild "
			% [blank, sections] + "that produced what it just discarded would pass "
		+ "every other assertion here")

	# --- 5. The played ground is untouched -----------------------------------
	check(world.grid.segment_data(0) != null,
		"and the LOBBY the party is standing in is still there, because re-cutting "
		+ "under somebody standing on it is the one thing this must never do")

# --- 6. Whose thing is it -----------------------------------------------------

func _the_level_goes_and_the_party_stays() -> void:
	var keep: int = SegmentPool.segments_through_lobby(0)
	var cut_row: int = _row_of_segment(world.grid, keep)
	if not check(cut_row > 0 and world.grid.segment_count() > keep,
			"there is ground past the cut to put things on"):
		return
	var past: Vector3 = world.grid.cell_surface_world(Vector2i(WIDTH / 2, cut_row + 2)) 		+ Vector3(0.0, 1.0, 0.0)

	# ONE OF EACH, BOTH PAST THE CUT, so the only thing that can tell them apart is
	# which side of the line they are on.
	var rusher: Node = world._spawn_rusher(past)
	var hat: Node = world._hats.spawn_loose(past + Vector3(0.6, 0.0, 0.0))
	if not check(rusher != null and hat != null, "a rusher and a hat exist to sort"):
		return
	var hat_id: int = int(hat.hat_id)

	# AND A MINE, WHICH WAS THE POOL NOBODY ADDED. Reported from play as mines
	# floating with no deck under them: they were placed correctly and the ground
	# was cut out from beneath them, because every pool that stands on discarded
	# corridor is swept here and deployables were not on the list. Hats and
	# specials were added for the identical symptom; the lesson did not
	# generalise, so the claim is written per pool now.
	var mine: Node = world._spawn_deployable(Deployable.Kind.MINE)
	mine.place_at(past, 0, true)
	mine.timer = 0.0

	# AND A CORPSE, WHICH IS THE FOURTH POOL OF THE SAME KIND. Added on the merge
	# that introduced corpses rather than after a report -- a corpse lies where an
	# enemy died for eight seconds, so a mode change while one is cooling leaves it
	# over the hole the road used to be. Short window, same shape.
	world._show_corpse(0, past + Vector3(0.0, 0.0, 0.3), Vector3.ZERO, false)
	var corpse: Variant = world._corpses[world._corpses.size() - 1] 		if world._corpses.size() > 0 else null
	if not check(corpse != null, "a corpse exists to sort"):
		return

	world._discard_level_entities_past(keep)

	check(not is_instance_valid(corpse) or corpse.is_queued_for_deletion(),
		"a corpse past the cut goes with the ground the body fell on -- the level "
		+ "decided where it is, which is the question to ask of a pool rather "
		+ "than whether the thing in it is an enemy")
	eq(world.corpse_count(), 0, "and it leaves the pool with it")

	check(not is_instance_valid(mine) or mine.is_queued_for_deletion(),
		"a mine past the cut goes with the ground it was standing on -- it is "
		+ "PUT there by the level, so it belongs to the level, and an armed one "
		+ "left hanging over a hole is what got reported")

	var rusher_gone: bool = not is_instance_valid(rusher) or rusher.is_queued_for_deletion()
	var hat_kept: bool = is_instance_valid(hat) and not hat.is_queued_for_deletion()
	print("[teardown] past the cut: rusher discarded=%s, hat kept=%s"
		% [str(rusher_gone), str(hat_kept)])

	check(rusher_gone,
		"a rusher standing past the cut goes with the ground that put it there -- "
		+ "left alone it would hang in the void over the rebuilt corridor")
	# A LOOSE HAT ON THAT SAME GROUND GOES TOO, and this is the half the first
	# version got wrong. Hats live in the WORLD rather than under the grid, so
	# freeing a segment left every pickup the discarded corridor had placed hanging
	# exactly where it was -- at the height that corridor had climbed to. Reported
	# from play as "the items are all placed in the sky, farther and farther up the
	# round", which is exactly the shape of it.
	#
	# SAFE BECAUSE PAST THE CUT IS GROUND NOBODY HAS STOOD ON: the front wall is at
	# the lobby's far band while a choice is being made, so anything loose out
	# there was placed by the level and has never been touched by a player.
	check(not hat_kept,
		"a LOOSE hat past the cut goes with the ground that placed it -- it was "
		+ "never anybody's, and left behind it hangs in the sky over the corridor "
		+ "that replaces it")
	eq(world._hats.by_id(hat_id), null, "and it leaves the pool with it")

	# ...BUT A HAT SOMEBODY IS WEARING IS NEVER TOUCHED, wherever they are standing.
	# That is the half that was always right and is the one worth protecting: a hat
	# is the score of this game and there is no undo for one.
	world._spawn_player(1, 0)
	var wearer: Node = world.player_body(1)
	if check(wearer != null, "there is somebody to wear one"):
		wearer.global_position = past
		var worn: Node = world._hats.spawn_loose(past)
		var worn_id: int = int(worn.hat_id)
		world._wear_hat(worn_id, 1, 0)
		check(worn.mode == HatBody.Mode.WORN, "and they are wearing it")
		world._discard_level_entities_past(keep)
		check(world._hats.by_id(worn_id) != null,
			"a WORN hat past the cut is kept -- it belongs to the person carrying "
			+ "it, not to the ground they happen to be standing over")

	# ...AND SO IS THE PLAYER, the other half of the same line and the one whose
	# failure would be worst.
	world._spawn_player(1, 0)
	var body: Node = world.player_body(1)
	if check(body != null, "a player exists"):
		body.global_position = past + Vector3(0.0, 0.0, 0.6)
		world._discard_level_entities_past(keep)
		check(is_instance_valid(world.player_body(1)),
			"a PLAYER standing past the cut is never discarded either")

# --- helpers ------------------------------------------------------------------

func _row_of_segment(grid, i: int) -> int:
	var rows := 0
	for k in i:
		var seg = grid.segment_data(k)
		if seg != null:
			rows += seg.length
	return rows

func _exit_height_through(grid, keep: int) -> int:
	var h := 0
	for k in keep:
		var seg = grid.segment_data(k)
		if seg != null:
			h += seg.exit_height()
	return h

# Every prop under every per-kind root. Counted generically for the same reason
# the teardown sweeps generically.
func _props(grid) -> int:
	var n := 0
	for root in grid.get_children():
		if root is Node3D:
			n += (root as Node3D).get_child_count()
	return n

func _props_past(grid, cut_row: int) -> Array:
	var out: Array = []
	for root in grid.get_children():
		if not (root is Node3D):
			continue
		for prop in (root as Node3D).get_children():
			if not (prop is Node3D):
				continue
			if not is_instance_valid(prop) or prop.is_queued_for_deletion():
				continue
			if grid.cell_of_world((prop as Node3D).global_position).y >= cut_row:
				out.append("%s/%s" % [root.name, prop.name])
			if out.size() > 6:
				return out
	return out

func _cells(grid) -> int:
	var n := 0
	for entry in grid.get_property_list():
		var key: String = str(entry.get("name", ""))
		if key == "":
			continue
		var value = grid.get(key)
		if value is Dictionary:
			for k in (value as Dictionary):
				if k is Vector2i:
					n += 1
		elif value is Array:
			for item in (value as Array):
				if item is Vector2i:
					n += 1
	return n

func _cells_past(grid, cut_row: int) -> Array:
	var out: Array = []
	for entry in grid.get_property_list():
		var key: String = str(entry.get("name", ""))
		if key == "":
			continue
		var value = grid.get(key)
		if value is Dictionary:
			for k in (value as Dictionary):
				if k is Vector2i and (k as Vector2i).y >= cut_row:
					out.append("%s%s" % [key, str(k)])
		elif value is Array:
			for item in (value as Array):
				if item is Vector2i and (item as Vector2i).y >= cut_row:
					out.append("%s%s" % [key, str(item)])
		if out.size() > 6:
			return out
	return out
