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
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const PlayerScene = preload("res://scenes/player.tscn")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const BridgeGridScript = preload("res://scripts/grid/bridge_grid.gd")
const BridgeCameraScript = preload("res://scripts/ui/bridge_camera.gd")
const BallScene = preload("res://scenes/plinko_ball.tscn")
const RusherScene = preload("res://scenes/rusher.tscn")
const RusherBody = preload("res://scripts/sim/rusher_body.gd")
const HatPool = preload("res://scripts/sim/hat_pool.gd")
const SpecialPool = preload("res://scripts/sim/special_pool.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const BulletScene = preload("res://scenes/bullet.tscn")
const RocketScene = preload("res://scenes/rocket.tscn")
const HitboxView = preload("res://scripts/ui/hitbox_view.gd")
const SnapshotDelta = preload("res://scripts/net/snapshot_delta.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const StatRegistry = preload("res://scripts/sim/stat_registry.gd")
const GunnerBody = preload("res://scripts/sim/gunner_body.gd")
const SkirmisherScene = preload("res://scenes/skirmisher.tscn")
const TurretScene = preload("res://scenes/turret.tscn")
const GrenadeScene = preload("res://scenes/grenade.tscn")
const MineScene = preload("res://scenes/mine.tscn")
# The SCRIPT, for its statics. Reading a script-level member through the
# DebugSettings autoload INSTANCE is the trap CLAUDE.md records for enums: it
# raises at runtime and silently aborts the rest of the frame.
const DebugSettingsScript = preload("res://scripts/debug_settings.gd")
const BlastEffect = preload("res://scripts/ui/blast_effect.gd")
const Deployable = preload("res://scripts/sim/deployable.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const HatConfig = preload("res://scripts/hat_config.gd")
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

# Steam ids, peer -> id, riding exactly the channel player_names rides and for
# exactly the same reason. An AVATAR cannot go on the wire -- it is a 64x64 image
# and the snapshot budget is already the thing M13 is about -- but the ID is a
# number, and every machine that can see this player already has their picture in
# Steam's own cache. So the id travels and the picture is fetched locally.
#
# 0 means "no Steam", which is every headless run, every ENet session and every
# CI box. It is the ordinary case, not an error.
var player_steam_ids: Dictionary = {}

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

# THE MAGNITUDE, NOT ONLY THE COUNT, and the distinction decides whether a change
# to the netcode reads as a win or a regression.
#
# A correction that moves the body 2 cm is invisible; one that moves it 2 m is the
# glitch a playtester reports. Interpolating remote players is expected to trade a
# few large corrections for more small ones -- which the COUNT alone would score
# as a regression while the game got better. `_reconcile` already computed this
# distance to decide whether to correct at all, and threw it away.
var correction_metres: float = 0.0
var correction_worst: float = 0.0

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

# --- hats ---
#
# The carried-item channel. Deliberately NOT in PlayerBody.capture_state(): that
# array is the reconciliation blob, captured every tick and replayed through
# step(), so a worn-hat list there would be broadcast sixty times a second to
# report a change that happens twice a minute -- and would become part of the
# replay path, where a client would have to re-derive pickups it has no authority
# to decide. Hats are never predicted, for the same reason a shove is not.
var _hats: HatPool = HatPool.new()
var _hats_root: Node3D = null

# --- specials ---
#
# THE SAME CHANNEL'S SECOND CLIENT, which is what M8.5 said it was building it
# for. Nothing here is in capture_state() either, and for a stronger reason than
# hats: a hat does nothing, whereas a special deliberately does nothing THAT
# AFFECTS STEPPING. Firing does not move you -- there is no recoil, on purpose --
# so no part of a weapon is on the reconciliation path. See
# implementation_plans/m12_machine_gun.md.
var _specials: SpecialPool = SpecialPool.new()
var _specials_root: Node3D = null

# --- rounds in flight ---
#
# Not a pool: a round has no ownership, no pickup and no cull policy -- it exists
# for at most MG_BULLET_LIFETIME and then it does not. A plain list is the whole
# data structure, exactly as _balls is.
var _bullets: Array = []
var _bullets_root: Node3D = null
var _next_bullet_id: int = 0

# --- gunners: skirmishers and turrets ---
#
# TWO SCRIPTS, ONE POOL. They are separate types (skirmisher_body.gd,
# turret_body.gd) over a shared base, and everything this file does with them --
# stepping, targeting, culling, the wire -- is written against the base, so a
# third kind is a script and a scene and nothing here. They are the first enemies
# that make the GEOMETRY part of the fight: a rusher is answered by moving, and
# these are answered by breaking line of sight or closing the distance.
var _gunners: Array = []
var _gunners_root: Node3D = null
var _next_gunner_id: int = 0

# --- deployables: live things on the deck ---
#
# Thrown grenades, and the land mine when it lands. A short list on purpose: the
# fuse is what bounds it, so there is no cap and no cull-the-oldest rule the way
# there is for balls and loose specials.
var _deployables: Array = []
var _deployables_root: Node3D = null
var _next_deployable_id: int = 0

# --- rushers ---
var _rushers: Array = []
var _rushers_root: Node3D = null
# HOST-ASSIGNED AND MONOTONIC, never a creation-order index. A rusher is created
# mid-run by a trigger, so the stone list's "both machines loaded the same
# segments in the same order" trick does not apply -- two clients that woke
# different mounds first would disagree about which rusher is which.
var _next_rusher_id: int = 0

# --- the run ---
# CHECKPOINTS ARE GONE (M16). They existed to answer "where does the party
# restart" for an endless bridge; with rounds the answer is always the lobby you
# came from, which is authored and obvious to the player rather than derived from
# a segment index. Their arithmetic is also what produced the 2026-08-15 bug that
# respawned a party four thousand rows up the bridge -- rounds remove the
# question that was an answer to.
#
# `wipes` survives as a COUNT of rounds nobody finished, because it is worth
# knowing and the tests read it.
var wipes: int = 0

# THE ROUND. Lobby, section, lobby -- and the state that says which. Host-owned
# and replicated (see _round_sync); a client never infers it from where its body
# is standing, which is R1 of the plan and the reason this is a menu rather than
# a coincidence of geometry.
var round_machine = RoundMachine.new()

# The two barriers, as SIM OBJECTS. The transparent blue is a mesh that follows;
# a wall that exists only as a mesh is a wall a client walks through.
var _front_wall: StaticBody3D = null
var _rear_wall: StaticBody3D = null

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
	# Loose hats live in world space like the balls. A WORN hat is reparented onto
	# its wearer's head and comes back here when it is knocked off.
	_hats_root = Node3D.new()
	_hats_root.name = "Hats"
	add_child(_hats_root)
	_hats.attach(_hats_root)
	# And loose specials, for the same reason. A HELD one is reparented onto its
	# holder's Facing pivot -- which is what makes it point where they aim with no
	# per-tick transform work at all -- and comes back here when it is dropped.
	_specials_root = Node3D.new()
	_specials_root.name = "Specials"
	add_child(_specials_root)
	_specials.attach(_specials_root)
	_bullets_root = Node3D.new()
	_bullets_root.name = "Bullets"
	add_child(_bullets_root)
	_gunners_root = Node3D.new()
	_gunners_root.name = "Gunners"
	add_child(_gunners_root)
	_deployables_root = Node3D.new()
	_deployables_root.name = "Deployables"
	add_child(_deployables_root)
	# Read once, before anything can overwrite it. Deliberately not in start():
	# _remembered_hat must hold what is ON DISK from the first moment, or the
	# first pickup would look like a change and rewrite an identical file.
	if view_active:
		_remembered_hat = HatConfig.load_style()

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
			#
			# AND ONLY AN ASSEMBLED RUN IS DRESSED. A map pinned by name is
			# pinned on purpose: playtest_bridge is authored for feel and every
			# fixture is authored to be measured, so dressing either would change
			# what it is. The dressing is a pure function of (seed, index), so a
			# client told the seed builds the identical dressed bridge -- it rides
			# the same guarantee the terrain already does and needs no wire.
			grid.dress_hazards = true
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
	# BEFORE EITHER TICK, AND ON BOTH SIDES. A platform's position is a pure
	# function of the tick, so a client derives it rather than being told it — it
	# does not belong inside _host_tick with the things that are decided. Moved
	# first because a body stepping this tick must find the deck where it will BE,
	# not where it was.
	if grid != null:
		grid.step_elevators(tick)
	if is_host:
		_host_tick()
	else:
		_client_tick()
	# AFTER THE TICK, AND ON BOTH SIDES. A worn stack leans against the head under
	# it, so it has to be posed once every body has finished moving -- and it is a
	# drawing decision with no authority attached, so a client does it for itself
	# rather than being told. Nothing reads a lean back: not capture_state, not the
	# snapshot, not a pickup radius.
	_hats.pose_worn(players, PlayerBody.HALF_HEIGHT, SimConfig.TICK_DELTA)
	_pose_held_specials()
	_update_laser_sight()
	_sync_hitboxes()
	# The camera lets go of a player the drone has. See BridgeCamera.focus_held.
	if camera != null:
		camera.focus_held = _returning.has(local_peer)

func _host_tick() -> void:
	tick += 1
	# Before anything steps, so every body in this tick runs under one set of
	# rules. See push_setting.
	_apply_pending_settings()

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
		# A BODY THE DRONE HAS IS NOT IN THE WORLD, so it is not simulated.
		#
		# It used to keep stepping for the whole DRONE_RETURN_SECONDS: invisible,
		# out of play, with gravity still on it and no terminal velocity anywhere.
		# Measured 2026-08-13 -- three seconds after going over the edge a body was
		# at y = -124 m doing 67 m/s, still accelerating, and THE CAMERA WAS GLUED
		# TO IT, because the camera frames the local player and nothing said this
		# one had stopped being somewhere. Every tick of that is work done on a
		# position nobody will ever use.
		if _returning.has(peer):
			continue

		var inp: Array = _current_input.get(peer, PlayerInput.empty(0))
		_refresh_shield_flag(peer, body)

		var restore_mask: int = body.collision_mask
		if carriers.has(body):
			body.collision_mask = restore_mask & ~PLAYERS_LAYER_BIT
		body.step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS], PlayerInput.aim_of(inp),
			PlayerInput.point_of(inp))
		body.collision_mask = restore_mask

	_process_run()
	_process_spikes()
	_process_mutable()
	_process_plinko()
	# Before the rescue pass: a rusher can tumble someone into a hole, and the
	# rescue pass is what notices they left the world. Running it after means the
	# consequence lands on the same tick as the cause rather than the next one.
	_process_rushers()
	_process_gunners()
	# Before the rescue pass for the same reason rushers are: a blast is the single
	# biggest way to put somebody off the bridge, and the consequence should land on
	# the tick that caused it.
	_process_deployables()
	_process_rescue()
	_process_hearts()
	# LAST, AND AFTER EVERY BODY HAS STEPPED. Never inline in the step loop above:
	# _carry_order() sorts by who is standing on whom, so the order players step in
	# changes with the stack -- and deciding hat contests inside it would mean a
	# carried player systematically winning or losing races depending on whose head
	# they were on. See HatPool.resolve_pickups.
	_process_hats()
	# After hats, and last of all. A pickup pass wants every body settled, and the
	# fire loop wants this tick's inputs -- which _process_rushers and the rescue
	# pass may have invalidated by tumbling somebody.
	_process_specials()
	# AFTER the trigger, so a round fired this tick moves on the tick it was fired
	# rather than hanging at the muzzle for one frame. And after every body has
	# stepped, so the sweep tests against where people ACTUALLY are -- a round
	# resolved against last tick's positions would miss a walking player by the
	# distance they cover in a frame, forever.
	_process_bullets()

	# LAST, AND THAT PLACEMENT IS THE WHOLE CORRECTNESS OF IT. An edge detector has
	# to run AFTER every system that can change the state it reads, or it samples
	# the previous tick.
	#
	# It was at the end of _process_run, which is FIRST in this tick -- so a death
	# handed out by _process_rescue was not seen until the following tick, and on a
	# solo wipe that tick never came: the round machine goes to SCORING at the top
	# of _process_run and _settle_round_transition ERASES `_returning` on the way
	# past, so the flag was gone before anything looked at it. Measured, and the
	# symptom was a round log reading `deaths=0` for a round the player died in.
	#
	# Exactly the shape of the `wipes` counter that reads zero for the same reason,
	# and the second time that transition has eaten a signal. Anything that wants
	# to observe "a player went out" belongs here.
	_count_edges()

	if tick % SimConfig.SNAPSHOT_INTERVAL_TICKS == 0:
		_broadcast_snapshot()

# --- Round stats (M19) --------------------------------------------------------
#
# {peer -> {key -> int}}, HOST ONLY. A client never counts anything: it would be
# counting what it locally observed, which differs from the host's view of any
# round where a packet was late, and two players would be reading two different
# scoreboards. The host counts; the board carries the numbers; everyone reads.
var round_stats: Dictionary = {}

func _bump(peer: int, key: String, amount: int = 1) -> void:
	if not is_host or amount == 0 or peer <= 0:
		return
	if not round_stats.has(peer):
		round_stats[peer] = {}
	var row: Dictionary = round_stats[peer]
	row[key] = int(row.get(key, 0)) + amount

# A PEAK, NOT A TOTAL, and the registry needs both because they answer different
# questions. "How many hats did you pick up" sums; "how tall did your tower get"
# does not -- summing it would count the same hat on every tick you carried it.
#
# Polled rather than hooked, which is safe HERE and would not be for a death: the
# size of a stack is persistent state, so sampling it every tick cannot miss a
# peak that lasted longer than a frame. CLAUDE.md's warning is about values
# DESTROYED on reaching their terminal state, and a tower is not one.
func _bump_max(peer: int, key: String, value: int) -> void:
	if not is_host or peer <= 0:
		return
	if not round_stats.has(peer):
		round_stats[peer] = {}
	var row: Dictionary = round_stats[peer]
	row[key] = maxi(int(row.get(key, 0)), value)

func stats_of(peer: int) -> Dictionary:
	return (round_stats.get(peer, {}) as Dictionary).duplicate()

# CLEARED WHERE THE ROUND BEGINS, and nowhere else. RoundMachine._cross already
# clears `reached` and zeroes the clock on the way into RUNNING; hanging this off
# the same line means there is one definition of "this round" rather than two that
# can drift by a tick. A reset at the wrong moment produces a scoreboard covering
# two rounds, which is not something anybody would catch by looking at it.
func clear_round_stats() -> void:
	round_stats.clear()

# THE ROUND, WRITTEN DOWN. Once per round, on the host, on a path no game state
# can gate.
#
# DELIBERATELY NOT BEHIND A DEBUG TOGGLE. CLAUDE.md's rule is that the absence of
# a gated log is not the absence of the event: a print behind a DebugSettings knob
# that happens to be off looks exactly like nothing having happened, and this is
# the one record of what a playtest session actually did. Three lines a round, a
# few times an hour, is not a volume worth a switch.
#
# FROM THE BOARD, not from the live counters, so the log says exactly what the
# players were shown -- a report about a number on the screen is unanswerable if
# the two could differ.
# WHERE EVERYBODY IS AT EVERY ROUND TRANSITION, on the host, unconditionally.
#
# Added 2026-08-17 because a precise playtest report -- "one guy was still outside
# the lobby's south wall, and crossing it started the round" -- could not be
# reproduced from a rig, and a second attempt at guessing the sequence is worth
# less than one line of ground truth. A transition happens a few times a round.
#
# The corridor and the bodies together, because the bug was a DISAGREEMENT
# between them: every rule about the next round is derived from where the party is
# standing, so a player outside the corridor at this moment is the whole fault.
func _log_transition() -> void:
	var rows: Array = []
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		var row: int = grid.cell_of_world(body.position).y if grid != null else -1
		var inside: bool = grid != null and grid.is_lobby_row(row)
		rows.append("%d@%d%s" % [int(peer_key), row, "" if inside else "!OUT"])
	print("[round] -> %s rear=%d target=%d  %s" % [round_machine.state_name(),
		round_machine.rear_row, round_machine.target_row, " ".join(rows)])

func _log_round_stats() -> void:
	for line in StatRegistry.log_lines(round_machine.board, round_machine.round_index):
		print(line)

# ONE PLACE WHERE HARM IS DELIVERED, and the only place that counts it.
#
# DELIVERED, NOT INTENDED. A shield refuses a hit outright, cover eats a round,
# and a body on its last point takes one damage from a five-damage hit -- so the
# honest measure is health actually removed, which is `before - after` and cannot
# disagree with what happened. Reading `hit.amount` would have counted the shot a
# shield ate as full damage dealt.
#
# It also answers "was that a kill" for free: the last point is the transition
# from above zero to zero, measured at the line that caused it.
#
# NOT A CHANGE TO `receive_hit`. Widening that from `-> bool` to a damage figure
# would touch eight implementations and a dozen tests to learn something the
# health field already knows.
func _deliver(target, hit) -> bool:
	if target == null or not target.has_method("receive_hit"):
		return false
	var source: int = int(hit.source)
	var has_health: bool = "health" in target
	var before: int = int(target.health) if has_health else 0
	# SAMPLED BEFORE THE HIT, because kill() is what receive_hit does to an enemy
	# and there is no reading it back afterwards -- the same shape as capturing
	# approach velocity before move_and_slide.
	var enemy: bool = _is_enemy(target)
	var was_spent: bool = enemy and target.has_method("is_spent") and target.is_spent()
	var took: bool = target.receive_hit(hit)
	if not is_host or source <= 0:
		return took
	# A HIT IS SOMETHING THAT BLEEDS. Counted where it LANDS rather than where it
	# was fired -- the round that cover stopped never reaches here at all, which is
	# the difference between an accuracy figure and a trigger-pull figure -- and
	# counted only against a PERSON or an ENEMY.
	#
	# Deck, parapet and a shooter's pillar were already excluded for free: they have
	# no `receive_hit`, so _resolve_round_hit returns before reaching this. What was
	# not excluded is everything else in the world that DOES answer -- a stone, a
	# plinko ball, a loose hat, a dropped special. Shooting a stone is a legitimate
	# thing to do and it is not marksmanship, and counting it made accuracy a figure
	# you could inflate by firing at the scenery.
	#
	# Asked of GameWorld's own lists rather than of the target. The alternative is a
	# `counts_as_a_hit()` on eight bodies, which is a new protocol to answer a
	# question the world already knows the answer to.
	if took and (_is_player(target) or _is_enemy(target)):
		_bump(source, "hits")
	# AN ENEMY HAS NO HEALTH FIELD, AND MEASURING IT BY ONE COUNTED NOTHING.
	#
	# Reported from a playtest as "enemy damage and kills were both zero when they
	# shouldn't have been", and it was two lines above this one: `has_health` is
	# false for every enemy in the game -- a rusher and a gunner have no `health`
	# at all, a BULLET or an EXPLOSIVE calls kill() outright -- so this early
	# return fired first and both counters were unreachable code. `hits` worked
	# because it is bumped ABOVE the return.
	#
	# So enemies are measured by the model they actually have: `is_spent`. Damage
	# is the hit's own amount, because there is no health to subtract and a hit
	# that lands on an enemy IS fully absorbed by it -- the delivered-versus-
	# intended distinction that matters for a player has nothing to bite on here.
	#
	# THE TESTS COULD NOT HAVE CAUGHT THIS. Every assertion in test_stat_counting
	# about these two stats was that they are ZERO -- zero for a friendly hit, zero
	# for scenery -- so a permanently-zero counter satisfied all of them. A counter
	# only ever asserted absent is a counter nobody has checked.
	if enemy:
		if took:
			_bump(source, "enemy_damage", int(hit.amount))
			if not was_spent and target.is_spent():
				_bump(source, "enemy_kills")
		return took
	if not has_health:
		return took
	var lost: int = maxi(0, before - int(target.health))
	if lost > 0:
		# FRIENDLY OR NOT IS DECIDED BY THE TARGET, not by the source. `hit.source`
		# says whose it was; whether it was a mistake is a question about who
		# caught it.
		#
		# AND NEITHER, FOR ANYTHING THAT IS NOT A PERSON OR AN ENEMY. The first
		# version read "friendly if it is a player, enemy otherwise", so knocking
		# the health off a loose hat scored as damage to the opposition. There are
		# three answers here, not two, and the third is "that was scenery".
		if _is_player(target):
			# YOUR OWN GRENADE IS NOT FRIENDLY FIRE. Both are "you hurt a player",
			# and they are completely different stories -- one is a mistake that
			# cost somebody else, the other is a mistake that only cost you. Split
			# here because `_deliver` is the only place that has both ends of it.
			if int(target.peer_id) == source:
				_bump(source, "self_damage", lost)
			else:
				_bump(source, "friendly_damage", lost)

	return took

func _is_player(target) -> bool:
	return "peer_id" in target and players.has(int(target.peer_id))

# The things that shoot back. Membership in the lists this world already keeps,
# so a body that is not in one of them cannot be mistaken for an enemy however
# many of an enemy's properties it happens to have.
func _is_enemy(target) -> bool:
	return _rushers.has(target) or _gunners.has(target)

# DEATHS, ON THE RISING EDGE OF BEING OUT OF PLAY.
#
# Counted here rather than at `begin_downed` because there are several ways to go
# out -- damage, a fall past FALL_KILL_Y, a hang that expired -- and a counter per
# cause is a counter somebody forgets to add to the fourth one. An edge detector
# over "is this player out" catches every route by construction.
#
# AN EDGE, NOT A POLL, and the distinction matters: CLAUDE.md's note is that a
# value destroyed on reaching its terminal state is never observed in it. Being
# out is not destroyed -- it persists for seconds -- so a rising edge over it is
# safe where a poll for `health == 0` would miss deaths that pass straight through.
var _was_out: Dictionary = {}
var _was_dashing: Dictionary = {}
var _last_at: Dictionary = {}

# A SINGLE TICK OF REAL MOVEMENT CANNOT BE THIS FAR, so anything longer was a
# TELEPORT and is not distance travelled.
#
# This is the whole difficulty in measuring distance, and without it the number
# measures the wrong thing spectacularly: a wipe returns the party to the lobby,
# which is hundreds of metres backwards in one frame, and the leash MOVES a
# straggler outright. A player who died twice would "walk" further than one who
# played the whole round, and the badge would go to whoever failed most.
#
# The bound is set from the fastest thing a body can legitimately do: SHOVE_SPEED
# is 56 m/s, which is 0.93 m in a 60 Hz tick. Two metres is a wide margin over
# that and still an order of magnitude under any teleport in the game -- the
# nearest is a lobby return, and no round is two metres long.
const TELEPORT_TICK_DISTANCE := 2.0

# Both edge detectors, walked together because they walk the same list.
#
# A DASH IS COUNTED ON THE HOST, from the STATE, not at the input that asked for
# one. `_begin_shove` runs on the client too -- SHOVE is one of the states a
# client predicts (see the note on client prediction) -- so a counter there would
# fire on every machine and count a mispredicted dash that the host rewound.
func _count_edges() -> void:
	if not is_host:
		return
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if body == null or not is_instance_valid(body):
			continue
		var out: bool = _returning.has(peer) or int(body.state) == PlayerBody.State.DOWNED

		var dashing: bool = int(body.state) == PlayerBody.State.SHOVE
		if dashing and not bool(_was_dashing.get(peer, false)):
			_bump(peer, "dashes")
		_was_dashing[peer] = dashing

		# THE TALLEST TOWER THIS PLAYER GOT TO. Distinct from the hats they FINISH
		# with, which is the ranking key -- you can carry six and lose five, and
		# that is a better story than the one either number tells alone.
		_bump_max(peer, "hats_worn", hats_worn_by(peer).size())

		# TIME ALIVE, IN TICKS, and only while the round is actually running --
		# otherwise it counts the lobby, and the badge goes to whoever stood
		# around longest between rounds.
		var running: bool = round_machine.state == RoundMachine.State.RUNNING
		if running and not out:
			_bump(peer, "time_alive")

		# DISTANCE, FLAT AND IN CENTIMETRES. Flattened because falling is not
		# travelling: without it a player who goes off the bridge racks up metres
		# on the way down, which is the opposite of what the number should say.
		var here: Vector3 = body.global_position
		if running and not out and _last_at.has(peer):
			var step: Vector3 = here - Vector3(_last_at[peer])
			step.y = 0.0
			var moved: float = step.length()
			if moved < TELEPORT_TICK_DISTANCE:
				_bump(peer, "distance", int(round(moved * 100.0)))
		_last_at[peer] = here

# --- The run: lookahead, checkpoints, wipes, and the leash --------------------

func _process_run() -> void:
	if grid == null:
		return
	_extend_run()
	if is_host:
		var was: int = round_machine.state
		round_machine.step(self)
		if round_machine.state != was:
			_on_round_state_changed()
	_sync_walls()
	_check_wipe()
	_apply_leash()

# A state change is rare -- a few times a round -- so it goes out RELIABLY the
# moment it happens rather than riding the per-tick snapshot. The countdown is
# re-sent with it and again on the snapshot interval; a client tickng its own
# copy down between those is right to within a frame, and the frame it is wrong
# by is a number on a screen rather than anything the sim reads.
func _on_round_state_changed() -> void:
	_settle_round_transition()
	if is_host and round_machine.state == RoundMachine.State.SCORING:
		_log_round_stats()
	if is_host:
		_log_transition()
	if networked:
		_round_sync.rpc(round_machine.state, round_machine.rear_row,
			round_machine.target_row, round_machine.close_timer,
			round_machine.round_clock, round_machine.reached.keys(),
			round_machine.board)

@rpc("authority", "call_remote", "reliable")
func _round_sync(state: int, rear: int, target: int, closing: float,
		clock: float, reached: Array, board: Array) -> void:
	if is_host:
		return
	round_machine.state = state
	round_machine.rear_row = rear
	round_machine.target_row = target
	round_machine.close_timer = closing
	round_machine.round_clock = clock
	round_machine.reached.clear()
	for peer in reached:
		round_machine.reached[int(peer)] = true
	round_machine.board = board
	_sync_walls()

# WHAT A TRANSITION DOES TO BODIES. Only the host runs this; clients see the
# result as ordinary replicated positions.
func _settle_round_transition() -> void:
	if round_machine.state == RoundMachine.State.LOBBY:
		_restock_lobby()
		return
	if round_machine.state != RoundMachine.State.SCORING:
		return
	# EVERYBODY GOES IN THE LOBBY. Not just the stragglers.
	#
	# Reported from a playtest of three, two over the line and one behind: "when
	# the scores went away, one guy was still outside the lobby's south wall, in
	# the play area from the last round -- once he crossed it, the round STARTED".
	# That second half is the diagnosis. A round begins when the party crosses the
	# strip AHEAD of them, so a round that began on the strip BEHIND them means
	# `target_row` was pointing at the lobby's entry band -- which is what
	# `_enter_lobby` computes when it derives the corridor from a party member who
	# is not in the lobby.
	#
	# It used to move only players NOT in `reached`, on the reasoning that anybody
	# who crossed is already where they should be. They are not: crossing puts you
	# ON the strip, which is the lobby's doorway rather than its floor, and it
	# leaves the party spread across a boundary at the exact moment every rule
	# about the next round is derived from where they are standing.
	#
	# So the transition now GATHERS. It is also what makes the corridor safe to
	# re-derive at all: after this loop every player is demonstrably inside one
	# lobby, so "where is the rearmost player" has one honest answer.
	#
	# NOBODY SEES THE MOVE. The scoreboard goes up on the same tick and covers the
	# middle three quarters of the screen over a scrim.
	#
	# `reached` is untouched -- it is what the SCORING reads to say who made it,
	# and that is a statement about what happened rather than about where anybody
	# is standing now.
	# A LANE INDEX, COUNTED -- never the peer id. It was `_lobby_point(peer)` until
	# 2026-08-15, and peer ids are 1 and 2 locally but LARGE RANDOM INTS over the
	# network: entry_spawn_cell computes `width/2 - 3 + index*2` and clamps, so
	# every straggler resolved to the outermost column and two of them to the SAME
	# CELL. Coincident bodies depenetrate into a degenerate normal and are driven
	# down through the floor (CLAUDE.md's oldest trap), and on the way past the
	# deck the ledge catch grabs the lip -- which is the reported "teleported into
	# the lobby and left hanging off the outside of the bridge".
	#
	# It played fine locally for exactly the reason it was never noticed: peers 1
	# and 2 give lanes 1 and 2.
	# ONLY IF THERE IS A LOBBY TO GATHER INTO. `lobby_row_near` falls back to the
	# bridge entry when it cannot find one, which is right for a WIPE -- somewhere
	# is better than nowhere -- and completely wrong here: it would teleport a
	# party that just finished a round to the start of the run because the level
	# they are playing has no lobby in it. Test fixtures are exactly that, and
	# test_round_machine caught this within a minute of the gather going in.
	#
	# Without a lobby the old rule stands: stragglers are still returned, because
	# leaving them behind a closed boundary is worse.
	var lobby_row: int = grid.lobby_row_near(round_machine.rear_row) if grid != null else -1
	var gather_all: bool = grid != null and grid.is_lobby_row(lobby_row)

	var lane := 0
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		if round_machine.reached.has(peer) and not gather_all:
			continue
		var body: Node = players[peer]
		if body == null or not is_instance_valid(body):
			continue
		_returning.erase(peer)
		# FULL, NOT REVIVE_HEALTH. It was `maxi(health, REVIVE_HEALTH)`, which put a
		# straggler in the lobby on one hit point.
		#
		# STRICTLY REDUNDANT with the `_restock_lobby()` below, and A/B'd to confirm
		# that -- reverting this line alone leaves the test green. It is written out
		# anyway because `respawn_at` has to be handed a number, and leaving
		# REVIVE_HEALTH there would state a rule the next line contradicts. The one
		# that does the work is below.
		body.respawn_at(_lobby_point(lane), SimConfig.MAX_HEALTH)
		lane += 1

	# AND EVERYONE ELSE, INCLUDING THE PEOPLE WHO WON. The loop above only touches
	# players who did NOT reach the strip, so a party that finished a hard section
	# stood on the board at whatever health it cost them and was healed ten seconds
	# later when the lobby state opened. Same rule for everybody, applied at the
	# moment the round ends rather than at the end of the scoreboard.
	_restock_lobby()

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

# How far the party has got. Everything that scales with progress reads this --
# the run extension, the checkpoint, the leash -- so a wrong answer here is a
# wrong answer everywhere at once.
#
# A PLAYER WHO IS OUT OF THE WORLD IS NOT PROGRESS. Somebody waiting on the drone
# is invisible and parked at whatever coordinate they went over the edge at, and
# on 2026-08-15 that coordinate was BEHIND THE START of the bridge, which
# segment_index_of_row then reported as the front. That specific hole is fixed at
# its source; this is the layer that stops the next one, because there is no
# position a fallen body can hold that should move the run forward.
#
# The fallback matters: with everyone out at once (which is the wipe condition,
# and solo it is every fall) there is no in-world player to ask, and a party of
# nobody must still answer something rather than the origin.
func _front_position() -> Vector3:
	var best: Vector3 = Vector3.ZERO
	var found := false
	var any: Vector3 = Vector3.ZERO
	var found_any := false
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if not found_any or body.position.z < any.z:
			any = body.position
			found_any = true
		if _returning.has(peer):
			continue
		if not found or body.position.z < best.z:
			best = body.position
			found = true
	if found:
		return best
	return any

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
	for gunner in _gunners:
		if is_instance_valid(gunner):
			gunner.queue_free()
	_gunners.clear()
	for d in _deployables:
		if is_instance_valid(d):
			d.queue_free()
	_deployables.clear()
	# Hats go too. A wipe rewinds the party to a checkpoint, and hats scattered
	# across ground the party no longer occupies are debris nobody can reach.
	_hats.clear()
	# And specials, held ones included. A weapon carried backwards through a wipe
	# would make the checkpoint a place to stockpile: fail, keep the gun, come back
	# with it. The authored pickup respawns with the segment; what you were holding
	# does not.
	_specials.clear()
	for bullet in _bullets:
		if is_instance_valid(bullet):
			bullet.queue_free()
	_bullets.clear()

	# BACK TO THE LOBBY YOU CAME FROM. Authored, obvious, and derived from nothing
	# -- which is the whole reason M16 could delete checkpoint_row and the
	# integer-division interval that went with it.
	var lane := 0
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		# A wipe is the one place health comes back in full -- the run has already
		# taken the ground back, which is the cost.
		body.respawn_at(_lobby_point(lane), SimConfig.MAX_HEALTH)
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
		# A CLIENT DRESSES TOO, and must, because the dressing is part of what the
		# bridge IS -- a client that skipped it would build the same terrain with
		# none of the hazards on it. Safe to do locally rather than send: it is a
		# pure function of (seed, index), which is the same guarantee that lets a
		# joining client be told two numbers instead of a world.
		grid.dress_hazards = true
		grid.build_run(seed_value, wanted)

# --- Spike blocks (M17) -------------------------------------------------------
#
# A block that drives spikes into the cells AROUND it, on a fixed cycle.
#
# THE PHASE COMES FROM THE TICK AND NOTHING ELSE, which is what makes this free
# to replicate: every machine computes the same phase from the same tick, so
# there is nothing to send and nothing to get out of step. It is also why the
# offset is derived from the CELL -- a row of blocks that all fire in unison is
# one obstacle, and a row that fires out of phase is a rhythm to move through.
#
# THE BLOCK ITSELF IS SAFE TO STAND ON. What hurts is being beside it, so it is
# authored where a player must pass alongside something -- a corridor, a ledge,
# the gap between two holes.
# --- Mutable terrain (M17 phase 8) -------------------------------------------
#
# HOST-AUTHORITATIVE, and the reason is the RESTORE rather than the removal. A
# slab that comes back inside a body standing in its volume is the coincident-body
# trap in CLAUDE.md with a wall instead of a player, so a close has to be
# DEFERRABLE -- and a rule with an exception cannot also be a pure function of the
# tick that a client derives for itself.
var _crumble_timer: Dictionary = {}    # Vector2i -> seconds until it goes
var _restore_timer: Dictionary = {}    # Vector2i -> seconds until it comes back

func _process_mutable() -> void:
	if grid == null or not is_host or grid.mutable_cells.is_empty():
		return
	var changed: bool = false
	for cell in grid.mutable_cells:
		match grid.mutable_content(cell):
			GridConfig.Content.CRUMBLE:
				changed = _step_crumble(cell) or changed
			GridConfig.Content.TIMED:
				changed = _step_timed(cell) or changed
	if changed and networked:
		_sync_open_cells.rpc(grid.open_cell_layout())

# TRIGGERED BY WEIGHT, and it keeps going once it has started. A crumble you can
# cancel by stepping back off is a crumble that never costs anything: the moment
# of decision is the moment you step ON, and taking it back afterwards would move
# that moment to wherever the player happens to be when the timer runs out.
func _step_crumble(cell: Vector2i) -> bool:
	if grid.is_cell_open(cell):
		return _step_restore(cell)
	if not _crumble_timer.has(cell):
		if not _stood_on(cell):
			return false
		_crumble_timer[cell] = SimConfig.CRUMBLE_DELAY
		return false
	var left: float = float(_crumble_timer[cell]) - SimConfig.TICK_DELTA
	if left > 0.0:
		_crumble_timer[cell] = left
		return false
	_crumble_timer.erase(cell)
	_restore_timer[cell] = SimConfig.CRUMBLE_RESTORE
	return grid.set_cell_open(cell, true)

# ITS OWN CLOCK, out of phase with its neighbours, so a row of them is a rhythm
# to read rather than a wall that blinks in unison. The phase is derived from the
# CELL, not from a counter -- a counter would depend on load order, and two
# machines load the same segments in the same order today and that is not a thing
# worth depending on.
func _step_timed(cell: Vector2i) -> bool:
	if grid.is_cell_open(cell) and _occupied(cell):
		return false        # never re-solidify around somebody; wait a tick
	var phase: int = absi(cell.x * 7 + cell.y * 13) % SimConfig.TIMED_PERIOD_TICKS
	var at: int = (tick + phase) % SimConfig.TIMED_PERIOD_TICKS
	return grid.set_cell_open(cell, at >= SimConfig.TIMED_SOLID_TICKS)

func _step_restore(cell: Vector2i) -> bool:
	if not _restore_timer.has(cell):
		return false
	# STORED CLAMPED, so a timer that has run out READS as run out. Leaving the
	# last positive value in place while the close waits made the state say "0.4
	# seconds to go" for eight seconds, and anything asking whether the cell was
	# overdue -- a test, a HUD, the next person to read this -- got a no.
	var left: float = maxf(0.0, float(_restore_timer[cell]) - SimConfig.TICK_DELTA)
	_restore_timer[cell] = left
	if left > 0.0:
		return false
	# THE ONE CASE THAT MUST NOT FIRE ON TIME. Waiting is free; a slab built around
	# a player is the fall-through-the-floor trap with the roles swapped.
	if _occupied(cell):
		return false
	_restore_timer.erase(cell)
	return grid.set_cell_open(cell, false)

# STANDING ON IT: in the cell, on the ground, and at its height rather than under
# it. The height test is what stops a player walking BENEATH a raised crumble cell
# from bringing it down on nobody.
func _stood_on(cell: Vector2i) -> bool:
	var surface: float = grid.cell_surface_world(cell).y
	for peer_key in players:
		var body: Node = players[peer_key]
		if not is_instance_valid(body) or not body.grounded:
			continue
		if grid.cell_of_world(body.position) != cell:
			continue
		if absf(body.position.y - PlayerBody.HALF_HEIGHT - surface) < 0.6:
			return true
	return false

# Anything of ours inside the volume the slab would occupy. Wider than _stood_on:
# a body FALLING through the hole is exactly what must not have a slab built
# around it, and it is neither grounded nor at the surface.
func _occupied(cell: Vector2i) -> bool:
	var surface: float = grid.cell_surface_world(cell).y
	for peer_key in players:
		var body: Node = players[peer_key]
		if not is_instance_valid(body):
			continue
		if grid.cell_of_world(body.position) != cell:
			continue
		if body.position.y - surface < PlayerBody.HALF_HEIGHT * 2.0 			and body.position.y - surface > -(GridConfig.DECK_THICKNESS + PlayerBody.HALF_HEIGHT * 2.0):
			return true
	return false

func _process_spikes() -> void:
	if grid == null or grid.spike_cells.is_empty():
		return
	var now: float = float(tick) * SimConfig.TICK_DELTA
	for cell in grid.spike_cells:
		var offset: float = float((int(cell.x) * 5 + int(cell.y) * 3) % 7) / 7.0
		var phase: float = fmod(now / SimConfig.SPIKE_PERIOD + offset, 1.0)
		# THE RAMP IS THE TELEGRAPH. A quarter of the out-window is spent coming
		# up and a quarter going back down, so a player sees them rising and has
		# time to step off -- a hazard that appears instantly is a hazard you can
		# only learn by dying to it.
		var lift := 0.0
		if phase < SimConfig.SPIKE_OUT_FRACTION:
			var t: float = phase / SimConfig.SPIKE_OUT_FRACTION
			lift = clampf(minf(t / 0.25, (1.0 - t) / 0.25), 0.0, 1.0)
		grid.set_spikes_lift(cell, lift)
		# HURT ONLY WHEN THEY ARE ACTUALLY OUT, which is what makes the ramp a
		# real warning rather than a decoration over an instant hit.
		if lift < 0.6 or not is_host:
			continue
		_spike_hits(cell)

# DIRECTLY ABOVE THE BLOCK, and nowhere else.
#
# This used to iterate the block's four NEIGHBOURS and hurt anybody near one of
# them, which made the middle of the spikes the safest place to stand and put the
# danger in a ring reaching 3.3 m out. It is drawn as nine cones coming straight
# up out of one cell; that is what it should do.
#
# The alternative shape — a solid block with spikes fanning out of its sides
# down to the floor around it — would justify the old rule, and is a different
# model with a different silhouette. If that is ever wanted, the MESH moves first
# and this follows it. A hit test that disagrees with the art is a hazard players
# learn by dying to.
func _spike_hits(cell: Vector2i) -> void:
	var at: Vector3 = grid.cell_surface_world(cell)
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		if body.is_awaiting_rescue():
			continue
		var to: Vector3 = body.position - at
		# Above the deck, not below it: a player under an overhang with spikes on
		# top is not being stabbed by them.
		if to.y < -0.5 or to.y > SimConfig.SPIKE_TOP_REACH:
			continue
		if Vector2(to.x, to.z).length() > SimConfig.SPIKE_REACH:
			continue
		var hit = Hit.new()
		# CRUSH: reserved by the damage model on the day it was written for
		# "a saw-blade, something falling", and this is the first thing to
		# use it. A shield does not stop the floor -- see shield_blocks, which
		# refuses this kind outright rather than by distance.
		hit.kind = Hit.Kind.CRUSH
		hit.amount = SimConfig.SPIKE_DAMAGE
		hit.from = at
		body.receive_hit(hit)

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

func _launch_ball(cell: Vector2i) -> Node:
	if _balls.size() >= SimConfig.PLINKO_MAX_BALLS:
		return null
	var ball: Node3D = BallScene.instantiate()
	_next_ball_id += 1
	ball.ball_id = _next_ball_id
	ball.name = "Ball_%d" % _next_ball_id
	_balls_root.add_child(ball)
	_balls.append(ball)
	ball.set_simulated(true)
	ball.launch(grid.shooter_muzzle(cell), _launch_direction())
	# Returned so a caller can place one deliberately. _fire_shooters ignores it;
	# a test that wants a ball in a known spot has no other way to get one, and
	# reaching into _balls after the fact is worse.
	return ball

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
	# THE PLAYER'S RADIUS, NOT ITS HALF-HEIGHT.
	#
	# This read PlayerBody.HALF_HEIGHT (0.9) until 2026-08-14, which is the body's
	# TALLNESS standing in for its WIDTH -- so the horizontal test ran at
	# 1.1 + 0.9 = 2.0 m against a real contact distance of 0.6 + 0.4 = 1.0 m.
	# Exactly twice the geometry, and the playtest report "plinko balls can hit
	# you from quite a distance going past you" measured.
	#
	# hat_pool.gd had the right number two files away the whole time
	# (PLAYER_HALF_WIDTH). This is now PlayerBody.RADIUS so there is one place to
	# read it from, and test_plinko walks a ball in to pin the distance.
	var reach: float = DebugSettings.tuned("plinko_hit_radius", SimConfig.PLINKO_HIT_RADIUS) 		+ PlayerBody.RADIUS
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body.is_awaiting_rescue() or _returning.has(int(peer_key)):
			continue
		if body.position.distance_to(ball.position) > reach:
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
	if not rusher.is_in_play():
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

		# ALREADY DEFLECTED, SO IT CANNOT COLLECT ON THE COUNTER IT LOST. `continue`
		# rather than `return`: this rusher is harmless to THIS player, but another
		# player may still be mid-dash and entitled to bat it further.
		#
		# Without this the dash was a counter that lost. See rusher_body's
		# is_dangerous(): the dash is six ticks, the stagger it buys is a hundred
		# and twenty, and the player spent the counter, walked into the thing they
		# had just deflected, and was tumbled by it with the cooldown still running.
		if not rusher.is_dangerous():
			continue

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

		body.receive_hit(Hit.make(Hit.Kind.IMPACT, SimConfig.RUSHER_DAMAGE,
			rusher.position, SimConfig.RUSHER_KNOCKBACK, SimConfig.RUSHER_KNOCKBACK_LIFT))
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

# --- Gunners ------------------------------------------------------------------

func gunner_count() -> int:
	return _gunners.size()

func _process_gunners() -> void:
	if not is_host:
		return
	if grid != null:
		for entry in grid.take_authored_gunner_cells():
			_spawn_gunner(grid.cell_surface_world(entry[0]) + Vector3(0.0, 1.0, 0.0),
				int(entry[1]))

	for i in range(_gunners.size() - 1, -1, -1):
		var gunner: Node = _gunners[i]
		if not is_instance_valid(gunner):
			_gunners.remove_at(i)
			continue
		if gunner.is_spent() or gunner.position.z > _trailing_edge_z():
			_gunners.remove_at(i)
			gunner.queue_free()
			continue

		# LINE OF SIGHT GATES BOTH HALVES, and for a gunner it matters more than
		# it does for a rusher. A rusher with no sight stands still, which is
		# merely wasteful; a GUN that fired through a pillar would have no
		# counter-play at all, and cover is the whole answer to these.
		var target: Node = _nearest_visible_player(gunner)
		gunner.step(target)
		if target == null:
			continue
		var range_to: float = gunner.position.distance_to(target.position)
		# The target goes in as well as the distance: a turret also has to be able
		# to BEAR on it, and that is a question about angle that only the turret
		# can answer.
		if gunner.wants_to_fire(range_to, target):
			gunner.note_fired()
			_spawn_round(gunner.muzzle(),
				_spread((target.global_position + Vector3(0.0, 0.25, 0.0) - gunner.muzzle()).normalized()),
				0, gunner.get_rid())

func _nearest_visible_player(gunner: Node) -> Node:
	var best: Node = null
	var best_d: float = INF
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		if body.is_awaiting_rescue() or _returning.has(peer):
			continue
		var d: float = gunner.position.distance_to(body.position)
		if d >= best_d:
			continue
		if not _clear_line(gunner.global_position + Vector3(0.0, 0.25, 0.0),
				body.global_position):
			continue
		best = body
		best_d = d
	return best

# THE KIND PICKS THE SCENE AND NOTHING ELSE. `kind` is not assigned onto the body
# afterwards -- each script sets its own in _init, so the scene is the single
# source of truth and a scene wired to the wrong script cannot quietly report
# itself as the other thing over the wire.
func _spawn_gunner(at: Vector3, kind: int) -> Node:
	var scene: PackedScene = TurretScene if kind == GunnerBody.Kind.TURRET else SkirmisherScene
	var gunner: Node3D = scene.instantiate()
	_next_gunner_id += 1
	gunner.gunner_id = _next_gunner_id
	gunner.world = self
	gunner.name = "Gunner_%d" % _next_gunner_id
	_gunners_root.add_child(gunner)
	gunner.position = at
	_gunners.append(gunner)
	return gunner

func _gunner_by_id(id: int) -> Node:
	for gunner in _gunners:
		if is_instance_valid(gunner) and gunner.gunner_id == id:
			return gunner
	return null

# --- Hats ---------------------------------------------------------------------

# Write the local player's hat to disk, when and only when it has changed.
#
# ONLY IN A WORLD SOMEBODY IS LOOKING AT. A headless test world writing to
# user:// would rewrite the developer's own saved hat every time the gate ran --
# a test that quietly mutates real user state is one nobody can trust twice.
# view_active is the same gate _poll_aim uses for the same reason.
func _remember_hat(style: int) -> void:
	if not view_active or style == _remembered_hat:
		return
	_remembered_hat = style
	HatConfig.save_style(style)

# What is on disk, so a pickup that changes nothing does not rewrite the file --
# a dash through five hats is five acquisitions in one tick.
var _remembered_hat: int = HatConfig.NONE

func hat_count() -> int:
	return _hats.count()

func hats_worn_by(peer: int) -> Array:
	return _hats.worn_by(peer)

func _process_hats() -> void:
	if not is_host:
		return

	# Authored hats from any segment that has loaded since the last tick. Drained
	# rather than read, so a segment streamed in mid-run contributes its hats once
	# and the initial load and a later extension go down the same path.
	if grid != null:
		for cell in grid.take_authored_hat_cells():
			_hats.spawn_loose(grid.cell_surface_world(cell) + Vector3(0.0, 0.3, 0.0))

	_hats.step(_trailing_edge_z())

	# WHICH STATES MAY CARRY. Allowed in WALK and SHOVE -- a dash down a line of
	# loose hats collecting all of them is one of the better moments available
	# here and costs nothing to allow. Refused in TUMBLE, LEDGE_HANG, DOWNED and
	# the bus states: a tumbling player scooping their own hats back up as they
	# roll through them removes the entire cost of the tumble.
	var can_carry := func(peer: int, body: Node) -> bool:
		if _returning.has(peer):
			return false
		return body.state == PlayerBody.State.WALK or body.state == PlayerBody.State.SHOVE
	var worn_count := func(peer: int) -> int:
		return _hats.worn_by(peer).size()

	for claim in _hats.resolve_pickups(players, can_carry, worn_count):
		var hat: Node = claim[0]
		var peer: int = int(claim[1])
		var index: int = int(claim[2])
		_wear_hat(hat.hat_id, peer, index)
		# OWNERSHIP CHANGES GO RELIABLY. A lost pickup that silently never applies
		# is a client wearing a hat the host says is on the deck -- a divergence
		# that never self-corrects, because nothing re-sends it. Loose positions
		# ride the unreliable snapshot; who owns what does not.
		if networked:
			_wear_hat.rpc(hat.hat_id, peer, index)

# Behind the rearmost living player is behind the streaming window. +Z is
# down-bridge, so a larger z is further back.
func _trailing_edge_z() -> float:
	var back: float = -INF
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		back = maxf(back, body.position.z)
	if back == -INF:
		return INF
	return back + SimConfig.LEASH_HARD

@rpc("authority", "call_remote", "reliable")
func _wear_hat(id: int, peer: int, index: int) -> void:
	var hat: Node = _hats.by_id(id)
	var body: Node = players.get(peer)
	if hat == null or body == null:
		return
	hat.wear(peer, index)
	# ACQUIRING A HAT MAKES IT YOURS, TOMORROW TOO. Steal one and you keep it.
	if peer == local_peer:
		_remember_hat(hat.style_id)
	# NOT REPARENTED ONTO THE HEAD, which is what M8.5 did and what 2026-08-16
	# had to undo. Sitting under the player followed it for free, but A
	# RIGIDBODY3D THAT IS A CHILD OF ANOTHER PHYSICS BODY IS NOT RETURNED BY A
	# QUERY — measured, with the shape enabled, the mask set to every bit and the
	# physics server holding the correct transform. So a worn hat could not be
	# shot, which is a whole verb lost to a parenting convenience.
	#
	# It stays at the pool root and is driven by GLOBAL transform instead. The
	# "one frame late" the old comment worried about does not happen: pose_worn
	# runs after every body has stepped, on both machines, which is later than
	# any parent transform would have propagated anyway.
	#
	# Posed through the same function the per-tick lean uses, with dt = 0 for
	# "upright, now". Two formulas for where a hat sits would drift apart, and
	# the one that drifted would be this one -- it runs once per pickup, so a
	# mistake here shows up as a single wrong frame nobody catches.
	_hats.pose_stack(peer, body, PlayerBody.HALF_HEIGHT, 0.0)

# The whole stack, fanned. Called by PlayerBody on entering TUMBLE or LEDGE_HANG.
#
# A DETERMINISTIC FAN, never a random direction. Two reasons and both matter: a
# host-authoritative sim does not need randomness a test then has to tolerate,
# and a fan guarantees no two hats leave from the same point -- which is the
# coincident-bodies trap in CLAUDE.md, where two bodies at one position
# depenetrate straight through the floor.
func dislodge_hats(body: Node) -> void:
	if not is_host:
		return
	var worn: Array = _hats.worn_by(int(body.peer_id))
	if worn.is_empty():
		return
	var ids: Array = []
	for i in worn.size():
		var hat: Node = worn[i]
		var angle: float = TAU * float(i) / float(maxi(worn.size(), 1))
		var fan := Vector3(cos(angle), 0.0, sin(angle)) * SimConfig.HAT_SCATTER_SPEED
		var from: Vector3 = body.position + Vector3(0.0, PlayerBody.HALF_HEIGHT, 0.0) + fan.normalized() * 0.3
		_release_hat(hat, from, body.velocity + fan + Vector3(0.0, SimConfig.HAT_SCATTER_LIFT, 0.0))
		ids.append(hat.hat_id)
	_forget_hat_if_bare(int(body.peer_id))
	if networked:
		_hats_released.rpc(ids)

# LOSE YOUR HAT AND IT IS GONE NEXT TIME. Called after anything that removes
# hats: the save follows what you are actually WEARING, so a tumble that leaves
# you bare is felt the next time you open the game and not merely for the rest of
# the run.
#
# Only when the stack is empty. Losing four of five leaves you wearing one, and
# that one is still yours.
func _forget_hat_if_bare(peer: int) -> void:
	if peer != local_peer:
		return
	var worn: Array = _hats.worn_by(peer)
	if worn.is_empty():
		_remember_hat(HatConfig.NONE)
	else:
		_remember_hat(int(worn[worn.size() - 1].style_id))

# DESTROYED, not dropped. A player who leaves the world -- fell, drone-returned,
# disconnected -- takes their hats with them.
#
# Dropping them at the last deck position would be a rescue for the one failure
# the design deliberately does not rescue, and it would leave a free pile of hats
# at the exact spot that just killed somebody. Confirmed in playtest 2026-08-10:
# if you fall, you lose them.
func destroy_worn_hats(peer: int) -> void:
	if not is_host:
		return
	var ids: Array = []
	for hat in _hats.worn_by(peer):
		ids.append(hat.hat_id)
		_hats.destroy(hat)
	# LOST IS LOST, however it happened. This path is the fall and the drone -- the
	# tower is DESTROYED rather than dropped, per the rule above -- and the other
	# path is being shot off. Counted at both rather than at some later "how many
	# do they have now", because a count of what remains cannot tell a hat that was
	# lost from one that was never picked up.
	_bump(peer, "hats_lost", ids.size())
	_forget_hat_if_bare(peer)
	if networked and ids.size() > 0:
		_hats_destroyed.rpc(ids)

# SHOT OFF YOUR HEAD (playtest 2026-08-16). A round that hits a HAT takes that
# hat and every hat above it. The player is untouched: this is not armour, it is
# a second thing to aim at.
#
# THE STACK IS A SILHOUETTE, and that is the entire design. Aim in this game is
# 2D yaw, so a round travels flat at the height of the muzzle that fired it —
# which means a shooter on your level hits your BODY and a shooter above you, on a
# ramp or a raised deck or a turret on a pillar, meets your TOWER first. Carrying
# five hats does not protect you and does not endanger you; it puts a metre and a
# half of score above your head where high ground can reach it. M8.5's whole bet
# was that carrying more is louder, and this is what makes it literally so.
#
# THAT ONE AND EVERYTHING ABOVE IT. A tower is stacked, so a round through its
# middle takes the top off; the hats below it are still under the impact and stay.
# Anything else needs the tower to close up around a hole, which is both odd to
# look at and a rule nobody could read off the screen.
func knock_off_hat_stack_from(hat: Node, from_point: Vector3) -> void:
	if not is_host:
		return
	var peer: int = int(hat.owner_peer)
	var worn: Array = _hats.worn_by(peer)
	var index: int = worn.find(hat)
	if index < 0:
		return
	var body: Node = players.get(peer, null)
	var away := Vector3(0.0, 0.0, 1.0)
	if is_instance_valid(body):
		away = body.global_position - from_point
		away.y = 0.0
		if away.length_squared() < 0.01:
			away = GridConfig.yaw_vector(body.facing)
	away = away.normalized()

	var ids: Array = []
	for i in range(index, worn.size()):
		var going: Node = worn[i]
		# FANNED, so a tower that comes off does not land in one pile. The higher
		# the hat, the further it goes -- it had further to fall and more of the
		# round's line to travel along.
		var spread: float = 1.0 + 0.35 * float(i - index)
		_release_hat(going, going.global_position,
			away * SimConfig.HAT_SCATTER_SPEED * spread
			+ Vector3(0.0, SimConfig.HAT_SCATTER_LIFT, 0.0))
		ids.append(going.hat_id)
	# THE OTHER WAY TO LOSE A TOWER. Shot off rather than destroyed, and the count
	# is the same fact about the same player.
	_bump(peer, "hats_lost", ids.size())
	_forget_hat_if_bare(peer)
	if networked:
		_hats_released.rpc(ids)

func _release_hat(hat: Node, from: Vector3, velocity: Vector3) -> void:
	if hat.get_parent() != _hats_root:
		hat.get_parent().remove_child(hat)
		_hats_root.add_child(hat)
	hat.owner_peer = 0
	hat.launch(from, velocity)

@rpc("authority", "call_remote", "reliable")
func _hats_released(ids: Array) -> void:
	for id in ids:
		var hat: Node = _hats.by_id(int(id))
		if hat != null:
			_release_hat(hat, hat.global_position, Vector3.ZERO)

@rpc("authority", "call_remote", "reliable")
func _hats_destroyed(ids: Array) -> void:
	for id in ids:
		var hat: Node = _hats.by_id(int(id))
		if hat != null:
			_hats.destroy(hat)

# --- Specials -----------------------------------------------------------------
#
# The machine gun, and the slot every later special arrives in. See
# implementation_plans/m12_machine_gun.md.

func special_count() -> int:
	return _specials.count()

func special_held_by(peer: int) -> Node:
	return _specials.held_by(peer)

func _process_specials() -> void:
	if not is_host:
		return

	if grid != null:
		for entry in grid.take_authored_special_cells():
			_specials.spawn_loose(
				grid.cell_surface_world(entry[0]) + Vector3(0.0, 0.4, 0.0), int(entry[1]),
				-1, true)

	_specials.step(_trailing_edge_z())

	# WHICH STATES MAY PICK ONE UP. The same set hats use, and the same reason:
	# collecting something mid-tumble removes the cost of the tumble. A dash may,
	# because a dash across a contested pickup is exactly the moment this rule is
	# for.
	var can_carry := func(peer: int, body: Node) -> bool:
		if _returning.has(peer):
			return false
		return body.state == PlayerBody.State.WALK or body.state == PlayerBody.State.SHOVE

	for claim in _specials.resolve_pickups(players, can_carry):
		var taken: Node = claim[0]
		var peer: int = int(claim[1])
		var replaced: Node = claim[2]
		# ONE SLOT: the old one leaves the hand before the new one enters it, with
		# whatever ammo it had. Dropped a step in FRONT of the holder rather than
		# underneath them -- two bodies at identical coordinates depenetrate into a
		# degenerate normal and fall through the floor.
		if replaced != null and is_instance_valid(replaced):
			_drop_special(replaced, _specials.drop_offset(players[peer]))
			if networked:
				_special_dropped.rpc(replaced.special_id, replaced.position)
		_take_special(taken.special_id, peer)
		# OWNERSHIP GOES RELIABLY, positions ride the unreliable snapshot. Same
		# split as hats: a lost pickup that never applies is a client holding a
		# weapon the host says is on the deck, and nothing re-sends it.
		if networked:
			_take_special.rpc(taken.special_id, peer)

	_fire_specials()

# One tick of everybody's trigger.
#
# HOST ONLY, AND NEVER PREDICTED. A client has no authority to decide that a round
# hit somebody, and there is nothing to gain by guessing -- unlike walking, which
# is predicted precisely because the delay is felt. See physics_and_authority.md:
# committed actions play from host state.
func _fire_specials() -> void:
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var body: Node = players[peer]
		var weapon: Node = _specials.held_by(peer)
		if weapon == null:
			continue

		weapon.fire_timer = maxf(0.0, weapon.fire_timer - SimConfig.TICK_DELTA)

		var inp: Array = _current_input.get(peer, PlayerInput.empty(0))
		var held: bool = (int(inp[PlayerInput.ACTIONS]) & SimConfig.ACTION_SPECIAL_HELD) != 0

		# LOSING CONTROL LOSES THE THROW, and that is not merely bookkeeping. If a
		# lost trigger counted as a RELEASE, being tumbled mid-charge would hurl a
		# grenade at whatever the tumble happened to leave you facing -- a special
		# spent, by the game, on your behalf. Cancelling costs the charge and keeps
		# the ammo, so the cost of being knocked over is the moment rather than the
		# resource.
		if not _can_fire(peer, body):
			weapon.charge = 0.0
			weapon.was_held = false
			continue

		# ONE BUTTON, FOUR MEANINGS. The machine gun fires while it is DOWN; a
		# grenade throws when it comes UP; a mine is laid on the way down; a shield
		# is simply UP for as long as the button is. Which one a special is, is the
		# whole difference between them -- the slot, the pickup, the drop and the
		# HUD box are shared, so this match is where a new special actually lands.
		var spent_a_use: bool = false
		match weapon.kind:
			SpecialBody.Kind.MACHINE_GUN:
				spent_a_use = _step_machine_gun(body, weapon, held)
			SpecialBody.Kind.GRENADE:
				spent_a_use = _step_grenade(peer, body, weapon, held)
			SpecialBody.Kind.MINE:
				spent_a_use = _step_mine(peer, body, weapon, held)
			SpecialBody.Kind.SHIELD:
				spent_a_use = _step_shield(peer, body, weapon, held)
			SpecialBody.Kind.ROCKET:
				spent_a_use = _step_rocket(body, weapon, held)
			SpecialBody.Kind.LEGS:
				spent_a_use = _step_legs(body, weapon)
			SpecialBody.Kind.SHOTGUN:
				spent_a_use = _step_shotgun(body, weapon, held)
			SpecialBody.Kind.RIFLE:
				spent_a_use = _step_rifle(body, weapon, held)
		weapon.was_held = held

		# SPENT MEANS GONE. An empty special you keep carrying is the worst possible
		# occupant of a one-slot rule: it does nothing and it stops you picking up
		# the thing that would.
		#
		# CHECKED EVERY TICK RATHER THAN ONLY WHEN A USE WAS SPENT, and NOT while a
		# shield is still up. A shield spends its use the moment it RISES, so
		# destroying on the spend would have deleted the last one in the same tick
		# it was raised -- a third deployment that protected nobody from anything,
		# and the kind of bug that only shows up on the last charge.
		if weapon.is_spent() and not (int(weapon.kind) == SpecialBody.Kind.SHIELD 				and body.shielding):
			var id: int = weapon.special_id
			_specials.destroy(weapon)
			if networked:
				_special_destroyed.rpc(id)

# Held down, and every interval a round leaves.
func _step_machine_gun(body: Node, weapon: Node, held: bool) -> bool:
	if not held or weapon.fire_timer > 0.0:
		return false
	weapon.fire_timer = DebugSettings.tuned("mg_fire_interval", SimConfig.MG_FIRE_INTERVAL)
	weapon.ammo -= 1
	_fire_round(body, weapon)
	return true

# HELD DOWN, like the machine gun, and firing on the same timer -- a rocket is a
# gun, not a thrown thing. The cadence does all the work of making it feel
# different: at ROCKET_FIRE_INTERVAL two shots take three seconds, so holding the
# button is not a strategy.
# THE BODY LAUNCHED; THIS IS THE BILL. Legs are the one special whose effect is
# NOT applied out here, because the effect is on the player's own vertical
# velocity and a client predicts that — see PlayerBody._step_walk. So the
# condition lives there, in the function a replay re-runs, and the world reads the
# flag it raised rather than re-deriving "did they launch" from the inputs. Two
# copies of that predicate is two things that have to agree forever, and this
# project has already paid for that shape more than once.
#
# `held` is deliberately not a parameter: whether the button is down is exactly
# the question the body already answered.
func _step_legs(body: Node, weapon: Node) -> bool:
	if not body.legs_fired:
		return false
	body.legs_fired = false
	weapon.ammo -= 1
	return true

func _step_rocket(body: Node, weapon: Node, held: bool) -> bool:
	if not held or weapon.fire_timer > 0.0:
		return false
	weapon.fire_timer = SimConfig.ROCKET_FIRE_INTERVAL
	weapon.ammo -= 1
	# ZEROED THE SAME WAY THE MACHINE GUN IS, and for the same reason: the barrel
	# is held to one side of the body, so a rocket sent straight down `facing`
	# would travel on a line offset by that much forever and miss somebody standing
	# dead centre. See _fire_round for the full argument.
	#
	# BUT NO SPREAD. The cone is what makes the machine gun a suppression weapon; a
	# rocket is one decision and it goes where it was pointed, or the player is
	# being asked to gamble two of them on a dice roll.
	_spawn_round(_muzzle_of(weapon, body), aim_direction(body, weapon),
		int(body.peer_id), body.get_rid(), true)
	return true

# A FISTFUL AT ONCE. Seven pellets leave on one trigger pull, each with its own
# roll inside a wide cone, and the SHOT is what costs ammunition -- not the pellet.
# That is what makes the magazine eight rather than fifty-six, and what makes each
# pull a decision the player can count.
#
# EVERY PELLET IS AIMED THROUGH aim_direction, so the shotgun gets point aim and
# the assist for free and the cone is applied on top. A weapon that computed its
# own direction would be outside the A/B while looking like it was in it.
func _step_shotgun(body: Node, weapon: Node, held: bool) -> bool:
	if not held or weapon.fire_timer > 0.0:
		return false
	weapon.fire_timer = SimConfig.SHOTGUN_FIRE_INTERVAL
	weapon.ammo -= 1
	var from: Vector3 = _muzzle_of(weapon, body)
	var aimed: Vector3 = aim_direction(body, weapon)
	for _pellet in SimConfig.SHOTGUN_PELLETS:
		_spawn_round(from, _spread(aimed, SimConfig.SHOTGUN_SPREAD_DEG,
			SimConfig.SHOTGUN_SPREAD_VERTICAL_DEG), int(body.peer_id),
			body.get_rid(), false, SimConfig.SHOTGUN_DAMAGE)
	return true

# ONE ROUND, ALMOST EXACTLY WHERE YOU POINTED, SLOWLY.
#
# The cone is 0.4 degrees rather than zero. Not squeamishness: a perfectly
# deterministic line makes two players standing in the same place fire the same
# round forever, and a hair of scatter is what keeps a burst from being one
# bullet. It is well inside a body at any range the bridge offers.
func _step_rifle(body: Node, weapon: Node, held: bool) -> bool:
	if not held or weapon.fire_timer > 0.0:
		return false
	weapon.fire_timer = SimConfig.RIFLE_FIRE_INTERVAL
	weapon.ammo -= 1
	_spawn_round(_muzzle_of(weapon, body),
		_spread(aim_direction(body, weapon), SimConfig.RIFLE_SPREAD_DEG,
			SimConfig.RIFLE_SPREAD_VERTICAL_DEG),
		int(body.peer_id), body.get_rid(), false, SimConfig.RIFLE_DAMAGE)
	return true

# HELD TO ADJUST DISTANCE, thrown on release.
#
# THE RELEASE EDGE IS DERIVED FROM THE LEVEL BIT rather than sent as its own
# action, so a throw does not depend on one press packet arriving -- see
# special_body.was_held. The charge is read at the moment the button comes up,
# which is what makes the hold a decision the player watches themselves make.
func _step_grenade(peer: int, body: Node, weapon: Node, held: bool) -> bool:
	if held:
		weapon.charge = minf(weapon.charge + SimConfig.TICK_DELTA,
			SimConfig.GRENADE_CHARGE_TIME)
		return false
	if not weapon.was_held:
		return false
	var fraction: float = weapon.charge_fraction()
	weapon.charge = 0.0
	weapon.ammo -= 1
	_throw_grenade(peer, body, fraction)
	return true

# A BALLISTIC LOB, not a flat shot. Range is set by SPEED at a fixed angle, which
# is what makes "hold longer, throw further" one number; and an arc is what lets a
# grenade clear a parapet a bullet cannot, which is the geometry answer the
# specials exist to add.
#
# The near end of the range is INSIDE the blast on purpose. A tap has to be able
# to hurt you, or holding longer is strictly better and the verb is decoration.
func _throw_grenade(peer: int, body: Node, fraction: float) -> void:
	var distance: float = lerpf(SimConfig.GRENADE_MIN_RANGE, SimConfig.GRENADE_MAX_RANGE,
		fraction)
	var angle: float = deg_to_rad(SimConfig.GRENADE_THROW_ANGLE_DEG)
	# THROUGH GridConfig, NOT sin/cos BY HAND. Written out longhand this was
	# Vector3(sin(f), 0, cos(f)) -- the exact NEGATION of yaw_vector -- so every
	# grenade in the game was lobbed over the thrower's shoulder. Measured
	# 2026-08-14: facing north, the grenade travelled +2.94 m in Z when forward is
	# -Z. The same expression lives in SpecialPool.drop_offset, where it is
	# correctly called `away`; copying it and renaming it `forward` is the whole
	# bug. Nothing caught it because test_grenade measured DISTANCE, which is a
	# magnitude and has no opinion about which way anything went.
	var forward: Vector3 = GridConfig.yaw_vector(body.facing)

	# SOLVED FROM THE RELEASE POINT, NOT FROM LEVEL GROUND. The hand is 1.2 m up
	# and 0.7 m forward, and a grenade launched from a height flies further than
	# `R = v^2 sin(2a)/g` says -- see GRENADE_RELEASE_HEIGHT for what that cost.
	#
	#   0 = h + x tan(a) - g x^2 / (2 v^2 cos^2(a))   ->   v^2 = g x^2 / D
	#
	# where x is the horizontal run still to cover and h the height it falls.
	var run: float = maxf(distance - SimConfig.GRENADE_THROW_FORWARD, 0.5)
	var denom: float = 2.0 * pow(cos(angle), 2.0) \
		* (SimConfig.GRENADE_RELEASE_HEIGHT + run * tan(angle))
	var speed: float = sqrt(SimConfig.GRAVITY * run * run / denom)

	var velocity: Vector3 = forward * speed * cos(angle) + Vector3.UP * speed * sin(angle)
	var feet: float = body.global_position.y - PlayerBody.HALF_HEIGHT
	var release := Vector3(
		body.global_position.x + forward.x * SimConfig.GRENADE_THROW_FORWARD,
		feet + SimConfig.GRENADE_RELEASE_HEIGHT,
		body.global_position.z + forward.z * SimConfig.GRENADE_THROW_FORWARD)
	var d: Node = _spawn_deployable(Deployable.Kind.GRENADE)
	d.throw_from(release, velocity, peer)

# PLACED AT YOUR FEET, on the button going DOWN. A mine is the one special whose
# whole verb is spending something now to be paid back later, so there is nothing
# to hold and nothing to aim -- the decision is WHERE you were standing and WHEN.
func _step_mine(peer: int, body: Node, weapon: Node, held: bool) -> bool:
	# THE SAME TRIGGER THE MACHINE GUN USES, down to the timer field: held lays
	# them on a cadence, a tap lays one. It was one-per-press, which made the same
	# button behave differently depending on what was in your hands.
	if not held or weapon.fire_timer > 0.0:
		return false
	weapon.fire_timer = SimConfig.MINE_PLACE_INTERVAL
	weapon.ammo -= 1
	var spot: Array = _mine_drop_point(body)
	_spawn_deployable(Deployable.Kind.MINE).place_at(spot[0], peer, bool(spot[1]))
	return true

# WHERE A MINE GOES: at your feet, one step in front, sitting ON the deck.
#
# Returns [point, found_ground]. The downward probe is what makes it sit rather
# than drop -- placing at the feet and letting gravity do the rest puts the mine
# wherever the fall ends, which on a ramp or a moving player is not where the
# button was pressed.
func _mine_drop_point(body: Node) -> Array:
	var forward: Vector3 = GridConfig.yaw_vector(body.facing)
	var feet: float = body.global_position.y - PlayerBody.HALF_HEIGHT
	var ahead := Vector3(
		body.global_position.x + forward.x * SimConfig.MINE_DROP_FORWARD,
		feet,
		body.global_position.z + forward.z * SimConfig.MINE_DROP_FORWARD)

	var space := get_world_3d().direct_space_state
	if space != null:
		var from: Vector3 = ahead + Vector3(0.0, 0.5, 0.0)
		var query := PhysicsRayQueryParameters3D.create(from,
			from - Vector3(0.0, SimConfig.MINE_GROUND_PROBE + 0.5, 0.0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			# Its own half-height above the surface, so it rests ON the deck rather
			# than half inside it.
			return [Vector3(ahead.x, float(hit["position"].y) + 0.07, ahead.z), true]
	# Nothing under it -- placed over a hole. Left live so it falls away, which
	# costs the use and is the right answer.
	return [ahead, false]

func _spawn_deployable(kind: int) -> Node:
	var scene: PackedScene = MineScene if kind == Deployable.Kind.MINE else GrenadeScene
	var d: Node3D = scene.instantiate()
	_next_deployable_id += 1
	d.deployable_id = _next_deployable_id
	d.kind = kind
	d.name = "Deployable_%d" % d.deployable_id
	_deployables_root.add_child(d)
	_deployables.append(d)
	return d

# One tick of every live thing on the deck. HOST ONLY: a client is told where a
# grenade is and never decides that one went off, for the same reason it never
# decides a round hit somebody.
func _process_deployables() -> void:
	for i in range(_deployables.size() - 1, -1, -1):
		var d: Node = _deployables[i]
		if not is_instance_valid(d):
			_deployables.remove_at(i)
			continue
		# OFF THE BRIDGE IS NOT A BANG. A grenade thrown into the void is a wasted
		# special, which is the correct outcome and the funnier one.
		if d.position.y < SimConfig.FALL_KILL_Y or d.position.z > _trailing_edge_z():
			_deployables.remove_at(i)
			d.queue_free()
			continue
		# ONLY A MINE ASKS. A grenade's answer is always ignored, and this is a
		# distance check against every walking body on the bridge.
		var near: bool = d.wants_proximity_check() 			and _anything_walking_within(d.position, SimConfig.MINE_TRIGGER_RADIUS)
		if not d.step(near):
			continue
		blast_at(d.position, d.blast_radius(), Hit.Kind.EXPLOSIVE, int(d.thrower))
		_deployables.remove_at(i)
		d.queue_free()

func _deployable_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for d in _deployables:
		if is_instance_valid(d):
			out.append(d.capture_state())
	return SnapshotDelta.encode(out, _section("deployables"), keyframe)

# A client rebuilds its set to match the host's. A grenade that goes off simply
# stops being mentioned, and the manifest turns that into a free -- the same
# destroy-if-absent rule every other section uses.
func _apply_deployable_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var d: Node = _deployable_by_id(id)
		if d == null:
			# THE KIND PICKS THE SCENE, exactly as it does on the host. A client
			# that built every deployable from one scene would show a mine as a
			# grenade -- and the two are told apart by shape on purpose.
			d = _spawn_deployable(int(entry[1]))
			d.deployable_id = id
			d.name = "Deployable_%d" % id
		d.apply_state(entry)
	for i in range(_deployables.size() - 1, -1, -1):
		var existing: Node = _deployables[i]
		if not is_instance_valid(existing) or not seen.has(existing.deployable_id):
			_deployables.remove_at(i)
			if is_instance_valid(existing):
				existing.queue_free()

func _deployable_by_id(id: int) -> Node:
	for d in _deployables:
		if is_instance_valid(d) and d.deployable_id == id:
			return d
	return null

# IS THE THING IN YOUR HANDS A SHIELD? An INPUT to the body, not state on it: the
# body decides whether it is anchored, and it needs to know what it is holding to
# do that, but the slot itself is the pool's business and never the body's.
#
# Refreshed on both machines, from the same lookup, because the client predicts
# its own anchoring -- see the note at the call site in _client_tick.
func _refresh_shield_flag(peer: int, body: Node) -> void:
	var weapon: Node = _specials.held_by(peer)
	body.has_shield = weapon != null and int(weapon.kind) == SpecialBody.Kind.SHIELD
	# THE AMMO IS FOLDED IN HERE, not tested at the launch. "Can I launch" has to
	# be ONE question asked in ONE place, or the client predicts a hop the host
	# refuses and the correction lands on the player's own body. The slot is
	# replicated, so both machines read the same weapon and the same count.
	body.has_legs = weapon != null 		and int(weapon.kind) == SpecialBody.Kind.LEGS 		and int(weapon.ammo) > 0

# ONE USE PER DEPLOYMENT, spent when it goes up. There is no timer on the shield:
# standing still IS the timer, on a bridge that has to be crossed and with things
# arriving from behind. The anchoring itself is decided in PlayerBody._step_walk,
# because a client replays that function and a shield applied from out here would
# be missing on every replayed tick.
func _step_shield(_peer: int, _body: Node, weapon: Node, held: bool) -> bool:
	if not held or weapon.was_held:
		return false
	weapon.ammo -= 1
	return true

# A player has to be in control of themselves to fire. Same set that may pick one
# up, for the same reason: shooting while tumbling would make a tumble free.
func _can_fire(peer: int, body: Node) -> bool:
	if _returning.has(peer):
		return false
	return body.state == PlayerBody.State.WALK or body.state == PlayerBody.State.SHOVE

# A ROUND IS AN OBJECT IN FLIGHT, spawned at the muzzle. It was a hitscan ray
# first; playtest asked for balls, and the argument that made a ray right -- ten
# rounds a second per player is too many objects -- stopped applying when the rate
# came down to 2.5. See scripts/sim/bullet.gd for what a round actually is (not a
# rigid body either).
#
# IT LEAVES THE BARREL, NOT THE NOSE. Asked for in playtest, and it is not
# cosmetic: the muzzle is about a metre in front of the body and 45 cm to its
# right, so a round now starts on the correct side of anything the shooter is
# standing beside. The weapon hangs off the Facing pivot, which player_body
# already rotates to match `facing`, so the barrel's global transform IS the
# answer and nothing here has to re-derive where anyone is pointing.
func _fire_round(shooter: Node, weapon: Node) -> void:
	var from: Vector3 = _muzzle_of(weapon, shooter)

	# CONVERGED ON THE AIM RAY, not fired parallel to it, and this is the part
	# moving the muzzle off the nose actually costs.
	#
	# The barrel is held to one side of the body. A round sent straight down
	# `facing` from there travels on a line offset by that much FOREVER -- so
	# somebody standing directly in front of you, dead centre, is missed by a
	# couple of hand-widths at every range. Which reads as the gun being broken.
	#
	# Aiming at a point on the body's own aim ray fixes it the way a real weapon is
	# zeroed: exact at MG_RANGE, and off by less than the muzzle offset everywhere
	# nearer -- which is well inside a 0.4 m body.
	var direction: Vector3 = _spread(aim_direction(shooter, weapon))

	_spawn_round(from, direction, int(shooter.peer_id), shooter.get_rid())

# ONE ROUND, whoever fired it. Shared by the player's machine gun and by both
# gunners -- so an enemy's round is the same object as yours, stopped by the same
# cover, and resolved through the same matrix. `source` of 0 means the world.
# `damage` DEFAULTS TO THE MACHINE GUN'S so every existing caller -- both gunners
# included -- keeps firing exactly what it fired before. A round has to carry it
# rather than have it looked up at impact, because by then the weapon may be
# spent, dropped, or in somebody else's hands.
func _spawn_round(from_global: Vector3, direction: Vector3, source: int,
		shooter_rid: RID, as_rocket: bool = false,
		damage: int = SimConfig.MG_DAMAGE) -> void:
	# SHOTS FIRED, AT THE LINE A ROUND IS SPAWNED. Every round in the game comes
	# through here -- the player's machine gun, the rocket, and both gunners' --
	# so a source of 0 (the world) is filtered by _bump rather than by a branch.
	_bump(source, "shots_fired")
	var scene: PackedScene = RocketScene if as_rocket else BulletScene
	var bullet: Node3D = scene.instantiate()
	_next_bullet_id += 1
	bullet.bullet_id = _next_bullet_id
	bullet.damage = damage
	bullet.name = "Bullet_%d" % _next_bullet_id
	_bullets_root.add_child(bullet)
	_bullets.append(bullet)
	bullet.launch(to_local(from_global), direction, source, shooter_rid, as_rocket)

# The tip of the barrel, in GLOBAL space. Falls back to the body if a weapon has
# somehow not been posed yet -- a round from slightly the wrong place beats a
# round from the origin of the world.
# --- Where a shot is aimed (M20) ----------------------------------------------
#
# ONE FUNCTION, AND EVERYTHING USES IT. The round, the rocket, the laser sight
# and the barrel rotation all ask here. That is not tidiness: a sight that
# computed its own direction could agree with the cursor while the bullet
# disagreed with both, and this project has already shipped a hit test that
# disagreed with the art it was drawn from.

# The PLACE a shot is aimed at.
#
# `level` reproduces the shipped behaviour exactly -- a zero 30 m down the
# bearing at the shooter own height, which is why every shot leaves flat.
# `point` uses the world position the cursor rests on, which carries height.
func aim_target(body: Node) -> Vector3:
	var target: Vector3 = body.global_position + GridConfig.yaw_vector(body.facing) * SimConfig.MG_RANGE
	if DebugSettings.get_choice_name("aim_mode") == "point" and is_finite(body.aim_point.x):
		target = body.aim_point
	if DebugSettings.get_choice_name("aim_assist") == "snap":
		target = _snap_to_enemy(body, target)
	return target

# THE DIRECTION FROM THE GUN, not from the player.
#
# The muzzle is the barrel tip, held to one side, so a direction taken at the
# body and reused at the muzzle is off by that offset forever. Aiming FROM the
# muzzle AT the target is what makes the offset vanish -- and in `point` mode it
# vanishes at the range the shot is actually taken rather than only at thirty
# metres, which is the whole of the rocket complaint.
func aim_direction(body: Node, weapon: Node) -> Vector3:
	var from: Vector3 = _muzzle_of(weapon, body)
	var away: Vector3 = aim_target(body) - from
	if away.length_squared() < 0.0001:
		return GridConfig.yaw_vector(body.facing)
	return away.normalized()

# CENTRE MASS, WHEN THE SHOT WAS ALREADY GOING TO PASS CLOSE.
#
# Alien Swarm rule and their phrasing: any entity in line of sight of where you
# are aiming is aimed at, snapping to the centre of the body. It triggers on what
# the RAY passes rather than on screen proximity, which is what makes it the fix
# for shooting at a different height -- point roughly at something above you and
# the assist supplies the elevation.
#
# A TIGHT RADIUS, DELIBERATELY. See SimConfig.AIM_SNAP_RADIUS.
func _snap_to_enemy(body: Node, target: Vector3) -> Vector3:
	var from: Vector3 = body.global_position
	var along: Vector3 = target - from
	var span: float = along.length()
	if span < 0.001:
		return target
	along /= span
	var best: Vector3 = target
	var best_distance: float = span
	for list in [_rushers, _gunners]:
		for enemy in list:
			if not is_instance_valid(enemy) or enemy.is_spent():
				continue
			var offset: Vector3 = enemy.global_position - from
			var along_ray: float = offset.dot(along)
			# BEHIND YOU IS NOT A TARGET, and neither is past the point you asked
			# for -- aiming SHORT of something is how a blast is placed in front of
			# it, which the tight radius exists to preserve.
			if along_ray <= 0.0 or along_ray > span:
				continue
			if (offset - along * along_ray).length() > SimConfig.AIM_SNAP_RADIUS:
				continue
			# NEAREST WINS. A second enemy further down the same line must not
			# steal the aim off the one in front of it.
			if along_ray < best_distance:
				best_distance = along_ray
				best = enemy.global_position
	return best

func _muzzle_of(weapon: Node, shooter: Node) -> Vector3:
	var barrel := weapon.get_node_or_null("Barrel") as Node3D
	if barrel != null and barrel.is_inside_tree():
		# HALF ITS OWN LENGTH ALONG ITS LOCAL +Y, which is the tip. A cylinder's
		# axis is Y in Godot, and special.tscn rotates the barrel so that Y lies
		# along the gun's -Z -- so the obvious `Vector3(0, 0, -0.3)` points at the
		# ground rather than down the bore. Worth the sentence: it fired
		# convincingly and put every round 30 cm under the muzzle.
		return barrel.global_transform * Vector3(0.0, 0.25, 0.0)
	# MUZZLE HEIGHT IS A HITBOX DECISION, not a cosmetic one. The body's origin is
	# its centre, 0.9 m above the deck; +0.25 is 1.15 m, comfortably inside a 1.8 m
	# player AND inside a 1.4 m rusher. Firing from shoulder height looked better
	# and shot straight over the top of every rusher on the bridge.
	return shooter.global_position + Vector3(0.0, 0.25, 0.0)

# AN ELLIPTICAL CONE: wide across, narrow up and down. Asked for in playtest, in
# two goes -- "a little weapon spread", then 10 degrees, then 2 degrees of
# vertical.
#
# Yaw and pitch are rolled SEPARATELY rather than as one tilt-and-azimuth, which
# is what makes two numbers possible at all. A round cone has a single width by
# construction, and the width it had was throwing rounds two metres over people's
# heads at thirty: the bridge is a narrow strip and everything worth shooting
# stands on it, so horizontal scatter reads as spraying and vertical scatter reads
# as broken.
#
# Random on the HOST ONLY, which is what makes randf_range acceptable here: nobody
# else re-derives it, the same licence plinko's launch angle takes. It is the only
# randomness in the whole weapon.
# A CONE AROUND A DIRECTION, and the cone is now the WEAPON'S rather than the
# machine gun's. Defaulting to the machine gun's numbers keeps every existing
# caller and every existing test on exactly the path they were on.
func _spread(base: Vector3, spread_deg: float = -1.0,
		vertical_deg: float = -1.0) -> Vector3:
	var spread: float = spread_deg if spread_deg >= 0.0 		else DebugSettings.tuned("mg_spread_deg", SimConfig.MG_SPREAD_DEG)
	var vertical: float = vertical_deg if vertical_deg >= 0.0 		else SimConfig.MG_SPREAD_VERTICAL_DEG
	var yaw_off: float = deg_to_rad(randf_range(-spread, spread))
	var pitch_off: float = deg_to_rad(randf_range(-vertical, vertical))

	# Yaw about world up, so "horizontal" means horizontal on the bridge rather
	# than horizontal relative to a barrel that may be pointing slightly downhill.
	var out: Vector3 = base.rotated(Vector3.UP, yaw_off)
	# Then pitch about the axis across the NEW heading.
	var across: Vector3 = out.cross(Vector3.UP)
	if across.length_squared() < 0.0001:
		return out.normalized()      # aimed straight up or down; nothing to pitch about
	return out.rotated(across.normalized(), pitch_off).normalized()

# Every round in flight, one tick.
#
# THE SWEEP IS THE HIT TEST. Each round reports where it came from, and a single
# ray along the segment it just covered answers everything at once: terrain,
# cover, players, rushers. Exact at any speed -- a round cannot pass through a
# player between two frames, which is the failure a fast rigid body has and the
# reason this is not one.
func _process_bullets() -> void:
	if not is_host:
		return
	var space := get_world_3d().direct_space_state
	for i in range(_bullets.size() - 1, -1, -1):
		var bullet: Node = _bullets[i]
		if not is_instance_valid(bullet):
			_bullets.remove_at(i)
			continue

		var from_local: Vector3 = bullet.step()
		var struck: bool = false
		if space != null:
			# world | players | stones | BALLS | rushers.
			#
			# Balls were deliberately absent, on the argument that a ball stopping a
			# round makes the plinko field cover. Playtest asked for rounds to push
			# them, and that IS the trade: the field is now partial cover, and it is
			# also something you can shoot at somebody.
			#
			# AND WORN HATS, on their own layer (2026-08-16). A hat on a head is a
			# target; one on the DECK is not, or a dropped pile would be cover
			# nobody built. Two layers, because a hat means two different things
			# depending on where it is.
			var query := PhysicsRayQueryParameters3D.create(
				to_global(from_local), to_global(bullet.position),
				1 | 2 | 4 | 8 | 16 | HatBody.WORN_LAYER)
			query.exclude = [bullet.shooter_rid]
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				struck = true
				# THE ONLY LINE A ROCKET CHANGES. It travels, is swept and is
				# replicated exactly as a round is; what differs is what happens at
				# the far end of the raycast.
				if bool(bullet.explodes):
					blast_at(to_local(hit["position"]), SimConfig.BLAST_RADIUS,
						Hit.Kind.EXPLOSIVE, int(bullet.owner_peer))
				else:
					_resolve_round_hit(hit.get("collider"), bullet.velocity.normalized(),
						to_local(hit["position"]), bullet.origin,
						int(bullet.owner_peer), int(bullet.damage))

		if struck or bullet.is_spent():
			_bullets.remove_at(i)
			bullet.queue_free()

func bullet_count() -> int:
	return _bullets.size()

# ONE EXPLOSION, resolved through the matrix. Every EXPLOSIVE source will call
# this -- grenades and mines both -- and it exists now because a mound is
# reachable by nothing else.
#
# THE ORDER MATTERS: mounds first, because they are grid DATA rather than bodies
# and would otherwise be invisible to a pass that walks nodes. That is also the
# whole reason a grenade can pre-empt a rusher before it wakes.
#
# Returns how many things it affected, so a caller can tell whether the charge
# was worth spending.
# `source` is whoever set it off, or 0 for the world -- a mound going up under
# somebody is nobody's doing. Defaulted so every existing caller still compiles,
# and passed by the ones that know.
func blast_at(centre: Vector3, radius: float, kind: int = Hit.Kind.EXPLOSIVE,
		source: int = 0) -> int:
	if not is_host:
		return 0
	var affected := 0
	if kind == Hit.Kind.EXPLOSIVE and grid != null:
		var structures: int = grid.blast_mounds(centre, radius) 			+ grid.blast_shooters(centre, radius)
		affected += structures
		# TOLD, NOT INFERRED, and told the moment it happens. A mound or a shooter
		# is rebuilt from the run seed on every machine, so a client that is not
		# told keeps drawing scenery the host has destroyed. This was already a gap
		# for mounds -- the spent set was sent on JOIN and never again -- so the
		# same line closes both.
		if structures > 0 and networked and is_host:
			_sync_spent_mounds.rpc(grid.spent_mound_layout())
			_sync_spent_shooters.rpc(grid.spent_shooter_layout())

	for target in _blast_targets(centre, radius):
		var hit: RefCounted = Hit.make(kind, SimConfig.BLAST_DAMAGE, centre,
			SimConfig.BLAST_PUSH, SimConfig.BLAST_LIFT, maxi(source, 0))
		if _deliver(target, hit):
			affected += 1

	# SEEN BY EVERYONE, AND TOLD RATHER THAN INFERRED. A client could almost work
	# this out for itself -- a grenade stops being mentioned in the snapshot when
	# it goes off -- but "stopped being mentioned" is also what happens when one
	# falls off the bridge, and that deliberately is NOT a bang. Guessing would put
	# an explosion over the void every time somebody missed.
	#
	# EVERY blast comes through here, so the grenade and the mine get this from the
	# same line and a third explosive will too.
	_play_blast(centre, radius)
	if networked:
		_blast_seen.rpc(centre, radius)
	return affected

# The visual only. Host and client both land here -- one from blast_at, the other
# from the RPC -- so there is a single description of what an explosion looks like.
func _play_blast(at: Vector3, radius: float) -> void:
	if not view_active:
		return
	BlastEffect.spawn(self, at, radius)

@rpc("authority", "call_remote", "reliable")
func _blast_seen(at: Vector3, radius: float) -> void:
	if is_host:
		return
	_play_blast(at, radius)

# ANYTHING ON LEGS, standing here. Players, rushers and gunners -- the things a
# mine is for. Deliberately NOT balls: a plinko ball rolling over a mine would
# spend it on nobody, and the arena is full of them.
#
# Assembled from the pools rather than from a physics query, for the same reason
# _blast_targets is: these are the objects that can answer for themselves, and a
# shapecast would be filtering the world by shape when the question is about kind.
func _anything_walking_within(centre: Vector3, radius: float) -> bool:
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if is_instance_valid(body) and not body.is_awaiting_rescue() 				and body.position.distance_to(centre) <= radius:
			return true
	for group in [_rushers, _gunners]:
		for node in group:
			if is_instance_valid(node) and node.position.distance_to(centre) <= radius:
				return true
	return false

# Everything within reach that can answer for itself. Deliberately assembled from
# the pools rather than from a physics query: a blast reaches through cover by
# design (that is what distinguishes it), so a shapecast would be filtering by the
# wrong rule.
func _blast_targets(centre: Vector3, radius: float) -> Array:
	var out: Array = []
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if is_instance_valid(body) and body.position.distance_to(centre) <= radius:
			out.append(body)
	for group in [_rushers, _gunners, _balls, _hats.all(), _specials.all(), _deployables]:
		for node in group:
			if is_instance_valid(node) and node.has_method("receive_hit") 					and node.position.distance_to(centre) <= radius:
				out.append(node)
	if grid != null:
		for stone in grid._stone_list:
			if is_instance_valid(stone) and stone.position.distance_to(centre) <= radius:
				out.append(stone)
	return out

# `at` is where the round STOPPED; `origin` is where it came from. They are two
# different questions and passing the first as the answer to the second is what
# made the shield useless against gunfire (playtest 2026-08-16, "the shield
# doesn't block shots very well").
func _resolve_round_hit(target, direction: Vector3, at: Vector3,
		origin: Vector3 = Vector3.INF, shooter: int = -1,
		damage: int = SimConfig.MG_DAMAGE) -> void:
	if target == null:
		return
	# THE CHAIN OF "WHAT ARE YOU?" QUESTIONS IS GONE. This used to ask
	# has_method("deflect") and "ball_id" in target, then has_method("begin_rise"),
	# then "peer_id" in target -- the machine gun deciding, in its own code, what
	# every other object in the game was and what it deserved. Each of those
	# answers now lives on the thing being hit, next to the reason for it.
	if not target.has_method("receive_hit"):
		return                    # deck, parapet, a shooter's pillar: cover works
	# A HAT ON A HEAD IS ITS OWN TARGET, and the round is spent on it rather than
	# on the person under it. Asked of the hat rather than decided here:
	# `takes_rounds` lives on HatBody next to the reason for it, which is the rule
	# this function was rewritten around.
	if target.has_method("takes_rounds") and target.takes_rounds():
		# NOT YOUR OWN. The muzzle is a metre in front of your face and your tower
		# is above it; shooting your own hats off by firing would be a tax on
		# holding the trigger.
		if int(target.owner_peer) != shooter:
			knock_off_hat_stack_from(target, origin if is_finite(origin.x) else at)
		return
	# A HAT ON A HEAD IS ITS OWN TARGET, and the round is spent on it rather than
	# on the person under it. Asked of the hat, not decided here: `takes_rounds`
	# lives on HatBody next to the reason for it, which is the rule this function
	# was rewritten around.
	# THE MUZZLE, NOT THE IMPACT POINT. `hit.from` means "where did this come
	# from", and every consumer of it — the shield's arc most of all — is asking
	# a question about a BEARING. The impact point of a round is roughly the
	# surface of the thing it hit, so passing it made every bullet in the game
	# arrive from a point 40 cm away: inside SHIELD_MIN_BLOCK_DISTANCE, therefore
	# unblockable, at every angle, always.
	var came_from: Vector3 = origin if is_finite(origin.x) else at - direction * SimConfig.MG_RANGE
	# SOURCE, WHICH WAS BEING DROPPED. Hit.make takes it last and defaults it to 0
	# -- the world -- so every round in the game arrived unattributed even though
	# `shooter` was sitting right here in the signature. Nothing needed it until
	# M19 asked who shot whom, which is how a defaulted argument stays wrong.
	_deliver(target, Hit.make(Hit.Kind.BULLET, damage, came_from,
		SimConfig.MG_KNOCKBACK, SimConfig.MG_KNOCKBACK_LIFT, maxi(shooter, 0)))

# Under the holder's Facing pivot, which player_body already rotates to match
# `facing` -- so the barrel points where they are aiming and nothing here has to
# know what aiming is.
func _pose_held_special(weapon: Node, body: Node) -> void:
	var attach := body.get_node_or_null("Facing") as Node3D
	if attach == null:
		return
	if weapon.get_parent() != attach:
		weapon.get_parent().remove_child(weapon)
		attach.add_child(weapon)
	# HELD CLOSE TO THE CENTRELINE. It looked better further out on the hip, and
	# every centimetre of that is error the convergence in _fire_round has to
	# correct for at close range -- so it is carried in front rather than beside.
	# 0.25 m up puts the barrel at 1.15 m, inside a 1.8 m player and inside a 1.4 m
	# rusher; firing from shoulder height shot over the top of every rusher on the
	# bridge.
	weapon.position = Vector3(0.22, 0.25, -0.35)
	# THE BARREL POINTS WHERE THE ROUND GOES (M20 phase 2b).
	#
	# It was Vector3.ZERO -- parented to the Facing pivot and left there -- so the
	# gun pointed along `facing` while the shot did not. Both weapons have always
	# converged on a zero down the centreline, which leaves the muzzle angled 0.42
	# degrees inboard of the barrel it comes out of.
	#
	# Nobody chose that. It is a picture disagreeing with the simulation, which is
	# the shape of the spike hit test and the hat collider before it. And it had to
	# go before the laser sight could mean anything: a line drawn out of a barrel
	# that points somewhere the round does not go is an instrument that lies, and
	# the whole A/B is judged through it.
	weapon.rotation = Vector3.ZERO
	var aimed: Vector3 = aim_direction(body, weapon)
	if aimed.length_squared() > 0.0001:
		# Into the pivot own space, since the weapon hangs off Facing rather than
		# off the world.
		var local: Vector3 = attach.global_transform.basis.inverse() * aimed
		weapon.rotation = Vector3(asin(clampf(local.y, -1.0, 1.0)),
			atan2(-local.x, -local.z), 0.0)

func _drop_special(weapon: Node, at: Vector3) -> void:
	if weapon.get_parent() != _specials_root:
		weapon.get_parent().remove_child(weapon)
		_specials_root.add_child(weapon)
	weapon.owner_peer = 0
	weapon.drop(at, Vector3.ZERO)

# DROPPED when its holder goes down or over an edge. Called by PlayerBody on
# entering LEDGE_HANG or DOWNED -- see _drop_special there for why those two and
# not TUMBLE.
#
# Dropped rather than destroyed: a downed player is rescuable, and the weapon
# lying beside them is a reason for somebody to come. It is also contestable while
# they are out of the game, which is the good version of this.
func drop_special_of(body: Node) -> void:
	if not is_host:
		return
	var weapon: Node = _specials.held_by(int(body.peer_id))
	if weapon == null:
		return
	var at: Vector3 = _specials.drop_offset(body)
	_drop_special(weapon, at)
	if networked:
		_special_dropped.rpc(weapon.special_id, at)

# DESTROYED, not dropped, when a player leaves the world -- the same rule hats
# follow and the same reason: a free weapon at the spot that just killed somebody
# rescues the one failure the design does not rescue.
func destroy_held_special(peer: int) -> void:
	if not is_host:
		return
	var weapon: Node = _specials.held_by(peer)
	if weapon == null:
		return
	var id: int = weapon.special_id
	_specials.destroy(weapon)
	if networked:
		_special_destroyed.rpc(id)

# Every held special, every tick, on host and client alike. Cosmetic -- the
# parent pivot does the aiming -- so a client poses its own rather than being
# told, exactly like the hat lean.
# --- The laser sight (M20 phase 1) --------------------------------------------
#
# THE INSTRUMENT, NOT THE FEATURE. It is how both aim modes are judged, so it
# works in BOTH -- a line that only appeared in the new one would show you its
# aim with nothing to compare against.
#
# DRAWN FROM aim_direction, THE SAME FUNCTION THAT FIRES. Not a parallel copy: a
# sight computing its own direction can agree with the cursor while the round
# disagrees with both, which is precisely the disagreement it exists to expose.
#
# LOCAL PLAYER ONLY, and view-only in the registry, so it changes nothing the
# simulation reads and a client may switch it on the instant it is clicked.
var _laser: MeshInstance3D = null

func _update_laser_sight() -> void:
	if not view_active:
		return
	var on: bool = DebugSettings.is_on("laser_sight")
	var body: Node = players.get(local_peer)
	var weapon: Node = _specials.held_by(local_peer) if body != null else null
	# NO GUN, NO LINE. A sight on an empty hand would be aiming something that
	# does not exist, and the muzzle fallback in _muzzle_of is the body centre --
	# which would draw a beam out of the player chest.
	if not on or body == null or weapon == null or not is_instance_valid(weapon):
		if _laser != null:
			_laser.visible = false
		return
	if _laser == null:
		_laser = MeshInstance3D.new()
		_laser.name = "LaserSight"
		_laser.mesh = BoxMesh.new()
		var beam := StandardMaterial3D.new()
		beam.albedo_color = Color(1.0, 0.25, 0.2, 0.85)
		beam.emission_enabled = true
		beam.emission = Color(1.0, 0.3, 0.25)
		beam.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		beam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_laser.material_override = beam
		add_child(_laser)
	_laser.visible = true

	var from: Vector3 = _muzzle_of(weapon, body)
	var along: Vector3 = aim_direction(body, weapon)
	# STOPS AT THE FIRST THING IT WOULD HIT, so the line reports the shot rather
	# than a ray through the world. Same layers a round is stopped by.
	var reach: float = SimConfig.MG_RANGE
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(from, from + along * reach)
		query.collision_mask = (1 << 0) | (1 << 1) | (1 << 4)
		query.exclude = [body.get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			reach = from.distance_to(hit["position"])
	var mesh: BoxMesh = _laser.mesh as BoxMesh
	mesh.size = Vector3(0.02, 0.02, maxf(reach, 0.05))
	_laser.global_position = from + along * (reach * 0.5)
	if absf(along.dot(Vector3.UP)) < 0.999:
		_laser.global_transform = _laser.global_transform.looking_at(
			from + along * reach, Vector3.UP)

func _pose_held_specials() -> void:
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		var weapon: Node = _specials.held_by(peer)
		if weapon != null and is_instance_valid(players[peer]):
			_pose_held_special(weapon, players[peer])

@rpc("authority", "call_remote", "reliable")
func _take_special(id: int, peer: int) -> void:
	var weapon: Node = _specials.by_id(id)
	var body: Node = players.get(peer)
	if weapon == null or body == null:
		return
	weapon.hold(peer)
	_pose_held_special(weapon, body)

@rpc("authority", "call_remote", "reliable")
func _special_dropped(id: int, at: Vector3) -> void:
	var weapon: Node = _specials.by_id(id)
	if weapon != null:
		_drop_special(weapon, at)

@rpc("authority", "call_remote", "reliable")
func _special_destroyed(id: int) -> void:
	var weapon: Node = _specials.by_id(id)
	if weapon != null:
		_specials.destroy(weapon)

@rpc("authority", "call_remote", "reliable")
func _mound_taken(cx: int, cz: int) -> void:
	if grid != null:
		grid.take_mound(Vector2i(cx, cz))

# Drop-in: the newcomer built the bridge from the seed, so it has every mound
# including the ones this run already used up.
@rpc("authority", "call_remote", "reliable")
func _sync_spent_shooters(layout: PackedInt32Array) -> void:
	if is_host:
		return
	if grid != null:
		grid.apply_spent_shooters(layout)

@rpc("authority", "call_remote", "reliable")
func _sync_spent_mounds(layout: PackedInt32Array) -> void:
	if grid != null:
		grid.apply_spent_mounds(layout)

# MUTABLE TERRAIN (M17 phase 8). The WHOLE open set, not a single toggle.
#
# It is a handful of ints and it is idempotent, so a lost packet costs one cell
# looking wrong for a fraction of a second rather than forever. A per-cell
# "cell 4,7 is now open" message is smaller and is the kind of thing that goes
# permanently wrong when one of them is dropped -- and the floor being solid on
# one machine and not the other is the worst disagreement this game can have.
@rpc("authority", "call_remote", "reliable")
func _sync_open_cells(layout: PackedInt32Array) -> void:
	if grid != null:
		grid.apply_open_cells(layout)

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
	return _helper_peer_near(peer, body) > 0

# WHO is standing with them, not merely WHETHER somebody is -- a rescue has to be
# credited to a person, and the predicate that already walks the party is the only
# thing that knows which one. Returns 0 for nobody, so the boolean above is one
# line and the two answers cannot disagree about the radius.
#
# The NEAREST helper, not the first found: with two teammates in range the credit
# should go to the one who actually came, and `players` iterates in whatever order
# the dictionary happens to hold -- which is a coin toss dressed as a rule.
func _helper_peer_near(peer: int, body: Node) -> int:
	var best: int = 0
	var best_distance: float = INF
	for other_key in players.keys():
		var other: int = int(other_key)
		if other == peer or _returning.has(other):
			continue
		var helper: Node = players[other]
		# Someone who is themselves hanging or downed cannot help anyone.
		if helper.is_awaiting_rescue():
			continue
		var distance: float = helper.position.distance_to(body.position)
		if distance <= SimConfig.REVIVE_RADIUS and distance < best_distance:
			best_distance = distance
			best = other
	return best

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
	var helper: int = _helper_peer_near(peer, body)
	if helper > 0:
		body.rescue_progress += SimConfig.TICK_DELTA
		if body.rescue_progress >= SimConfig.REVIVE_SECONDS:
			body.revive()
			# ON THE RESCUER, at the line that does it. Counting it where the
			# downed player is put back would credit the person who was saved.
			_bump(helper, "rescues")
			_bump(peer, "rescued")
			return
	else:
		# Reset rather than pause: wandering off and back should not bank credit.
		body.rescue_progress = 0.0

	if body.state_timer >= SimConfig.DOWNED_SECONDS:
		_begin_drone_return(peer)

func _begin_drone_return(peer: int) -> void:
	if _returning.has(peer):
		return
	# A DEATH IS BEING PUT ON THE DRONE, counted at the line that does it.
	#
	# THE EDGE DETECTOR DID NOT WORK AND COULD NOT. It watched "is this player
	# out", which is true for seconds and looked like the safe thing to sample --
	# but on a solo wipe the round machine goes to SCORING at the TOP of the tick
	# and _settle_round_transition erases `_returning` on its way past, so the flag
	# was created and destroyed inside one tick with no observer in between.
	# Measured: a round log reading `deaths=0` for a round the player died in.
	# Moving the detector to the end of the tick did not fix it either, because the
	# erase happens at the start of the NEXT one.
	#
	# That transition has now eaten two signals -- `wipes` reads zero for exactly
	# the same reason. CLAUDE.md already says to prefer a DIRECT COUNT at the line
	# that does the thing; this is the second time the clever alternative has lost.
	#
	# AND IT DEFINES THE STAT WELL, which is the part worth keeping. If a teammate
	# reaches you in time you did not die -- that is what the rescue was for -- so
	# `deaths` and `rescued` become a matched pair: the times nobody got there, and
	# the times somebody did.
	_bump(peer, "deaths")
	# IF YOU FALL, YOU LOSE THEM. Not dropped where you went over -- destroyed.
	# See destroy_worn_hats: dropping them would rescue the one failure the design
	# does not rescue, and would leave a free pile at the spot that killed you.
	destroy_worn_hats(peer)
	destroy_held_special(peer)
	_returning[peer] = SimConfig.DRONE_RETURN_SECONDS
	var body: Node = players.get(peer)
	if body != null:
		body.visible = false
		# STOPPED DEAD, not left falling. The step loop skips it from here, so
		# without this it would keep whatever velocity it went over the edge with
		# for three seconds and respawn_at would be the first thing to clear it --
		# and anything reading the body in between (the camera, the HUD's distance
		# and bearing, the leash) would be reading a body still travelling at
		# 40 m/s into nothing.
		body.velocity = Vector3.ZERO
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

# THE LOBBY IS WHERE YOU GET PUT BACK TOGETHER. Full health, for everybody,
# every time -- asked for after the first playtest.
#
# NOT A REWARD AND NOT A DIFFICULTY DIAL: a round is scored on what you carried
# through it, so arriving at the next one on two hit points would mean the
# previous round's damage silently deciding the next round's score. Health
# carrying over would make a bad round compound into a worse one, which is the
# opposite of what a lobby between rounds is for.
#
# The hats and specials restock by AUTHORING rather than by code -- every lobby
# segment carries its own rack and its own hats (see segments/lobby.seg), and
# each lobby in a run is a new segment with its own. There is deliberately no
# "refill the pickups" pass: a pickup that respawns under you is a pickup you
# cannot spend, and the one-slot rule is the whole economy.
# REACHING THE LOBBY IS FULL HEALTH, IN EVERY CASE AND BY EVERY ROUTE.
#
# Called both when the round ENDS (the board goes up, and the party is already
# standing in the lobby by then) and when the lobby state opens ten seconds later.
# Idempotent, so being called twice is free -- and being called at both is what
# makes the rule true of the scoreboard as well as of the lobby proper.
#
# The four ways into a lobby used to give four different answers: you kept your
# damage if you reached the strip, you got one hit point if you were a straggler,
# you got full health from a wipe, and everybody got topped up when the state
# finally changed. The cost of losing a round is the GROUND, which the return
# already takes back; carrying a health debt past the boundary on top of that
# makes the next round harder because the last one went badly, which is the wrong
# way round.
func _restock_lobby() -> void:
	for peer_key in players.keys():
		var body: Node = players[int(peer_key)]
		if body == null or not is_instance_valid(body):
			continue
		body.health = SimConfig.MAX_HEALTH

# WHERE THE LOBBY IS, in world space, spread across lanes.
#
# The lobby is the stretch immediately up-bridge of the strip the party last came
# through, so `rear_row + 1` is its first walkable row. Before the first crossing
# there is no rear strip and the answer is the bridge's own entry -- which is the
# lobby, for the first round.
#
# LANES, NEVER A POINT. Two perfectly coincident bodies depenetrate into a
# degenerate normal and are driven DOWN THROUGH THE FLOOR (CLAUDE.md), so every
# function in this file that places several players at once spreads them.
func _lobby_point(lane: int) -> Vector3:
	if grid == null:
		return spawn_point(lane)
	# BEHIND THE STRIP THEY MUST CROSS, NOT ON IT.
	#
	# It was `rear_row + 1`, described as "the first walkable row of the lobby",
	# and it is neither. `rear_row` is the START of the strip the party came
	# through and A GATE BAND IS TWO ROWS DEEP (M16: one row is 2 m and a party of
	# four told to gather on it is four players jostling), so `rear_row + 1` is the
	# band's SECOND ROW -- still on the checker, and already past it as far as
	# `gate_after` is concerned.
	#
	# Reported from a solo playtest as "it says you lost, but you don't spawn in a
	# lobby -- the lobby/non-lobby gets flipped", and the flip is the consequence
	# rather than the fault. Measured: the body ended at row 11, and `_enter_lobby`
	# then asked `gate_after(11)` for the strip to cross next. That skips the
	# lobby's own exit band, which starts at 10, and answers with the NEXT lobby's
	# entry -- row 95, five sections up-bridge. The machine says LOBBY, the front
	# wall stands at the far end of the round, and the party plays the entire next
	# section in the lobby state. Everything downstream is then one boundary out.
	#
	# So the question is asked of the GRID instead: which lobby, given the strip
	# they came through. `lobby_row_near` looks past the strip first and behind it
	# only if what is past it is not a lobby -- because the two callers of this
	# function want opposite directions. A straggler at a round END is behind a
	# party that just walked INTO a lobby and belongs forwards with them; a party
	# that LOST is standing in the section that beat them and belongs backwards.
	# The first draft of this fix walked backwards unconditionally and sent
	# stragglers a whole round down the bridge, where the leash then dragged them
	# into one stacked pile -- caught by test_straggler_return.
	var row: int = grid.lobby_row_near(round_machine.rear_row)
	var cell := Vector2i(grid.entry_spawn_cell(lane).x, row)
	if not grid.is_solid(cell):
		# An authored lobby is solid across its entry row; a section that is not
		# falls back to the bridge entry rather than dropping somebody into a gap.
		cell = grid.entry_spawn_cell(lane)
	return grid.cell_surface_world(cell) + Vector3(0.0, 1.2, 0.0)

# --- The barriers -------------------------------------------------------------
#
# ONE RULE, TWO WALLS. The party is always in a corridor between the strip they
# came through and the strip they are heading for, and a wall stands at each end
# of it -- the front one on the UP-BRIDGE edge of the target, so a player can
# stand ON the checker and not pass, and the rear one on the DOWN-BRIDGE edge of
# the strip behind, so it appears immediately behind them the moment they cross.
#
# A wall exists exactly when it should block. During RUNNING there is no front
# wall at all: the section is the thing you are supposed to cross.
func _sync_walls() -> void:
	if grid == null:
		return
	var want_front: int = -1
	var want_rear: int = round_machine.rear_row
	if round_machine.state != RoundMachine.State.RUNNING:
		want_front = round_machine.target_row
	_front_wall = _place_wall(_front_wall, "FrontWall", want_front, true)
	_rear_wall = _place_wall(_rear_wall, "RearWall", want_rear, false)

func _place_wall(wall: StaticBody3D, wall_name: String, row: int,
		up_bridge: bool) -> StaticBody3D:
	if row < 0:
		if wall != null and is_instance_valid(wall):
			wall.queue_free()
		return null
	if wall == null or not is_instance_valid(wall):
		wall = _build_wall(wall_name)
		grid.add_child(wall)
	# The band, not the row: a two-deep strip has to be standable end to end, so
	# the front wall goes past its far edge rather than into the middle of it.
	var span: int = grid.gate_band_end(row) - row + 1
	# LOCAL to the grid, so the four-degree pitch comes for free. A world-space
	# placement would have to redo it and would be wrong on every segment above
	# the first.
	wall.position = Vector3(0.0,
		float(grid.height_at(Vector2i(grid.width / 2, row))) * GridConfig.HEIGHT_UNIT
			+ SimConfig.ROUND_WALL_HEIGHT * 0.5,
		RoundMachine.wall_z_local(row, up_bridge, span))
	return wall

func _build_wall(wall_name: String) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = wall_name
	# PLAYERS ONLY, on the NAMED "barrier" layer 8 -- and the players' mask has bit
	# 8 in it (scenes/player.tscn, mask 135 = 7 + 128). Both halves are required
	# and the first draft had only one: the wall sat on a layer nothing masked, so
	# it existed, replicated, drew, and stopped absolutely nothing. That is the
	# FIFTH bug in this project to be one wrong bit in a collision mask, and it
	# survived a test that asserted the wall EXISTS -- which is why there is now
	# one that walks a body into it.
	#
	# Not layer 1 (world), which every body masks: putting the barrier there would
	# stop bullets, balls, grenades and rushers too, and each of those is a design
	# decision nobody has made yet.
	wall.collision_layer = 1 << 7
	wall.collision_mask = 0

	# EXACTLY AS WIDE AS THE BRIDGE. It was 128 m before -- wide enough to be
	# unflankable, and also a slab of blue hanging out over the drop on both
	# sides, which reads as scenery rather than as a rule about this deck. The
	# parapet already stops anyone going round the end.
	var width: float = float(grid.width) * GridConfig.CELL_SIZE
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, SimConfig.ROUND_WALL_HEIGHT, 0.4)
	var col := CollisionShape3D.new()
	col.shape = shape
	wall.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = shape.size
	mesh.mesh = box
	mesh.material_override = _wall_material()
	wall.add_child(mesh)
	return wall

# SOLID AT THE FEET, GONE AT THE TOP. A uniformly translucent slab is a window
# you keep trying to look through; a gradient reads as a field that is DENSE
# WHERE IT STOPS YOU -- at knee height, where the body actually meets it -- and
# thins out of the way of the thing you are trying to see, which is the lobby or
# the section on the far side.
#
# A SHADER RATHER THAN STACKED BOXES, which was the alternative: several slabs of
# decreasing alpha is several materials, several draw calls and a visible banding
# artefact at every seam. One material, one quad's worth of maths.
#
# The gradient is driven by LOCAL VERTEX Y rather than by UV, because a BoxMesh's
# UVs differ per face -- the two ends would gradient sideways.
func _wall_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color;
uniform float height;

varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

void fragment() {
	// VERTEX.y runs -height/2 (bottom) to +height/2 (top) on a centred BoxMesh,
	// so this is 1 at the feet and 0 at the top edge.
	float lift = clamp(0.5 - local_y / height, 0.0, 1.0);
	ALBEDO = tint.rgb;
	ALPHA = tint.a * lift;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tint", SimConfig.ROUND_WALL_COLOUR)
	mat.set_shader_parameter("height", SimConfig.ROUND_WALL_HEIGHT)
	return mat

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
			_bump(int(peer_key), "healed")
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
		# BEFORE THE PREDICTION, and this is the line that keeps a shield from
		# reading as lag. The client decides for itself that it is anchored,
		# because it knows its own trigger and it has been told what it is
		# holding -- so its prediction agrees with the host instead of guessing
		# that it walked and being dragged back every tick.
		_refresh_shield_flag(local_peer, body)
		if _is_predicted(body.state):
			body.step(inp[PlayerInput.MOVE], inp[PlayerInput.ACTIONS], PlayerInput.aim_of(inp),
			PlayerInput.point_of(inp))
			_predicted.append([tick, body.capture_state()])
		else:
			# TUMBLE, LEDGE_HANG, DOWNED and the bus states genuinely have no
			# input: the player is not driving, so there is nothing to predict
			# with and nothing to gain. Authority drives them.
			_predicted.clear()

	_trim_history()

# WHICH STATES A CLIENT RUNS FORWARD FOR ITSELF.
#
# WALK, obviously. And SHOVE, added 2026-08-14, which reverses half of an earlier
# decision -- so here is the whole argument.
#
# The old rule was "committed actions are not predicted: there is no input to
# mispredict, so the correction never fights the player". That is a statement
# about the OUTCOME of a dash, and it was being applied to its START. Those are
# different questions:
#
#   The ENTRY is perfectly predictable. The direction is chosen at the instant of
#   the press, it is already on the wire as an absolute angle (the host cannot
#   re-derive an aim), and the first six ticks are a straight line at a fixed
#   speed. A client reproduces that exactly.
#
#   The CONTACT is not. What the dash hits, and what that does to the other body,
#   depends on positions this machine does not own.
#
# So the client runs the line and authority settles the collision. On a coast-to-
# coast link the old rule cost a FULL ROUND TRIP OF DEAD AIR on the press --
# roughly 80 ms in which the game's signature verb did nothing at all -- and a
# dash that hits nothing is the common case, where the prediction is exact and
# there is no correction to make.
#
# When it IS wrong, reconciliation handles it the same way it handles a
# mispredicted step: rewind and replay. A dash lasts six ticks and a client is
# about five ahead, so a contact the client did not know about arrives near the
# end of its own dash and corrects there.
#
# Replaying a shove is safe. _step_shove reads no input, and _begin_shove is
# reachable only from _step_walk -- so replaying the tick that carried
# ACTION_SHOVE re-enters the dash exactly once, and replaying later ticks inside
# it does nothing.
func _is_predicted(state: int) -> bool:
	return state == PlayerBody.State.WALK or state == PlayerBody.State.SHOVE

func _gather_local_input(for_tick: int) -> Array:
	if input_provider.is_valid():
		return input_provider.call(for_tick)
	return PlayerInput.sample(for_tick, _poll_aim(), _poll_aim_point())

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

# The same cursor as _poll_aim, resolved to a place instead of a bearing. Asked
# second and separately so the bearing path is untouched -- see aim_source.point().
func _poll_aim_point() -> Vector3:
	if not view_active or camera == null:
		return PlayerInput.AIM_POINT_NONE
	var body: Node = players.get(local_peer)
	if body == null:
		return PlayerInput.AIM_POINT_NONE
	return _aim.resolve_point(camera, body.position)

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
	# HOST ONLY, and this is a live branch now rather than defence in depth: a
	# client DOES simulate its own shove (see _is_predicted), so it reaches here
	# on contact. It must not push a stone or launch a teammate -- those are
	# authority's to decide, and a client that moved them would be inventing a
	# result for a body it does not own. Its own dash still STOPS on the contact,
	# because move_and_slide already swept it.
	if not is_host or other == null or other == shover:
		return
	if other.has_method("receive_shove"):
		other.receive_shove(yaw)
		# A BOOST. `receive_shove` is on PlayerBody and nothing else, so reaching
		# this line is one player launching another -- the verb this whole game is
		# named after, and the one thing nothing measured.
		#
		# EVERY PLAYER-TO-PLAYER SHOVE COUNTS, including the ones that were not
		# kind. A boost up a steep ramp and a shove off the side of the bridge are
		# the same call at the same instant, and which one it was is decided
		# afterwards by where they land -- so nothing here can tell them apart
		# without guessing. It reads fine either way: a big boost count beside a
		# teammate's death count is a story the board tells by itself.
		if "peer_id" in shover:
			_bump(int(shover.peer_id), "boosts")
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
	# A KEYFRAME EVERY KEYFRAME_TICKS, or whenever somebody just joined. See
	# snapshot_delta.gd: a delta means nothing to a client with no baseline, and a
	# joiner has none.
	var keyframe: bool = _keyframe_due or (tick % SnapshotDelta.KEYFRAME_TICKS) == 0
	_keyframe_due = false

	var raw_players: Array = []
	for peer_key in players.keys():
		var peer: int = int(peer_key)
		raw_players.append([peer, players[peer].capture_state(), int(_last_input_tick.get(peer, 0))])
	# Players go through the same codec as everything else even though nothing
	# destroys a player on absence -- one shape for every section is what makes
	# the next body type one call rather than a decision. In practice the local
	# player's entry is always "changed" anyway, because the acked input tick in
	# it advances every tick.
	var entries: Array = SnapshotDelta.encode(raw_players, _section("players"), keyframe)

	# Stones are NOT deltaed and do not need to be: stone_snapshot() already sends
	# only the ones that are not SETTLED, and nothing destroys a stone on absence
	# -- they are grid-resident, built from the segments both machines loaded.
	var stones: Array = grid.stone_snapshot() if grid != null else []
	# The layout only on a slow cadence -- see BridgeGrid.stone_layout().
	var layout: PackedInt32Array = PackedInt32Array()
	if grid != null and (tick % SimConfig.STONE_RESYNC_TICKS) == 0:
		layout = grid.stone_layout()
	_apply_snapshot.rpc(tick, entries, stones, _ball_snapshot(keyframe), layout,
		_rusher_snapshot(keyframe), _hat_snapshot(keyframe), _special_snapshot(keyframe),
		_bullet_snapshot(keyframe), _gunner_snapshot(keyframe),
		_deployable_snapshot(keyframe))

# Balls are FULLY AUTHORITATIVE and never predicted. The cheap alternative --
# clients simulating them from a shared seed -- is tempting and specifically
# risky: a ball is exactly the thing whose trajectory has to agree, because two
# machines disagreeing about where it is means two machines disagreeing about who
# got hit. A ball is a position and a velocity and there are at most a couple of
# dozen; measure before optimising this.
func _ball_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for ball in _balls:
		if is_instance_valid(ball):
			out.append([ball.ball_id, ball.position, ball.linear_velocity])
	return SnapshotDelta.encode(out, _section("balls"), keyframe)

# The per-section memory, created on first use so a new section is one call and
# not also a declaration.
func _section(name: String) -> Dictionary:
	if not _last_sent.has(name):
		_last_sent[name] = {}
	return _last_sent[name]

# Clients rebuild their ball set to match the host's, creating and freeing to
# suit. Self-healing by construction: a dropped packet costs a frame of staleness
# rather than a ball that exists forever on one machine.
func _apply_ball_snapshot(section: Array) -> void:
	# SEEN COMES FROM THE MANIFEST, NOT FROM THE ENTRIES. That one line is what
	# lets the payload carry only what moved while "a body the host stops
	# mentioning has gone" keeps meaning what it always meant.
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
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

# Every id the host says exists this tick. The destroy pass below each applier
# reads this, so an entry that did not change is still "present" and survives.
func _seen_from(section: Array) -> Dictionary:
	var seen: Dictionary = {}
	for id in SnapshotDelta.ids_of(section):
		seen[int(id)] = true
	return seen

func _ball_by_id(id: int) -> Node:
	for ball in _balls:
		if is_instance_valid(ball) and ball.ball_id == id:
			return ball
	return null

# Rushers ride the per-tick snapshot exactly like balls: host-authoritative,
# never predicted. No velocity on the wire -- a client does not integrate one, so
# sending it would be paying MTU for a number nobody reads. See the CLAUDE.md
# note about the 4595-byte snapshot that would not fit ENet's 1392.
func _gunner_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for gunner in _gunners:
		if is_instance_valid(gunner):
			out.append(gunner.capture_state())
	return SnapshotDelta.encode(out, _section("gunners"), keyframe)

# Self-healing like every other pool: one the host stops naming has been shot.
func _apply_gunner_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var gunner: Node = _gunner_by_id(id)
		if gunner == null:
			gunner = _spawn_gunner(entry[2], int(entry[1]))
			gunner.gunner_id = id
		gunner.apply_state(entry)

	for i in range(_gunners.size() - 1, -1, -1):
		var existing: Node = _gunners[i]
		if not is_instance_valid(existing) or not seen.has(existing.gunner_id):
			_gunners.remove_at(i)
			if is_instance_valid(existing):
				existing.queue_free()

func _rusher_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for rusher in _rushers:
		if is_instance_valid(rusher):
			out.append(rusher.capture_state())
	return SnapshotDelta.encode(out, _section("rushers"), keyframe)

# Self-healing by construction, same as the ball set: a dropped packet costs a
# frame of staleness rather than an enemy that exists forever on one machine.
# THIS IS ALSO HOW A CLIENT LEARNS A RUSHER DIED -- it stops being mentioned.
func _apply_rusher_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
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

# LOOSE AND FLYING HATS ONLY. Who is WEARING what travels reliably instead -- see
# _wear_hat. This is the split the plan calls the expensive mistake available
# here: a position that changes every tick belongs on the unreliable per-tick
# wire, and an ownership change that happens twice a minute does not.
#
# style_id rides along because it is what a hat LOOKS like, and it is how a
# client that has never seen this hat before draws the right one.
func _hat_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for hat in _hats.all():
		if is_instance_valid(hat) and hat.mode != HatBody.Mode.WORN:
			out.append([hat.hat_id, hat.style_id, hat.mode, hat.position])
	return SnapshotDelta.encode(out, _section("hats"), keyframe)

# Self-healing by construction, like the ball set: a dropped packet costs a frame
# of staleness rather than a hat that exists forever on one machine. A hat the
# host stops mentioning has been picked up, culled or destroyed -- and a WORN hat
# is not in this list, so it is removed here and re-created by the reliable
# _wear_hat that put it on a head.
func _apply_hat_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var hat: Node = _hats.by_id(id)
		if hat == null:
			hat = _hats.adopt(id, int(entry[1]))
		hat.apply_remote(int(entry[2]), entry[3])

	for hat in _hats.all().duplicate():
		if not is_instance_valid(hat):
			continue
		# A worn hat is legitimately absent from the snapshot; anything else that
		# is missing has gone.
		if hat.mode != HatBody.Mode.WORN and not seen.has(hat.hat_id):
			_hats.destroy(hat)

# Drop-in: a newcomer built the bridge from the seed, which gives it the AUTHORED
# hats -- but not who is wearing what, and not any hat that has moved since. The
# loose ones arrive on the next snapshot; the worn ones need telling.
@rpc("authority", "call_remote", "reliable")
func _sync_worn_hats(entries: Array) -> void:
	for entry in entries:
		var id: int = int(entry[0])
		if _hats.by_id(id) == null:
			_hats.adopt(id, int(entry[1]))
		_wear_hat(id, int(entry[2]), int(entry[3]))

@rpc("authority", "call_remote", "reliable")
func _sync_held_specials(entries: Array) -> void:
	for entry in entries:
		var id: int = int(entry[0])
		var s: Node = _specials.by_id(id)
		if s == null:
			s = _specials.adopt(id, int(entry[1]))
		s.ammo = int(entry[3])
		_take_special(id, int(entry[2]))

func _held_special_dump() -> Array:
	var out: Array = []
	for s in _specials.all():
		if is_instance_valid(s) and s.mode == SpecialBody.Mode.HELD:
			out.append([s.special_id, s.kind, s.owner_peer, s.ammo])
	return out

func _worn_hat_dump() -> Array:
	var out: Array = []
	for hat in _hats.all():
		if is_instance_valid(hat) and hat.mode == HatBody.Mode.WORN:
			out.append([hat.hat_id, hat.style_id, hat.owner_peer, hat.stack_index])
	return out

# LOOSE AND FLYING SPECIALS ONLY, exactly as with hats: who is HOLDING what
# travels reliably through _take_special. `kind` rides along so a client that has
# never seen this one draws the right thing; `ammo` rides along because the HUD
# shows a friend's remaining rounds and a stale count is worse than none.
func _special_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for s in _specials.all():
		if is_instance_valid(s) and s.mode != SpecialBody.Mode.HELD:
			out.append([s.special_id, s.kind, s.mode, s.position, s.ammo])
	return SnapshotDelta.encode(out, _section("specials"), keyframe)

# Self-healing by construction, like the ball and hat sets: a dropped packet costs
# a frame of staleness rather than a weapon that exists forever on one machine.
func _apply_special_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var s: Node = _specials.by_id(id)
		if s == null:
			s = _specials.adopt(id, int(entry[1]))
		s.apply_remote(int(entry[2]), entry[3], int(entry[4]))

	for s in _specials.all().duplicate():
		if not is_instance_valid(s):
			continue
		# A held special is legitimately absent from the snapshot; anything else
		# that is missing has been taken, spent or destroyed.
		if s.mode != SpecialBody.Mode.HELD and not seen.has(s.special_id):
			_specials.destroy(s)

# POSITIONS ONLY, and no velocity. A client draws rounds and simulates none of
# them, so the only thing it needs is where each one is right now -- and at
# SNAPSHOT_INTERVAL_TICKS of 1 that is every tick, which is as smooth as the host's
# own copy. The moment that interval rises, this is one of the things that will
# want interpolating.
func _bullet_snapshot(keyframe: bool) -> Array:
	var out: Array = []
	for bullet in _bullets:
		if is_instance_valid(bullet):
			# The EXPLODES flag rides along because a client picks the scene from
			# it. A rocket drawn as a bullet would be the one thing on screen that
			# gives no warning of what is about to happen.
			out.append([bullet.bullet_id, bullet.position, bullet.explodes])
	return SnapshotDelta.encode(out, _section("bullets"), keyframe)

# Self-healing like the ball set: a round the host stops mentioning has hit
# something, expired or left the world, and the client removes it without needing
# to be told which.
func _apply_bullet_snapshot(section: Array) -> void:
	var seen: Dictionary = _seen_from(section)
	for entry in SnapshotDelta.changed_of(section):
		var id: int = int(entry[0])
		var bullet: Node = _bullet_by_id(id)
		if bullet == null:
			var rocket: bool = entry.size() > 2 and bool(entry[2])
			bullet = (RocketScene if rocket else BulletScene).instantiate()
			bullet.explodes = rocket
			bullet.bullet_id = id
			bullet.name = "Bullet_%d" % id
			_bullets_root.add_child(bullet)
			_bullets.append(bullet)
		bullet.apply_remote(entry[1])

	for i in range(_bullets.size() - 1, -1, -1):
		var bullet: Node = _bullets[i]
		if not is_instance_valid(bullet) or not seen.has(bullet.bullet_id):
			_bullets.remove_at(i)
			if is_instance_valid(bullet):
				bullet.queue_free()

func _bullet_by_id(id: int) -> Node:
	for bullet in _bullets:
		if is_instance_valid(bullet) and bullet.bullet_id == id:
			return bullet
	return null

@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_snapshot(server_tick: int, entries: Array, stones: Array, balls: Array,
		layout: PackedInt32Array, rushers: Array, hats: Array, specials: Array,
		bullets: Array, gunners: Array, deployables: Array) -> void:
	if is_host:
		return
	if debug_inbound_delay_ticks > 0:
		_delayed_snapshots.append([tick + debug_inbound_delay_ticks, entries, stones, balls, layout, rushers, hats, specials, bullets, gunners, deployables])
		return
	_consume_snapshot(entries, stones, balls, layout, rushers, hats, specials, bullets, gunners, deployables)

func _release_delayed_snapshots() -> void:
	while _delayed_snapshots.size() > 0 and int(_delayed_snapshots[0][0]) <= tick:
		var held: Array = _delayed_snapshots.pop_front()
		_consume_snapshot(held[1], held[2], held[3], held[4], held[5], held[6], held[7], held[8], held[9], held[10])

func _consume_snapshot(entries: Array, stones: Array, balls: Array,
		layout: PackedInt32Array, rushers: Array, hats: Array, specials: Array,
		bullets: Array, gunners: Array, deployables: Array) -> void:
	if grid != null:
		grid.apply_stone_snapshot(stones)
		if layout.size() > 0:
			grid.apply_stone_layout(layout)
	_apply_ball_snapshot(balls)
	_apply_rusher_snapshot(rushers)
	_apply_hat_snapshot(hats)
	_apply_special_snapshot(specials)
	_apply_bullet_snapshot(bullets)
	_apply_gunner_snapshot(gunners)
	_apply_deployable_snapshot(deployables)
	for e in SnapshotDelta.changed_of(entries):
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

	# In a state the client does not predict there is nothing to compare against --
	# take what the host says and start clean.
	if not _is_predicted(int(authoritative[2])):
		body.apply_state(authoritative)
		_predicted.clear()
		return

	# Compare what we predicted for the acked tick against what actually
	# happened. Close enough and the prediction stands and the player sees
	# nothing, which is the common case and the whole point.
	var missed: float = 0.0
	if _predicted.size() > 0 and int(_predicted[0][0]) == acked:
		var predicted_position: Vector3 = _predicted[0][1][0]
		missed = predicted_position.distance_to(authoritative[0])
		if missed <= SimConfig.CORRECTION_EPSILON:
			return

	corrections += 1
	correction_metres += missed
	correction_worst = maxf(correction_worst, missed)

	# Rewind to the authoritative frame and replay every input the host has not
	# seen. Because step() is the same function the host ran, and a sim tick is
	# exactly one physics tick, replaying N inputs inside this frame lands where
	# N frames of host simulation will land.
	body.apply_state(authoritative)
	_predicted.clear()
	for pending in _pending_inputs:
		body.step(pending[PlayerInput.MOVE], pending[PlayerInput.ACTIONS],
			PlayerInput.aim_of(pending), PlayerInput.point_of(pending))
		_predicted.append([int(pending[PlayerInput.TICK]), body.capture_state()])

# --- Names --------------------------------------------------------------------
#
# Each machine knows only its OWN name, so a client announces itself and the host
# -- which is already the one thing that decides who exists -- republishes the
# whole roster. The dictionary is four entries at most, so pushing all of it on
# every change is cheaper than working out what changed.

func _announce_name() -> void:
	var display: String = _local_display_name()
	var steam: int = NetworkManager.steam_id_of_self()
	if is_host:
		player_names[local_peer] = display
		player_steam_ids[local_peer] = steam
		_broadcast_names()
	elif networked:
		_submit_name.rpc_id(1, display, steam)

func _local_display_name() -> String:
	# Steam persona where there is one; otherwise a name derived from OUR OWN peer
	# id, not from NetworkManager's -- a headless world (and every world the net
	# harness stands up) has no session, so NetworkManager.local_id() is 0 there
	# and every player in the rig would be called the same thing.
	var persona: String = NetworkManager.steam_display_name()
	return persona if persona != "" else default_player_name(local_peer)

@rpc("any_peer", "call_remote", "reliable")
func _submit_name(display: String, steam: int = 0) -> void:
	if not is_host:
		return
	var from: int = multiplayer.get_remote_sender_id()
	player_names[from] = display
	player_steam_ids[from] = steam
	_broadcast_names()

func _broadcast_names() -> void:
	if networked:
		_set_names.rpc(player_names, player_steam_ids)

# Somebody's Steam id, or 0. The HUD asks so it can ask for a face.
func player_steam_id(peer: int) -> int:
	return int(player_steam_ids.get(peer, 0))

# --- Debug config -------------------------------------------------------------
#
# ANY PLAYER MAY ASK; THE HOST DECIDES. A knob that is only true on the machine
# that flipped it is worse than no knob at all -- two people tuning the same
# number would be looking at two different games and comparing notes.
#
# The shape is deliberately the one player_names already uses: a client submits,
# the host is the single owner, and the host republishes the WHOLE dictionary. It
# is a handful of entries changed by hand, so working out what changed costs more
# than sending all of it.
#
# IT LIVES HERE AND NOT ON THE DebugSettings AUTOLOAD. An RPC on an autoload
# travels over the default peerless MultiplayerAPI, while the net harness roots
# each world at its own SceneMultiplayer -- so an autoload RPC is one no test can
# ever reach. m9_hud.md hit exactly this with player names, and the answer was the
# same: make it world state.

# Requests that arrived between ticks, applied at the top of the next one. A knob
# that affects stepping is a sim rule, and changing one halfway through a step
# loop would mean two bodies in the same tick ran under different rules.
# What each section last sent, per id, as a quantised comparison key. See
# snapshot_delta.gd -- this is the entire state delta encoding needs, and it is
# the same on every client because it is never per-client.
var _last_sent: Dictionary = {}

# Forced full snapshots. Counted down from the tick, and set outright whenever
# somebody joins: a delta is only meaningful to a client that already has the
# baseline, and a joiner has nothing.
var _keyframe_due: bool = true

var _pending_settings: Dictionary = {}

# How many config broadcasts this world has taken from the host. Test-visible on
# purpose -- see _set_settings.
var settings_applied: int = 0

# The local entry point. The menu calls this and does not care which machine it
# is on.
func push_setting(key: String, value: Variant) -> void:
	if not networked:
		DebugSettings.set_value(key, value)
		return
	if is_host:
		_pending_settings[key] = value
		return
	# A VIEW KNOB TAKES EFFECT ON THE SPOT; A SIMULATION KNOB WAITS FOR THE HOST.
	#
	# A client used to change nothing at all on its own machine and wait for the
	# host's snapshot to come back, so between the click and the echo the local
	# value was still the OLD one -- and any refresh in that window (a `changed`
	# signal from another key, or reopening the panel) put the control straight back
	# where it was. Reported from playtest as "after turning it off it periodically
	# turns itself back on".
	#
	# Applying EVERY knob optimistically was the first fix and it was too broad:
	# test_debug_replication caught it in one run. A simulation knob is applied by
	# the host at a tick boundary precisely so that two bodies in one tick cannot
	# run under different rules, and a client writing the value early is exactly
	# that hazard. `view_only` knobs cannot be -- nothing in the sim reads them --
	# so they are safe to apply at once and are the ones whose latency is felt,
	# because the player is looking straight at the thing they toggled.
	if DebugSettingsScript.is_view_only(key):
		DebugSettings.set_value(key, value)
	_request_setting.rpc_id(1, key, value)

@rpc("any_peer", "call_remote", "reliable")
func _request_setting(key: String, value: Variant) -> void:
	if not is_host:
		return
	_pending_settings[key] = value

func _apply_pending_settings() -> void:
	if _pending_settings.is_empty():
		return
	DebugSettings.apply_snapshot(_pending_settings)
	_pending_settings.clear()
	if networked:
		_set_settings.rpc(DebugSettings.snapshot())

@rpc("authority", "call_remote", "reliable")
func _set_settings(values: Dictionary) -> void:
	if is_host:
		return
	# COUNTED AT THE LINE THAT DOES IT. Host and clients share one DebugSettings
	# autoload whenever they share a process, which every test in this project
	# does -- so "the client has the right value" is true whether or not this RPC
	# ever arrived. The counter is the only thing that can tell the difference,
	# and without it test_debug_replication passed with this function emptied out.
	settings_applied += 1
	DebugSettings.apply_snapshot(values)

# Bodies are created constantly -- balls, rounds, rushers, hats -- so this cannot
# be a one-shot sweep when the knob flips. Running it every tick is idempotent
# (HitboxView.apply only adds what is missing) and returns immediately while the
# knob is off, which is always in a shipped game.
var _hitboxes_on: bool = false

func _sync_hitboxes() -> void:
	if not view_active:
		return
	var want: bool = DebugSettings.is_on("show_hitboxes")
	if not want and not _hitboxes_on:
		return
	HitboxView.apply(self, want)
	_hitboxes_on = want

@rpc("authority", "call_remote", "reliable")
func _set_names(names: Dictionary, steam_ids: Dictionary = {}) -> void:
	if is_host:
		return
	player_names = names.duplicate()
	player_steam_ids = steam_ids.duplicate()

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
	_give_saved_hat(peer)

# YOU START WEARING WHAT YOU SAVED, and bare if you lost it.
#
# Host-side, and only for a peer whose saved hat this machine actually knows --
# which today is the local player. A remote client's saved hat would have to be
# announced to the host the way its display name already is (_submit_name); the
# hook belongs there and is deliberately not invented here, because a client
# telling the host "spawn me wearing X" is a trust decision, not a plumbing one.
func _give_saved_hat(peer: int) -> void:
	if not is_host or not view_active or peer != local_peer:
		return
	var style: int = _remembered_hat
	if style == HatConfig.NONE:
		return
	var body: Node = players.get(peer)
	if body == null:
		return
	var hat: Node = _hats.spawn_loose(body.position, style)
	_wear_hat(hat.hat_id, peer, 0)
	if networked:
		_wear_hat.rpc(hat.hat_id, peer, 0)

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
		_sync_spent_shooters.rpc_id(peer, grid.spent_shooter_layout())
		_sync_open_cells.rpc_id(peer, grid.open_cell_layout())
	# Who is wearing what. The loose hats arrive on the next snapshot; a worn hat
	# is not in that list by design, so it has to be told.
	_sync_worn_hats.rpc_id(peer, _worn_hat_dump())
	# And who is holding what, for the identical reason: a HELD special is absent
	# from the snapshot by design, so a newcomer would see an unarmed party.
	_sync_held_specials.rpc_id(peer, _held_special_dump())
	# The debug config, so a joiner tunes against the same numbers everyone else
	# is already playing on rather than against the shipped defaults.
	_set_settings.rpc_id(peer, DebugSettings.snapshot())
	# THE NEXT SNAPSHOT IS A FULL ONE. A newcomer has no baseline, so a delta
	# would name ids it has never been told the positions of -- and it would never
	# create those bodies at all, because an applier only builds what it is sent.
	_keyframe_due = true
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
	_hats.forget_wearer(peer)
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
