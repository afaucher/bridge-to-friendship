extends AudioStreamPlayer3D

# THE FIRST SOUND IN THIS GAME. Until 2026-08-22 there was no audio at all — no
# bus, no listener, no `AudioStreamPlayer` of any kind (`design_ideas/sound.md`
# opens by saying so). This is the rig as much as it is the effect.
#
# A PLACEHOLDER, AND IT SHOULD SOUND LIKE ONE. The stream is a recording of a
# person saying "pew". That is deliberate: a placeholder that sounds nearly right
# is one nobody replaces, and one that is obviously a human being is a to-do
# nobody can ignore.
#
# POSITIONAL, WHICH IS THE WHOLE ARGUMENT. sound.md's ordering rests on the fact
# that this game has a fixed-yaw camera framing 60 m of bridge, so things happen
# outside your attention constantly — audio is the only channel that addresses a
# player who is looking somewhere else. A gunshot played flat through the Master
# bus would carry none of that, so this is an AudioStreamPlayer3D at the muzzle
# and the camera is the listener.
#
# IT FREES ITSELF, same as blast_effect.gd and for the same reason: the thing that
# made the sound is very often destroyed before the sound ends. A round that hits
# a wall two frames after leaving the barrel must not take its own report with it.

# THE PITCH WOBBLE, and the reason it does NOT use randf().
#
# A repeated sample fired several times a second machine-guns badly, and a few
# percent of pitch either way is the standard cure. But the global RNG is SEEDED
# in tests, and this project has already been bitten by an unrelated edit shifting
# how many randf() calls happen before a sim-affecting one — test_gunners had two
# damage assertions passing on the luck of that stream. A presentation path must
# never draw from the same sequence the simulation does, so this keeps its own
# generator.
static var _rng: RandomNumberGenerator = null

const PITCH_SPREAD := 0.08

# Audible across most of the bridge but not all of it: a shot 40 m up-bridge is
# somebody else's problem, and hearing every round in the run at once is noise
# rather than information.
const MAX_DISTANCE := 45.0
const UNIT_SIZE := 14.0

# TWO SAMPLES, AND THE SPLIT IS THE POINT. Until 2026-08-22 every round in the
# game -- yours, a skirmisher's, a turret's -- reported with one placeholder, and
# sound.md says in as many words why that cannot stand: cadence is the defining
# property of the ranged enemies, so if they sound like you the split between "I
# am shooting" and "I am being shot at" is inaudible. On a bridge where the camera
# frames sixty metres and half of it is behind you, that is the difference between
# a warning and noise.
#
# The line between them is `source == 0`, which is what `_spawn_round` already
# means by "the world" -- no new fact, just one that had nowhere to go.
const PLAYER_STREAM := preload("res://sounds/player_shot.wav")
const ENEMY_STREAM := preload("res://sounds/enemy_shot.wav")

# `sounds/mg_shot.wav` is the original recorded "pew" and is deliberately still in
# the tree, unreferenced, for future use -- it is the only sound here that is
# obviously a human being, which makes it the right placeholder for whatever gets
# built next.

# `at` is in the PARENT's space — the GameWorld's — like every other position that
# crosses this boundary. Two worlds in one process sit a kilometre apart, so a
# sound placed in global coordinates would come from the wrong one.
static func spawn(parent: Node, at: Vector3, from_enemy: bool) -> Node:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	var player := AudioStreamPlayer3D.new()
	player.set_script(load("res://scripts/ui/shot_sound.gd"))
	player.stream = ENEMY_STREAM if from_enemy else PLAYER_STREAM
	player.max_distance = MAX_DISTANCE
	player.unit_size = UNIT_SIZE
	player.pitch_scale = 1.0 + _rng.randf_range(-PITCH_SPREAD, PITCH_SPREAD)
	parent.add_child(player)
	# NAMED AFTER THE ADD, and that is not style. A name assigned before
	# add_child is DISCARDED when a sibling already holds it -- Godot falls back
	# to a generated "@AudioStreamPlayer3D@342" rather than to "ShotSound2" --
	# so with several shots alive at once most of them end up anonymous. Cost a
	# round here: a test counting nodes by name found one of the two it had just
	# made. Set after, and the uniquifier does the sensible thing.
	player.name = "ShotSound"
	player.position = at
	player.finished.connect(player.queue_free)
	player.play()
	return player
