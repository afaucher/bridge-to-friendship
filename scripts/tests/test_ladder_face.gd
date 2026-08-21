extends "res://scripts/test_support/test_case.gd"

# THE LADDER IS DRAWN ON ONE SIDE AND CLIMBED ON ANOTHER.
#
# Reported from play of the watchpost: "it renders the ladder on the right side.
# Approaching it snaps you to the front side."
#
# The face is computed TWICE -- once in `BridgeGrid._spawn_ladder` for the rungs
# and once in `PlayerBody._ladder_face` for the body -- and the comment on the
# first one already warns about exactly this: "Same face, same arithmetic, one
# place each. If _ladder_face ever changes, this has to change with it or the
# disagreement comes straight back."
#
# They are NOT the same arithmetic. One compares `cell_surface` (grid-local) and
# the other `cell_surface_world` (world, which carries the bridge's 4 degree
# pitch), and CLAUDE.md already has a note about comparing world-space Y across
# different Z on this pitched plane.
#
# IT NEEDED A TOWER TO SHOW. Every ladder before this sat on a cliff FACE with
# one clearly-lowest neighbour, so both agreed however they measured. A
# free-standing post has THREE neighbours tied at deck level, and then the
# tie-break is the whole answer -- local order picks one, the pitch picks another.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const MAP := "res://segments/test_watchpost.seg"
const LADDER := Vector2i(7, 5)
const PEER := 553311777

var world: Node3D = null
var body: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "LadderFaceWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = [MAP]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _name_of(v: Vector3) -> String:
	for dir in 4:
		if GridConfig.DIR_VECTORS[dir].distance_to(v) < 0.01:
			return ["north", "east", "south", "west"][dir]
	return str(v)

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < 4:
		return
	done = true

	# WHAT THE BODY WILL DO: the climb's own answer.
	var climbed: Vector3 = body._ladder_face(LADDER)

	# WHAT THE PLAYER SEES: recovered from the rungs the grid actually built,
	# because the art's face is not exposed -- and reading it back off the node is
	# the only way to compare the thing on screen rather than a second opinion
	# about it.
	var rungs: Node3D = world.grid.get_node_or_null(
		"Ladders/Ladder_%d_%d" % [LADDER.x, LADDER.y])
	if not check(rungs != null, "the grid built rungs for the post"):
		finish()
		return
	var drawn := Vector3(sin(rungs.rotation.y), 0.0, cos(rungs.rotation.y))

	print("[ladder] drawn on the %s face, climbed on the %s face"
		% [_name_of(drawn), _name_of(climbed)])
	for dir in 4:
		var side: Vector2i = LADDER + GridConfig.DIR_CELLS[dir]
		print("[ladder]   %-5s height %d, local y %.2f, world y %.2f"
			% [["north", "east", "south", "west"][dir],
				world.grid.height_at(side),
				world.grid.cell_surface(side).y,
				world.grid.cell_surface_world(side).y])

	_test_you_are_not_snapped_around_the_block(drawn)
	_test_you_can_get_back_down(drawn)
	_test_the_descent_actually_lands(drawn)

	check(drawn.distance_to(climbed) < 0.01,
		"the rungs and the climb agree on which face the ladder is on (drawn %s, "
			% _name_of(drawn)
		+ "climbed %s). Two functions computing one fact is the arrangement the "
			% _name_of(climbed)
		+ "grid's own comment warned about, and they disagree because one measures "
		+ "grid-local height and the other world height on a bridge pitched 4 "
		+ "degrees -- so a tie between deck-level neighbours breaks differently")
	finish()

# --- AND YOU ARE NOT DRAGGED AROUND THE TOWER TO GET TO IT --------------------
#
# Reported from play right after the face was fixed: "you still snap to the
# ladder side when touching any edge of the block". `_ladder_cell` asked only how
# CLOSE the body was, in any of eight surrounding cells, so brushing the far side
# of a free-standing post grabbed the ladder -- and `_step_climb` then pinned the
# body to the face, which is the best part of three metres away.
#
# The grab has to ask the same question the hold answers. Anything else is a
# difference the player gets MOVED by.
func _test_you_are_not_snapped_around_the_block(face: Vector3) -> void:
	var post: Vector3 = world.grid.cell_surface_world(LADDER)
	# The far side, one cell out, at deck level: touching the block, nowhere near
	# the rungs.
	var behind: Vector3 = post - face * (GridConfig.CELL_SIZE * 0.5 + 0.4) 		+ Vector3(0.0, 1.2, 0.0)
	body.position = behind
	body.state = PlayerBody.State.WALK

	var found: Vector2i = body._ladder_cell()
	print("[ladder] standing on the FAR side, _ladder_cell returns %s" % str(found))
	check(found.x < 0,
		"a body against the opposite side of the post does not reach the ladder "
		+ "(got %s). Reaching it there is not a climb, it is a teleport: the hold "
			% str(found)
		+ "pins the body to the FACE, so grabbing from behind moves it around the "
		+ "whole block")

	# AND THE NEAR SIDE STILL WORKS, or the fix is just a ladder nobody can use --
	# the half of the gate that says something is POSSIBLE.
	body.position = post + face * (GridConfig.CELL_SIZE * 0.5 + 0.4) 		+ Vector3(0.0, 1.2, 0.0)
	var near: Vector2i = body._ladder_cell()
	print("[ladder] standing on the FACE side, _ladder_cell returns %s" % str(near))
	check(near == LADDER,
		"while a body on the ladder's own face still reaches it (%s)" % str(near))

# --- AND A LADDER IS NOT A ONE-WAY TRIP ---------------------------------------
#
# Asked for from play: "let's also make sure you can get down off the ladder."
# `_try_grab_ladder` refused any grab from at-or-above the ladder's top, on the
# reasoning that "a ladder is not a handrail: standing on the deck it serves and
# pushing at it should walk". That is right at a CLIFF, where the deck continues
# past the ladder and there is somewhere to walk to. On a free-standing post the
# top IS the ladder cell, so the rule made the tower climb-up-and-jump-off.
func _test_you_can_get_back_down(face: Vector3) -> void:
	var post: Vector3 = world.grid.cell_surface_world(LADDER)

	# Standing on top of the post, pushing OUT over the ladder's own face.
	body.position = post + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0)
	body.state = PlayerBody.State.WALK
	var out_over := Vector2(face.x, face.z).normalized()
	var grabbed: bool = body._try_grab_ladder(out_over)
	print("[ladder] on top pushing over the face: grabbed=%s state=%d y=%.2f"
		% [str(grabbed), body.state, body.position.y])
	check(grabbed and body.state == PlayerBody.State.CLIMB,
		"walking off the top over the ladder's own face starts a climb DOWN "
		+ "rather than a fall -- otherwise a tower is one-way")
	check(body.position.y < post.y + PlayerBody.HALF_HEIGHT,
		"and the body starts below the lip (%.2f against %.2f), or the climb "
			% [body.position.y, post.y + PlayerBody.HALF_HEIGHT]
		+ "reads it as having just arrived at the top and hands it straight back "
		+ "to WALK in the same tick")

	# AND PUSHING ANY OTHER WAY ON TOP STILL WALKS, which is the rule the old
	# blanket refusal was protecting and is worth keeping: a ladder is not a
	# handrail you fall onto by brushing it.
	body.position = post + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0)
	body.state = PlayerBody.State.WALK
	var inward := -out_over
	var wrong_way: bool = body._try_grab_ladder(inward)
	print("[ladder] on top pushing AWAY from the face: grabbed=%s" % str(wrong_way))
	check(not wrong_way,
		"while pushing away from it on top still walks -- the old rule refused "
		+ "every grab from above to stop a ladder acting as a handrail, and that "
		+ "reason survives as the CONDITION rather than as a blanket refusal")

# --- THE ROUND TRIP, RUN RATHER THAN REASONED ---------------------------------
#
# Everything above asks whether the right STATE is entered. That is not the
# claim: the claim is that a player who climbs a post can get off it again, and
# a descent that enters CLIMB and then sticks, or that hands back to WALK still
# eight feet up, satisfies every assertion above. So this one steps the body and
# watches where it ends up.
func _test_the_descent_actually_lands(face: Vector3) -> void:
	var post: Vector3 = world.grid.cell_surface_world(LADDER)
	var deck: float = world.grid.cell_surface_world(
		LADDER + GridConfig.cell_step(face)).y

	body.position = post + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0)
	body.state = PlayerBody.State.WALK
	var out_over := Vector2(face.x, face.z).normalized()
	if not check(body._try_grab_ladder(out_over), "the descent starts"):
		return

	# AND THEN PULL BACK, WHICH IS A DIFFERENT INPUT FROM THE ONE THAT GRABBED.
	#
	# Worth knowing rather than discovering: the grab is DIRECTIONAL -- you step
	# off the edge the ladder is on -- while the climb's vertical axis is the
	# stick's forward/back, by the convention `_step_climb` states ("away from the
	# camera is up"). On an east-facing ladder those are different axes, so a
	# player steps on by pushing east and descends by pulling back, and holding
	# east on the rungs does nothing. The first draft of this test held the grab
	# direction for 240 ticks and the body sat at 4.46 the whole way -- which is
	# the same thing a player would do.
	var started: float = body.position.y
	var down := Vector2(0.0, 1.0)
	for _t in 240:
		if body.state != PlayerBody.State.CLIMB:
			break
		body._step_climb(down)
	print("[ladder] descent: from y %.2f to y %.2f (deck beside the post is %.2f), state %d"
		% [started, body.position.y, deck, body.state])

	check(body.state == PlayerBody.State.WALK,
		"the climb ENDS rather than sticking on the rungs (state %d)" % body.state)
	check(body.position.y < started - 1.0,
		"and the body really came down (%.2f from %.2f)" % [body.position.y, started])
	check(absf(body.position.y - (deck + PlayerBody.HALF_HEIGHT)) < 0.6,
		"and is standing on the deck beside the post (%.2f, deck %.2f) -- not "
			% [body.position.y, deck]
		+ "left hanging partway down, which every state assertion above would "
		+ "have been perfectly happy with")
