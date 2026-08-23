extends "res://scripts/test_support/test_case.gd"

# The networking instrument, over a real socket.
#
# BUILT BECAUSE OF A REPORT THAT IS NOT A BUG REPORT: networking is wrong and *it
# feels worse over time*. There is no line to go and read for that, so the answer
# is an instrument rather than a fix, and the instruction was explicit -- "let's
# not guess at what is happening".
#
# WHICH MAKES THIS TEST THE IMPORTANT PART. CLAUDE.md, twice over:
#
#   VALIDATE AN INSTRUMENT AGAINST A CASE WHERE IT MUST REPORT FAILURE before
#   trusting its output. Probes that could only ever return 0 have produced
#   confident WRONG eliminations in this project before.
#
# So the load-bearing claim here is not "it writes a file". It is that the numbers
# MOVE when the network is made worse on purpose -- and `debug_inbound_delay_ticks`
# exists to make it worse on purpose, which is the piece of luck that makes this
# checkable at all.
#
# The claims:
#   1. It writes a header and rows, and every row has as many fields as the header
#      promises. A CSV that drifts a column is worse than no CSV.
#   2. It counts snapshots WHERE THEY ARRIVE. The client's count is non-zero over
#      a real socket -- a number taken on the send side would look identical in
#      exactly the case worth investigating.
#   3. IT CAN REPORT A FAULT. With inbound delay injected the client's view of the
#      host diverges and the correction columns move. An instrument that has never
#      said anything is bad news is not evidence.
#   4. It costs the gate nothing: a world that was not told to opens no file.

const PORT := 28788
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const NetTelemetry = preload("res://scripts/net/net_telemetry.gd")

var harness: Node = null
var host_world: Node = null
var client_world: Node = null
var phase: int = 0
var frame: int = 0
var recorded: Dictionary = {}

func setup(_main) -> void:
	timeout_seconds = 60.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	host_world = harness.host_world
	client_world = harness.client_worlds[0]

	# --- 4. The gate pays nothing ---------------------------------------------
	#
	# Asserted BEFORE anything is switched on, because it is a claim about the
	# default: the harness never sets `telemetry_enabled`, so neither world may
	# have opened a file. A test that writes into user:// on every gate run is the
	# saved-hat trap with a different filename.
	check(host_world._telemetry == null and client_world._telemetry == null,
		"a world nobody asked opens no telemetry file -- the gate builds a hundred "
		+ "of these and none of them may write to user://")

	# Now switch it on by hand, which is what main.gd does for a real session.
	host_world._telemetry = NetTelemetry.new()
	host_world._telemetry.open_for("test_host")
	client_world._telemetry = NetTelemetry.new()
	client_world._telemetry.open_for("test_client")
	recorded["client_csv"] = client_world._telemetry.path()
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1
	match phase:
		1: _phase_it_records()
		2: _phase_it_can_report_a_fault()

# --- 1 and 2. It writes, and it counts arrivals -------------------------------

func _phase_it_records() -> void:
	# Two sample windows, so there is a row to read and a second one to prove the
	# heartbeat repeats rather than firing once.
	if frame < NetTelemetry.SAMPLE_TICKS * 2 + 10:
		return
	var rows: Array = _rows(recorded["client_csv"])
	print("[net] client wrote %d rows" % rows.size())
	check(rows.size() >= 3,
		"the client wrote a header and at least two rows (%d) -- one row is a "
			% rows.size() + "reading, and this is meant to show a TREND")
	if rows.size() < 3:
		finish()
		return

	var header: PackedStringArray = rows[0].split(",")
	eq(header.size(), NetTelemetry.COLUMNS.size(), "the header names every column")
	for i in range(1, rows.size()):
		eq(rows[i].split(",").size(), header.size(),
			"and row %d has the same number of fields -- a CSV that drifts a "
				% i + "column is worse than no CSV")

	# THE CLIENT'S OWN COUNT, taken where a snapshot arrives.
	var snaps: int = int(_column(rows, "snaps", 1))
	print("[net] client received %d snapshots in the first second" % snaps)
	check(snaps > 0,
		"the client counted snapshots ARRIVING (%d) -- counted on the send side "
			% snaps + "this number would look healthy in exactly the case worth "
		+ "investigating")

	phase = 2
	frame = 0

# --- 3. And it can say something is wrong -------------------------------------

func _phase_it_can_report_a_fault() -> void:
	if frame == 1:
		# FORTY TICKS OF INBOUND DELAY, which is two thirds of a second of the
		# client acting on stale news. The same injector test_contact_prediction
		# uses, and the reason this assertion is possible at all.
		client_world.debug_inbound_delay_ticks = 40
		# SOMETHING HAS TO BE MOVING for staleness to be observable. CLAUDE.md:
		# a latency instrument read on a stationary body reports zero at 4 ticks of
		# delay AND at 40, which reads as "the delay does nothing" and would condemn
		# a working rig. Every peer walks for the rest of the phase.
		for peer in [1, 2]:
			harness.set_input_provider(peer, func(t: int) -> Array:
				return PlayerInput.make(t, Vector2(0.0, -1.0), 0))
		return
	if frame < NetTelemetry.SAMPLE_TICKS * 3:
		return
	var rows: Array = _rows(recorded["client_csv"])
	# THE COLUMN THAT CAN SEE IT. The first version of this phase asked
	#  -- the client's error about ITSELF -- and got 0.00 m at
	# forty ticks of delay, because a client replays its own inputs and lands in
	# the same place however stale its news is. That is a probe that could only
	# ever return zero, and it was caught only because the instrument was made to
	# prove it could report a fault.
	var worst := 0.0
	for i in range(1, rows.size()):
		worst = maxf(worst, float(_column(rows, "jump_max", i)))
	print("[net] with 40 ticks of delay: worst remote jump %.2f m over %d rows"
		% [worst, rows.size()])
	check(worst > 0.05,
		"injecting delay moves the numbers (%.2f m of remote teleport) -- an "
			% worst
		+ "instrument that has never reported a fault is not evidence, and this "
		+ "project has twice believed a probe that could only ever return zero")
	client_world.debug_inbound_delay_ticks = 0
	finish()

# --- helpers ------------------------------------------------------------------

func _rows(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out: Array = []
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() != "":
			out.append(line)
	return out

func _column(rows: Array, name: String, row_index: int) -> String:
	var header: PackedStringArray = rows[0].split(",")
	var at: int = -1
	for i in header.size():
		if header[i] == name:
			at = i
	if at < 0 or row_index >= rows.size():
		return "0"
	var fields: PackedStringArray = rows[row_index].split(",")
	return fields[at] if at < fields.size() else "0"
