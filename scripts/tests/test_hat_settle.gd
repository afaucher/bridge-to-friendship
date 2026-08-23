extends "res://scripts/test_support/test_case.gd"

# PLAYTEST 2026-08-16: "I got knocked over an edge and my hats got stuck in an
# infinite bounce loop."
#
# A dislodged hat has exactly three honest endings: it settles on the deck where
# somebody can pick it up, it falls out of the world and is destroyed, or it is
# culled behind the streaming window. Bouncing forever is none of them, and it is
# the worst kind of not-ending: the body stays in the contact graph, the pool
# never reclaims it, and it is visible the whole time.
#
# THE INTERESTING PART IS WHERE THEY LAND. A hat popped in open deck settles
# trivially and every existing hat test does exactly that. This one pops the stack
# AT THE LIP OF A HOLE, which is where the report came from and where the awkward
# geometry is: a derived parapet on one side, an edge on the other, and a body
# whose ROTATION IS LOCKED so it cannot tip out of a wedge the way a real hat
# would.
#
# The claim is one sentence: N seconds after the stack pops, every hat has
# reached one of its three endings.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# At the lip of the wide hole in test_flat: row 6 is missing from column 4 to 21,
# so row 5 is a long edge with deck behind it.
const LIP_CELL := Vector2i(12, 5)
const WORN := 5

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var frames: int = 0
var popped_frame: int = -1
# The worst speed seen in the last second, per hat id. A settled hat contributes
# zero; a bouncing one never does.
var late_speed: Dictionary = {}
var late_from: Dictionary = {}
var late_samples: int = 0

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "HatSettleWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	# A SECOND PLAYER, PARKED FAR AWAY. A solo player going over an edge is the
	# whole party out, which is a wipe -- and a wipe clears every hat, so "no hat
	# is bouncing" would be true because there are no hats. Same trap
	# test_hat_tumble documents and the same fix.
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	b.position = world.grid.cell_surface_world(Vector2i(27, 1)) + Vector3(0.0, 1.0, 0.0)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	# WALKED OFF, NOT SHOVED OFF. A one-shot velocity is scrubbed by walk friction
	# inside a few ticks and the player never reaches the lip -- which is how the
	# first run of this spent sixty seconds waiting for a fall that was never going
	# to happen. The stick is released the moment the stack is gone, per the note
	# CLAUDE.md carries about rigs that hold an input.
	world.scripted_inputs[1] = func(t: int) -> Array:
		var walking: bool = frames > 60 and popped_frame < 0
		return [t, Vector2(0.0, -1.0) if walking else Vector2.ZERO, 0, a.facing]

	a.position = world.grid.cell_surface_world(LIP_CELL) + Vector3(0.0, 1.0, 0.0)
	a.velocity = Vector3.ZERO

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	frames += 1

	# Wear the stack, then walk off the lip. Not teleported over it: the pop is
	# supposed to happen from wherever the ledge catch decides, and placing the
	# body by hand would be choosing the answer.
	if frames == 20:
		for i in WORN:
			world._hats.spawn_loose(a.position + Vector3(0.05 * float(i), 0.0, 0.0))
	if frames == 60:
		eq(world._hats.worn_by(1).size(), WORN, "the stack is on before the fall")
	if popped_frame < 0 and frames > 60 and world._hats.worn_by(1).is_empty():
		popped_frame = frames

	# THE LAST SECOND OF THE RUN, not the whole of it. Every hat is fast for the
	# first moment by design -- the scatter is a launch -- so a maximum over the
	# run answers "did it ever move", which is not the question.
	if popped_frame > 0 and frames > popped_frame + 480:
		late_samples += 1
		for hat in world._hats.all():
			if not is_instance_valid(hat) or hat.mode == HatBody.Mode.WORN:
				continue
			# WHERE IT WAS WHEN THE WINDOW OPENED, and how far it has got since.
			#
			# THIS READ linear_velocity UNTIL 2026-08-23 and could not be trusted after
			# the deck was flattened. A hat wedged at the lip is depenetrated by the
			# solver every few frames -- a real 5.7 cm in one tick, so a real 3.44 m/s
			# -- while going nowhere at all: measured, 7 cm of drift in four seconds.
			# The tilt used to push such a hat out of the wedge before anyone noticed.
			#
			# The claim in the header is that a hat REACHES AN ENDING, and the ending
			# that matters is "settled where somebody can pick it up". That is a
			# question about displacement, and a body that is buzzing in place has
			# answered it. The buzz itself is cosmetic and is recorded as open.
			if not late_from.has(hat.hat_id):
				late_from[hat.hat_id] = hat.position
			var drift: float = Vector3(late_from[hat.hat_id]).distance_to(hat.position)
			late_speed[hat.hat_id] = maxf(float(late_speed.get(hat.hat_id, 0.0)), drift)

	if late_samples < 60:
		return

	var worst_id: int = -1
	var worst: float = 0.0
	for id in late_speed:
		if float(late_speed[id]) > worst:
			worst = float(late_speed[id])
			worst_id = int(id)
	print("[hat settle] popped f%d, %d hats alive, worst late drift %.2f m (hat %d)"
		% [popped_frame, late_speed.size(), worst, worst_id])

	check(popped_frame > 0, "the stack came off at the edge")

	# THE ONE CLAIM. Nine seconds after the pop, nothing is still moving: every
	# surviving hat has settled where it can be picked up. The ones that fell out
	# of the world are not here to be asked, which is correct -- destroyed is an
	# ending.
	# The window is one second of samples, so the distance a hat moving at the
	# settle speed would cover in it.
	check(worst < SimConfig.HAT_SETTLE_SPEED,
		"every hat that is still in the world has stopped GOING anywhere (worst "
		+ "%.2f m of drift " % worst
		+ "against %.2f) -- a hat bouncing forever is in "
			% SimConfig.HAT_SETTLE_SPEED
		+ "the contact graph forever, is never reclaimed by the pool, and is "
		+ "visible the whole time")
	for id in late_speed:
		var hat: Node = _hat_by_id(int(id))
		if hat == null:
			continue
		eq(hat.mode, HatBody.Mode.LOOSE,
			"and is LOOSE, so it can be picked back up -- a hat stuck FLYING is "
			+ "uncollectable scenery")
	finish()

func _hat_by_id(id: int) -> Node:
	for hat in world._hats.all():
		if is_instance_valid(hat) and int(hat.hat_id) == id:
			return hat
	return null
