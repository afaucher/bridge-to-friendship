extends "res://scripts/test_support/test_case.gd"

# WHAT A DEATH LEAVES BEHIND, IN A REAL WORLD, FOR EVERY ENEMY THAT LEAVES ONE.
#
# The other half of the death-animation gate. test_fragment_shape proves the
# CUTTING is right without running the game; this proves the cut pieces are
# actually put in the world, in the right place, on the right deaths, and that
# they behave. It is table-driven over KINDS below, so a fourth enemy that earns
# a corpse costs one line here.
#
# The claims, in the order they matter:
#
#   1. A weapon kill leaves a pile, and the pile OCCUPIES THE SPACE THE BODY DID.
#      This is the whole feature: if the silhouette moves on the frame of death
#      the animation has failed at the only moment anybody is watching it.
#   2. It is INTACT and frozen -- an untouched corpse costs the solver nothing.
#   3. IT CANNOT TOUCH A PLAYER. Asserted as a relationship between two masks
#      rather than as a literal, and asserted in BOTH directions, because a
#      deliberately narrow mask is indistinguishable from a mistyped one unless
#      the intent is written down as a test.
#   4. Walking into it knocks it apart.
#   5. AN EXPLOSIVE NEVER LEAVES ONE STANDING.
#   6. THE DEATHS THAT ARE NOT DEATHS LEAVE NOTHING. A rusher that burrows and a
#      body that falls off the bridge both stop existing exactly the way a killed
#      one does, and neither should leave rubble.
#
# CLAIM 6 IS THE ONE THAT NEEDED WRITING DOWN. Every other assertion here is
# about a corpse being present, and CLAUDE.md is blunt that a counter only ever
# asserted PRESENT is as untested as one only ever asserted absent -- the code
# that decides a death "earned" a corpse has two branches and a test that only
# kills things exercises one of them.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const GunnerBody = preload("res://scripts/sim/gunner_body.gd")
const Corpse = preload("res://scripts/sim/corpse.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const PlayerScene = preload("res://scenes/player.tscn")

# EVERY ENEMY THAT EARNS ONE. `spawner` names the world's own spawn helper so the
# test builds enemies the way the game does rather than instantiating scenes
# itself -- a body assembled by hand is a body that has not been through the code
# under test.
const KINDS := [
	{"name": "rusher", "spawn": "rusher", "corpse_kind": Corpse.Kind.RUSHER},
	{"name": "zombie", "spawn": "zombie", "corpse_kind": Corpse.Kind.ZOMBIE},
	{"name": "skirmisher", "spawn": "skirmisher", "corpse_kind": Corpse.Kind.SKIRMISHER},
	# A TURRET SHATTERS TOO. Bolted down in life and no less breakable for it --
	# and the reason the fragmenter stopped assuming one mesh per body, since a
	# turret is a base, a ring and a box gun barrel in two different greys.
	{"name": "turret", "spawn": "turret", "corpse_kind": Corpse.Kind.TURRET},
]

# Well clear of the spawn ring and of each other, so nothing in one phase is
# standing in the previous phase's rubble. See CLAUDE.md on isolating EVERY
# sample rather than once at setup.
const TEST_SPOT := Vector3(0.0, 1.2, -14.0)

# The client world is a separate SceneTree child but shares ONE physics space
# with the host world -- CLAUDE.md's note that two worlds in one process do. Its
# pile goes a long way from the other one so neither can touch the other.
const CLIENT_SPOT := Vector3(0.0, 1.2, -40.0)

# TURNED WELL AWAY FROM THE SCENE FILE'S OWN POSE, which is the whole point.
#
# A corpse is cut from a PRISTINE instance of the scene, so it knows where a
# turret's barrel sits when the turret is aimed dead ahead and nothing else. If
# the test killed a body still in its default pose, the pile would match by
# accident and the assertion would hold with the aim thrown away -- which is
# exactly the bug that reached play: a turret's barrel snapping to a new
# direction on the hit.
const TEST_YAW := 1.1

var world: Node3D = null
# A SECOND WORLD THAT IS NOT THE HOST. See the last phase.
var client: Node3D = null
var phase: int = 0
var phase_frame: int = 0
var kind_index: int = 0
var subject: Node = null
var noted: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 300.0
	world = world_under_test(Node3D.new())
	world.name = "CorpseWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)

func _physics_process(_delta: float) -> void:
	if world == null or world.tick == 0:
		return
	phase_frame += 1
	# UNCONDITIONAL HEARTBEAT. Six phases times three kinds, each waiting on a
	# different condition, is exactly the shape that presents as a 120 s timeout
	# with no clue which claim never resolved. Nothing about the test can gate
	# this line.
	if phase_frame % 120 == 0:
		print("[CORPSE] phase %d kind %d frame %d corpses %d killed_at %d"
			% [phase, kind_index, phase_frame, world.corpse_count(), _killed_at()])
	match phase:
		0: _phase_weapon_kill()
		1: _phase_bump_scatters()
		2: _phase_explosive_never_stands()
		3: _phase_a_fall_is_not_a_death()
		4: _phase_expiry_is_not_a_death()
		5: _phase_it_goes_away()
		6: _phase_a_client_runs_its_own_piles()
		7: _phase_a_round_knocks_it_down()
		8: _phase_a_blast_knocks_a_standing_pile_down()
		_: finish()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0
	noted["killed_at"] = 0

# Clear the deck between samples. A corpse from the previous claim standing where
# the next one is measured would be counted by corpse_count() and would be within
# bump range of the next body.
func _reset() -> void:
	world.clear_corpses()
	# AND ROUNDS IN FLIGHT. Skirmishers in earlier phases SHOOT, and a stray round
	# still travelling down the bridge is what turned the "a round goes through a
	# pile" assertion into a dead one: it watched for ANY bullet to reach the far
	# side, and somebody else's round got there whether or not the one under test
	# was stopped. The A/B is what found it -- putting the debris layer into the
	# bullet sweep, which makes a corpse into cover, left the test green.
	for bullet in world._bullets:
		if is_instance_valid(bullet):
			bullet.queue_free()
	world._bullets.clear()
	for list in [world._rushers, world._zombies, world._gunners]:
		for enemy in list:
			if is_instance_valid(enemy):
				enemy.queue_free()
		list.clear()
	# THE PLAYER GOES BACK TO A SPAWN POINT, NOT TO AN ARBITRARY COORDINATE, and
	# this cost a round. The first version parked it at z = 40 to get it out of
	# bump range -- which on test_flat is off the end of the deck. It fell, went
	# below FALL_KILL_Y, and a solo party entirely out is a WIPE: the round machine
	# restarted at the checkpoint and FREED EVERY ENEMY IN THE WORLD, including the
	# one the next phase had just spawned and was waiting on. The symptom was a
	# 120 s timeout in the phase after the one that spawned the player, with the
	# subject silently invalid -- exactly the fuse CLAUDE.md describes.
	#
	# spawn_point(0) is guaranteed to be somewhere a body can stand, and it is far
	# more than CORPSE_BUMP_RADIUS from TEST_SPOT.
	for peer_key in world.players.keys():
		var body: Node = world.players[peer_key]
		if is_instance_valid(body):
			body.position = world.spawn_point(0)
			body.velocity = Vector3.ZERO
	# And the flag itself, because it OUTLIVES a phase: a return begun on the last
	# tick of one phase lands on the first tick of the next and deletes something
	# that phase never touched.
	world._returning.clear()

func _spawn(kind: Dictionary, at: Vector3) -> Node:
	match str(kind["spawn"]):
		"rusher":
			return world._spawn_rusher(at)
		"zombie":
			return world._spawn_zombie(at)
		"turret":
			return world._spawn_gunner(at, GunnerBody.Kind.TURRET)
		_:
			return world._spawn_gunner(at, GunnerBody.Kind.SKIRMISHER)

func _kill(body: Node, kind: int, from: Vector3) -> void:
	# THROUGH _deliver, not by setting `killed` by hand. The path that records
	# WHAT killed something lives in _deliver, and a test that set the flag
	# directly would skip the code it is here to check -- CLAUDE.md's note about a
	# test that hand-builds its own input having not tested the caller.
	world._deliver(body, Hit.make(kind, 1, from, 0.0, 0.0, 1))

# --- Staging ------------------------------------------------------------------
#
# SPAWN, THEN WAIT UNTIL IT IS ACTUALLY STANDING THERE, THEN SHOOT IT.
#
# The waiting is not politeness, and leaving it out cost a round. A rusher and a
# zombie spend their first second in a RISE, underground, with the step writing
# position every tick -- so an enemy killed at a fixed frame after spawning is
# killed BELOW THE DECK and the pile is assembled down there. Every assertion in
# the first phase still passed, because they all compare the corpse against the
# body's own position and both were wrong together. What gave it away was the
# BUMP phase failing for exactly the two kinds that have a rise and passing for
# the one that does not.
#
# It is CLAUDE.md's "measure on a fixture with nothing else moving in it", in the
# form this project keeps producing: a body that is still arriving is not a body.
func _staged(kind: Dictionary) -> bool:
	if phase_frame == 1:
		_reset()
		subject = _spawn(kind, TEST_SPOT)
		# POSED, not left in the scene file's default. Both angles, because they
		# are different angles: a zombie swings its whole body and its arms go
		# with it, a turret leaves its base and spins a pivot to aim the gun.
		if is_instance_valid(subject):
			subject.rotation.y = TEST_YAW
			if "facing" in subject:
				subject.facing = -TEST_YAW
		noted["killed_at"] = 0
		return false
	# One tick for the pose to be applied by the body's own code rather than by
	# this test reaching into its nodes.
	if phase_frame < 4:
		return false
	if not is_instance_valid(subject):
		return false
	if subject.has_method("is_in_play") and not subject.is_in_play():
		return false
	return true

func _killed_at() -> int:
	return int(noted.get("killed_at", 0))

# --- 1, 2 and 3. A weapon kill leaves the body's own shape, inert -------------

func _phase_weapon_kill() -> void:
	var kind: Dictionary = KINDS[kind_index]
	var name: String = str(kind["name"])

	if _killed_at() == 0:
		if not _staged(kind):
			return
		# THE BODY'S OWN EXTENT, TAKEN WHILE IT IS STILL ALIVE. Compared against
		# the corpse below: this is the "the silhouette does not move" claim, and
		# it has to be measured rather than restated from the .tscn, or it is a
		# test agreeing with a second copy of the numbers.
		noted["alive_aabb"] = _body_extent(subject)
		noted["alive_at"] = subject.position
		# THE POSE HAS TO HAVE SURVIVED, or the comparison below is a claim about
		# a body that was facing forwards all along. Measured at the moment of the
		# kill rather than assumed from what was set three ticks ago -- the body's
		# own step may have re-aimed it, and whatever it settled on is what the
		# corpse must match.
		noted["alive_yaw"] = subject.rotation.y
		check(absf(subject.rotation.y) > 0.2,
			"%s: the body is turned away from its default when it dies" % name)
		if "facing" in subject:
			check(absf(float(subject.facing)) > 0.2,
				"%s: the aim pivot is turned away from its default when it dies" % name)
		_kill(subject, Hit.Kind.BULLET, TEST_SPOT + Vector3(0.0, 0.0, 6.0))
		noted["killed_at"] = phase_frame
		return

	# The reap loop runs on the enemy's own pass, so the corpse exists on the tick
	# after the kill at the earliest.
	if phase_frame != _killed_at() + 3:
		return

	eq(world.corpse_count(), 1, "%s: a weapon kill leaves exactly one corpse" % name)
	if world.corpse_count() != 1:
		_next_kind(0)
		return
	var corpse: Node = world._corpses[0]
	check(corpse.is_intact(), "%s: the pile starts intact" % name)
	eq(corpse.fragments.size(), SimConfig.CORPSE_FRAGMENTS,
		"%s: cut into the configured number of pieces" % name)

	# 1. IT OCCUPIES THE SPACE THE BODY DID. The union of the fragments in world
	# space against the living body's own mesh extent.
	# WHERE THE PILE IS, AND WHICH WAY IT IS TURNED -- asked directly rather than
	# inferred from a bounding box, because the second one is the claim that
	# failed in play: a turret's barrel snapping to a new direction on the hit.
	check(corpse.position.distance_to(noted["alive_at"]) < 0.01,
		"%s: the pile stands where the body stood" % name)
	near(corpse.rotation.y, float(noted["alive_yaw"]), 0.01,
		"%s: the pile is turned the way the body was turned" % name)

	# AND THE SHAPE, COMPARED IN THE BODY'S OWN FRAME.
	#
	# NOT IN WORLD SPACE, and the first attempt that did cost a round. A
	# Transform3D applied to an AABB returns the AABB **of the rotated box**,
	# which is bigger than the box -- so a rotated body inflates to 1.34 where it
	# was 1.0, while the pile, being many small boxes each inflating hardly at
	# all, unions to 1.19. Two different inflations of the same shape, neither of
	# them the shape. Measured in the frame both were authored in, the rotation
	# cancels on both sides and what is left is the comparison that was wanted.
	#
	# The AIM still shows up here, which is the point: a barrel left at the scene
	# file's default sits somewhere quite different from one turned by -1.1 rad,
	# and it moves this extent by far more than the slack.
	var union: AABB = _fragment_union_local(corpse)
	var alive: AABB = noted["alive_aabb"]
	var slack := 0.06
	check(union.position.distance_to(alive.position) < slack
			and (union.size - alive.size).length() < slack,
		"%s: the pile has the body's shape -- body %s, pile %s"
			% [name, alive, union])

	# 2. Frozen: an untouched corpse costs the solver nothing.
	var frozen: int = 0
	for piece in corpse.fragments:
		if piece.freeze:
			frozen += 1
	eq(frozen, corpse.fragments.size(), "%s: every piece is frozen while intact" % name)

	# 3. IT CANNOT TOUCH A PLAYER, both directions.
	var player: Node = PlayerScene.instantiate()
	var piece: Node = corpse.fragments[0]
	eq(piece.collision_layer & player.collision_mask, 0,
		"%s: a player's mask does not include the debris layer" % name)
	eq(piece.collision_mask & player.collision_layer, 0,
		"%s: debris does not mask the players layer" % name)
	check(piece.collision_mask & 1 != 0,
		"%s: debris does collide with the world, or it falls through the deck" % name)
	player.free()

	_next_kind(1)

# --- 4. Walking into it knocks it apart --------------------------------------

func _phase_bump_scatters() -> void:
	var kind: Dictionary = KINDS[kind_index]
	var name: String = str(kind["name"])

	if _killed_at() == 0:
		if not _staged(kind):
			return
		_kill(subject, Hit.Kind.BULLET, TEST_SPOT + Vector3(0.0, 0.0, 6.0))
		noted["killed_at"] = phase_frame
		return

	if phase_frame == _killed_at() + 3:
		if not check(world.corpse_count() == 1, "%s: bump phase has a corpse to bump" % name):
			_next_kind(1)
			return
		var corpse: Node = world._corpses[0]
		noted["spread_before"] = _fragment_spread(corpse)
		# A PLAYER WALKS INTO IT, and PLACED rather than spawned-and-waited-for: a
		# freshly spawned enemy is underground for a second (see _staged), so using
		# one as the thing that does the bumping would be measuring the rise.
		#
		# NOTHING HERE CALLS scatter(). The world's own pass has to notice, which
		# is the whole claim -- a test that burst the pile itself would pass with
		# _process_corpses deleted.
		if not world.players.has(1):
			world._spawn_player(1, 0)
		world.player_body(1).position = corpse.position + Vector3(0.4, 0.0, 0.0)
		return

	if phase_frame == _killed_at() + 6:
		var corpse: Node = world._corpses[0] if world.corpse_count() > 0 else null
		if not check(corpse != null, "%s: the corpse survived the bump tick" % name):
			_next_kind(2)
			return
		check(not corpse.is_intact(), "%s: something walking into the pile scatters it" % name)
		var unfrozen: int = 0
		for piece in corpse.fragments:
			if not piece.freeze:
				unfrozen += 1
		eq(unfrozen, corpse.fragments.size(), "%s: every piece is loose after a scatter" % name)
		return

	# AND THEY ACTUALLY GO SOMEWHERE. "Unfrozen" is a flag; this is the thing the
	# flag is for, and the two are not the same -- a piece with no impulse on it is
	# unfrozen and stationary, and would satisfy every assertion above.
	if phase_frame == _killed_at() + 40:
		var corpse: Node = world._corpses[0] if world.corpse_count() > 0 else null
		if corpse != null:
			var after: float = _fragment_spread(corpse)
			check(after > float(noted["spread_before"]) * 1.15,
				"%s: the pieces move apart -- %.3f m before, %.3f m after"
					% [name, noted["spread_before"], after])
		_next_kind(2)

# --- 5. An explosive never leaves one standing -------------------------------

func _phase_explosive_never_stands() -> void:
	var kind: Dictionary = KINDS[kind_index]
	var name: String = str(kind["name"])

	if _killed_at() == 0:
		if not _staged(kind):
			return
		_kill(subject, Hit.Kind.EXPLOSIVE, TEST_SPOT + Vector3(0.0, -0.5, 0.0))
		noted["killed_at"] = phase_frame
		return
	if phase_frame == _killed_at() + 3:
		if check(world.corpse_count() == 1, "%s: an explosive kill still leaves pieces" % name):
			var corpse: Node = world._corpses[0]
			check(not corpse.is_intact(),
				"%s: a blast never leaves the pile standing -- it arrives scattered" % name)
		_next_kind(3)

# --- 6. The deaths that are not deaths ---------------------------------------

func _phase_a_fall_is_not_a_death() -> void:
	var kind: Dictionary = KINDS[kind_index]
	var name: String = str(kind["name"])

	if _killed_at() == 0:
		if not _staged(kind):
			return
		# SHOT ON THE WAY DOWN: the case where "it was killed" and "it fell off the
		# bridge" are both true at once, and the one a naive test of either
		# condition on its own gets wrong.
		subject.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 5.0, -14.0)
		_kill(subject, Hit.Kind.BULLET, Vector3(0.0, 0.0, -8.0))
		noted["killed_at"] = phase_frame
		return
	if phase_frame == _killed_at() + 4:
		# TWO RULES PRODUCE THIS AND THE TEST CANNOT TELL THEM APART, which the A/B
		# showed: _retire_enemy refuses to build a corpse below FALL_KILL_Y, and
		# _process_corpses culls one that is already down there. Deleting the first
		# left this assertion green while the burrow claim below went red.
		#
		# Left as it is, and said out loud rather than sharpened. It is the true
		# player-visible property -- shoot something as it goes over the edge and
		# nothing is left behind -- and both rules are worth having: without the
		# first, a networked game RPCs a corpse nobody can see.
		eq(world.corpse_count(), 0,
			"%s: something shot on its way off the bridge leaves nothing" % name)
		_next_kind(4)

# A rusher that outlives its welcome burrows away, and a gunner the party has
# walked past is culled. Neither is a death. Only the rusher has a lifetime short
# enough to wait out, so this claim is made once rather than per kind.
func _phase_expiry_is_not_a_death() -> void:
	if phase_frame == 1:
		_reset()
		subject = world._spawn_rusher(TEST_SPOT)
		return
	# Past RUSHER_LIFETIME, with nothing having touched it.
	if phase_frame > int((SimConfig.RUSHER_LIFETIME + 1.0) / SimConfig.TICK_DELTA):
		eq(world._rushers.size(), 0, "the rusher burrowed away as it should")
		eq(world.corpse_count(), 0, "a rusher that burrows leaves nothing behind")
		_advance(5)
		phase_frame = 0

# --- The pile does not stay forever -------------------------------------------

func _phase_it_goes_away() -> void:
	if phase_frame == 1:
		_reset()
		subject = world._spawn_rusher(TEST_SPOT)
		return
	if phase_frame == 4:
		_kill(subject, Hit.Kind.BULLET, TEST_SPOT + Vector3(0.0, 0.0, 6.0))
		return
	if phase_frame == 7:
		check(world.corpse_count() == 1, "lifetime phase has a corpse")
		return
	if phase_frame > int((SimConfig.CORPSE_LIFETIME + 1.0) / SimConfig.TICK_DELTA):
		eq(world.corpse_count(), 0,
			"an undisturbed pile clears itself after CORPSE_LIFETIME")
		_advance(6)

# --- 7. A client runs its own piles -------------------------------------------
#
# THE CORPSE PASS MUST NOT BE HOST-GATED, and it was: _process_corpses() was
# written inside _host_tick(), next to the enemy passes whose deaths create a
# corpse, with a comment on it claiming it was not host-gated. On a client it
# therefore never ran -- a pile could only be scattered by a blast (which arrives
# as its own RPC and takes a different path), was never culled behind the party,
# and the list grew with freed entries for the whole session.
#
# NO SOCKET HERE. The claim is not about networking, it is about a gate: does the
# pass run on a world whose is_host is false. A world built that way answers it
# for the price of a phase, where a real two-peer session would be a port, a
# harness and thirty seconds. If corpses ever become something a client must be
# told the STATE of rather than merely the death of, that is when this earns a
# net test.
#
# The pile is placed with _show_corpse rather than by killing something, because
# a client never kills anything -- that is the host's job, and it is exactly why
# the bug existed.
func _phase_a_client_runs_its_own_piles() -> void:
	if phase_frame == 1:
		_reset()
		client = world_under_test(Node3D.new())
		client.name = "CorpseClientWorld"
		client.set_script(GameWorldScript)
		get_parent().add_child(client)
		client.segment_paths = ["res://segments/test_flat.seg"]
		# NOT the host. The whole point of the phase.
		client.start(false, 2, false)
		return
	if phase_frame == 3:
		check(not client.is_host, "the second world is a client")
		client._show_corpse(Corpse.Kind.RUSHER, CLIENT_SPOT, 0.0, 0.0, Vector3.ZERO, false)
		eq(client.corpse_count(), 1, "a client can be told to show a pile")
		return
	if phase_frame == 5:
		if not check(client.corpse_count() == 1, "the client pile is still there"):
			_advance(7)
			return
		var corpse: Node = client._corpses[0]
		check(corpse.is_intact(), "the client pile starts intact")
		# Something walks into it. On the client, with no host anywhere.
		client._spawn_player(2, 0)
		client.player_body(2).position = corpse.position + Vector3(0.4, 0.0, 0.0)
		return
	if phase_frame == 8:
		if check(client.corpse_count() == 1, "the client pile survived"):
			var corpse: Node = client._corpses[0]
			check(not corpse.is_intact(),
				"a CLIENT scatters its own pile when something walks into it")
		_advance(7)

# --- 8. A round knocks it down AND GOES THROUGH IT ----------------------------
#
# TWO CLAIMS IN ONE PHASE, AND THE SECOND IS THE ONE THAT PROTECTS THE GAME.
#
# Shooting a pile should knock it apart. Shooting a pile must NOT stop the round:
# the bullet sweep excludes the debris layer on purpose, and the sweep's own
# comment already makes the argument about a hat on the deck -- "a dropped pile
# would be cover nobody built". A body that fell where you are shooting must not
# become a sandbag, so the round has to carry on to whatever it was aimed at.
#
# The round is fired from short of the pile and aimed straight through it, and
# the test watches for it to arrive on the far SIDE. That is the only way to
# state "it was not consumed" -- a bullet still existing proves nothing, since it
# may simply not have reached the pile yet.
func _phase_a_round_knocks_it_down() -> void:
	if phase_frame == 1:
		_reset()
		world._show_corpse(Corpse.Kind.RUSHER, TEST_SPOT, 0.0, 0.0, Vector3.ZERO, false)
		noted["passed_beyond"] = false
		return
	if phase_frame == 3:
		if not check(world.corpse_count() == 1, "shot phase has a pile to shoot"):
			_advance(8)
			return
		check(world._corpses[0].is_intact(), "the pile is standing before the shot")
		# DOWN THE BRIDGE THROUGH THE PILE, AND DELIBERATELY OFF THE AXIS.
		#
		# The first version fired at x = 0, straight down the middle -- which is the
		# one line through a subdivided solid where the answer is undefined: the
		# axis is the shared EDGE of every angular wedge, and a ray running exactly
		# along it can miss every piece to floating point. Instrumented, the round
		# reported MISS the whole way past a pile it was travelling through, and
		# the A/B that should have proved "a corpse is not cover" passed with the
		# debris layer added to the bullet sweep -- a dead assertion caused
		# entirely by where the fixture aimed.
		#
		# 0.15 m off centre and below the middle, where the cone is 0.37 m wide, is
		# solidly inside one piece rather than on the seam between thirty-two.
		world._spawn_round(TEST_SPOT + Vector3(0.15, -0.3, 4.0), Vector3(0.0, 0.0, -1.0),
			1, RID(), false, 1)
		# AND THE ONE ROUND IS THE ONLY ROUND. The deck is cleared of rounds in
		# _reset for this reason; asserting it here is what stops the claim below
		# quietly becoming about somebody else's bullet again.
		eq(world._bullets.size(), 1, "exactly one round is in flight")
		noted["shot_id"] = int(world._bullets[0].bullet_id)
		return
	if phase_frame > 3:
		# THE ROUND REACHING THE FAR SIDE is what says it was not stopped. Watched
		# every tick rather than sampled at one, because the frame it arrives on
		# is a fact about the bullet speed and nobody should have to keep that
		# number in step with this test.
		for bullet in world._bullets:
			if (is_instance_valid(bullet)
					and int(bullet.bullet_id) == int(noted.get("shot_id", -1))
					and bullet.position.z < TEST_SPOT.z - 1.5):
				noted["passed_beyond"] = true
	if phase_frame == 90:
		if check(world.corpse_count() == 1, "the pile is still in the world"):
			check(not world._corpses[0].is_intact(),
				"a round knocks the pile down")
		check(bool(noted["passed_beyond"]),
			"the round went THROUGH the pile -- a corpse is not cover")
		_advance(8)

# --- 9. And an explosion knocks over a pile that was already standing ---------
#
# SEPARATE FROM THE EXPLOSIVE-KILL PHASE, which only ever proves that a corpse
# CREATED by a blast arrives scattered -- a different code path (`has_from` at
# spawn) from a blast landing near a pile that has been standing for a while.
# Only the second one goes through _play_blast, which is also the path a client
# reaches by RPC.
func _phase_a_blast_knocks_a_standing_pile_down() -> void:
	if phase_frame == 1:
		_reset()
		world._show_corpse(Corpse.Kind.ZOMBIE, TEST_SPOT, 0.0, 0.0, Vector3.ZERO, false)
		return
	if phase_frame == 3:
		if not check(world.corpse_count() == 1, "blast phase has a standing pile"):
			_advance(9)
			return
		check(world._corpses[0].is_intact(), "the pile is standing before the blast")
		world.blast_at(TEST_SPOT + Vector3(1.5, 0.0, 0.0), SimConfig.BLAST_RADIUS,
			Hit.Kind.EXPLOSIVE, 1)
		return
	if phase_frame == 6:
		if check(world.corpse_count() == 1, "the pile survived the blast tick"):
			check(not world._corpses[0].is_intact(),
				"a blast knocks over a pile that was already standing")
		_advance(9)

# --- Helpers ------------------------------------------------------------------

func _next_kind(next_phase: int) -> void:
	noted["killed_at"] = 0
	kind_index += 1
	if kind_index >= KINDS.size():
		kind_index = 0
		_advance(next_phase)
	else:
		phase_frame = 0

# EVERY VISIBLE MESH ON THE LIVING BODY, UNIONED -- the silhouette the corpse has
# to match.
#
# THIS USED TO ASK FOR THE NODE CALLED "Mesh", AND IT COST TWO FAILURES AT ONCE.
# A turret has no such node -- it is a Base, a Ring and a Gun -- so the read
# returned null, `.get_aabb()` on it RAISED, and the raise aborted the rest of
# the phase every frame. The kill never happened and the test reported a TIMEOUT
# rather than a failure, which is the GDScript trap CLAUDE.md records: a runtime
# error is not a test failure, it is a function that silently stops. And on the
# zombie it was quietly wrong rather than fatal, comparing a corpse that now
# includes two arms against a torso-only extent.
#
# It is the same mistake the fragmenter itself had to stop making. "The mesh" is
# not a thing a body has; a list of meshes is.
func _body_extent(body: Node) -> AABB:
	var out := AABB()
	var first := true
	for view in _meshes_of(body):
		var here: AABB = _local_transform_of(view, body) * view.get_aabb()
		if first:
			out = here
			first = false
		else:
			out = out.merge(here)
	return out

func _meshes_of(node: Node) -> Array:
	var out: Array = []
	var view := node as MeshInstance3D
	if view != null and view.visible and view.mesh != null:
		out.append(view)
	for child in node.get_children():
		out.append_array(_meshes_of(child))
	return out

func _local_transform_of(node: Node3D, root: Node) -> Transform3D:
	var out := Transform3D.IDENTITY
	var walk: Node = node
	while walk != null and walk != root:
		var here := walk as Node3D
		if here != null:
			out = here.transform * out
		walk = walk.get_parent()
	return out

# The pile's extent IN THE CORPSE'S OWN FRAME -- directly comparable with
# _body_extent, which measures the living body in its frame. See the note at the
# call site for why this is not done in world space.
func _fragment_union_local(corpse: Node) -> AABB:
	var out := AABB()
	var first := true
	for piece in corpse.fragments:
		var view := piece.get_child(0) as MeshInstance3D
		var here: AABB = piece.transform * view.get_aabb()
		if first:
			out = here
			first = false
		else:
			out = out.merge(here)
	return out

# The union of every fragment's world-space extent -- the pile's silhouette.
func _fragment_union(corpse: Node) -> AABB:
	var out := AABB()
	var first := true
	for piece in corpse.fragments:
		var view := piece.get_child(0) as MeshInstance3D
		var local: AABB = view.get_aabb()
		var here := AABB(local.position + piece.global_position, local.size)
		if first:
			out = here
			first = false
		else:
			out = out.merge(here)
	return out

# How far the pieces are from their common centre. A single number for "has this
# come apart", which is what makes the before/after comparison possible.
func _fragment_spread(corpse: Node) -> float:
	var centre := Vector3.ZERO
	for piece in corpse.fragments:
		centre += piece.global_position
	centre /= float(maxi(1, corpse.fragments.size()))
	var total: float = 0.0
	for piece in corpse.fragments:
		total += piece.global_position.distance_to(centre)
	return total / float(maxi(1, corpse.fragments.size()))
