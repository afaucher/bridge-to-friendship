extends "res://scripts/test_support/test_case.gd"

# THE PACK: the grave, the bodies it raises, and what happens when one reaches
# you. The walk itself is measured in test_zombie_walk.gd.
#
# The claims worth defending, in the order they matter:
#
#   1. A grave raises a PACK -- three to five, from one authored cell -- and is
#      spent. One cell is worth several bodies, which nothing else in this game is.
#   2. NO TWO OF THEM ARE IN THE SAME PLACE, and they are still standing a second
#      later. This is the assertion the whole feature turns on: two coincident
#      bodies depenetrate into a degenerate normal that drives both DOWN through
#      the deck, and this is the most concentrated instance of that trap the
#      project has -- five bodies, one cell, one tick.
#   3. The rise is a TELEGRAPH. For its whole duration nothing in the pack can
#      touch you. That is the fairness argument for the hazard.
#   4. Contact costs a hit point and the zombie SURVIVES it. That is the one place
#      it differs from a rusher, and it is what makes a group work.
#   5. The tumble is a CHANCE, not a certainty. Both outcomes really happen.
#   6. A dashing player deflects it and takes nothing. The free answer.
#   7. It rots on its own clock, so a weaponless player is never stranded.
#   8. A blast empties a grave before it opens -- three to five enemies pre-empted
#      by one charge, which is the best trade in the game.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const ZombieBody = preload("res://scripts/sim/zombie_body.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# The three graves authored in the fixture, ten cells apart so no single visit is
# inside two trigger radii.
const GRAVE_A := Vector2i(5, 5)
const GRAVE_B := Vector2i(5, 15)
const GRAVE_C := Vector2i(14, 5)

# How many contacts the tumble-chance phase collects. Thirty-five is enough that
# "both outcomes occur" is not luck, and few enough that the phase costs two
# seconds of simulated time.
const CONTACT_SAMPLES := 35

var world: Node3D = null
var victim: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}
var tumbles: int = 0
var bites: int = 0

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "ZombieWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_zombies.seg"]
	world.start(true, 1, false)

	eq(world.grid.grave_count(), 3, "the fixture authors three graves")

	world._spawn_player(1, 0)
	victim = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.make(t, recorded.get("move", Vector2.ZERO), int(recorded.get("actions", 0)))

	# Well clear of all three, so nothing opens before its phase asks it to.
	_park(Vector2i(18, 22))

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_wake_the_pack()
		1: _phase_the_telegraph()
		2: _phase_contact_costs_and_survives()
		3: _phase_the_tumble_is_a_chance()
		4: _phase_dash_deflects()
		5: _phase_it_rots()
		6: _phase_a_blast_pre_empts()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

# --- 1 & 2. A grave raises a pack, and none of them are in the same place ------

func _phase_wake_the_pack() -> void:
	if phase_frame == 1:
		recorded["graves_before"] = world.grid.grave_count()
		# TWO CELLS from grave A -- inside ZOMBIE_TRIGGER_RADIUS (9 m), and not
		# standing ON it. Standing on it would put the player inside the ring the
		# pack rises on, which is a different test and a worse one.
		_park(Vector2i(5, 3))
		return
	if phase_frame == 3:
		var raised: int = world.zombie_count()
		check(raised >= SimConfig.ZOMBIE_PACK_MIN and raised <= SimConfig.ZOMBIE_PACK_MAX,
			"walking up to a grave raises a PACK -- %d, expected %d to %d"
				% [raised, SimConfig.ZOMBIE_PACK_MIN, SimConfig.ZOMBIE_PACK_MAX])
		check(raised > 1, "and a pack is more than one body, which is the whole enemy")
		eq(world.grid.grave_count(), int(recorded["graves_before"]) - 1,
			"and the grave is spent")

		# THE TRAP THIS FEATURE EXISTS TO WALK INTO. Measured pairwise rather than
		# asserted about the ring's arithmetic: the ring is the mechanism, and what
		# has to be true is the OUTCOME.
		var closest := INF
		for i in world._zombies.size():
			for j in range(i + 1, world._zombies.size()):
				closest = minf(closest, world._zombies[i].position.distance_to(
					world._zombies[j].position))
		check(closest > SimConfig.ZOMBIE_RADIUS * 2.0,
			"and no two of them are inside each other -- closest pair %.2f m, bodies %.2f m across"
				% [closest, SimConfig.ZOMBIE_RADIUS * 2.0])
		_advance(1)

# --- 3. The rise is a telegraph -----------------------------------------------
#
# Asserted on EVERY TICK of the rise, not once at the end. CLAUDE.md: a phase that
# samples one frame cannot see a bug seven frames later, and "X is safe FOR A
# DURATION" is precisely the shape that needs every tick of the duration.
#
# It also checks is_dangerous() directly rather than only checking that health did
# not move. A pack two cells away could not have reached the player in a second and
# a half anyway, so a health assertion alone would pass against a rising zombie
# that was perfectly capable of biting -- an assertion that cannot fail.

func _phase_the_telegraph() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(5, 13))
		return
	if phase_frame == 3:
		eq(world.zombie_count() > 0, true, "grave B opened")
		recorded["risers"] = world.zombie_count()
		recorded["deck_y"] = world.grid.cell_surface_world(GRAVE_B).y
		return

	var rise_ticks: int = int(SimConfig.ZOMBIE_RISE_SECONDS * 60.0)
	if phase_frame > 3 and phase_frame < rise_ticks:
		for zombie in world._zombies:
			if not is_instance_valid(zombie):
				continue
			if zombie.state != ZombieBody.State.RISE:
				check(false, "the rise ended early at frame %d of %d" % [phase_frame, rise_ticks])
				_advance(2)
				return
			if zombie.is_dangerous():
				check(false, "a RISING zombie is dangerous at frame %d -- the telegraph is a lie"
					% phase_frame)
				_advance(2)
				return
		if victim.health != SimConfig.MAX_HEALTH:
			check(false, "a rising pack took health at frame %d" % phase_frame)
			_advance(2)
			return
		return

	if phase_frame == rise_ticks + 4:
		check(victim.health == SimConfig.MAX_HEALTH,
			"nothing in the pack can touch you for the whole telegraph")
		var walking := 0
		for zombie in world._zombies:
			if is_instance_valid(zombie) and zombie.state == ZombieBody.State.WALK:
				walking += 1
		# THE OTHER HALF: a telegraph that never ends is a pack that never arrives,
		# and every assertion above would be just as happy with one.
		check(walking > 0, "and then the whole pack comes for you -- %d of %d walking"
			% [walking, recorded.get("risers", 0)])

		# AND THEY ARE STANDING ON THE DECK, checked HERE rather than during the
		# rise -- which is where the first version of this put it, and it was an
		# assertion that could not fail. Mid-rise the whole pack is legitimately
		# BELOW the deck (that is what it is rising out of), so any tolerance loose
		# enough to allow the rise is loose enough to allow a body that fell
		# through the world.
		#
		# This is the observable half of the no-two-in-one-place claim. Coincident
		# bodies do not look coincident from the deck; they look like a pack that
		# rose and vanished, because the solver drives them DOWN through the floor.
		var lowest := INF
		for zombie in world._zombies:
			if is_instance_valid(zombie):
				lowest = minf(lowest, zombie.position.y)
		check(lowest > float(recorded["deck_y"]) + 0.3,
			"standing ON the deck, not through it -- lowest body centre %.2f, deck %.2f"
				% [lowest, recorded["deck_y"]])
		_advance(2)

# --- 4. Contact costs a hit point, and the zombie survives it -----------------
#
# THE ONE PLACE IT DIFFERS FROM A RUSHER, and the difference is what makes a group
# work. A rusher expends itself on contact so that ONE of them cannot chain-tumble
# somebody already out of control; with five that rule protects nobody -- the pack
# would land five hits and delete itself in a second.

func _phase_contact_costs_and_survives() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(6, 12))
		_place_zombie(victim.position + Vector3(1.0, 0.0, 0.0))
		return
	if phase_frame == 12:
		eq(victim.health, SimConfig.MAX_HEALTH - SimConfig.ZOMBIE_DAMAGE,
			"a zombie that reaches you costs a hit point")
		eq(world.zombie_count(), 1, "and is NOT spent by the hit, unlike a rusher")
		var zombie: Node = world._zombies[0] if world.zombie_count() > 0 else null
		if is_instance_valid(zombie):
			eq(zombie.state, ZombieBody.State.RECOVER, "it is knocked back off you instead")
			check(not zombie.is_dangerous(),
				"and cannot bite again while it recovers -- otherwise the beat is not a beat")
		_advance(3)

# --- 5. The tumble is a chance ------------------------------------------------
#
# BOTH OUTCOMES, over enough contacts to mean it. A single sampled contact tells
# you a branch exists, which is not the claim -- and the failure this exists to
# catch is the silent one, where the roll is computed and the answer is always the
# same because a comparison went the wrong way or the constant reached nothing.
#
# It runs through the REAL contact resolver, never a hand-built Hit. CLAUDE.md's
# shield note is the reason: that bug was entirely in the caller which built the
# real one, and its test was green for the whole life of it because it constructed
# its own.

func _phase_the_tumble_is_a_chance() -> void:
	if phase_frame == 1:
		_isolate()
		tumbles = 0
		bites = 0
		return
	if tumbles + bites >= CONTACT_SAMPLES:
		var total: int = tumbles + bites
		var share: float = float(tumbles) / float(total)
		check(tumbles > 0, "some contacts tumble you (%d of %d)" % [tumbles, total])
		check(bites > 0, "and some are only a bite (%d of %d)" % [bites, total])
		# A WIDE BAND on purpose. The claim is "it is a chance near
		# ZOMBIE_TUMBLE_CHANCE", not "this hash is uniform at n=35" -- at 35 samples
		# a 0.35 process has a standard deviation of 8 percentage points, so this
		# is about three sigma either way and cannot flake. It still fails against a
		# constant, a reversed comparison, or a rate that has drifted to a rusher's.
		check(share > 0.1 and share < 0.7,
			"and the rate is near ZOMBIE_TUMBLE_CHANCE (%.2f) -- measured %.2f"
				% [SimConfig.ZOMBIE_TUMBLE_CHANCE, share])
		_advance(4)
		return

	# One contact per three frames: arm, let the world resolve it, read the outcome.
	match phase_frame % 3:
		1:
			_isolate()
			_park(Vector2i(6, 12))
			_place_zombie(victim.position + Vector3(1.0, 0.0, 0.0))
		0:
			if victim.health < SimConfig.MAX_HEALTH:
				if victim.state == PlayerBody.State.TUMBLE:
					tumbles += 1
				else:
					bites += 1

# --- 6. A dashing player deflects it ------------------------------------------

func _phase_dash_deflects() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(6, 12))
		return
	if phase_frame == 6:
		# Two cells up-bridge (grid +z is world -z), which is the way a move of
		# (0, -1) dashes -- so the player runs straight into it.
		var zombie: Node = _place_zombie(
			world.grid.cell_surface_world(Vector2i(6, 14)) \
				+ Vector3(0.0, SimConfig.ZOMBIE_HEIGHT * 0.5, 0.0))
		recorded["id"] = zombie.zombie_id
		recorded["zombie_z"] = zombie.position.z
		recorded["move"] = Vector2(0.0, -1.0)
		recorded["actions"] = SimConfig.ACTION_SHOVE
		return
	if phase_frame == 7:
		recorded["actions"] = 0             # a press is one tick wide
		return
	# LET GO once the dash has carried the player through. Holding a movement input
	# for two seconds walks the body off the end of the deck into a LEDGE_HANG,
	# which is CLAUDE.md's "measure on a fixture with nothing else moving in it" in
	# its most literal form -- the rig itself becomes the thing that fails.
	if phase_frame == 40:
		recorded["move"] = Vector2.ZERO
		return
	if phase_frame == 20:
		var zombie: Node = world._zombie_by_id(int(recorded.get("id", 0)))
		check(is_instance_valid(zombie) and world.zombie_count() == 1,
			"a dash does NOT kill a zombie -- that is the weapons' job")
		if is_instance_valid(zombie):
			eq(zombie.state, ZombieBody.State.STAGGER, "it is staggered")
			check(zombie.position.z < float(recorded["zombie_z"]) - 0.3,
				"and knocked back along the dash axis (%.2f -> %.2f)"
					% [recorded["zombie_z"], zombie.position.z])
		eq(victim.health, SimConfig.MAX_HEALTH, "and the dashing player takes nothing")
		check(victim.state != PlayerBody.State.TUMBLE, "and is not tumbled")
		return

	# THE STAGGER HAS TO OUTLAST THE DASH, or the counter is one that loses -- the
	# exact bug the rusher shipped and CLAUDE.md records in full. Checked on EVERY
	# tick until the zombie gets up, and the window is read off the ZOMBIE rather
	# than counted in frames, because a dash re-deflects on each of its six ticks
	# and every one resets the clock.
	if phase_frame > 20:
		var zombie: Node = world._zombie_by_id(int(recorded.get("id", 0)))
		var still: bool = is_instance_valid(zombie) \
			and int(zombie.state) == ZombieBody.State.STAGGER
		if victim.state == PlayerBody.State.TUMBLE:
			check(false, "a deflected zombie tumbled the player who deflected it, %d frames in"
				% [phase_frame - 20])
			_advance(5)
			return
		if still and phase_frame < 400:
			return
		eq(victim.health, SimConfig.MAX_HEALTH,
			"and costs no health for the whole stagger it bought")
		_advance(5)

# --- 7. It rots, so a weaponless player is never stranded ---------------------

func _phase_it_rots() -> void:
	if phase_frame == 1:
		_isolate()
		# Out of reach: this measures the LIFETIME, not how long it took to walk
		# somewhere. It must expire on its own clock with nobody to chase.
		_park(Vector2i(18, 22))
		var zombie: Node = _place_zombie(
			world.grid.cell_surface_world(Vector2i(6, 12)) \
				+ Vector3(0.0, SimConfig.ZOMBIE_HEIGHT * 0.5, 0.0))
		# Aged to just short of the limit, so the phase costs a fraction of a second
		# rather than twenty-two of them. It is the same clock either way.
		zombie.age = SimConfig.ZOMBIE_LIFETIME - 0.5
		return
	if phase_frame == 10:
		eq(world.zombie_count(), 1, "still there just before its time is up")
		return
	if phase_frame == 60:
		eq(world.zombie_count(), 0, "a zombie nobody could fight rots away on its own")
		_advance(6)

# --- 8. A blast empties a grave before it opens -------------------------------
#
# The same rule a mound has, and it is worth MORE here: pre-empting a rusher saves
# you one enemy, pre-empting a grave saves you three to five. That makes a charge
# spent on a slab you can see the best trade in the game, and it is assembled
# entirely out of parts that already existed.

func _phase_a_blast_pre_empts() -> void:
	if phase_frame == 1:
		_isolate()
		_park(Vector2i(18, 22))
		recorded["graves"] = world.grid.grave_count()
		check(int(recorded["graves"]) > 0, "there is a grave left to pre-empt")
		return
	if phase_frame == 4:
		# A ROUND FIRST, and it must do nothing. A grave is flush with the deck --
		# there is nothing above ground for a bullet to hit -- and that asymmetry is
		# the whole reason a blast is worth spending here. Without this half, "a
		# blast empties it" passes against a grave that anything at all destroys.
		world.blast_at(world.grid.grave_surface_world(GRAVE_C), 4.0, Hit.Kind.BULLET, 1)
		eq(world.grid.grave_count(), int(recorded["graves"]),
			"a bullet does nothing to a grave -- there is nothing above ground to hit")
		return
	if phase_frame == 8:
		world.blast_at(world.grid.grave_surface_world(GRAVE_C), 4.0, Hit.Kind.EXPLOSIVE, 1)
		eq(world.grid.grave_count(), int(recorded["graves"]) - 1,
			"but a blast reaches down and empties it")
		eq(world.zombie_count(), 0, "and nothing rises from a grave that is already gone")
		finish()

# --- helpers ------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	victim.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO
	victim.state = PlayerBody.State.WALK
	victim.grounded = true
	victim.health = SimConfig.MAX_HEALTH
	victim.invulnerable = 0.0
	victim.shove_cooldown = 0.0
	recorded["move"] = Vector2.ZERO
	recorded["actions"] = 0

# Clear the board. The fixture has nothing else in it by design, so this is only
# ever about zombies and graves -- but a phase that inherited the previous phase's
# pack would be measuring the wrong bodies, and CLAUDE.md's note about a sweep
# getting dirtier as it runs is exactly that failure: it tracks the sample INDEX
# rather than the sample value, which is the hardest kind to read.
func _isolate() -> void:
	for zombie in world._zombies:
		if is_instance_valid(zombie):
			zombie.queue_free()
	world._zombies.clear()

# A zombie already up and walking, for the phases that are not about the rise.
#
# THE POSITION MUST BE SET AFTER THE STATE, not before. begin_rise() parks the body
# a full ZOMBIE_HEIGHT BELOW the deck -- that is what it emerges from -- and only
# _step_rise lifts it back out. Forcing WALK straight afterwards skips the lift,
# which would leave every subject of every phase underneath the bridge, quietly
# falling. The rusher's helper carries the same warning, having learned it the
# expensive way.
func _place_zombie(at: Vector3) -> Node:
	var zombie: Node = world._spawn_zombie(at)
	zombie.state = ZombieBody.State.WALK
	zombie.state_timer = 0.0
	zombie.position = at
	zombie.velocity = Vector3.ZERO
	zombie.grounded = true
	return zombie
