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
#   1. THE STREAM IS REAL. It loads, it has a length, and it is the mono 44.1 kHz
#      placeholder that was prepared -- not a null that AudioStreamPlayer3D would
#      accept in silence.
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

	# --- 1. The stream ---------------------------------------------------------
	var stream: AudioStream = ShotSound.STREAM
	check(stream != null, "the placeholder stream loaded")
	if stream == null:
		finish()
		return
	var seconds: float = stream.get_length()
	print("[sound] mg_shot.wav is %.3f s" % seconds)
	check(seconds > 0.05 and seconds < 1.0,
		"and is a shot rather than a silence or a loop (%.3f s) -- this fires "
			% seconds
		+ "several times a second, so length is a gameplay property")

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
		made.append(ShotSound.spawn(world, Vector3(float(i) * 2.0, 1.0, -4.0)))
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
		check(node.stream == stream, "with the placeholder on it")
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
	root._play_shot(Vector3.ZERO)
	eq(root.get_child_count(), before_count,
		"a world nobody is looking at makes no sound")
	root.view_active = true
	root._play_shot(Vector3.ZERO)
	check(root.get_child_count() > before_count,
		"and a world somebody is looking at does -- both halves, because a gate "
		+ "stuck shut passes the first one perfectly")
	root.view_active = false
	finish()
