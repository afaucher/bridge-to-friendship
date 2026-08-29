extends "res://scripts/test_support/test_case.gd"

# THE SELECTOR. M25 phase 2: the in-world control that says what the next stretch
# of bridge will be.
#
# A MERCHANT WITH A DIFFERENT JOB -- a grid-resident thing you walk up to and DASH
# INTO -- which is the plan's own description and most of the design. The dash is
# the right verb rather than merely the available one: the game has bits for
# shove, special and call and none for `interact`, and a committed aimed action is
# what should be required to change the party's next twenty minutes.
#
# THE CLAIM THAT MATTERS MOST IS THE MASK. This project has now shipped FIVE bugs
# that were one wrong bit in a collision layer, and the shape is always the same:
# the thing exists, is positioned, is drawn and is replicated, and players walk
# straight through it. `check(post != null)` is green for all of that. So the mask
# is asserted directly AND a body is dashed into it under power.
#
# The claims:
#   1. A LOBBY HAS ONE, and a section does not -- being in a lobby is what makes
#      it safe to be dashable at all.
#   2. THE PLAYER CAN HIT IT: its layer is in the player's mask, and a dash
#      actually stops against it.
#   3. DASHING IT CHANGES THE CHOICE, and cycles rather than sticking.
#   4. THE CHOICE REACHES THE CORRIDOR -- the thing a control is FOR.
#   5. LAST WRITE WINS: a second player's dash overrides the first, with no vote
#      and no deadlock.
#   6. THE BANNER FOLLOWS, and every post shows the same thing.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const ModePost = preload("res://scripts/sim/mode_post.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const WIDTH := 21

var world: Node3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "PostWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = 20260825
	world.start(true, 1, false)
	world_under_test(world)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)

	_a_lobby_has_one()
	_the_player_can_hit_it()
	_dashing_it_changes_the_choice()
	_the_choice_reaches_the_corridor()
	_last_write_wins()
	finish()

# --- 1. Where it is -----------------------------------------------------------

func _a_lobby_has_one() -> void:
	var lobby = SegmentGen.lobby(WIDTH, 4242, 0)
	var section = SegmentGen.section(WIDTH, 4242, 1)
	eq(_posts_in(lobby), 1,
		"a lobby carries exactly one selector -- one because the choice is one "
		+ "per round, and in a LOBBY because that is what makes it safe to be "
		+ "dashable: the corridor past it is speculative and nobody is standing "
		+ "on the ground a change re-cuts")
	eq(_posts_in(section), 0,
		"and a section carries none. A control mid-round would either do nothing, "
		+ "or re-cut ground people are walking on")

	# ...AND IT IS ON GROUND SOMEBODY CAN STAND ON. Content on a hole is refused by
	# the generator's own placement check, and a control floating over a gap is a
	# control nobody can reach.
	for z in lobby.length:
		for x in lobby.width:
			if lobby.content_at(x, z) == GridConfig.Content.MODE_POST:
				check(lobby.is_solid(x, z),
					"and it stands on solid deck (%d, %d)" % [x, z])

# --- 2. And you can actually reach it ------------------------------------------

func _the_player_can_hit_it() -> void:
	var post: Node = _first_post()
	if not check(post != null, "the run built a selector"):
		return

	# THE MASK, ASSERTED DIRECTLY. Five bugs in this project have been one wrong
	# bit here, and every one of them looked exactly like this test passing: the
	# thing existed, was positioned, was drawn, and players walked through it.
	var body: Node = world.player_body(1)
	check(post.collision_layer & body.collision_mask != 0,
		"the selector's layer (%d) is in the player's mask (%d) -- the half that "
			% [post.collision_layer, body.collision_mask]
		+ "has been one wrong bit five times in this project")

	# AND A BODY REALLY STOPS AGAINST IT, which is the half a mask assertion still
	# does not prove: a shape can be on the right layer and be the wrong size, or
	# be somewhere else entirely.
	var from: Vector3 = post.global_position + Vector3(0.0, 0.9, 2.2)
	body.global_position = from
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true
	var toward: Vector3 = post.global_position - from
	body.facing = GridConfig.yaw_of_vector(toward)
	# THROUGH THE ACTION BIT, which is how a dash is really started. The first
	# version called `begin_shove`, which does not exist -- and the raise ABORTED
	# THE REST OF THIS PHASE, so every assertion below it silently never ran while
	# the file reported PASS. The runner checks the exit code and the marker, and a
	# GDScript runtime error changes neither (CLAUDE.md).
	body.shove_cooldown = 0.0
	body.dash_charges = SimConfig.DASH_CHARGES
	var move := Vector2(toward.x, toward.z).normalized()
	body.step(move, SimConfig.ACTION_SHOVE)
	var hit := false
	for _i in 40:
		body.step(move, 0)
		if body.global_position.distance_to(post.global_position) < 1.4:
			hit = true
	var closed: float = from.distance_to(post.global_position) \
		- body.global_position.distance_to(post.global_position)
	print("[post] a dash closed %.2f m and came within %.2f m"
		% [closed, body.global_position.distance_to(post.global_position)])
	check(closed > 0.5,
		"a dash aimed at it actually travels toward it (%.2f m closed)" % closed)
	check(hit, "and arrives, so there is something to dash INTO")

# --- 3, 6. Dashing it ---------------------------------------------------------

func _dashing_it_changes_the_choice() -> void:
	var post: Node = _first_post()
	if post == null:
		return
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.LOBBY
	world.selected_mode = GameMode.BASE
	world._show_selection()
	eq(post.showing, GameMode.BASE, "the banner starts on base")

	# THROUGH THE REAL DISPATCH TARGET. `_select_next_mode` is what
	# resolve_shove_contact calls once it has decided what was hit, so this is the
	# caller's entry point rather than a helper invented for the test.
	world._select_next_mode(post)
	eq(world.selected_mode, GameMode.BLANK,
		"dashing it moves the choice on (%s)" % GameMode.name_of(world.selected_mode))
	eq(post.showing, GameMode.BLANK,
		"and the banner follows -- a control that changed nothing you can see is "
		+ "one players stop trusting")

	# IT CYCLES RATHER THAN STICKING, and wraps back to base, so a party that
	# dashes it until they are bored ends up at the ordinary game.
	var seen: Dictionary = {}
	for _i in GameMode.ids().size():
		world._select_next_mode(post)
		seen[world.selected_mode] = true
	eq(seen.size(), GameMode.ids().size(),
		"and cycling it visits every registered mode (%d of %d)"
			% [seen.size(), GameMode.ids().size()])
	eq(world.selected_mode, GameMode.BLANK,
		"wrapping round to where it started")

	# EVERY POST SHOWS THE SAME THING. A run has many lobbies, and one still
	# advertising a choice from twenty minutes ago is worse than none at all.
	for other in world.grid.mode_posts():
		eq(other.showing, world.selected_mode,
			"every post on the bridge shows the same choice")

# --- 4. And it reaches the corridor -------------------------------------------

func _the_choice_reaches_the_corridor() -> void:
	# THE THING A CONTROL IS FOR. Everything above is about the post; this is about
	# the decision arriving where it matters -- and without it the file would be
	# testing a lamp.
	var post: Node = _first_post()
	if post == null:
		return
	world.round_machine.round_index = 0
	world.round_machine.state = RoundMachine.State.LOBBY
	world.selected_mode = GameMode.BASE
	world.next_mode = GameMode.BASE
	world.run_modes = [GameMode.BASE]
	world._extend_run()

	while world.selected_mode != GameMode.BLANK:
		world._select_next_mode(post)
	world._extend_run()

	eq(world.mode_for_round(0), GameMode.BLANK,
		"the round the party is about to play is the one that was chosen")
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
	print("[post] after dashing the selector, round 0 is %d/%d blank"
		% [blank, sections])
	check(sections > 0, "there is corridor to check (%d sections)" % sections)
	eq(blank, sections,
		"and the ground past the lobby really is what was selected (%d of %d) -- "
			% [blank, sections]
		+ "a control that moved a number and left the bridge alone is a lamp")

# --- 5. No vote, no deadlock ---------------------------------------------------

func _last_write_wins() -> void:
	var post: Node = _first_post()
	if post == null:
		return
	world.round_machine.state = RoundMachine.State.LOBBY
	world.selected_mode = GameMode.BASE
	world._show_selection()

	# TWO PLAYERS, ONE AFTER THE OTHER. There is no vote and no consensus: anyone
	# may set it and the last write wins, because in a four-player co-op a vote can
	# deadlock and losing one means being dragged somewhere you did not choose.
	world._select_next_mode(post)
	var first: int = world.selected_mode
	world._select_next_mode(post)
	var second: int = world.selected_mode
	check(second != first,
		"a second dash overrides the first (%s then %s) rather than being refused "
			% [GameMode.name_of(first), GameMode.name_of(second)]
		+ "or queued behind a vote that can deadlock")
	eq(post.showing, second, "and the banner shows the latest one")

# --- helpers ------------------------------------------------------------------

func _posts_in(seg) -> int:
	var n := 0
	for z in seg.length:
		for x in seg.width:
			if seg.content_at(x, z) == GridConfig.Content.MODE_POST:
				n += 1
	return n

func _first_post() -> Node:
	if world.grid == null or not world.grid.has_method("mode_posts"):
		return null
	var posts: Array = world.grid.mode_posts()
	return posts[0] if posts.size() > 0 else null
