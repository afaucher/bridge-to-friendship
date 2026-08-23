extends AudioStreamPlayer

# The hold music, for the time between rounds.
#
# NOT POSITIONAL, which is the whole difference between this and shot_sound.gd.
# Every other sound in this game is an AudioStreamPlayer3D at a point in the world,
# because `sound.md` argues that the value of audio here is telling you about
# things you are not looking at. Music is the exception: it is not about anywhere,
# so a 3D emitter would make it quieter when the camera drifted, which is the one
# thing it must not do.
#
# IT FADES, and that is not decoration either. The lobby is entered by walking
# over a line and left the same way, so a track that cut in at full volume on a
# tick boundary would announce a state change the player is in the middle of
# causing. A second and a half of rise is slow enough to read as arriving
# somewhere.
#
# WHY IT STOPS RATHER THAN MUTING. Silence and "playing silently" are the same
# thing to listen to and different things to come back to: a lobby theme that
# resumes eleven seconds in, mid-phrase, sounds like a mistake, and this is a
# fifty-second loop that will be heard from the start many times in a run.

# MONO, AND IT WAS NOT WHEN IT ARRIVED. The take was marked stereo and measured as
# one signal: correlation 0.94 between the channels, with LEFT being RIGHT at
# -10.3 dB. So the file was collapsed to the right channel alone rather than
# averaged -- which is what Godot's `force/mono` would have done, and averaging a
# decorrelated quiet copy back in is comb filtering, not a downmix. Halved the
# source, 8.95 MB to 4.48.
#
# It is also QUIET: peak -12.6 dBFS, RMS -36.5. That is a level decision rather
# than a format one and is deliberately left alone here -- see FULL_DB below, which
# then plays it 10 dB further down again.
const STREAM := preload("res://sounds/hold_music.wav")

# UNDER THE GAME. Music that competes with a gunshot loses the gunshot, and the
# gunshot is the one carrying information. A starting value with a reason rather
# than a mixed one -- there is no mix yet, this being the second sound in the
# project.
const FULL_DB := -10.0

# Below this it is inaudible and the player is stopped. -40 dB is a four
# hundredth of full amplitude.
const SILENT_DB := -40.0

const FADE_IN_SECONDS := 1.5
const FADE_OUT_SECONDS := 1.0

var _wanted: bool = false

# LOOPED IN CODE, NOT IN THE IMPORT, and the import was tried first.
#
# `edit/loop_mode=1` in sounds/hold_music.wav.import does not survive to the
# AudioStreamWAV -- set, cache cleared, re-imported, and `loop_mode` still reads
# LOOP_DISABLED (the file is QOA-compressed, which is where the two part ways).
# Rather than keep a setting that says one thing and a resource that does
# another, the fact lives in exactly one place, here, where the script that
# depends on it can be read.
#
# IT MUTATES THE SHARED RESOURCE, deliberately. A preload is one instance for the
# whole process, so this is a global write -- acceptable because it is idempotent,
# always the same value, and this is the only thing that ever plays the track.
# Duplicating instead would copy fifty seconds of audio to change one enum.
static func _ensure_loops() -> void:
	var wav := STREAM as AudioStreamWAV
	if wav == null or wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
		return
	wav.loop_begin = 0
	# In FRAMES, and the importer leaves this at 0 -- which with LOOP_FORWARD is a
	# loop of nothing rather than a loop of everything.
	wav.loop_end = int(wav.get_length() * float(wav.mix_rate))
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD

static func spawn(parent: Node) -> Node:
	_ensure_loops()
	var music := AudioStreamPlayer.new()
	music.set_script(load("res://scripts/ui/lobby_music.gd"))
	music.stream = STREAM
	music.volume_db = SILENT_DB
	parent.add_child(music)
	music.name = "LobbyMusic"
	return music

# Called every tick by the world. Idempotent on purpose: the caller does not have
# to notice the edge, it just says what the situation is.
func want(on: bool) -> void:
	_wanted = on

func _process(delta: float) -> void:
	var target: float = FULL_DB if _wanted else SILENT_DB
	if is_equal_approx(volume_db, target):
		if not _wanted and playing:
			stop()
		return
	# Per SECOND rather than per frame, so the fade takes the time it says it does
	# whatever the frame rate is.
	var span: float = FULL_DB - SILENT_DB
	var rate: float = span / (FADE_IN_SECONDS if _wanted else FADE_OUT_SECONDS)
	volume_db = move_toward(volume_db, target, rate * delta)
	if _wanted and not playing:
		# FROM THE TOP. See the header: resuming mid-phrase reads as a fault.
		play()
	elif not _wanted and is_equal_approx(volume_db, SILENT_DB):
		stop()
