extends "res://scripts/sim/world/world_system.gd"

# LAPS: the race mode's own system. See implementation_plans/m26_race_track.md.
#
# THE RULE, WHICH IS SHORTER THAN IT SOUNDS. Crossing the start line always
# begins a lap. Crossing it again ends one -- but it only COUNTS if every other
# gate was touched in order on the way round, and otherwise it silently starts
# over. So a cut corner is not punished, it just does not score, which is the
# right severity for a thing you did to yourself.
#
# HELD PER PLAYER, NOT PER BUS. Four people in one bus post the same time and
# that is true; somebody who steps off and boards another keeps their own
# progress. It also means a lap driven and a lap walked are the same object.
#
# RUNS WHERE ITS TERRAIN PUT GATES. The race mode brings this system; the race
# circuit is the only ground that has lap gates, so a world with none has nothing
# for it to do.
#
# DECIDED ON THE HOST, TOLD TO CLIENTS RELIABLY. It lived in GameWorld and was
# never sent at all, so a client's HUD had no lap clock and no best, and the gate
# it should drive at next was never lit for it. Progress changes at most a few
# times a lap, so each change goes out as one reliable message (`_lap_state`)
# and a client keeps the same dictionaries the host does. The running clock is
# derived on the client from `from` and the synced tick.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

func _init() -> void:
	system_name = "laps"

func present() -> void:
	show_gates()

var on_gate: Dictionary = {}      # peer -> the gate it is standing in
var next_gate: Dictionary = {}    # peer -> the gate index expected next
var lap_from: Dictionary = {}     # peer -> tick the running lap started
var best: Dictionary = {}         # peer -> best completed lap, in ticks

# A DIRECT COUNT AT THE LINE THAT DOES IT. Every other way of noticing a lap
# happened has been an instrument this project later found was measuring
# something else.
var laps_completed: int = 0

# THE GATES, COLOURED FOR THE PERSON LOOKING AT THEM. Alternating shades of blue
# so the circuit reads as a numbered sequence; the start line paler because it is
# the finish rather than a checkpoint; and YOURS lit.
const GATE_SHADE_A := Color(0.16, 0.30, 0.58)
const GATE_SHADE_B := Color(0.28, 0.47, 0.78)
const GATE_START := Color(0.86, 0.89, 0.95)
const GATE_NEXT := Color(0.42, 0.86, 1.00)

func _gates() -> int:
	return world.grid.lap_gate_count() if world.grid != null else 0

# EDGE-TRIGGERED ON THE GATE, not level-triggered. A gate is several cells deep
# in the direction you cross it at walking pace, so a level trigger would fire
# for every tick you were inside one -- and on the start line that means
# restarting the lap five times in a row and never completing one.
func host_tick() -> void:
	var grid = world.grid
	if grid == null or grid.lap_gate_cells.is_empty():
		return
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		var body: Node = world.players[peer]
		if body == null or not is_instance_valid(body):
			continue
		var at: int = grid.lap_gate_at(grid.cell_of_world(body.position))
		if at < 0:
			on_gate.erase(peer)
			continue
		if int(on_gate.get(peer, -1)) == at:
			continue                  # still standing in the one we already counted
		on_gate[peer] = at
		touch(peer, at)

func touch(peer: int, at: int) -> void:
	if at != 0:
		# ONLY THE NEXT ONE COUNTS. Touching gate 3 before gate 2 is ignored
		# rather than resetting: the lap is already lost, and taking it away at
		# the moment somebody drives over a checkpoint would read as the gate
		# being broken.
		if at == int(next_gate.get(peer, -1)):
			next_gate[peer] = at + 1
			_announce(peer)
		return
	# The start line, which is both the finish and the start.
	if int(next_gate.get(peer, -1)) >= _gates():
		var lap: int = world.tick - int(lap_from.get(peer, world.tick))
		if lap > 0:
			laps_completed += 1
			var was: int = int(best.get(peer, 0))
			if was == 0 or lap < was:
				best[peer] = lap
	lap_from[peer] = world.tick
	next_gate[peer] = 1
	_announce(peer)

# WHICH GATE THIS PLAYER IS DRIVING AT NEXT.
#
# NOT THE SAME AS `next_gate`, and the difference is the whole of what a player
# needs to see. `next_gate` counts up 1, 2, 3 and then runs off the end of the
# list -- there is no gate 4 on a four-gate circuit, because the thing you go to
# after the last checkpoint is the START LINE again. And before you have started
# a lap at all there is no entry, and the answer is also the start line.
func next_gate_of(peer: int) -> int:
	if _gates() == 0:
		return -1
	var want: int = int(next_gate.get(peer, 0))
	return 0 if want <= 0 or want >= _gates() else want

# THE BEST LAP THIS PLAYER HAS DRIVEN, in ticks, or 0 for nobody who has finished
# one. ZERO IS NOT A GOOD TIME -- it is the absence of one; see RoundMachine.
func best_of(peer: int) -> int:
	return int(best.get(peer, 0))

# HOW LONG THE LAP IN PROGRESS HAS BEEN RUNNING, in ticks, or 0 when there is
# none -- the same convention about zero as `best_of`.
func elapsed_of(peer: int) -> int:
	if not next_gate.has(peer):
		return 0
	return maxi(0, world.tick - int(lap_from.get(peer, world.tick)))

# THE RUNNING LAP, THROWN AWAY. Not the best, which was earned and is kept.
#
# Every piece of the in-progress lap goes together: which gate is expected next,
# when it started, and which gate the body is standing on. Leaving any one of
# them would mean a player who died mid-lap came back part-way through a sequence
# they are no longer driving.
func abandon(peer: int) -> void:
	next_gate.erase(peer)
	lap_from.erase(peer)
	on_gate.erase(peer)
	_announce(peer)

# EVERY LAP IN PROGRESS, THROWN AWAY; the bests are untouched. For the end of a
# round: the clock going on ticking in the lobby would be a timer for a lap
# nobody is driving.
func abandon_all() -> void:
	for peer_key in world.players.keys():
		abandon(int(peer_key))

# A NEW ROUND. Everything, bests included -- a best lap from round one must not be
# ranked on in round three. Called with the round's stats, on the same line.
func reset() -> void:
	best.clear()
	next_gate.clear()
	lap_from.clear()
	on_gate.clear()
	laps_completed = 0
	if world.networked and world.is_host:
		world._lap_reset.rpc()

# --- Across the wire ----------------------------------------------------------

func _announce(peer: int) -> void:
	if not world.networked or not world.is_host:
		return
	world._lap_state.rpc(peer, int(next_gate.get(peer, -1)),
		int(lap_from.get(peer, -1)), int(best.get(peer, 0)))

# A client told a player's progress. -1 means "no running lap".
func apply_remote(peer: int, next: int, from: int, best_ticks: int) -> void:
	if next < 0:
		next_gate.erase(peer)
		lap_from.erase(peer)
	else:
		next_gate[peer] = next
		lap_from[peer] = from
	if best_ticks > 0:
		best[peer] = best_ticks
	else:
		best.erase(peer)

# A joiner, told everybody's.
func replay_to(joiner: int) -> void:
	for peer_key in world.players.keys():
		var peer: int = int(peer_key)
		world._lap_state.rpc_id(joiner, peer, int(next_gate.get(peer, -1)),
			int(lap_from.get(peer, -1)), int(best.get(peer, 0)))

# --- On screen ----------------------------------------------------------------

# THE GATES, TINTED. Every machine does this for itself -- it is per-viewer (the
# lit gate is the LOCAL player's next one) and nothing authoritative reads a
# colour -- which is why it runs after both ticks rather than inside the host's.
#
# THEY WERE INVISIBLE ONCE -- recorded, sequenced, tested, and drawn by nothing,
# so a player could not find the start line. A rule you cannot see is not a rule.
func show_gates() -> void:
	var grid = world.grid
	if grid == null:
		return
	var marks: Dictionary = grid.lap_gate_marks()
	if marks.is_empty():
		return
	var target: int = next_gate_of(world.local_peer)
	for cell in marks:
		var mark: Node = marks[cell]
		if not is_instance_valid(mark):
			continue
		var idx: int = grid.lap_gate_at(cell)
		var want: Color = GATE_START if idx == 0 else \
			(GATE_SHADE_A if idx % 2 == 1 else GATE_SHADE_B)
		var lit: bool = idx == target
		if lit:
			want = GATE_NEXT
		# AND THE CHECKER SURVIVES THE TINT. These are the deck's own squares, and
		# the parity is what makes distance readable from a fixed 45-degree camera
		# on the one surface where judging distance at speed is the whole activity.
		# TWO AXES THAT MUST NOT FIGHT: the HUE says which gate (and whether it is
		# yours), the LIGHTNESS says which square.
		var pale: bool = (int(cell.x) + int(cell.y)) % 2 == 0
		want = want.lightened(0.10) if pale else want.darkened(0.10)
		var material := mark.material_override as StandardMaterial3D
		if material == null or material.albedo_color == want:
			continue
		material.albedo_color = want
		material.emission_enabled = true
		material.emission = want
		# THE ONE YOU WANT IS BRIGHTER, not a different hue nobody has learned.
		material.emission_energy_multiplier = 0.9 if lit else 0.25
