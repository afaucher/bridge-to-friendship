extends "res://scripts/test_support/test_case.gd"

# The hold music: it loops, it follows the round state, and it fades.
#
# WHY A TEST FOR MUSIC. `_update_lobby_music` is gated on `view_active`, false in
# every headless world, so none of this would otherwise execute a line in the gate
# -- the same reason test_shot_sound and test_aim_readout exist. And the first
# claim below is not about behaviour at all: a WAV imports with looping OFF, so a
# fifty-second track wired up perfectly plays once and leaves the lobby silent.
# Nothing in the code would be wrong; the resource would be.
#
# The claims:
#   1. THE STREAM LOOPS, over a real range. `edit/loop_mode=1` in the .import does
#      NOT survive to the AudioStreamWAV -- tried, cache cleared, re-imported,
#      still LOOP_DISABLED -- so LobbyMusic sets it, and this is what proves it.
#   2. IT FOLLOWS THE ROUND STATE, both ways -- on in the lobby, off in a round.
#      A track that never stopped would pass the first half perfectly.
#   3. IT FADES rather than cutting, and the fade takes about as long as it says.
#      The lobby is entered by walking over a line, so a cut would announce a
#      transition the player is in the middle of causing.
#   4. IT IS NOT POSITIONAL. Every other sound here is an AudioStreamPlayer3D at a
#      point in the world; music that got quieter as the camera drifted would be
#      the one thing that must not.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const LobbyMusic = preload("res://scripts/ui/lobby_music.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "MusicWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.view_active = true
	world.start(true, 1, false)

func _physics_process(_delta: float) -> void:
	if world.tick == 0:
		return
	set_physics_process(false)

	# --- 1. It loops -----------------------------------------------------------
	LobbyMusic._ensure_loops()
	var stream: AudioStreamWAV = LobbyMusic.STREAM as AudioStreamWAV
	check(stream != null, "the hold music loaded as a WAV")
	if stream == null:
		finish()
		return
	print("[music] %.1f s, loop_mode %d, %d Hz"
		% [stream.get_length(), stream.loop_mode, stream.mix_rate])
	check(stream.loop_mode != AudioStreamWAV.LOOP_DISABLED,
		"and it LOOPS -- a WAV imports with looping off, so hold music wired up "
		+ "perfectly still plays once and leaves the lobby silent. The import "
		+ "setting for this does NOT survive to the resource, so the script sets "
		+ "it -- which makes this the assertion that the script really does")
	check(stream.loop_end > 0,
		"over a real range -- LOOP_FORWARD with loop_end at the importer's 0 is a "
		+ "loop of nothing rather than a loop of everything (%d frames)" % stream.loop_end)
	check(stream.get_length() > 5.0,
		"and it is long enough to be a track rather than a sting (%.1f s)"
			% stream.get_length())

	# --- 2 and 4. It follows the state -----------------------------------------
	world.round_machine.state = RoundMachine.State.LOBBY
	world._update_lobby_music()
	var music: Node = world.get_node_or_null("LobbyMusic")
	check(music != null, "the lobby builds the player")
	if music == null:
		finish()
		return
	check(not (music is AudioStreamPlayer3D),
		"and it is NOT positional -- music that faded with the camera would be "
		+ "the one sound in the game that must not")

	# A second of lobby, stepped by hand: the node fades in _process and nothing
	# is running one here.
	_advance(music, 1.0)
	var in_lobby: float = music.volume_db
	check(music.playing, "it plays in the lobby")
	check(in_lobby > LobbyMusic.SILENT_DB + 5.0,
		"and has risen (%.1f dB)" % in_lobby)

	# --- 3. The fade -----------------------------------------------------------
	#
	# A FADE IS THE CLAIM, so it is sampled part-way rather than at the ends. A cut
	# would be at its target on the first tick and would pass any assertion that
	# only looked at where it ended up.
	world.round_machine.state = RoundMachine.State.RUNNING
	world._update_lobby_music()
	_advance(music, LobbyMusic.FADE_OUT_SECONDS * 0.4)
	var midway: float = music.volume_db
	check(midway < in_lobby - 1.0 and midway > LobbyMusic.SILENT_DB + 1.0,
		"leaving the lobby it FADES rather than cutting -- %.1f dB partway down "
			% midway + "from %.1f" % in_lobby)

	_advance(music, LobbyMusic.FADE_OUT_SECONDS)
	print("[music] lobby %.1f dB -> midway %.1f -> round %.1f"
		% [in_lobby, midway, music.volume_db])
	check(not music.playing,
		"and it stops once it is inaudible -- a lobby theme that resumed eleven "
		+ "seconds in, mid-phrase, would sound like a fault")

	# AND BACK. The other half of claim 2: a track that stopped for good would
	# satisfy everything above.
	world.round_machine.state = RoundMachine.State.SCORING
	world._update_lobby_music()
	_advance(music, 1.0)
	check(music.playing and music.volume_db > LobbyMusic.SILENT_DB + 5.0,
		"and the scoreboard brings it back (%.1f dB) -- the board, the regroup "
			% music.volume_db
		+ "and the walk to the line are one stretch of waiting to a player")
	finish()

# `_process` is not running in a headless test's tree the way a game's is, so the
# fade is stepped explicitly. Sixty calls per second, which is what it would get.
func _advance(music: Node, seconds: float) -> void:
	var ticks: int = int(seconds / SimConfig.TICK_DELTA)
	for _i in ticks:
		music._process(SimConfig.TICK_DELTA)
