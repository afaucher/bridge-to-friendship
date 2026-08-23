extends "res://scripts/test_support/test_case.gd"

# The first audio in the game, and the first thing in the gate that touches an
# AudioStreamPlayer at all.
#
# THIS TEST EXISTS BECAUSE THE FEATURE IS INVISIBLE TO EVERY OTHER ONE. `_play_shot`
# is gated on `view_active`, which is FALSE in every headless world -- so the whole
# rig would ship having never been executed once, and CLAUDE.md has that scar
# already: headless builds the Control tree and just does not draw it, GDScript
# resolves properties at runtime, and `ProgressBar.tint_progress` was a Godot 3
# name that raised on the first frame and nowhere earlier. `unit_size` and
# `max_distance` are exactly the same kind of bet.
#
# The claims:
#   1. BOTH STREAMS ARE REAL, and they are DIFFERENT. sound.md's argument for the
#      split: on a bridge whose camera frames 60 m, half of it behind you,
#      "somebody is shooting" and "somebody is shooting AT ME" have to be
#      different sounds or the channel carries nothing. A player's report and an
#      enemy's being the same file would satisfy every other claim here.
#   2. SPAWNING ONE RUNS EVERY LINE OF `ShotSound.spawn`, so a property that does
#      not exist on this engine version fails here rather than in someone's hands.
#   3. THE PITCH WOBBLE STAYS IN BAND, and -- the part that matters -- it does NOT
#      draw from the global RNG. A presentation path that consumed the seeded
#      stream would shift every sim-affecting roll after it, which is precisely
#      how two assertions in test_gunners came to be passing on luck.
#   4. `view_active` GATES IT BOTH WAYS. A world nobody is looking at makes no
#      sound, and a world somebody is looking at does.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const ShotSound = preload("res://scripts/ui/shot_sound.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "SoundWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)

func _physics_process(_delta: float) -> void:
	if world.tick == 0:
		return
	set_physics_process(false)

	# --- 1. Both streams -------------------------------------------------------
	var mine: AudioStream = ShotSound.PLAYER_STREAM
	var theirs: AudioStream = ShotSound.ENEMY_STREAM
	check(mine != null and theirs != null, "both shot streams loaded")
	if mine == null or theirs == null:
		finish()
		return
	print("[sound] player %.3f s, enemy %.3f s" % [mine.get_length(), theirs.get_length()])
	for stream in [mine, theirs]:
		var seconds: float = stream.get_length()
		check(seconds > 0.01 and seconds < 1.0,
			"a shot is a shot rather than a silence or a loop (%.3f s) -- this "
				% seconds
			+ "fires several times a second, so length is a gameplay property")
	check(mine != theirs,
		"and yours is not the enemy's -- one file for both would make the whole "
		+ "split inaudible while passing every other claim in this file")

	# --- 2 and 3. Spawning one -------------------------------------------------
	#
	# THE GLOBAL RNG IS SAMPLED EITHER SIDE. `main.gd` seeds it for every test, so
	# `randi()` here is a fixed sequence -- and if ShotSound ever draws from it,
	# the two draws below stop being consecutive and this fails. That is the whole
	# claim: a presentation path must not move the sim's dice.
	# The control run: one draw, then the next value the stream would give.
	seed(20260822)
	var _burn: int = randi()
	var expected_next: int = randi()

	# The same two draws with four sound spawns wedged between them.
	seed(20260822)
	var _burn2: int = randi()
	var made: Array = []
	for i in 4:
		made.append(ShotSound.spawn(world, Vector3(float(i) * 2.0, 1.0, -4.0), false))
	var after_spawns: int = randi()

	eq(after_spawns, expected_next,
		"spawning a sound does not draw from the seeded RNG -- a presentation "
		+ "path that moves the sim's dice is how a green suite starts passing "
		+ "on luck")

	var pitches: Array = []
	for node in made:
		check(node != null, "a shot sound was created")
		if node == null:
			continue
		check(node.stream == mine, "with the player's report on it")
		check(node.max_distance == ShotSound.MAX_DISTANCE,
			"and its falloff set (%.1f m)" % node.max_distance)
		check(node.unit_size == ShotSound.UNIT_SIZE, "and its unit size")
		pitches.append(node.pitch_scale)
		check(absf(node.pitch_scale - 1.0) <= ShotSound.PITCH_SPREAD + 0.001,
			"and a pitch inside the wobble (%.3f)" % node.pitch_scale)
	print("[sound] four shots at pitches %s" % [pitches])
	# NOT ALL THE SAME. A wobble that produced one value would be a wobble that is
	# not running -- the same shape as the per-enemy wake roll in test_alertness.
	var distinct := {}
	for p in pitches:
		distinct[p] = true
	check(distinct.size() > 1,
		"and they are not all the same pitch (%d distinct of %d) -- a repeated "
			% [distinct.size(), pitches.size()]
		+ "sample with no variation machine-guns")

	# --- 4. The gate -----------------------------------------------------------
	#
	# `_play_shot` is called DIRECTLY rather than by firing a round, and no frame is
	# advanced while `view_active` is true. That flag also gates `_remember_hat`,
	# which WRITES THE DEVELOPER'S SAVED HAT TO user:// -- a test that quietly
	# mutates real user state is one nobody can trust twice.
	var root: Node = world
	var before_count: int = root.get_child_count()
	root.view_active = false
	root._play_shot(Vector3.ZERO, false)
	eq(root.get_child_count(), before_count,
		"a world nobody is looking at makes no sound")
	root.view_active = true
	root._play_shot(Vector3.ZERO, false)
	check(root.get_child_count() > before_count,
		"and a world somebody is looking at does -- both halves, because a gate "
		+ "stuck shut passes the first one perfectly")

	# --- 5. And it picks the right one -----------------------------------------
	#
	# THROUGH `_play_shot`, not through `spawn`. The flag is derived from
	# `source == 0` at the call sites, and a test that hands `spawn` a literal
	# would agree with itself about a translation it never made.
	for child in root.get_children():
		if child.name.begins_with("ShotSound"):
			root.remove_child(child)
			child.queue_free()
	root._play_shot(Vector3.ZERO, true)
	root._play_shot(Vector3(1.0, 0.0, 0.0), false)
	var heard: Array = []
	for child in root.get_children():
		if child.name.begins_with("ShotSound"):
			heard.append(child.stream)
	eq(heard.size(), 2, "two shots, two sounds")
	if heard.size() == 2:
		check(heard[0] == ShotSound.ENEMY_STREAM,
			"a round from the world uses the ENEMY report")
		check(heard[1] == ShotSound.PLAYER_STREAM,
			"and one from a peer uses the player's")
	root.view_active = false
	finish()
