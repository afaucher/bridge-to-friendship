extends "res://scripts/test_support/test_case.gd"

# YOU START WEARING WHAT YOU SAVED -- ALL OF IT, AND THE RIGHT ONES.
#
# Reported from play 2026-08-23, one restart after the stack format shipped:
# "I saved 4 hats, quit, restarted, looked at character screen and saw 4 of the
# original colours. Went to the game and I had four of the SAME colour."
#
# The two halves of that report point at different code. The character screen
# reads the file directly and was right, so the SAVE is fine; the game builds its
# hats in `_give_saved_hat`, so the RESTORE is where the fault is. A test that
# only round-tripped HatConfig would have been green throughout -- which is
# exactly what test_hat_config is, and it was.
#
# THE CLAIM IS ABOUT THE BODIES, NOT THE FILE. What the player sees is four hats
# on their head; asserting the disk again would be asserting the half that was
# already known to work.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const HatConfig = preload("res://scripts/hat_config.gd")
const CharacterConfig = preload("res://scripts/character_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const SAVED := [101, 202, 303, 404]

var world: Node3D = null

func setup(main) -> void:
	timeout_seconds = 30.0
	# DISPOSABLE PATHS FOR BOTH FILES. `view_active` has to be true for the restore
	# to run at all, and that same flag is what makes a world read the developer's
	# real config -- so the gate would otherwise rewrite somebody's own hat and
	# face on every run.
	HatConfig.path_override = "user://test_saved_stack.cfg"
	CharacterConfig.path_override = "user://test_saved_stack_face.cfg"
	HatConfig.reset()
	HatConfig.save_styles(SAVED)

	world = Node3D.new()
	world.name = "RestoreWorld"
	world.set_script(GameWorldScript)
	# BEFORE add_child: _ready() is what reads the disk, and a flag set afterwards
	# would be set after the only line that looks at it.
	world.view_active = true
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world.host_spawn(1)

	var worn: Array = []
	for hat in world.hats_worn_by(1):
		worn.append(int(hat.style_id))
	print("[restore] saved %s -> wearing %s" % [str(SAVED), str(worn)])

	eq(worn.size(), SAVED.size(),
		"every saved hat comes back (%d of %d)" % [worn.size(), SAVED.size()])
	eq(worn, SAVED,
		"and they are the hats that were saved, in the order they were stacked -- "
		+ "the report was four hats of ONE colour, which is a restore that read "
		+ "one style and used it four times")

	# AND THE FILE IS UNCHANGED BY PUTTING THEM ON. Wearing a hat writes the save,
	# so a restore that reconstructs the stack incorrectly also OVERWRITES the
	# correct file with its own mistake -- the second restart is worse than the
	# first, and the evidence of what you owned is gone.
	eq(HatConfig.load_styles(), SAVED,
		"and the file still names the same four afterwards: a restore writes back "
		+ "as it dresses you, so a wrong one destroys the record of what you owned")

	HatConfig.reset()
	HatConfig.path_override = ""
	CharacterConfig.path_override = ""
	finish()
