extends Node3D

# The simulated world, and the only thing that decides what is true.
#
# ONE INSTANCE PER MACHINE. On the host it runs the authoritative simulation for
# every player and broadcasts the result. On a client it predicts the local
# player only, and takes everything else from the host.
#
# It deliberately does NOT use the NetworkManager autoload. Everything here goes
# through `multiplayer`, which for a Node resolves to whichever MultiplayerAPI
# owns its subtree -- so two GameWorlds can live in one process under two
# different multiplayer roots and genuinely play against each other over a
# socket. That is what makes the authority model testable in the gate.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")
const BridgeCameraScript = preload("res://scripts/ui/bridge_camera.gd")
const BallScene = preload("res://scenes/plinko_ball.tscn")
const RusherScene = preload("res://scenes/rusher.tscn")
const RusherBody = preload("res://scripts/sim/rusher_body.gd")
const SceneLighting = preload("res://scripts/ui/scene_lighting.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const AimSource = preload("res://scripts/sim/aim_source.gd")

signal player_spawned(peer_id: int)
signal player_despawned(peer_id: int)

# Snapshot entry layout. Named because a bare e[3] in the reconciler is how a
# field silently ends up read as the wrong thing.
const S_PEER := 0
const S_STATE_BLOB := 1
const S_ACKED_INPUT := 2

@export var level_scene_path: String = "res://scenes/gym.tscn"

# When non-empty, the level is a bridge built from these .seg files instead of
# the gym scene. Leave it empty and set `run_seed` to assemble a run from the
# pool instead -- which is what a real session does.
var segment_paths: Array = []

# Assemble the level from the pool rather than from a fixed list. An explicit
# flag, not "segment_paths is empty", because seed 0 is a perfectly good seed and
# a level with no segments is not the same thing as the gym.
var assemble_run: bool = false

# The seed a run is assembled from. The bridge is a pure function of this and the
# segment count, so a client is told two numbers rather than a world.
var run_seed: int = 0

var is_host: bool = false
var local_peer: int = 1
var networked: bool = false
var running: bool = false
var tick: int = 0

var players: Dictionary = {}
var grid: Node3D = null
var camera: Camera3D = null

# Display names, keyed by peer id. Host-owned and pushed out reliably; a peer
# that has not announced one falls back to default_player_name().
#
# It lives HERE and not on NetworkManager because of how the gate is wired: the
# net harness gives each world its own SceneMultiplayer rooted at its own node,
# so an RPC on the /root autoload would travel over the default (peerless)
# MultiplayerAPI and could never be exercised by a test. Riding the world's own
# multiplayer means name replication is tested by the same rig as everything
# else.
var player_names: Dictionary = {}

# True on the world a human is looking at. False for headless test worlds and for
# every world the net harness stands up, so they do not fight over the viewport's
# single `current` camera.
var view_active: bool = false

# Tests and tools drive the sim by supplying inputs instead of a keyboard. When
# set, called as input_provider.call(tick) -> [tick, move, actions]. It feeds the
# SAME path a human's input takes, so a test cannot exercise movement code the
# game does not use.
var input_provider: Callable = Callable()

# Per-peer input, keyed by peer id, for peers this machine drives directly:
# tests today, and local second players or bots later. Takes precedence over
# both the keyboard and the network inbox for that peer.
var scripted_inputs: Dictionary = {}

# Test-only inbound latency, in ticks.
var debug_inbound_delay_ticks: int = 0

# A client that corrects constantly is mispredicting, and the count is the
# cheapest possible signal that a state field is missing from capture_state().
var corrections: int = 0

var _level: Node = null
var _players_root: Node3D = null
var _spawn_index: Dictionary = {}

# --- host-side ---
var _inbox: Dictionary = {}
var _current_input: Dictionary = {}
var _last_input_tick: Dictionary = {}
var _highest_queued: Dictionary = {}
var _next_spawn_index: int = 0

# peer -> seconds left before the drone puts them back. Both a lost player and a
# player whose rescue countdown expired land here; there is one way back.
var _returning: Dictionary = {}

# --- plinko ---
var _balls: Array = []
var _balls_root: Node3D = null
var _shooter_timers: Dictionary = {}   # shooter cell -> seconds until next shot
var _next_ball_id: int = 0

# --- rushers ---
var _rushers: Array = []
var _rushers_root: Node3D = null
# HOST-ASSIGNED AND MONOTONIC, never a creation-order index. A rusher is created
# mid-run by a trigger, so the stone list's "both machines loaded the same
# segments in the same order" trick does not apply -- two clients that woke
# different mounds first would disagree about which rusher is which.
var _next_rusher_id: int = 0

# --- the run ---
var checkpoint_index: int = 0
var checkpoint_row: int = 0
var wipes: int = 0

# project.godot names 3d_physics layer 2 "players"; this is its mask bit.
const PLAYERS_LAYER_BIT := 2

# Where the local human is pointing. Stateful because it remembers which device
# was last used, and holds the last angle when neither is being moved.
var _aim: AimSource = AimSource.new()

# --- client-side ---
var _pending_inputs: Array = []
var _predicted: Array = []
var _delayed_snapshots: Array = []

func _ready() -> void:
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)
	# Balls live in WORLD space, not under the grid: the grid is pitched, and a
	# ball rolls down that pitch under ordinary gravity rather than being carried
	# by the node it hangs off.
	_balls_root = Node3D.new()
	_balls_root.name = "Balls"
	add_child(_balls_root)
	# Rushers too: they walk the deck, so they live in world space and let the
	# pitch be something they climb rather than something that tilts them.
	_rushers_root = Node3D.new()
	_rushers_root.name = "Rushers"
	add_child(_rushers_root)

func start(as_host: bool, peer_id: int, is_networked: bool) -> void:
	is_host = as_host
	local_peer = peer_id
	networked = is_networked
	_build_level()
	running = true
	_announce_name()

func stop() -> void:
	running = false

func _build_level() -> void:
	if _level != null or grid != null:
		return
	if segment_paths.size() > 0 or assemble_run:
		grid = Node3D.new()
		grid.name = "Bridge"
		grid.set_script(BridgeGridScript)
		add_child(grid)
		move_child(grid, 0)
		if segment_paths.size() > 0:
			# An explicit list -- used by tests and by anything pinning a
			# specific map. A run assembled from the pool ignores this.
			for path in segment_paths:
				grid.load_segment_file(path)
		elif is_host:
			# A RUN. Deterministic in the seed, which is the whole reason a
			# joining client can be told two numbers instead of a world.
			#
			# HOST ONLY. A client must not build anything until it has been told
			# which run this is: building eagerly means building from whatever
			# seed it happened to hold (0), and `build_run` only ever APPENDS, so
			# those wrong segments would survive being told the right seed and
			# the two bridges would differ for the rest of the session.
			grid.build_run(run_seed, SimConfig.RUN_INITIAL_SEGMENTS)
		# A bridge is assembled from .seg files, which describe structure and
		# nothing else -- so unlike the gym it has no lighting of its own.
		# Only for a world someone is looking at: a second WorldEnvironment in
		# the same viewport is a warning and a coin toss over which one wins.
		if view_active:
			add_child(SceneLighting.build())
		_build_camera(grid.width)
		return
	if level_scene_path == "":
		return
	var packed := load(level_scene_path) as PackedScene
	if packed == null:
		printerr("[GameWorld] could not load level: ", level_scene_path)
		return
	_level = packed.instantiate()
	_level.name = "Level"
	add_child(_level)
	# Ahead of the players in the tree so its static bodies are registered with
	# the physics server before anything is asked to stand on them.
	move_child(_level, 0)
	_build_camera(GridConfig.DEFAULT_WIDTH)

# The one camera: fixed yaw, 45 degrees, the whole bridge across, tracking only
# along the bridge. See scripts/ui/bridge_camera.gd for why each of those is
# load-bearing rather than a preference.
func _build_camera(bridge_width: int) -> void:
	if camera != null:
		return
	camera = Camera3D.new()
	camera.name = "BridgeCamera"
	camera.set_script(BridgeCameraScript)
	camera.bridge_width_cells = bridge_width
	add_child(camera)
	# Only a world someone is actually looking at takes the viewport. Headless
	# test worlds -- and the several the net harness stands up at once -- would
	# otherwise fight over `current`, which is a per-viewport exclusive flag.
	if view_active:
		camera.current = true

# --- Tick ---------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not running:
		return
	if is_host:
		_host_tick()
	else:
		_client_tick()

func _host_tick() -> void:
	tick += 1

	for peer_key in players.keys():
		var peer: int = int(peer_key)
		if scripted_inputs.has(peer):
			# A test (later: a bot, or a second local player) driving this peer
			# directly. Same path a keyboard takes -- the point is that nothing
			# gets a private movement code path.
			var provider: Callable = scripted_inputs[peer]
			_current_input[peer] = provider.call(tick)
			_last_input_tick[peer] = tick
		elif peer == local_peer:
			_current_input[peer] = _gather_local_input(tick)
			_last_input_tick[peer] = tick
		else:
			_consume_remote_input(peer)

	# Stones move BEFORE players, so a player standing on a sliding stone
	# inherits this tick's motion rather than last tick's.
	if grid != null:
		grid.step_stones()

	var order: Array = _carry_order()

	# Who is currently being stood on. A CARRIER MUST NOT BE BLOCKED BY ITS OWN
	# RIDER: two kinematic bodies block each other, and a rider is in permanent
	# contact with its carrier, so the carrier's sweep collides with the thing
	# standing on it and it cannot walk at all. Measured 2026-08-08: a carrier
	# with a rider held velocity 6 m/s and moved 0.2 mm, forever, which reads as
	# "walking is broken" rather than "something is standing on me".
	#
	# Godot's add_collision_exception_with is MUTUAL in effect, so using one here
	# makes the rider fall through its carrier -- it alternated grounded/not and
	# both bodies moved at half speed. Dropping the players bit from the
	# CARRIER's mask for the duration of its own step is asymmetric, which is
	# what this needs: the rider keeps its own mask and can still stand on
	# anything, so stacks deeper than two still work.
	var carriers: Dictionary = {}
	for peer in order:
		var c: Node = players[peer].carrier
		if c != null:
			carriers[c] = true

	for peer in order:
		var body: Node = players[peer]
		# Transporting the rider is Godot's job (see player_body._ready). The
		# carrier probe is still needed here for the mask exclusion below, and
		# the carrier-before-rider order is kept because it is what the explicit
		# ride() path would need if we swap back.
		var inp: Array = _current_input.get(peer, PlayerInput.empty(0))

		var restore_mask: int = body.collision_mask
		if carriers.has(body):
			body.collision_mask = restore_mask & ~PLAYERS_LAYER_BIT
		body.step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS], PlayerInput.aim_of(inp))
		body.collision_mask = restore_mask

	_process_run()
	_process_plinko()
	# Before the rescue pass: a rusher can tumble someone into a hole, and the
	# rescue pass is what notices they left the world. Running it after means the
	# consequence lands on the same tick as the cause rather than the next one.
	_process_rushers()
	_process_rescue()
	_process_hearts()

	if tick % SimConfig.SNAPSHOT_INTERVAL_TICKS == 0:
		_broadcast_snapshot()

# --- The run: lookahead, checkpoints, wipes, and the leash --------------------

func _process_run() -> void:
	if grid == null:
		return
	_extend_run()
	_bank_checkpoint()
	_check_wipe()
	_apply_leash()

# The bridge is endless; it is just built lazily. Keep a couple of segments ahead
# of whoever is furthest up, and tell clients so they build the same thing.
func _extend_run() -> void:
	# Only a world that ASSEMBLED its level may extend it. A world pinned to an
	# explicit segment list is pinned on purpose -- appending pool segments to it
	# was caught only by the width guard refusing to join a 15-cell segment to a
	# 30-cell bridge, which is a guard doing someone else's job.
	if not assemble_run:
		return
	var lead_segment: int = _segment_of(_front_position().z)
	var wanted: int = lead_segment + 1 + SimConfig.RUN_LOOKAHEAD_SEGMENTS
	if wanted <= grid.segment_count():
		return
	grid.build_run(grid.run_seed, wanted)
	if networked:
		_extend_run_to.rpc(grid.run_seed, wanted)

# Which segment a world-space z falls in. Segments vary in length, so this walks
# rather than dividing.
func _segment_of(world_z: float) -> int:
	var cell: Vector2i = grid.cell_of_world(Vector3(0.0, 0.0, world_z))
	return grid.segment_index_of_row(cell.y)

func _front_position() -> Vector3:
	var best: Vector3 = Vector3.ZERO
	var found := false
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if not found or body.position.z < best.z:
			best = body.position
			found = true
	return best

# Progress banks every few segments. What is stored is the CELL ROW, not a
# position, so a restart puts everyone back on authored deck rather than at
# whatever coordinate somebody happened to be standing at.
func _bank_checkpoint() -> void:
	var lead_segment: int = _segment_of(_front_position().z)
	var reached: int = lead_segment / SimConfig.CHECKPOINT_EVERY_SEGMENTS
	if reached > checkpoint_index:
		checkpoint_index = reached
		checkpoint_row = grid.first_row_of_segment(reached * SimConfig.CHECKPOINT_EVERY_SEGMENTS)

# A WIPE is everyone out at once -- downed, hanging, or waiting on the drone.
# Nothing else can end a run: the drone always brings people back, so "everyone
# is out simultaneously" is the only moment where the party has actually lost
# ground rather than lost a player.
# A WIPE IS WHEN NOBODY HAS A CHANCE LEFT, not when nobody is standing.
#
# It used to count `is_awaiting_rescue()` -- which includes LEDGE_HANG -- so it
# fired at the exact moment rescue became POSSIBLE rather than when it became
# impossible. Playtest found the sharp end of that: catch a lip as the last
# player up, and the run restarts on the same tick you grabbed it. Solo it was
# every failure, so a lone player could never reach the 8 s hang timer or see a
# drone at all.
#
# Only `_returning` counts now: a player waiting on the drone has already spent
# their hang or their bleed-out and nobody can reach them. Everyone in that state
# means the party really has lost ground, and the checkpoint restart is a kinder
# outcome than drones dribbling four people back to the bridge entry one at a
# time -- which is the only thing this rule is really for.
#
# It costs a fully-downed party the full 15 s before the restart. Accepted
# deliberately: the alternative denies a hanging player the window their state
# exists to give them, and that window is the whole co-op rescue.
#
# NO SPECIAL CASE FOR A PARTY OF ONE. A solo hang runs its timer, drops, and then
# wipes, exactly like any other -- the grab delays the restart instead of causing
# it. A lone player still has no way out of a hang, which is by design: hanging
# is a co-op state and solo is a practice mode.
func _check_wipe() -> void:
	if players.is_empty():
		return
	for peer_key in players.keys():
		if not _returning.has(int(peer_key)):
			return
	_restart_at_checkpoint()

func _restart_at_checkpoint() -> void:
	wipes += 1
	_returning.clear()
	for ball in _balls:
		if is_instance_valid(ball):
			ball.queue_free()
	_balls.clear()
	# Rushers go with them. A wipe rewinds the party to a checkpoint, and leaving
	# the thing that killed them still standing where they respawn is a loop, not
	# a setback. Mounds stay SPENT, though: the ground the party already fought
	# over does not reload with it.
	for rusher in _rushers:
		if is_instance_valid(rusher):
			rusher.queue_free()
	_rushers.clear()

	var lane := 0
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		var cell := Vector2i(grid.entry_spawn_cell(lane).x, checkpoint_row + 1)
		# A wipe is the one place health comes back in full -- the run has already
		# taken the ground back, which is the cost.
		body.respawn_at(grid.cell_surface_world(cell) + Vector3(0.0, 1.2, 0.0),
			SimConfig.MAX_HEALTH)
		lane += 1

# Nobody gets left behind far enough that the party stops being a party. Under
# SOFT nothing happens at all; past it a straggler is helped along; past HARD
# they are simply moved, because at that range they are off everyone's screen and
# cannot be helped by anyone.
func _apply_leash() -> void:
	if players.size() < 2:
		return
	var front: Vector3 = _front_position()
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if body.is_awaiting_rescue() or _returning.has(peer):
			continue
		var behind: float = body.position.z - front.z      # +Z is down-bridge
		if behind > SimConfig.LEASH_HARD:
			body.position = front + Vector3(1.6, 1.0, 4.0)
			body.velocity = Vector3.ZERO
		elif behind > SimConfig.LEASH_SOFT and body.state == PlayerBody.State.WALK:
			# A gentle hand forward, not a tow. A leash you can feel dragging you
			# is worse than one you cannot.
			body.velocity.z -= SimConfig.LEASH_ASSIST * SimConfig.TICK_DELTA

@rpc("authority", "call_remote", "reliable")
func _extend_run_to(seed_value: int, wanted: int) -> void:
	if grid != null:
		grid.build_run(seed_value, wanted)

# --- Plinko -------------------------------------------------------------------
#
# The world fires and simulates; the grid only draws the shooters. A ball is
# authoritative gameplay -- it does damage -- so it belongs on the same side of
# the line as momentum transfer.

func _process_plinko() -> void:
	if grid == null:
		return
	_fire_shooters()

	for i in range(_balls.size() - 1, -1, -1):
		var ball: Node = _balls[i]
		if not is_instance_valid(ball):
			_balls.remove_at(i)
			continue
		ball.step()
		if ball.is_spent():
			_balls.remove_at(i)
			ball.queue_free()
			continue
		_resolve_ball_hits(ball)

func _fire_shooters() -> void:
	for cell in grid.shooter_cells:
		var due: float = float(_shooter_timers.get(cell, _initial_shooter_delay(cell)))
		due -= SimConfig.TICK_DELTA
		if due <= 0.0:
			due = SimConfig.PLINKO_FIRE_INTERVAL
			_launch_ball(cell)
		_shooter_timers[cell] = due

# Stagger the first shot per shooter so a row of them does not fire in unison
# forever. Derived from the cell rather than random, so it is the same on every
# machine and in every run.
func _initial_shooter_delay(cell: Vector2i) -> float:
	var spread: float = float((cell.x * 7 + cell.y * 3) % 10) / 10.0
	return SimConfig.PLINKO_FIRE_INTERVAL * (0.2 + spread * 0.8)

func _launch_ball(cell: Vector2i) -> void:
	if _balls.size() >= SimConfig.PLINKO_MAX_BALLS:
		return
	var ball: Node3D = BallScene.instantiate()
	_next_ball_id += 1
	ball.ball_id = _next_ball_id
	ball.name = "Ball_%d" % _next_ball_id
	_balls_root.add_child(ball)
	_balls.append(ball)
	ball.set_simulated(true)
	ball.launch(grid.shooter_muzzle(cell), _launch_direction())

# THE ONLY RANDOMISATION: the angle. Straight up, tilted by up to
# PLINKO_CONE_DEG, in any direction. Speed is fixed, so every arc is the same
# size and the field has a rhythm a player can learn -- see plinko.md.
func _launch_direction() -> Vector3:
	var tilt: float = deg_to_rad(randf() * SimConfig.PLINKO_CONE_DEG)
	var azimuth: float = randf() * TAU
	return Vector3(sin(tilt) * cos(azimuth), cos(tilt), sin(tilt) * sin(azimuth)).normalized()

# Resolved by PROXIMITY rather than from a collision list, so it happens in one
# place and once. The ball also collides physically, which is what makes it
# bounce off you; this is only the gameplay consequence.
func _resolve_ball_hits(ball: Node) -> void:
	if ball.hit_cooldown > 0.0:
		return
	var reach: float = SimConfig.BALL_RADIUS + 0.5
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body.is_awaiting_rescue() or _returning.has(int(peer_key)):
			continue
		if body.position.distance_to(ball.position) > reach + PlayerBody.HALF_HEIGHT:
			continue

		# A DASHING PLAYER BATS IT AWAY. No damage, and the dash carries on --
		# unlike a dash into a stone or a player, which ends on contact. It gives
		# the shove a third job and makes the most committed action a defensive
		# one.
		if body.state == PlayerBody.State.SHOVE:
			ball.deflect(GridConfig.yaw_vector(body.shove_yaw))
			return

		if body.invulnerable > 0.0:
			continue

		# A ball has to still be MOVING, and moving toward you, to hurt.
		#
		# Two separate questions, deliberately not combined into one. SPEED is the
		# ball's own -- not the relative speed, because a ball that has stopped is
		# not made dangerous by you walking into it. DIRECTION is only a sign
		# test: is it coming at me at all.
		#
		# Projecting the velocity onto the ball-to-player line and thresholding
		# THAT was the first attempt and it was wrong twice over: the line runs
		# from a ball 0.6 m off the deck to a body centre 0.9 m up, so a ball
		# rolling flat at you scored well under its real speed; and a ball
		# dropping onto you from a shooter's arc scored almost nothing at all,
		# despite arriving with the most energy of anything in the game.
		var toward: Vector3 = body.position - ball.position
		if ball.linear_velocity.length() < SimConfig.PLINKO_MIN_HIT_SPEED:
			continue
		if ball.linear_velocity.dot(toward) <= 0.0:
			continue          # rolling away; it has had its go

		# Otherwise: every ball that connects tumbles you. One outcome, and no
		# invisible threshold inside the dangerous range.
		var along := Vector3(ball.linear_velocity.x, 0.0, ball.linear_velocity.z)
		if along.length_squared() < 0.01:
			along = Vector3(0.0, 0.0, 1.0)
		along = along.normalized()
		body.take_damage(SimConfig.PLINKO_DAMAGE)
		body.begin_tumble(Vector3(
			along.x * SimConfig.PLINKO_KNOCKBACK,
			SimConfig.PLINKO_KNOCKBACK_LIFT,
			along.z * SimConfig.PLINKO_KNOCKBACK))
		ball.hit_cooldown = SimConfig.PLINKO_HIT_COOLDOWN
		return

func ball_count() -> int:
	return _balls.size()

# --- Rushers ------------------------------------------------------------------
#
# The first DESTRUCTIBLE hazard. See design_ideas/hazards.md; the body's own
# behaviour is in rusher_body.gd. This is the part that only the host may do:
# deciding when a mound wakes, who each rusher is chasing, and what a contact
# costs. A client is told the results and invents none of them.
func _process_rushers() -> void:
	if not is_host:
		return
	_wake_mounds()

	for i in range(_rushers.size() - 1, -1, -1):
		var rusher: Node = _rushers[i]
		if not is_instance_valid(rusher):
			_rushers.remove_at(i)
			continue

		# Target chosen HERE, per tick, because it is a host decision. Re-picked
		# rather than locked on: a rusher that kept chasing someone who has since
		# been carried off by a drone is a rusher chasing a corpse.
		var target: Node = _nearest_target(rusher)
		rusher.target_peer = int(target.peer_id) if target != null else 0
		rusher.step(target.position if target != null else Vector3.ZERO, target != null)

		if rusher.is_spent():
			_rushers.remove_at(i)
			rusher.queue_free()
			continue

		_resolve_rusher_contact(rusher)

# A player within RUSHER_TRIGGER_RADIUS wakes the mound they are standing near.
# Deliberately proximity and not a collision: the mound has no collider, because
# a lump you can bump into is a wall, and the trigger has to be able to fire on a
# player who merely walked PAST rather than onto it.
func _wake_mounds() -> void:
	if grid == null:
		return
	if _rushers.size() >= SimConfig.RUSHER_MAX:
		return
	# A COPY of the keys: take_mound() erases from the dictionary being iterated.
	for cell in grid.mound_cells():
		var at: Vector3 = grid.mound_surface_world(cell)
		for peer_key in players.keys():
			var body: Node = players[int(peer_key)]
			# Someone hanging off a lip or already down cannot trip anything --
			# waking a rusher onto a player who has no verbs left is a punishment
			# with no decision in it.
			if body.is_awaiting_rescue() or _returning.has(int(peer_key)):
				continue
			if body.position.distance_to(at) > SimConfig.RUSHER_TRIGGER_RADIUS:
				continue
			# The same sight test that gates the chase gates the WAKE. Otherwise a
			# player walking past on the far side of a pillar spends the mound on a
			# rusher that rises with nobody to run at, stands still for ten seconds
			# and burrows -- an authored hazard consumed without ever being one.
			if not _clear_line(to_global(at), body.global_position):
				continue
			if grid.take_mound(cell):
				_spawn_rusher(at)
				# A mound changes state exactly ONCE in its life, so this is a
				# discrete event and goes reliably -- unlike the rusher itself,
				# which rides the unreliable per-tick snapshot. Losing this packet
				# would leave a client drawing a lump that is not there, forever,
				# and nothing later would correct it.
				if networked:
					_mound_taken.rpc(cell.x, cell.y)
			break

func _spawn_rusher(at: Vector3) -> Node:
	var rusher: Node3D = RusherScene.instantiate()
	_next_rusher_id += 1
	rusher.rusher_id = _next_rusher_id
	rusher.name = "Rusher_%d" % _next_rusher_id
	_rushers_root.add_child(rusher)
	_rushers.append(rusher)
	rusher.begin_rise(at)
	return rusher

# Nearest player who can actually be chased. Someone hanging, downed or in
# transit is not a target: the rusher would stand over them running on the spot,
# which looks like a bug and is a hit nobody could have avoided.
#
# AND IT MUST BE ABLE TO SEE THEM. Without that, a rusher with no pathfinding
# walks into the near side of a pillar and grinds there for its whole lifetime --
# the straight line that makes it cheap also makes it stupid, and a hazard that
# is visibly stuck stops being threatening. With it, breaking line of sight
# becomes a real answer, and it is the one that pairs with the burrow timer:
# get something solid between you and it, and outliving it is a plan rather than
# a hope.
#
# A rusher that can see nobody simply STANDS THERE. It does not wander or guess:
# guessing needs a search behaviour, which is the pathfinding this design bought
# its way out of.
func _nearest_target(rusher: Node) -> Node:
	var best: Node = null
	var best_distance := INF
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if body.is_awaiting_rescue() or _returning.has(peer):
			continue
		var d: float = body.position.distance_to(rusher.position)
		if d >= best_distance:
			continue
		if not _can_see(rusher, body):
			continue
		best_distance = d
		best = body
	return best

# Deck, parapets and pillars block sight; players do not. Hiding BEHIND A FRIEND
# would make the friend a shield, which is a mechanic this game has not decided
# to have -- and the one it does have for that is the shove.
const SIGHT_BLOCKERS := 1 | 4        # world | stones

func _can_see(rusher: Node, body: Node) -> bool:
	return _clear_line(rusher.global_position, body.global_position)

# GLOBAL positions, not local. Two GameWorlds in one process share a single
# physics space (the test harness offsets them by a kilometre precisely because
# of this), so a ray cast in world-local coordinates would be cast through
# whichever world happens to sit at the origin.
func _clear_line(from_global: Vector3, to_global: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(from_global, to_global, SIGHT_BLOCKERS)
	# Neither a player nor a rusher is on a layer this mask covers, so neither can
	# occlude itself or the other.
	return space.intersect_ray(query).is_empty()

# What a rusher does when it reaches somebody -- and what a dashing player does
# to it. Resolved here, by proximity, for the same reason ball hits are: the
# outcome is a game rule, not a physics response, and it has to be decided in one
# place and once.
func _resolve_rusher_contact(rusher: Node) -> void:
	if not rusher.is_dangerous():
		return
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body.is_awaiting_rescue() or _returning.has(int(peer_key)):
			continue
		if body.position.distance_to(rusher.position) > SimConfig.RUSHER_HIT_RADIUS + PlayerBody.HALF_HEIGHT:
			continue

		# A DASHING PLAYER WINS THE EXCHANGE. Checked before the hit, so the two
		# can never both happen -- and it is the free answer available to
		# everyone, which is what keeps a weaponless player from being stranded.
		if body.state == PlayerBody.State.SHOVE:
			rusher.deflect(GridConfig.yaw_vector(body.shove_yaw))
			return

		# Otherwise it reaches you: tumble, one hit point, and it is SPENT.
		# Expending itself is the whole reason a single rusher cannot chain-tumble
		# someone who is already out of control and has no way to answer.
		var along := Vector3(rusher.velocity.x, 0.0, rusher.velocity.z)
		if along.length_squared() < 0.0001:
			along = (body.position - rusher.position)
			along.y = 0.0
		if along.length_squared() < 0.0001:
			along = Vector3(0.0, 0.0, 1.0)
		along = along.normalized()

		body.take_damage(SimConfig.RUSHER_DAMAGE)
		body.begin_tumble(Vector3(
			along.x * SimConfig.RUSHER_KNOCKBACK,
			SimConfig.RUSHER_KNOCKBACK_LIFT,
			along.z * SimConfig.RUSHER_KNOCKBACK))
		_kill_rusher(rusher)
		return

func _kill_rusher(rusher: Node) -> void:
	var index: int = _rushers.find(rusher)
	if index >= 0:
		_rushers.remove_at(index)
	if is_instance_valid(rusher):
		rusher.queue_free()

func rusher_count() -> int:
	return _rushers.size()

@rpc("authority", "call_remote", "reliable")
func _mound_taken(cx: int, cz: int) -> void:
	if grid != null:
		grid.take_mound(Vector2i(cx, cz))

# Drop-in: the newcomer built the bridge from the seed, so it has every mound
# including the ones this run already used up.
@rpc("authority", "call_remote", "reliable")
func _sync_spent_mounds(layout: PackedInt32Array) -> void:
	if grid != null:
		grid.apply_spent_mounds(layout)

# --- Rescue: one countdown, two states, one drone -----------------------------
#
# LEDGE_HANG and DOWNED are the same situation wearing different hats -- immobile,
# no verbs, a countdown, a teammate who can end it early, and the drone if nobody
# does. Handled together on purpose: two near-identical implementations would
# drift apart, and every rule that applies to one applies to the other.
func _process_rescue() -> void:
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]

		# Off the bottom of the world. Not a death -- a setback and a laugh.
		if body.position.y < SimConfig.FALL_KILL_Y and not _returning.has(peer):
			_begin_drone_return(peer)
			continue

		if body.state == PlayerBody.State.LEDGE_HANG:
			_tick_haul(peer, body)
		elif body.state == PlayerBody.State.DOWNED:
			_tick_revive(peer, body)

	_tick_drone_returns()

# Is a teammate on their feet, close enough to help? The same question for both
# rescues, so it is asked in one place.
func _helper_near(peer: int, body: Node) -> bool:
	for other_key in players.keys():
		var other: int = int(other_key)
		if other == peer or _returning.has(other):
			continue
		var helper: Node = players[other]
		# Someone who is themselves hanging or downed cannot help anyone.
		if helper.is_awaiting_rescue():
			continue
		if helper.position.distance_to(body.position) <= SimConfig.REVIVE_RADIUS:
			return true
	return false

# A hanging player is hauled up by a teammate standing at the lip. They still
# cannot get themselves out -- that is the entire point of the state -- but
# "cannot get out AT ALL" is a dead end, and until the rope exists a teammate
# standing right there is the only puller available.
func _tick_haul(peer: int, body: Node) -> void:
	if _helper_near(peer, body):
		body.rescue_progress += SimConfig.TICK_DELTA
		if body.rescue_progress >= SimConfig.LEDGE_HAUL_SECONDS:
			body.mantle()
			return
	else:
		body.rescue_progress = 0.0

	if body.state_timer >= SimConfig.LEDGE_HANG_SECONDS:
		body.release_ledge()

# A downed player is revived by a teammate STANDING WITH THEM.
func _tick_revive(peer: int, body: Node) -> void:
	if _helper_near(peer, body):
		body.rescue_progress += SimConfig.TICK_DELTA
		if body.rescue_progress >= SimConfig.REVIVE_SECONDS:
			body.revive()
			return
	else:
		# Reset rather than pause: wandering off and back should not bank credit.
		body.rescue_progress = 0.0

	if body.state_timer >= SimConfig.DOWNED_SECONDS:
		_begin_drone_return(peer)

func _begin_drone_return(peer: int) -> void:
	if _returning.has(peer):
		return
	_returning[peer] = SimConfig.DRONE_RETURN_SECONDS
	var body: Node = players.get(peer)
	if body != null:
		body.visible = false
		body.velocity = Vector3.ZERO

func _tick_drone_returns() -> void:
	for peer_key in _returning.keys():
		var peer: int = int(peer_key)
		_returning[peer] = float(_returning[peer]) - SimConfig.TICK_DELTA
		if float(_returning[peer]) > 0.0:
			continue
		_returning.erase(peer)
		var body: Node = players.get(peer)
		if body == null:
			continue
		# Never LESS health than you went out with: the drone is a setback and a
		# laugh, not a punishment on top of the fall.
		body.respawn_at(_drone_drop_point(peer), maxi(body.health, SimConfig.REVIVE_HEALTH))

# Dropped NEXT TO A TEAMMATE, which is the whole point -- being returned should
# put you back in the game rather than alone somewhere behind it.
func _drone_drop_point(peer: int) -> Vector3:
	var best: Node = null
	for other_key in players.keys():
		var other: int = int(other_key)
		if other == peer or _returning.has(other):
			continue
		var candidate: Node = players[other]
		# The one furthest up the bridge, so a return never drags the party back.
		if best == null or candidate.position.z < best.position.z:
			best = candidate
	if best != null:
		# BESIDE THEM, ON SOLID DECK. It used to be a blind `+1.6 m in x`, which is
		# beside them but says nothing about what is there -- and 1.6 m sideways
		# from a teammate standing at the edge of a gap is the gap. The drone would
		# then return a player directly into the hole they had just fallen down.
		#
		# Invisible until the ledge grab started working for self-inflicted falls,
		# because a player dropped into a hole was in WALK on the way down and
		# "returned in control" was still technically true. Now they catch the lip
		# and hang, which is at least honest about where they were put.
		#
		# Beside and never ON TOP: coincident bodies depenetrate through the floor
		# (see CLAUDE.md), which is why this steps a whole cell rather than nudging.
		if grid != null:
			var beside: Vector2i = grid.cell_of_world(best.position)
			for dir in 4:
				var side: Vector2i = beside + GridConfig.DIR_CELLS[dir]
				if grid.is_solid(side) and grid.stone_at(side) == null:
					return grid.cell_surface_world(side) + Vector3(0.0, 1.0, 0.0)
		return best.position + Vector3(1.6, 1.0, 0.0)
	if grid != null:
		return grid.cell_surface_world(grid.entry_spawn_cell(0)) + Vector3(0.0, 1.2, 0.0)
	return spawn_point(0)

# --- Hearts -------------------------------------------------------------------
#
# First come, first served -- a thing to communicate about rather than a thing to
# collect. Exclusivity is by construction: the first body found within reach
# takes it and the heart is gone.
func _process_hearts() -> void:
	if grid == null:
		return
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body.is_awaiting_rescue():
			continue
		if grid.try_take_heart(body.position) and body.heal(SimConfig.HEART_HEAL):
			pass

# Peers ordered so that anything being stood on is stepped before whoever is
# standing on it. Otherwise a rider inherits its carrier's PREVIOUS motion and
# visibly slides around on its friend's head.
#
# Stacks are shallow and the party is at most four, so the naive repeated sweep
# beats maintaining a graph.
func _carry_order() -> Array:
	var remaining: Array = players.keys().duplicate()
	var ordered: Array = []
	while remaining.size() > 0:
		var progressed := false
		for i in range(remaining.size() - 1, -1, -1):
			var peer: int = int(remaining[i])
			var carrier: Node = players[peer].carrier
			var carrier_pending := false
			if carrier != null:
				for other_key in remaining:
					if players.get(int(other_key)) == carrier:
						carrier_pending = true
						break
			if not carrier_pending:
				ordered.append(peer)
				remaining.remove_at(i)
				progressed = true
		if not progressed:
			# A carry cycle: physically impossible (two bodies each standing on
			# the other), but looping forever on one is far worse to diagnose
			# than a wrong step order for a single tick.
			for leftover in remaining:
				ordered.append(int(leftover))
			break
	return ordered

func _client_tick() -> void:
	tick += 1
	_release_delayed_snapshots()

	var inp: Array = _gather_local_input(tick)
	_pending_inputs.append(inp)
	_send_input()

	var body: Node = players.get(local_peer)
	if body != null:
		if body.state == PlayerBody.State.WALK:
			body.step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS], PlayerInput.aim_of(inp))
			_predicted.append([tick, body.capture_state()])
		else:
			# COMMITTED ACTIONS ARE NOT PREDICTED. In a shove, a tumble or a
			# rope yank the player has no control, so there is no input to
			# mispredict and nothing to gain -- while the outcome depends on
			# collisions with bodies and stones this machine does not own.
			# Authority drives it. The design's comedy constraint (a shove
			# cannot be steered) and its networking constraint are the same
			# constraint.
			_predicted.clear()

	_trim_history()

func _gather_local_input(for_tick: int) -> Array:
	if input_provider.is_valid():
		return input_provider.call(for_tick)
	return PlayerInput.sample(for_tick, _poll_aim())

# Resolving the aim needs the camera and the local body -- a cursor is a point on
# the screen and the answer wanted is a direction on the deck. Those live here, so
# this half happens here and the answer is handed to the static sampler.
#
# Only the world a human is looking at has an aim: a headless test world has no
# camera, no cursor and no pad, and asking would give it a meaningless one.
func _poll_aim() -> float:
	if not view_active or camera == null:
		return PlayerInput.AIM_NONE
	var body: Node = players.get(local_peer)
	if body == null:
		return PlayerInput.AIM_NONE
	return _aim.poll(camera, body.position)

func _trim_history() -> void:
	while _pending_inputs.size() > SimConfig.HISTORY_TICKS:
		_pending_inputs.pop_front()
	while _predicted.size() > SimConfig.HISTORY_TICKS:
		_predicted.pop_front()

# --- Momentum transfer --------------------------------------------------------

# A dashing player hit something. The WORLD owns this rule, not the body: what a
# shove does to what it hits is a statement about the game, and keeping it in one
# place is what stops it from being re-derived slightly differently per collider.
#
# WHERE THE FREE ANGLE MEETS THE CELL GRID, and the two halves are treated
# differently on purpose.
#
# A PLAYER takes the dash's actual yaw. Bodies move through continuous space, so
# a friend kicked at 20 degrees off north should go 20 degrees off north -- and
# aiming a teammate precisely is now a thing a player can do, which is the point
# of the whole revision.
#
# A STONE snaps to the nearest cardinal, because a stone moves exactly ONE CELL
# and a cell has four neighbours no matter how you were pointing when you hit it.
# There is no 20-degree cell to push it into. That is not a compromise with the
# old scheme; it is the grid being the grid, and the same reason the ledge hang
# keeps a cardinal `hang_dir`.
func resolve_shove_contact(shover: Node, other: Node, yaw: float) -> void:
	# Host only. A client does not simulate its own shove (see _client_tick), so
	# this is defence in depth rather than a live branch.
	if not is_host or other == null or other == shover:
		return
	if other.has_method("receive_shove"):
		other.receive_shove(yaw)
		return
	if grid != null and other.has_method("slide_to"):
		grid.try_push(other.cell, GridConfig.yaw_to_direction(yaw))

# --- Host: consuming client input ---------------------------------------------

func _consume_remote_input(peer: int) -> void:
	var queue: Array = _inbox.get(peer, [])
	if queue.size() > 0:
		var e: Array = queue.pop_front()
		_current_input[peer] = e
		_last_input_tick[peer] = int(e[PlayerInput.TICK])
		return
	# Nothing arrived in time. Repeat the last input and DO NOT advance the ack.
	# Both halves matter: repeating keeps a player walking through a dropped
	# packet instead of stuttering, and holding the ack keeps the client's replay
	# aligned -- acknowledging an input we never applied would make the client
	# discard it and replay from a state the host never reached.

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _submit_input(batch: Array) -> void:
	if not is_host:
		return
	var peer: int = multiplayer.get_remote_sender_id()
	if not players.has(peer):
		return
	var highest: int = int(_highest_queued.get(peer, 0))
	var queue: Array = _inbox.get(peer, [])
	# The batch is oldest-first and overlaps the previous one (see
	# INPUT_REDUNDANCY); take only what is genuinely new, in order.
	for e in batch:
		var t: int = int(e[PlayerInput.TICK])
		if t > highest:
			queue.append(e)
			highest = t
	_inbox[peer] = queue
	_highest_queued[peer] = highest

func _send_input() -> void:
	if not networked:
		return
	var count: int = mini(SimConfig.INPUT_REDUNDANCY, _pending_inputs.size())
	var batch: Array = _pending_inputs.slice(_pending_inputs.size() - count)
	_submit_input.rpc_id(1, batch)

# --- Host: broadcasting state -------------------------------------------------

func _broadcast_snapshot() -> void:
	if not networked:
		return
	var entries: Array = []
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		entries.append([peer, players[peer].capture_state(), int(_last_input_tick.get(peer, 0))])
	var stones: Array = grid.stone_snapshot() if grid != null else []
	# The layout only on a slow cadence -- see BridgeGrid.stone_layout().
	var layout: PackedInt32Array = PackedInt32Array()
	if grid != null and (tick % SimConfig.STONE_RESYNC_TICKS) == 0:
		layout = grid.stone_layout()
	_apply_snapshot.rpc(tick, entries, stones, _ball_snapshot(), layout, _rusher_snapshot())

# Balls are FULLY AUTHORITATIVE and never predicted. The cheap alternative --
# clients simulating them from a shared seed -- is tempting and specifically
# risky: a ball is exactly the thing whose trajectory has to agree, because two
# machines disagreeing about where it is means two machines disagreeing about who
# got hit. A ball is a position and a velocity and there are at most a couple of
# dozen; measure before optimising this.
func _ball_snapshot() -> Array:
	var out: Array = []
	for ball in _balls:
		if is_instance_valid(ball):
			out.append([ball.ball_id, ball.position, ball.linear_velocity])
	return out

# Clients rebuild their ball set to match the host's, creating and freeing to
# suit. Self-healing by construction: a dropped packet costs a frame of staleness
# rather than a ball that exists forever on one machine.
func _apply_ball_snapshot(balls: Array) -> void:
	var seen: Dictionary = {}
	for entry in balls:
		var id: int = int(entry[0])
		seen[id] = true
		var ball: Node = _ball_by_id(id)
		if ball == null:
			ball = BallScene.instantiate()
			ball.ball_id = id
			ball.name = "Ball_%d" % id
			_balls_root.add_child(ball)
			_balls.append(ball)
			# A client is TOLD where a ball is. Left simulating, its own physics
			# would fight the snapshot overwriting it every frame.
			ball.set_simulated(false)
		ball.position = entry[1]
		ball.linear_velocity = entry[2]

	for i in range(_balls.size() - 1, -1, -1):
		var existing: Node = _balls[i]
		if not is_instance_valid(existing) or not seen.has(existing.ball_id):
			_balls.remove_at(i)
			if is_instance_valid(existing):
				existing.queue_free()

func _ball_by_id(id: int) -> Node:
	for ball in _balls:
		if is_instance_valid(ball) and ball.ball_id == id:
			return ball
	return null

# Rushers ride the per-tick snapshot exactly like balls: host-authoritative,
# never predicted. No velocity on the wire -- a client does not integrate one, so
# sending it would be paying MTU for a number nobody reads. See the CLAUDE.md
# note about the 4595-byte snapshot that would not fit ENet's 1392.
func _rusher_snapshot() -> Array:
	var out: Array = []
	for rusher in _rushers:
		if is_instance_valid(rusher):
			out.append(rusher.capture_state())
	return out

# Self-healing by construction, same as the ball set: a dropped packet costs a
# frame of staleness rather than an enemy that exists forever on one machine.
# THIS IS ALSO HOW A CLIENT LEARNS A RUSHER DIED -- it stops being mentioned.
func _apply_rusher_snapshot(rushers: Array) -> void:
	var seen: Dictionary = {}
	for entry in rushers:
		var id: int = int(entry[0])
		seen[id] = true
		var rusher: Node = _rusher_by_id(id)
		if rusher == null:
			rusher = RusherScene.instantiate()
			rusher.rusher_id = id
			rusher.name = "Rusher_%d" % id
			_rushers_root.add_child(rusher)
			_rushers.append(rusher)
		rusher.apply_state(entry)

	for i in range(_rushers.size() - 1, -1, -1):
		var existing: Node = _rushers[i]
		if not is_instance_valid(existing) or not seen.has(existing.rusher_id):
			_rushers.remove_at(i)
			if is_instance_valid(existing):
				existing.queue_free()

func _rusher_by_id(id: int) -> Node:
	for rusher in _rushers:
		if is_instance_valid(rusher) and rusher.rusher_id == id:
			return rusher
	return null

@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_snapshot(server_tick: int, entries: Array, stones: Array, balls: Array,
		layout: PackedInt32Array, rushers: Array) -> void:
	if is_host:
		return
	if debug_inbound_delay_ticks > 0:
		_delayed_snapshots.append([tick + debug_inbound_delay_ticks, entries, stones, balls, layout, rushers])
		return
	_consume_snapshot(entries, stones, balls, layout, rushers)

func _release_delayed_snapshots() -> void:
	while _delayed_snapshots.size() > 0 and int(_delayed_snapshots[0][0]) <= tick:
		var held: Array = _delayed_snapshots.pop_front()
		_consume_snapshot(held[1], held[2], held[3], held[4], held[5])

func _consume_snapshot(entries: Array, stones: Array, balls: Array,
		layout: PackedInt32Array, rushers: Array) -> void:
	if grid != null:
		grid.apply_stone_snapshot(stones)
		if layout.size() > 0:
			grid.apply_stone_layout(layout)
	_apply_ball_snapshot(balls)
	_apply_rusher_snapshot(rushers)
	for e in entries:
		var peer: int = int(e[S_PEER])
		var body: Node = players.get(peer)
		if body == null:
			# The spawn RPC is reliable and will arrive; an unreliable snapshot
			# is allowed to mention a player we have not built yet.
			continue
		if peer == local_peer:
			_reconcile(body, e)
		else:
			# Remote players are pure authority -- no prediction, no
			# extrapolation. Visual interpolation is a later, cosmetic concern;
			# what matters is that a client never invents a position for someone
			# else.
			body.apply_state(e[S_STATE_BLOB])

# --- Client: reconciliation ---------------------------------------------------

func _reconcile(body: Node, e: Array) -> void:
	var acked: int = int(e[S_ACKED_INPUT])
	var authoritative: Array = e[S_STATE_BLOB]

	while _pending_inputs.size() > 0 and int(_pending_inputs[0][PlayerInput.TICK]) <= acked:
		_pending_inputs.pop_front()
	while _predicted.size() > 0 and int(_predicted[0][0]) < acked:
		_predicted.pop_front()

	# In a committed state there was no prediction to compare against -- just
	# take what the host says and start clean.
	if int(authoritative[2]) != PlayerBody.State.WALK:
		body.apply_state(authoritative)
		_predicted.clear()
		return

	# Compare what we predicted for the acked tick against what actually
	# happened. Close enough and the prediction stands and the player sees
	# nothing, which is the common case and the whole point.
	if _predicted.size() > 0 and int(_predicted[0][0]) == acked:
		var predicted_position: Vector3 = _predicted[0][1][0]
		if predicted_position.distance_to(authoritative[0]) <= SimConfig.CORRECTION_EPSILON:
			return

	corrections += 1

	# Rewind to the authoritative frame and replay every input the host has not
	# seen. Because step() is the same function the host ran, and a sim tick is
	# exactly one physics tick, replaying N inputs inside this frame lands where
	# N frames of host simulation will land.
	body.apply_state(authoritative)
	_predicted.clear()
	for pending in _pending_inputs:
		body.step(pending[PlayerInput.MOVE], pending[PlayerInput.ACTIONS], PlayerInput.aim_of(pending))
		_predicted.append([int(pending[PlayerInput.TICK]), body.capture_state()])

# --- Names --------------------------------------------------------------------
#
# Each machine knows only its OWN name, so a client announces itself and the host
# -- which is already the one thing that decides who exists -- republishes the
# whole roster. The dictionary is four entries at most, so pushing all of it on
# every change is cheaper than working out what changed.

func _announce_name() -> void:
	var display: String = _local_display_name()
	if is_host:
		player_names[local_peer] = display
		_broadcast_names()
	elif networked:
		_submit_name.rpc_id(1, display)

func _local_display_name() -> String:
	# Steam persona where there is one; otherwise a name derived from OUR OWN peer
	# id, not from NetworkManager's -- a headless world (and every world the net
	# harness stands up) has no session, so NetworkManager.local_id() is 0 there
	# and every player in the rig would be called the same thing.
	var persona: String = NetworkManager.steam_display_name()
	return persona if persona != "" else default_player_name(local_peer)

@rpc("any_peer", "call_remote", "reliable")
func _submit_name(display: String) -> void:
	if not is_host:
		return
	player_names[multiplayer.get_remote_sender_id()] = display
	_broadcast_names()

func _broadcast_names() -> void:
	if networked:
		_set_names.rpc(player_names)

@rpc("authority", "call_remote", "reliable")
func _set_names(names: Dictionary) -> void:
	if is_host:
		return
	player_names = names.duplicate()

func player_name(peer: int) -> String:
	var stored: String = str(player_names.get(peer, ""))
	return stored if stored != "" else default_player_name(peer)

static func default_player_name(peer: int) -> String:
	if peer >= PRACTICE_PEER_BASE:
		return "Partner %d" % (peer - PRACTICE_PEER_BASE + 1)
	return "Player %d" % peer

# --- Spawning -----------------------------------------------------------------

func host_spawn(peer: int) -> void:
	if not is_host:
		return
	var index: int = _next_spawn_index
	_next_spawn_index += 1
	if networked:
		_spawn_player.rpc(peer, index)
	else:
		_spawn_player(peer, index)

func host_add_peer(peer: int) -> void:
	if not is_host:
		return
	# DROP-IN, FIRST STEP: tell the newcomer what run this is before anything
	# else. The bridge is a pure function of (seed, segment count), so this one
	# message is the entire world -- and everything after it is a diff of what has
	# moved since. Sending the world itself would be orders of magnitude more.
	if grid != null:
		_extend_run_to.rpc_id(peer, grid.run_seed, grid.segment_count())
		# AFTER the run, never before: this names cells that only exist once the
		# newcomer has built the segments holding them. Both are reliable, so the
		# order they are sent in is the order they arrive in.
		_sync_spent_mounds.rpc_id(peer, grid.spent_mound_layout())
	# Catch the newcomer up on everyone already here, THEN announce it. That
	# order matters the moment a spawn carries state: the new peer should know
	# the world before the world knows it.
	for existing_key in players.keys():
		var existing: int = int(existing_key)
		_spawn_player.rpc_id(peer, existing, int(_spawn_index.get(existing, 0)))
	host_spawn(peer)
	# The newcomer needs everyone's name, and it may have announced its own
	# before the host had it in `players`. Republishing here costs one small
	# reliable packet and removes the ordering question entirely.
	_broadcast_names()

func host_remove_peer(peer: int) -> void:
	if not is_host:
		return
	if networked:
		_despawn_player.rpc(peer)
	else:
		_despawn_player(peer)

@rpc("authority", "call_local", "reliable")
func _spawn_player(peer: int, index: int) -> void:
	if players.has(peer):
		return
	var body: Node = PlayerScene.instantiate()
	body.name = "Player_%d" % peer
	body.peer_id = peer
	body.world = self
	body.position = spawn_point(index)
	_players_root.add_child(body)
	players[peer] = body
	_spawn_index[peer] = index
	if not _inbox.has(peer):
		_inbox[peer] = []
	if peer == local_peer and camera != null:
		camera.focus_target = body
	player_spawned.emit(peer)

@rpc("authority", "call_local", "reliable")
func _despawn_player(peer: int) -> void:
	if not players.has(peer):
		return
	players[peer].queue_free()
	players.erase(peer)
	_inbox.erase(peer)
	_current_input.erase(peer)
	_last_input_tick.erase(peer)
	_highest_queued.erase(peer)
	_spawn_index.erase(peer)
	player_names.erase(peer)
	player_despawned.emit(peer)

func spawn_point(index: int) -> Vector3:
	# On a bridge, players enter across the first row -- spread into separate
	# lanes, never stacked. Coincident bodies do not merely overlap: they
	# depenetrate into a degenerate normal and get driven DOWN THROUGH THE FLOOR
	# (see CLAUDE.md).
	if grid != null:
		var surface: Vector3 = grid.cell_surface_world(grid.entry_spawn_cell(index))
		return surface + Vector3(0.0, 1.2, 0.0)
	# The gym has no grid: a ring around the origin.
	var angle: float = TAU * float(index) / 4.0
	return Vector3(cos(angle) * 4.0, 1.5, sin(angle) * 4.0)

# --- Queries (tests and the HUD) ----------------------------------------------

func player_position(peer: int) -> Vector3:
	var body: Node = players.get(peer)
	return body.position if body != null else Vector3.ZERO

func player_state(peer: int) -> int:
	var body: Node = players.get(peer)
	return body.state if body != null else -1

func player_body(peer: int) -> Node:
	return players.get(peer)

# --- Practice partners (solo dev only) ----------------------------------------
#
# Every interesting verb in this game needs two bodies -- shove one player into
# another, stand on them, rope them together -- and none of it can be tried by
# one person without a second body to try it on. Standing up two networked
# clients to check whether a dash feels right is a wildly disproportionate loop.
#
# A practice partner is a real player in every respect: same body, same step(),
# same rules. It simply has nobody sending it input until you switch to it.
# Solo only, because in a networked session peer ids belong to actual peers.

const PRACTICE_PEER_BASE := 1000

func debug_add_practice_player() -> int:
	if networked:
		push_warning("[GameWorld] practice players are solo-only")
		return 0
	var peer: int = PRACTICE_PEER_BASE + players.size()
	host_spawn(peer)
	# Beside whoever is being controlled, so it is immediately in reach --
	# offset, never coincident, or both bodies depenetrate through the floor
	# (see CLAUDE.md).
	var controlled: Node = players.get(local_peer)
	var partner: Node = players.get(peer)
	if controlled != null and partner != null:
		partner.position = controlled.position + Vector3(2.5, 0.0, 0.0)
	return peer

# Hand local input to the next player in the world, and move the camera with it.
# What makes a practice partner useful: dash A into B, switch, and dash B back.
# Hurt the player you are controlling, one hit point, ignoring the grace window
# so repeated presses actually land.
#
# THE STATES WORTH LOOKING AT ARE THE HARDEST TO REACH. Going DOWNED takes five
# separate hits from the only two things in the game that deal damage, and
# falling deals none -- so checking anything about the downed state meant standing
# in a plinko field for a minute and hoping. The bleed-out counter shipped three
# times before anyone could confirm it was on screen, which is a verification
# problem and not a rendering one.
#
# Goes through take_damage(), not straight to begin_downed(), so what it exercises
# is the path the game uses -- including the last hit tipping into DOWNED.
func debug_hurt_controlled() -> String:
	var body: Node = players.get(local_peer)
	if body == null:
		return "No player to hurt."
	body.invulnerable = 0.0
	body.take_damage(1)
	if body.state == PlayerBody.State.DOWNED:
		return "Player %d is DOWNED (%s s)" % [local_peer, body.rescue_seconds_left_text()]
	return "Player %d hurt: %d/%d" % [local_peer, body.health, SimConfig.MAX_HEALTH]

func debug_cycle_control() -> int:
	if networked or players.is_empty():
		return local_peer
	var ids: Array = players.keys()
	ids.sort()
	var index: int = ids.find(local_peer)
	local_peer = int(ids[(index + 1) % ids.size()])
	if camera != null:
		camera.focus_target = players.get(local_peer)
	return local_peer
