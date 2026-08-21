extends "res://scripts/test_support/test_case.gd"

# COLUMNS SHIFTED BY 3 ON 2026-08-20 (M22 phase C). This test measures on
# playtest_bridge.seg, and the canvas went from 15 cells to 21 -- every
# authored file was padded with 3 columns of HOLE on each side, which leaves
# the world POSITION of every cell identical and moves its column INDEX right
# by 3. The literals below are the current file's columns; the geometry they
# point at has not moved a millimetre.

# MVP criteria B5, B5b, B6, B7, B8 — the whole failure-and-rescue loop.
#
# The claim this test exists to defend is the asymmetry in D2: **whether your
# friends can save you is decided by how you got hit, not by how fast they
# react.** Shoved along the deck and you catch the lip and are rescuable;
# launched clear of it and you simply fall. That is one rule with two outcomes,
# and it is the thing that makes standing near an edge legibly risky.
#
# Everything here runs on the world's own host tick with scripted input, so it
# exercises the code path the game uses.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "RescueWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/playtest_bridge.seg"]
	world.start(true, 1, false)

	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

	eq(a.health, SimConfig.MAX_HEALTH, "a player starts at full health")

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1

	# EVERY PHASE STARTS WITH NOBODY IN THE DRONE'S HANDS.
	#
	# Phase 4 deliberately launches a player clear of the world, which queues a
	# drone return that outlives the phase -- and A BODY THE DRONE HAS IS NOT
	# STEPPED, so the next phase repositions it and then watches it do nothing at
	# all. Three failures between them and not one named what it was about:
	# "catches the lip too", "hanging before the release is tested", and "the mesh
	# never span".
	#
	# It has to be HERE and not in _advance. The world ticks once between the end
	# of one phase and the setup of the next, sees a body still under the kill
	# plane, and queues it straight back up -- so the clear has to sit immediately
	# before the setup that moves it.
	if phase_frame == 1:
		world._returning.clear()

	match phase:
		0: _phase_damage_and_grace()
		1: _phase_downed_and_revive()
		2: _phase_ledge_catch()
		3: _phase_launched_clear()
		4: _phase_own_fall_catches()
		5: _phase_release_actually_falls()
		6: _phase_drone_return()

func _advance(next_phase: int) -> void:
	phase = next_phase
	phase_frame = 0

func _park(body: CharacterBody3D, cell: Vector2i, lift: float = 1.0) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, lift, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true

# --- 1. Damage, and the grace window that stops one tumble emptying the bar ----

func _phase_damage_and_grace() -> void:
	if phase_frame != 1:
		return
	_park(a, Vector2i(10, 1))

	# SILENCE IS A STATE. A player at full health shows nothing at all -- four
	# permanent bars on a 60 m bridge are furniture, and furniture is not read, so
	# a bar appearing has to mean somebody needs something.
	a.sync_downed_timer(0.0)
	var bar := a.get_node_or_null("StatusBar") as Node3D
	if check(bar != null, "a player carries a status bar"):
		check(not bar.visible, "which a HEALTHY player does not show at all")

	check(a.take_damage(1), "a hit lands")
	eq(a.health, SimConfig.MAX_HEALTH - 1, "and costs a hit point")

	# Injured: it appears, green over red, and reads the health rather than a
	# countdown.
	a.sync_downed_timer(0.0)
	if bar != null:
		check(bar.visible, "an INJURED player shows one")
		near(a.health_fraction(), 0.8, 0.001, "filled to the health that is left")
		eq(_fill_colour(a), PlayerBody.BAR_HEALTH_FILL, "green for health you still have")
		eq(_back_colour(a), PlayerBody.BAR_HEALTH_BACK, "over red for health you lost")

	check(not a.take_damage(1), "a second hit inside the grace window is refused")
	eq(a.health, SimConfig.MAX_HEALTH - 1, "so the bar does not drain in one go")

	# ONE PLAYER'S BAR MUST NOT FOLLOW ANOTHER'S. Free now that the halves are
	# ColorRect nodes -- each avatar owns its own -- but it was not free when they
	# were meshes sharing .tscn sub-resource materials, and the symptom then was
	# bars looking wrong at random rather than obviously shared. Kept because the
	# guarantee is what matters, not how it is currently obtained.
	b.health = SimConfig.MAX_HEALTH
	b.state = PlayerBody.State.LEDGE_HANG
	b.state_timer = 0.0
	b.sync_downed_timer(0.0)
	eq(_fill_colour(a), PlayerBody.BAR_HEALTH_FILL,
		"and one player's bar colour does not follow another's")
	eq(_fill_colour(b), PlayerBody.BAR_RESCUE_FILL, "each body owning its own")

	# --- BEING HELPED IS ITS OWN COLOUR, and it outranks the countdown ---------
	#
	# Red is a clock running out; blue is a hold filling up. Once somebody is
	# crouched over you, the countdown stops being what a third player needs to
	# read -- what they need is whether to come as well or go and deal with the
	# rusher. So the moment progress exists, the bar changes meaning.
	b.rescue_progress = SimConfig.LEDGE_HAUL_SECONDS * 0.5
	b.sync_downed_timer(0.0)
	eq(_fill_colour(b), PlayerBody.BAR_HAUL_FILL,
		"a hanging player being hauled shows BLUE, not the red countdown")
	eq(_back_colour(b), PlayerBody.BAR_HAUL_BACK, "on black")
	near(_fill_rect(b).size.x / PlayerBody.BAR_PIXELS.x, 0.5, 0.02,
		"and the width is how much of the HOLD is done, not how much time is left")

	# THE CASE THAT WOULD MAKE IT FLICKER. GameWorld._tick_revive resets progress
	# to zero the instant the helper steps outside REVIVE_RADIUS -- deliberately,
	# so wandering off and back cannot bank credit. If zero counted as "being
	# helped", an empty blue bar would appear and vanish every time somebody walked
	# past a downed friend.
	b.rescue_progress = 0.0
	b.sync_downed_timer(0.0)
	eq(_fill_colour(b), PlayerBody.BAR_RESCUE_FILL,
		"and it goes back to the red countdown the moment the helper leaves")

	# --- THE COUNTDOWN FLASHES, AND THE HAUL DOES NOT --------------------------
	#
	# Added 2026-08-15 with the marker change, and the two are one signal: a player
	# who needs help is red-to-white on crisis_flash's clock BOTH on the arrow at
	# the edge of the screen and on the bar over their head, so following the arrow
	# leads to the marking you were already following.
	#
	# EVERY sync_downed_timer CALL IN THIS FILE PASSES A PHASE for this reason. A
	# colour that alternates twice a second, asserted against the clock, is a coin
	# toss -- it would pass locally and fail in the gate about half the time, and a
	# flaky gate is a gate nobody reads.
	b.sync_downed_timer(CrisisFlash.PERIOD * 0.75)
	eq(_fill_colour(b), Color(1.0, 1.0, 1.0, PlayerBody.BAR_RESCUE_FILL.a),
		"a player waiting for help FLASHES WHITE on the other half of the cycle")
	b.sync_downed_timer(CrisisFlash.PERIOD * 1.1)
	eq(_fill_colour(b), PlayerBody.BAR_RESCUE_FILL, "and back to red on the next")

	# THE HAUL IS STEADY. Movement means "come here"; help is already there, and a
	# second thing demanding attention would pull a third player toward a problem
	# that is being solved. Asserted across the cycle, because "it did not flash"
	# is only meaningful if the sample would have caught one.
	b.rescue_progress = SimConfig.LEDGE_HAUL_SECONDS * 0.5
	for step in 4:
		b.sync_downed_timer(CrisisFlash.PERIOD * float(step) * 0.3)
		eq(_fill_colour(b), PlayerBody.BAR_HAUL_FILL,
			"while a haul in progress stays a steady blue all the way round")
	b.rescue_progress = 0.0

	b.rescue_progress = 0.0
	b.state = PlayerBody.State.WALK

	_advance(1)

func _fill_rect(body: CharacterBody3D) -> ColorRect:
	return body.get_node_or_null("StatusBar/SubViewport/Fill") as ColorRect

func _fill_colour(body: CharacterBody3D) -> Color:
	return _fill_rect(body).color

func _back_colour(body: CharacterBody3D) -> Color:
	return (body.get_node_or_null("StatusBar/SubViewport/Back") as ColorRect).color

# --- 2. Zero health downs you where you fell; a teammate revives you -----------

func _phase_downed_and_revive() -> void:
	if phase_frame == 1:
		_park(a, Vector2i(10, 1))
		# Park the helper out of range to start, so revive cannot begin by
		# accident and the "reset when they wander off" rule is exercised.
		_park(b, Vector2i(16, 1))
		a.health = 1
		a.invulnerable = 0.0
		check(a.take_damage(1), "the last hit point can be taken")
		eq(a.state, PlayerBody.State.DOWNED, "zero health puts the player DOWNED")
		recorded["down_at"] = a.position

		# THE RESCUE BAR OVER THEIR HEAD. In the world and not on the HUD because
		# both rescues are performed by standing next to someone: what a rescuer
		# needs is attached to the body they have to reach.
		a.sync_downed_timer(0.0)
		var bar := a.get_node_or_null("StatusBar") as Node3D
		if check(bar != null, "a player carries a status bar"):
			check(bar.visible, "which appears the moment they go down")
			near(a.rescue_fraction(), 1.0, 0.05, "starting full")
			recorded["first_fill"] = a.rescue_fraction()

			# AND SWITCHES WHAT IT MEANS. Down is not a worse injury, it is a
			# different question -- "how long have I got" rather than "how hurt am
			# I" -- so the colours change with it and cannot be confused at a
			# glance from across the bridge.
			eq(_fill_colour(a), PlayerBody.BAR_RESCUE_FILL, "now red for the time left")
			eq(_back_colour(a), PlayerBody.BAR_RESCUE_BACK, "over black for the time gone")

			# A SANITY BAND, NOT A LEGIBILITY CLAIM, and the difference matters.
			# An earlier version of this required the readout to be at least half a
			# player tall, on the theory that anything smaller was unreadable at
			# camera distance. That theory was never confirmed and playtest landed
			# well under it -- a guess wearing the clothes of a measurement. What
			# survives guards only the failures actually OBSERVED: shrinking to
			# nothing, and growing bigger than the player it belongs to.
			var sprite := bar as Sprite3D
			var width: float = PlayerBody.BAR_PIXELS.x * sprite.pixel_size
			check(width > 0.25, "of a real width (%.2f m)" % width)
			check(width <= PlayerBody.HALF_HEIGHT * 2.0,
				"and no larger than the player (%.2f m vs %.2f m)"
					% [width, PlayerBody.HALF_HEIGHT * 2.0])
			check(bar.position.y > PlayerBody.HALF_HEIGHT,
				"and sitting above the head rather than through the body")

			# THE FILL'S WIDTH IS THE VALUE, in viewport pixels.
			#
			# It was two 3D quads before, and that could not be asserted usefully:
			# no_depth_test puts a material in the alpha pass whatever its alpha,
			# that pass sorts by DISTANCE using each object's origin, and the
			# fill's origin slid sideways as it drained -- so partway down it went
			# behind the back quad and the back painted over it. Solid black for
			# the rest of the hang with the fraction perfectly correct underneath.
			#
			# Composed in a SubViewport, overlap is tree order and nothing else.
			# There is no sort to lose, so the width IS what is drawn.
			var fill_rect := _fill_rect(a)
			if check(fill_rect != null, "with a fill to read"):
				near(fill_rect.size.x, PlayerBody.BAR_PIXELS.x, 1.0,
					"full at the moment they go down (%.0f of %.0f px)"
						% [fill_rect.size.x, PlayerBody.BAR_PIXELS.x])

			# And the viewport only renders while the bar is up -- four healthy
			# players must not be four render targets redrawn every frame.
			var vp := bar.get_node_or_null("SubViewport") as SubViewport
			if check(vp != null, "drawn through a SubViewport"):
				eq(vp.render_target_update_mode, SubViewport.UPDATE_ALWAYS,
					"which is live while somebody needs help")
			check(sprite.no_depth_test, "and ignores depth, so a parapet cannot hide it")
		return

	if phase_frame == 30:
		eq(a.position, recorded["down_at"], "downed where they fell, not moved")
		check(not a.take_damage(1), "a downed player takes no further damage")
		eq(a.rescue_progress, 0.0, "and nobody is reviving them yet")
		# Bring the helper alongside.
		b.position = a.position + Vector3(1.5, 0.0, 0.0)
		return

	# Sampled every frame they are down, so the drain is read from the last moment
	# it was meaningful. Reading it after the revive would only ever see -1.
	if a.state == PlayerBody.State.DOWNED:
		recorded["last_fill"] = a.rescue_fraction()

	if phase_frame > 30 and a.state == PlayerBody.State.WALK:
		check(phase_frame < 30 + int(SimConfig.REVIVE_SECONDS * 60.0) + 20,
			"a teammate standing with them revives them, and promptly")
		eq(a.health, SimConfig.REVIVE_HEALTH, "revived at minimum health")

		var bar := a.get_node_or_null("StatusBar") as Node3D
		if bar != null:
			# It really DRAINED rather than sitting at its first value. A frozen
			# bar is the failure mode a single reading cannot see, and it is
			# exactly what a bar driven from step() would do over a remote player
			# -- which is why this one is driven from _process.
			check(float(recorded["last_fill"]) < float(recorded["first_fill"]),
				"the bar drained while they were out (%.2f -> %.2f)"
					% [recorded["first_fill"], recorded["last_fill"]])

			# BACK UP IS NOT THE SAME AS WELL. A revive returns you on
			# REVIVE_HEALTH, so the bar does not vanish -- it switches question,
			# from "how long have I got" to "how hurt am I", and the colours say
			# which one it is answering.
			a.sync_downed_timer(0.0)
			check(bar.visible, "and stays up, because a revive returns you hurt")
			eq(_fill_colour(a), PlayerBody.BAR_HEALTH_FILL,
				"having switched back to green-over-red health")
			near(a.health_fraction(),
				float(SimConfig.REVIVE_HEALTH) / float(SimConfig.MAX_HEALTH), 0.001,
				"reading the health they were revived on")

			# Only a player at FULL health shows nothing.
			a.health = SimConfig.MAX_HEALTH
			a.sync_downed_timer(0.0)
			check(not bar.visible, "and goes away entirely once they are patched up")
		_advance(2)
		return

	if phase_frame > 200:
		fail("a teammate stood alongside a downed player and never revived them")
		_advance(2)

# --- 3. Shoved along the deck: you catch the lip ------------------------------

func _phase_ledge_catch() -> void:
	if phase_frame == 1:
		# Toppling into the authored gap at z 2-3 (x 5-7), close to its lip --
		# the "shoved along the deck" case, where a rescue is meant to be
		# possible. Dropped INTO the gap rather than nudged toward it: a tumble
		# recovers as soon as it is slow and grounded, so a gentle push just
		# stands back up before it ever reaches the edge.
		a.position = world.grid.cell_surface_world(Vector2i(9, 2)) + Vector3(0.0, 0.5, 0.0)
		a.health = SimConfig.MAX_HEALTH
		a.begin_tumble(Vector3(0.0, 0.0, -1.0))
		# The helper goes well clear, so the hang is genuinely unassisted first.
		_park(b, Vector2i(16, 8))
		return
	if phase_frame == 90:
		eq(a.state, PlayerBody.State.LEDGE_HANG,
			"a player who topples into a gap catches the lip automatically")
		check(a.position.y > SimConfig.FALL_KILL_Y, "and is still in the world")
		recorded["hang_y"] = a.position.y
		return
	if phase_frame == 120:
		# THE COUNTER IS ON A HANGING PLAYER TOO. It covered only DOWNED at first,
		# which made it a feature almost nobody would see: going down takes five
		# separate hits and falling deals no damage, so in a real playtest you hang
		# or you fall. This is the reachable half, and it went three builds without
		# anyone being able to confirm the counter existed.
		a.sync_downed_timer(0.0)
		var hang_bar := a.get_node_or_null("StatusBar") as Node3D
		if check(hang_bar != null, "a hanging player carries a bar as well"):
			check(hang_bar.visible, "and it is showing while they hang")
			var fill: float = a.rescue_fraction()
			check(fill > 0.0 and fill <= 1.0, "with a real fill (%.2f)" % fill)

			# AGAINST THE HANG CLOCK, NOT THE BLEED-OUT ONE. Two seconds into an
			# 8 s hang the bar should read about 3/4 full; measured against the
			# 15 s downed clock it would read about 7/8, and a bar that drains at
			# the wrong rate is wrong in a way "is it visible" never catches.
			var expected: float = 1.0 - (a.state_timer / SimConfig.LEDGE_HANG_SECONDS)
			near(fill, expected, 0.05,
				"draining on the HANG clock (%.2f, expected %.2f)" % [fill, expected])
		return
	if phase_frame == 150:
		# ALONE, THERE IS NO WAY OUT. Not a missing button -- the entire point of
		# the state. If this ever starts passing on its own, the co-op gate has
		# quietly opened.
		eq(a.state, PlayerBody.State.LEDGE_HANG, "and cannot get out on their own")
		near(a.position.y, float(recorded["hang_y"]), 0.05, "hanging where they caught")
		eq(a.rescue_progress, 0.0, "with nobody helping")
		# Bring a teammate to the lip.
		_park(b, Vector2i(9, 1))
		return
	if phase_frame > 150 and a.state == PlayerBody.State.WALK:
		check(phase_frame < 150 + int(SimConfig.LEDGE_HAUL_SECONDS * 60.0) + 20,
			"a teammate at the lip hauls them up, and promptly")
		check(a.grounded, "putting them back on the deck in control")
		_advance(3)
		return
	if phase_frame > 400:
		fail("a teammate stood at the lip and never hauled the hanging player up")
		_advance(3)

# --- 4. Launched clear of the deck: no rescue, and that is intended -----------

# Deliberately the SAME lip, from the SAME spot, at a different speed -- so the
# only thing that can explain the different outcome is the speed. An earlier
# version launched the player right across the bridge and checked 2.5 s later; it
# failed, correctly, because the body had bounced, slowed, and caught a lip
# somewhere else entirely. That is the right behaviour and the wrong test.
func _phase_launched_clear() -> void:
	if phase_frame == 1:
		a.position = world.grid.cell_surface_world(Vector2i(9, 2)) + Vector3(0.0, 0.5, 0.0)
		a.begin_tumble(Vector3(0.0, -2.0, -SimConfig.LEDGE_CATCH_MAX_SPEED * 1.6))
		recorded["caught_fast"] = false
		return
	if phase_frame <= 24:
		if a.state == PlayerBody.State.LEDGE_HANG:
			recorded["caught_fast"] = true
		return
	if phase_frame == 25:
		check(not bool(recorded["caught_fast"]),
			"a player arriving at a lip too fast catches nothing -- launched clear is launched clear")
		_advance(4)

# --- 4b. A fall you caused YOURSELF catches the same lip ----------------------
#
# Reported from playtest: "when you dash across a gap but fall short you don't
# seem to be able to grab -- is grabbing specific to kicks?" It was. The catch
# lived inside _step_tumble, so it was reachable only by being kicked, shot or
# rushed; your own dash ends in WALK, and WALK never asked.
#
# Same lip, same spot, same slow arrival as phase 3 -- the ONLY difference is
# that nothing put the player there. If the outcome differs, the rule is keyed on
# invisible state rather than on the fall, which is what D2 says it is not.
func _phase_own_fall_catches() -> void:
	if phase_frame == 1:
		_park(b, Vector2i(16, 8))
		# Airborne over the authored gap, in WALK. This is the shape a dash that
		# fell short leaves you in: end_shove zeroes the horizontal velocity and
		# hands you back to WALK, dropping.
		a.position = world.grid.cell_surface_world(Vector2i(9, 2)) + Vector3(0.0, 0.5, 0.0)
		a.velocity = Vector3(0.0, -1.0, -1.0)
		a.state = PlayerBody.State.WALK
		a.grounded = false
		a.health = SimConfig.MAX_HEALTH
		recorded["ever_tumbled"] = false
		return
	if phase_frame < 60:
		if a.state == PlayerBody.State.TUMBLE:
			recorded["ever_tumbled"] = true
		return
	if phase_frame == 60:
		eq(a.state, PlayerBody.State.LEDGE_HANG,
			"a player who falls under their OWN steam catches the lip too")
		# And got there directly. Without this the phase would also pass if
		# something had quietly tumbled the player first, which would leave the
		# original bug in place and the test green over it.
		check(not bool(recorded["ever_tumbled"]),
			"having never been tumbled -- the grab is not kick-only")
		_advance(5)

# --- 4c. Letting go means FALLING, not grabbing the same lip again ------------
#
# Playtest: "when the hang counter expires it just starts over again -- they never
# fall." release_ledge drops the body 0.9 m under the lip, and LEDGE_CATCH_REACH
# is 1.4 m, so the next tick re-caught the lip it had just let go of and the
# countdown restarted. Forever.
#
# It had never been exercised: the only other test of the hang brings a teammate
# at frame 150 and the timer does not expire until frame 480, so the release path
# had no coverage at all. This is the whole reason the hang is not a soft landing.
func _phase_release_actually_falls() -> void:
	if phase_frame == 1:
		_park(b, Vector2i(16, 8))
		a.position = world.grid.cell_surface_world(Vector2i(9, 2)) + Vector3(0.0, 0.5, 0.0)
		a.health = SimConfig.MAX_HEALTH
		a.state = PlayerBody.State.WALK
		a.grounded = false
		a.velocity = Vector3(0.0, -1.0, -1.0)
		return
	if phase_frame == 30:
		if not check(a.state == PlayerBody.State.LEDGE_HANG,
				"the player is hanging before the release is tested"):
			finish()
			return
		recorded["hang_y"] = a.position.y
		# Skip to the end of the 8 s timer rather than waiting it out -- the
		# release is what is under test, not the countdown, and the countdown is
		# already asserted in phase 3.
		a.state_timer = SimConfig.LEDGE_HANG_SECONDS
		return
	if phase_frame == 90:
		# A full second later. Under the bug the state is LEDGE_HANG again with a
		# freshly reset timer, and the body has not moved at all.
		check(a.state != PlayerBody.State.LEDGE_HANG,
			"a player whose hang timer runs out lets go -- and does not re-grab")
		check(a.position.y < float(recorded["hang_y"]) - 2.0,
			"they are genuinely falling (%.2f m below where they hung)"
				% (float(recorded["hang_y"]) - a.position.y))
		_advance(6)

# --- 5. Falling is a setback: the drone brings you back next to a friend ------

func _phase_drone_return() -> void:
	if phase_frame == 1:
		# CLEAN SLATE FIRST. The phase above deliberately leaves a player falling,
		# and a fall that reaches the kill plane queues a drone return -- which
		# then fires three seconds into THIS phase and overwrites everything it
		# set up. Cost two confusing failures ("the mesh never span", "returned
		# them hanging") that were both this leftover and neither about the drone.
		world._returning.clear()
		a.visible = true
		a.ledge_cooldown = 0.0

		_park(b, Vector2i(10, 12))
		# A REAL tumble first, not a state assignment: the mesh spin has to be
		# produced by the game's own mechanism for the "comes back upright"
		# assertion below to mean anything.
		_park(a, Vector2i(10, 14))
		a.begin_tumble(Vector3(9.0, 3.0, 0.0))
		return
	if phase_frame == 20:
		# VALIDATE THE INSTRUMENT BEFORE TRUSTING IT. If the mesh never tilted in
		# the first place, "upright at the end" passes no matter what the respawn
		# does, and this whole phase would be measuring nothing.
		recorded["tilt"] = _mesh_tilt(a)
		check(float(recorded["tilt"]) > 0.2,
			"a tumbling player's mesh pinwheels (%.2f rad off vertical)" % recorded["tilt"])
		a.position = Vector3(0.0, SimConfig.FALL_KILL_Y - 5.0, -20.0)
		return
	if phase_frame == 40:
		check(world._returning.has(1), "a player who falls out of the world is picked up")
		recorded["taken_at"] = a.position
		return

	# A BODY THE DRONE HAS IS NOT SIMULATED, and it used to be.
	#
	# The step loop had no _returning check and there is no terminal velocity
	# anywhere, so an invisible out-of-play body kept falling for the full three
	# seconds. Measured 2026-08-13: y = -124 m at 67 m/s and still accelerating,
	# with THE CAMERA GLUED TO IT the whole way -- which is what a player sees as
	# the world lurching away underneath them when they go over the edge.
	if phase_frame > 60 and world._returning.has(1):
		var drift: float = a.position.distance_to(recorded["taken_at"])
		if drift > 0.01 or a.velocity.length() > 0.01:
			check(false, "a body the drone has holds still (drifted %.2f m, speed %.1f)"
				% [drift, a.velocity.length()])
			recorded["taken_at"] = a.position    # report once, not sixty times
		# AND THE CAMERA LETS GO. One still framing a body under the bridge dives
		# below the deck and stares at nothing for three seconds.
		if world.camera != null and not world.camera.focus_held:
			check(false, "and the camera stops following them while they are gone")
	if phase_frame == int(SimConfig.DRONE_RETURN_SECONDS * 60.0) + 40:
		check(not world._returning.has(1), "and the drone finishes the job")
		check(a.state == PlayerBody.State.WALK,
			"returning them in control (state %d at cell %s, %s, teammate at cell %s)" % [
				a.state, world.grid.cell_of_world(a.position),
				"grounded" if a.grounded else "airborne",
				world.grid.cell_of_world(b.position)])
		check(a.position.distance_to(b.position) < 6.0,
			"dropped next to a teammate (%.1f m away), not alone behind the party"
				% a.position.distance_to(b.position))
		# ON SOLID DECK. "Next to a teammate" is not enough on a bridge full of
		# holes: the drop used to be a blind 1.6 m sideways, which beside someone
		# standing at a lip is the gap itself. Caught only because the ledge grab
		# started working -- before that, a player dropped into a hole was falling
		# in WALK and still counted as "returned in control".
		var landed: Vector2i = world.grid.cell_of_world(a.position)
		check(world.grid.is_solid(landed),
			"and onto SOLID DECK (cell %s), not into the hole beside them" % landed)
		check(a.health >= SimConfig.REVIVE_HEALTH, "and able to carry on")

		# Reported from playtest: "if you get knocked off into space, when you
		# respawn you might be rotated." The mesh angle was an accumulator that
		# only the normal exits from TUMBLE cleared, and the drone return is not
		# one of them -- it sets WALK from GameWorld directly -- so a player came
		# back leaning for the rest of the run. It is now derived from state.
		check(_mesh_tilt(a) < 0.01,
			"and STANDING UP straight, not still leaning from the tumble (%.3f rad)"
				% _mesh_tilt(a))

		# The other two things a hand-written respawn list kept forgetting.
		eq(a.rescue_progress, 0.0, "with no rescue credit banked from before the fall")
		eq(a.shove_cooldown, 0.0, "and a dash ready, so the first press after a respawn works")
		finish()

# How far the mesh's own up-axis has fallen away from vertical. Reads the thing a
# player actually sees, rather than an euler triple that wraps.
func _mesh_tilt(body: CharacterBody3D) -> float:
	var mesh := body.get_node_or_null("Mesh") as Node3D
	if mesh == null:
		return 0.0
	return mesh.transform.basis.y.angle_to(Vector3.UP)
