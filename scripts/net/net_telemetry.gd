extends RefCounted

# ONE ROW A SECOND, TO A FILE, SO A TREND CAN BE READ AFTERWARDS.
#
# Built 2026-08-23 from a playtest: networking is wrong and *it feels worse over
# time*. The instruction was explicit -- "let's not guess at what is happening" --
# and that is also this project's own rule: prefer a direct count at the line that
# does the thing, because eliminating candidates by reading can be argued with and
# often wrongly.
#
# SO THIS DIAGNOSES NOTHING. It has no thresholds, no warnings and no opinion
# about what is broken. It writes numbers with a timestamp on them and gets out of
# the way.
#
# HOW TO READ ONE, because a file nobody knows how to open is not an instrument:
#
#   The host's file is the one to read -- it has everybody's rows in it. Find it
#   under user:// (the path is printed at session start), named net_host_<stamp>.
#   Filter by `from` to get one machine, sort by `t`, and look for a column that
#   CLIMBS across a run rather than a column that is large.
#
#   Start at `mark`: those rows are where a human said it felt bad, and the first
#   question is always whether anything else moved there. Then, in order --
#   `bytes` and the `b_*` split say whether the payload is growing and which pool
#   is growing it; `snaps` on a client's rows says whether they are ARRIVING (a
#   host's `snaps` is a send count and means something else); `jump_max` says
#   whether a body visibly teleported; `memo` and the entity levels say whether
#   something is accumulating that nothing prunes.
#
#   A gap in one peer's rows is that peer's reports not arriving, which is a
#   finding. It is NOT a zero, and the file is deliberately shaped so the two
#   cannot be confused.
#
# "WORSE OVER TIME" IS A SHAPE, NOT A VALUE, and that is what decides the design.
# A reading taken once cannot see it; a running total cannot either, because a
# total always rises. Every event column here is therefore a RATE over the last
# second, and every state column is a level at the moment of sampling. Put a run's
# worth of rows in a spreadsheet and the thing that climbs is the thing to look at.
#
# THE HEARTBEAT IS UNCONDITIONAL. A row goes out every second on a path no game
# state can gate -- CLAUDE.md's rule for any long-running harness, and here it
# earns its keep twice over: a row that STOPS is itself a finding, and one that
# keeps coming with zeroes in it says something very different from silence.
#
# THE TWO SIDES SEE DISJOINT THINGS, WHICH IS WHY EVERY CLIENT REPORTS TO THE
# HOST. Decided 2026-08-23 after reading where each counter is incremented:
#
#   `corr*` and `jump*` live on the client's reconciliation and snapshot-apply
#   paths, so they are STRUCTURALLY ZERO in a host's own row. `b_*` and `memo`
#   live in the host's encoder, so they are structurally zero in a client's.
#   And `snaps` means different things on the two sides -- attempted on the
#   host, ARRIVED on the client -- which is the counter this project has already
#   shipped once as a send count and read as a delivery count.
#
# So neither file is a superset of the other, and the symptom ("worse over
# time") is only observable on a client while the leading cause (payload growth)
# is only measurable on the host. Reading one alone answers half the question.
#
# THE REASON IT IS COLLECTED RATHER THAN JOINED IS LOGISTICS, NOT DATA. Three
# people play; asking two of them to go and find user:// afterwards is a step
# that does not survive contact with a Tuesday night. A client sends its finished
# row to the host once a second and the host files it under `from`, so the
# machine that is easiest to reach holds every machine's numbers.
#
# THE ROW IS BUILT IN ONE PLACE for both uses (`_row_values`). A second
# definition of "what a row is" is CLAUDE.md's "same arithmetic, one place each"
# trap, and the day the two copies disagree is the day the CSV silently shifts a
# column.
#
# AND A REPORT THAT DOES NOT ARRIVE IS DATA. It is sent unreliably, on purpose:
# a degrading session is exactly when it will be lost, and a MISSING ROW says so
# where a retried one would paper over it. Read a gap in a peer's rows as
# missing, NEVER as zero -- the file makes that legible by having no row at all
# rather than a row of noughts.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# Once a second. Frequent enough to see a trend inside one round, rare enough that
# measuring the payload size costs nothing worth counting.
const SAMPLE_TICKS := 60

# The columns, in order, written once as a header. Named here rather than at the
# point they are filled so that adding one cannot silently shift every value in
# the file one place to the left.
const COLUMNS := [
	# `from` IS WHICH MACHINE THIS ROW CAME FROM -- not `peers`, which is how many
	# players are in the session. On a client's own file it is always that client;
	# on the host's file it is 1 for the host's own rows and the peer id for every
	# reported one, so the whole session pivots on this column.
	#
	# `mark` is how many times somebody pressed the marker key in that window. It
	# is the only column here that comes from a human, and it exists because
	# "worse over time" is a FEELING until it has a timestamp against it.
	"t", "tick", "role", "from", "mark", "peers",
	# --- rates, per second ---
	"snaps", "bytes", "corr", "corr_m", "corr_max",
	# --- levels, at the sample ---
	"players", "bullets", "balls", "hats", "specials",
	"rushers", "gunners", "zombies", "deployables",
	"segments", "rows", "memo", "jump", "jump_max",
	# --- per-section bytes, host only ---
	"b_players", "b_bullets", "b_balls", "b_hats", "b_specials",
	"b_rushers", "b_gunners", "b_zombies", "b_deployables", "b_stones", "b_layout",
]

var _file: FileAccess = null
var _path: String = ""
var _ticks: int = 0
var _seconds: float = 0.0

# Event counters, zeroed every sample. These are the ones that must be counted at
# the line where the event happens rather than derived -- "attempted is not
# delivered" is in CLAUDE.md because this project has already shipped a counter
# that measured sends and was read as arrivals.
var _snaps: int = 0
var _bytes: int = 0
var _sections: Dictionary = {}

# Correction counters are read as DELTAS against the world's running totals, so
# nothing has to be pushed in from the correction site.
var _last_corr: int = 0
var _last_corr_m: float = 0.0

# HOW FAR A REMOTE BODY WAS TELEPORTED BY A SNAPSHOT. The rubber-band, and the one
# networking symptom a client can measure without knowing the host's truth. Summed
# over the window and kept as a worst case, because an average hides the single
# 3 m jump that is what a player actually sees.
#
# BE HONEST ABOUT WHAT IT MEASURES: DISCONTINUITY, NOT LAG. A client that is
# steadily half a second behind still receives one tick of movement per snapshot,
# so this reads near zero -- constant staleness is smooth. What it catches is the
# thing that JUMPS: a dropped run of packets, a resync, a body that was somewhere
# else. That is the reported symptom, but a session that feels laggy with this
# column flat has narrowed the search rather than come up empty.
var _jump: float = 0.0
var _jump_max: float = 0.0

# Marker presses in this window, and the finished row waiting to be sent to the
# host. The row is stashed rather than pushed because `step()` has no business
# knowing about RPCs -- the world takes it and sends it.
var _marks: int = 0
var _report: Array = []

func path() -> String:
	return _path

# STAMPED, AND ONE FILE PER RUN. "A DURABLE log is guilty until proven fresh" --
# reading a stale one has already cost this project a wrong call about a red gate,
# and a networking session that is compared against the wrong run is worse than no
# data at all.
func open_for(role: String) -> void:
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	_path = "user://net_%s_%s.csv" % [role, stamp]
	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		printerr("[net] could not open telemetry at ", _path)
		return
	_file.store_line(",".join(COLUMNS))
	_file.flush()
	print("[net] telemetry -> ", ProjectSettings.globalize_path(_path))

# --- What the world pushes in -------------------------------------------------

# The HOST, on a sample tick only. `named` is section name -> encoded array; the
# size is measured here rather than at the send so the cost lands once a second.
func note_sections(named: Dictionary) -> void:
	for key in named:
		_sections[key] = var_to_bytes(named[key]).size()

# The CLIENT, on every snapshot that ARRIVES. Counted at the line that consumes
# one, never at the send: a send function reports what it attempted.
func note_received(payload) -> void:
	_snaps += 1
	# Sized only on sample ticks -- var_to_bytes on a whole payload every tick
	# would be an instrument that changes what it measures. The rate column is
	# therefore snapshots-per-second exactly, and bytes-per-snapshot sampled.
	if due_to_size():
		_bytes += var_to_bytes(payload).size()

func note_remote_jump(metres: float) -> void:
	_jump += metres
	_jump_max = maxf(_jump_max, metres)

func note_sent(bytes: int) -> void:
	_snaps += 1
	_bytes += bytes

# Is the NEXT row the one that wants section sizes? Asked by the host so the
# measuring happens on one tick in sixty rather than on all of them.
func due_to_size() -> bool:
	return _ticks + 1 >= SAMPLE_TICKS

# --- The heartbeat ------------------------------------------------------------

func step(world) -> void:
	_ticks += 1
	_seconds += SimConfig.TICK_DELTA
	if _ticks < SAMPLE_TICKS:
		return
	_ticks = 0
	# BUILT ONCE, USED TWICE, AND THE COUNTERS ARE RESET AFTER BOTH. A row that
	# was written but not stashed -- or stashed from a second call to the builder
	# after the counters had been cleared -- is a client whose reported numbers do
	# not match its own file, which would be a fault in the instrument presenting
	# as a fault in the network.
	var row: Array = _row_values(world)
	_write(row)
	_report = row
	_reset_window()

# SOMEBODY PRESSED THE MARKER KEY. Counted rather than flagged, so two presses in
# one second are visibly two -- a player hammering it is telling you something a
# boolean would flatten.
func mark() -> void:
	_marks += 1

# The finished row, taken at most once. Emptied on the way out so a dropped tick
# cannot send the same second twice and make a stall look like activity.
func take_report() -> Array:
	var out: Array = _report
	_report = []
	return out

# A CLIENT'S ROW, FILED BY THE HOST. `from` is overwritten with the id the
# transport reports rather than the one in the payload: a row is a claim about
# somebody's own machine, never a claim about WHICH machine, and the two want
# different levels of trust.
#
# The size check is not politeness -- a peer on an older build sends a row of a
# different width, and joining it to this header is exactly the silently-shifted
# column the header comment exists to prevent. A row that does not fit is
# dropped, and the gap says so.
func note_peer_row(peer: int, row: Array) -> void:
	if _file == null or row.size() != COLUMNS.size():
		return
	var copy: Array = row.duplicate()
	copy[COLUMNS.find("from")] = peer
	_write(copy)

func _reset_window() -> void:
	_snaps = 0
	_bytes = 0
	_jump = 0.0
	_jump_max = 0.0
	_marks = 0
	_sections.clear()

func _row_values(world) -> Array:
	var corr: int = int(world.corrections) - _last_corr
	var corr_m: float = float(world.correction_metres) - _last_corr_m
	_last_corr = int(world.corrections)
	_last_corr_m = float(world.correction_metres)

	var segments: int = 0
	var rows: int = 0
	if world.grid != null:
		segments = world.grid.segment_count()
		rows = world.grid.total_length()

	var row: Array = [
		"%.1f" % _seconds, world.tick,
		"host" if world.is_host else "client",
		world.local_peer, _marks,
		world.players.size(),
		_snaps, _bytes, corr, "%.2f" % corr_m, "%.2f" % float(world.correction_worst),
		world.players.size(), world._bullets.size(), world._balls.size(),
		world._hats.all().size(), world._specials.all().size(),
		world._rushers.size(), world._gunners.size(), world._zombies.size(),
		world._deployables.size(),
		segments, rows, _memo_size(world),
		"%.2f" % _jump, "%.2f" % _jump_max,
	]
	for key in ["players", "bullets", "balls", "hats", "specials",
			"rushers", "gunners", "zombies", "deployables", "stones", "layout"]:
		row.append(int(_sections.get(key, 0)))
	return row

func _write(row: Array) -> void:
	if _file == null:
		return
	# A COMMA IN A VALUE SHIFTS EVERY COLUMN AFTER IT. Every value here is a number
	# or the word host/client today, so this cannot fire -- which is precisely why
	# it is worth writing down now rather than the day somebody adds a label.
	_file.store_line(",".join(row.map(func(v): return str(v).replace(",", ";"))))
	# FLUSHED EVERY ROW. FileAccess.store_line BUFFERS (CLAUDE.md), and a session
	# that ends by being killed -- which is how a networking session under
	# investigation usually ends -- would otherwise lose the tail, which is the
	# part worth reading.
	_file.flush()

# HOW MUCH THE DELTA CODEC IS REMEMBERING. `SnapshotDelta` keeps a per-section
# dictionary of what it last sent, so this is the size of that memory -- included
# because it is a number that can only grow if nothing prunes it, and a thing that
# only grows is the shape being reported. It is not a claim that this is the bug.
func _memo_size(world) -> int:
	var total: int = 0
	for key in world._last_sent:
		total += int(world._last_sent[key].size())
	return total
