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
#   5. THE HOST'S FILE HOLDS EVERY MACHINE'S NUMBERS. A client's row arrives over
#      the real socket and is filed under `from`. This is the half that decides
#      whether the instrument gets used at all: the two sides count disjoint
#      things, and a trace that needs two people to go and find user:// afterwards
#      is one nobody collects.
#   6. AND A MARK LANDS BESIDE THE NUMBERS. The only column here that comes from a
#      human, because "worse over time" is a feeling until it has a timestamp.
#   7. `from` IS THE TRANSPORT'S ID, NOT THE PAYLOAD'S, and a row of the wrong
#      width is dropped rather than joined to the header a column out.

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
	recorded["host_csv"] = host_world._telemetry.path()
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1
	match phase:
		1: _phase_it_records()
		2: _phase_it_can_report_a_fault()
		3: _phase_the_host_holds_everything()

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
	phase = 3
	frame = 0

# --- 5, 6 and 7. One file, every machine -------------------------------------

func _phase_the_host_holds_everything() -> void:
	if frame == 1:
		# THE PRESS HAPPENS ON THE CLIENT, which is the whole point: the person with
		# the symptom is the one who can say when it happened, and they are never
		# the host.
		client_world.debug_mark_moment()
		client_world.debug_mark_moment()
		return
	if frame < NetTelemetry.SAMPLE_TICKS * 2 + 10:
		return

	var rows: Array = _rows(recorded["host_csv"])
	var from_at: int = _index(rows, "from")
	var role_at: int = _index(rows, "role")
	var mark_at: int = _index(rows, "mark")
	var peer: int = int(client_world.local_peer)

	var own: int = 0
	var reported: int = 0
	var marked: int = 0
	for i in range(1, rows.size()):
		var f: PackedStringArray = rows[i].split(",")
		if f.size() <= maxi(from_at, maxi(role_at, mark_at)):
			continue
		if f[role_at] == "host":
			own += 1
		elif int(f[from_at]) == peer:
			reported += 1
			marked += int(f[mark_at])
	print("[net] host file: %d own rows, %d rows reported by peer %d, %d marks"
		% [own, reported, peer, marked])

	check(own > 0, "the host writes its own rows")
	check(reported > 0,
		"and the CLIENT's rows arrive in the host's file (%d) under `from` -- the "
			% reported
		+ "two sides count disjoint things, and a trace that needs somebody else to "
		+ "go and find user:// afterwards is one nobody collects")
	eq(marked, 2,
		"and a mark pressed on the client lands beside the numbers taken at that "
		+ "moment -- counted, not flagged, so two presses read as two")

	# ...AND THE FILE IS STILL RECTANGULAR with two writers in it. The failure this
	# guards is not a missing row, it is a row joined to the header one column out,
	# which makes every number after it quietly wrong rather than absent.
	var header: int = rows[0].split(",").size()
	var ragged: int = 0
	for i in range(1, rows.size()):
		if rows[i].split(",").size() != header:
			ragged += 1
	eq(ragged, 0, "every row in a two-writer file has the header's width")

	_it_does_not_trust_the_payload()
	finish()

# --- 7. Whose row is it -------------------------------------------------------

func _it_does_not_trust_the_payload() -> void:
	# Asserted directly on the object rather than over the socket, because the
	# claim is about what note_peer_row DOES with what it is handed -- and a test
	# that hand-builds its input is the right shape here for exactly the reason it
	# was the wrong shape for the shield: the input really does come from
	# somewhere else, and being able to lie is the property under test.
	var before: int = _rows(recorded["host_csv"]).size()
	var claim: Array = []
	for name in NetTelemetry.COLUMNS:
		claim.append(999 if name == "from" else 0)
	host_world._telemetry.note_peer_row(7, claim)

	# AND ONE OF THE WRONG WIDTH, which is what a peer on an older build sends.
	#
	# ONE COLUMN SHORT, NOT THREE COLUMNS LONG, and the difference is the whole
	# assertion. The first version passed `[1, 2, 3]` and the A/B showed the claim
	# was DEAD: with the guard deleted, writing `from` at index 3 of a 3-element
	# array raises, and a GDScript runtime error ABORTS THE REST OF THE FUNCTION
	# (CLAUDE.md) -- so no row was written either way and a crash was
	# indistinguishable from a guard. A row that is short but still long enough to
	# index is the case where the guard is the only thing doing any work.
	var short: Array = claim.duplicate()
	short.resize(claim.size() - 1)
	host_world._telemetry.note_peer_row(7, short)

	var after: Array = _rows(recorded["host_csv"])
	eq(after.size(), before + 1,
		"a row of the wrong width is dropped rather than joined to the header a "
		+ "column out -- the gap is legible, a shifted column is not")
	for i in range(1, after.size()):
		eq(after[i].split(",").size(), after[0].split(",").size(),
			"and row %d still has the header's width after a malformed one was "
				% i + "offered")
	var last: PackedStringArray = after[after.size() - 1].split(",")
	eq(int(last[_index(after, "from")]), 7,
		"and `from` is the id the TRANSPORT reports, not the one in the payload -- "
		+ "a row is a claim about somebody's own machine, never about which machine")

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

func _index(rows: Array, name: String) -> int:
	var header: PackedStringArray = rows[0].split(",")
	for i in header.size():
		if header[i] == name:
			return i
	return -1

func _column(rows: Array, name: String, row_index: int) -> String:
	var at: int = _index(rows, name)
	if at < 0 or row_index >= rows.size():
		return "0"
	var fields: PackedStringArray = rows[row_index].split(",")
	return fields[at] if at < fields.size() else "0"
