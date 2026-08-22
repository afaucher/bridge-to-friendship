extends "res://scripts/test_support/test_case.gd"

# A PACK, ACROSS A REAL SOCKET.
#
# THE CLAIM THE OTHER TWO CANNOT MAKE. test_zombie proves a grave raises five
# bodies and test_zombie_walk proves they zigzag; both are equally true of a pack
# that only one machine can see, which in a co-op game is the whole feature
# failing. And a zombie is the worst possible candidate for that failure, because
# it is the first enemy that arrives as a GROUP -- the symptom would not be "an
# enemy is missing", it would be one player being mobbed by nothing.
#
# IT ALSO GUARDS THE SNAPSHOT SIGNATURE. Zombies were the twelfth section added to
# _apply_snapshot, and the arguments are positional: a section threaded into the
# wrong slot is caught immediately by a type error, but a section threaded
# NOWHERE is silent -- the host encodes it, the wire carries it, and the client
# never applies it. Only asking the far end what it can see distinguishes those.
#
# No grid here: the harness builds gym.tscn, so the pack is raised directly on the
# host. That is deliberate. What is under test is the WIRE, and a grave is
# authored terrain that both machines already agree about without being told.
#
# The claims:
#   1. Every member of a pack raised on the host exists on the client. All of
#      them -- a group enemy that replicates one body is worse than none.
#   2. They are in the same PLACES. World-local coordinates, so the harness's
#      kilometre offset between worlds never reaches the wire.
#   3. move_kind crosses. It is the sixth field, and the only reason zombies have
#      a section of their own rather than riding the rusher's.
#   4. A zombie the host stops naming is dropped by the client. That is how a
#      client learns one died, and it is the only way it ever learns.
#   5. The client does not INVENT any. It never simulates a zombie, so its count
#      can only ever be what it was told.

const PORT := 28787
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const ZombieBody = preload("res://scripts/sim/zombie_body.gd")

# Enough that "the client built some" and "the client built the pack" are
# different statements, which is the failure a group enemy has and a lone one
# does not.
const PACK := 5

var harness: Node = null
var frame: int = 0
var phase: int = 0
var host_world: Node = null
var client_world: Node = null
var doomed_id: int = 0

func setup(_main) -> void:
	timeout_seconds = 30.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	host_world = harness.host_world
	client_world = harness.client_worlds[0]
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1

	if phase == 1 and frame > 4:
		# NOTHING BEFORE, SO SOMETHING AFTER MEANS SOMETHING. Without this an
		# assertion that the client has five zombies could be satisfied by a client
		# that always has five.
		eq(client_world.zombie_count(), 0, "the client starts with no zombies")

		var centre: Vector3 = host_world.player_body(1).position + Vector3(0.0, 0.0, -6.0)
		for i in PACK:
			var angle: float = TAU * float(i) / float(PACK)
			# Spread, for the same reason the real ring is spread: coincident
			# bodies go through the floor. See CLAUDE.md, and _spawn_pack.
			var zombie: Node = host_world._spawn_zombie(
				centre + Vector3(sin(angle), 0.0, cos(angle)) * 1.5)
			# RECOVER, NOT WALK, AND THE REASON IS THE WHOLE POINT OF PHASE 3.
			#
			# The first version of this put them in WALK and hand-set move_kind, and
			# the assertion downstream failed against correct code -- because a
			# WALKING zombie picks a fresh move every time its budget runs out, so
			# by the time a snapshot had crossed the host had already changed its
			# mind about four of the five. RECOVER is the state that steps, falls
			# and settles without ever calling _begin_move, so the field under test
			# holds still for the length of the window.
			#
			# A field that the sender keeps rewriting cannot be tested for having
			# been transmitted: the value on the far end is then a race, and a race
			# that happens to agree looks exactly like a wire that works.
			zombie.state = ZombieBody.State.RECOVER
			zombie.state_timer = 0.0
			# ALTERNATING, so BOTH values are really in flight. LUNGE is the
			# non-zero one, so a field that never crossed at all would read as
			# SHUFFLE everywhere -- which is indistinguishable from a default, and
			# is why a test that only ever sent shuffles would prove nothing.
			zombie.move_kind = ZombieBody.Move.LUNGE if (i % 2) == 0 else ZombieBody.Move.SHUFFLE
			if i == 0:
				doomed_id = zombie.zombie_id
		eq(host_world.zombie_count(), PACK, "the host raised a pack of %d" % PACK)
		phase = 2
		frame = 0
		return

	if phase == 2 and frame > 20:
		_test_the_whole_pack_crossed()
		_test_they_are_in_the_same_places()
		_test_the_move_kind_crossed()
		# Killed on the HOST only, and never mentioned to the client by any other
		# route -- there is no "a zombie died" message and there must not be one.
		var doomed: Node = host_world._zombie_by_id(doomed_id)
		if is_instance_valid(doomed):
			doomed.kill()
		phase = 3
		frame = 0
		return

	if phase == 3 and frame > 20:
		_test_the_dead_one_is_dropped()
		finish()

# --- 1. The whole pack crossed ------------------------------------------------

func _test_the_whole_pack_crossed() -> void:
	eq(client_world.zombie_count(), PACK,
		"every member of the pack reached the client")

# --- 2. In the same places ----------------------------------------------------
#
# WORLD-LOCAL, which is what makes this assertion about the protocol rather than
# about the harness. The two worlds sit a kilometre apart in this process (they
# share one physics space), so a wire format carrying absolute coordinates would
# put the client's copy of the pack inside the host's copy of the world -- and
# the numbers here would be off by exactly 1000.

func _test_they_are_in_the_same_places() -> void:
	var worst := 0.0
	var matched := 0
	for host_zombie in host_world._zombies:
		var mirror: Node = client_world._zombie_by_id(host_zombie.zombie_id)
		if not is_instance_valid(mirror):
			check(false, "zombie %d has no counterpart on the client" % host_zombie.zombie_id)
			continue
		matched += 1
		worst = maxf(worst, host_zombie.position.distance_to(mirror.position))
	eq(matched, PACK, "each of them is matched by id, not merely counted")
	# A tick of staleness is fine and is what an unreliable per-tick wire buys; a
	# kilometre is a protocol bug, and half a metre is a body the two machines
	# disagree about.
	check(worst < 0.5,
		"and stands in the same place on both machines -- worst disagreement %.3f m" % worst)

# --- 3. The sixth field -------------------------------------------------------

func _test_the_move_kind_crossed() -> void:
	var mismatched := 0
	var lunging := 0
	var shuffling := 0
	for host_zombie in host_world._zombies:
		var mirror: Node = client_world._zombie_by_id(host_zombie.zombie_id)
		if not is_instance_valid(mirror):
			continue
		if mirror.move_kind != host_zombie.move_kind:
			mismatched += 1
		if host_zombie.move_kind == ZombieBody.Move.LUNGE:
			lunging += 1
		else:
			shuffling += 1
	eq(mismatched, 0, "every zombie's move is the move the host says it is")
	# WITHOUT THIS THE LINE ABOVE IS VACUOUS. If the host happened to have every
	# zombie on the same value, a client that ignored the field entirely and left
	# them all on the default would match perfectly. Both values have to be in
	# flight for "they agree" to be a claim about the wire.
	check(lunging > 0 and shuffling > 0,
		"and both values were really in flight -- %d lunging, %d shuffling"
			% [lunging, shuffling])

# --- 4 and 5. It stops being mentioned, so it goes ----------------------------

func _test_the_dead_one_is_dropped() -> void:
	eq(host_world.zombie_count(), PACK - 1, "the host removed the one it killed")
	eq(client_world.zombie_count(), PACK - 1,
		"and the client dropped it too, having simply stopped being told about it")
	check(client_world._zombie_by_id(doomed_id) == null,
		"specifically that one, rather than whichever the client happened to drop")
	# A CLIENT NEVER INVENTS ONE. Its pool is a mirror and nothing else -- if it
	# ever ran _process_zombies the count could only go up, because a grave on its
	# own copy of the grid would open under its own copy of a player.
	check(client_world.zombie_count() <= host_world.zombie_count(),
		"and never has more than the host, because it never simulates one")
