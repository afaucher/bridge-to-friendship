extends "res://scripts/test_support/test_case.gd"

# M8.5, criterion B8: two players reaching one hat, and EXACTLY ONE gets it.
#
# The plan calls this "the one most likely to fail first, and it is the reason
# the pickup pass is specified as separate from the step loop". Both halves are
# asserted here:
#
#   1. Exactly one player ends up wearing a contested hat -- never both, never a
#      hat that exists twice.
#   2. The NEARER player wins, regardless of carry order. GameWorld._carry_order()
#      is a topological sort over who is standing on whom, so the order players
#      step in changes with the stack. If contests were decided inside that loop,
#      a carried player would systematically win or lose depending on whose head
#      they were standing on -- an ordering-dependent gameplay outcome hiding in a
#      function written for something else entirely.
#   3. A dead-heat is broken by ASCENDING PEER ID, and the tie is not exotic: it
#      is what two symmetric players produce, which is precisely the situation a
#      race creates.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "HatContestWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	a = world.player_body(1)
	b = world.player_body(2)
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_exactly_one()
		1: _phase_nearer_wins()
		2: _phase_dead_heat()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. Exactly one ------------------------------------------------------------

func _phase_exactly_one() -> void:
	if phase_frame == 1:
		_stage(Vector3(0.4, 0.0, 0.0), Vector3(-0.4, 0.0, 0.0))
		return
	if phase_frame == 10:
		var total: int = world.hats_worn_by(1).size() + world.hats_worn_by(2).size()
		eq(total, 1, "two players reaching one hat: exactly one wears it")
		eq(world.hat_count(), 1, "and there is still exactly one hat in the world")
		_advance(1)

# --- 2. The nearer player wins, whatever the carry order -----------------------

func _phase_nearer_wins() -> void:
	if phase_frame == 1:
		# B clearly nearer. A is inside pickup range too, so this is a contest
		# rather than a walkover -- if the rule were "first peer in the dictionary"
		# rather than "nearest", A would take it.
		_stage(Vector3(0.9, 0.0, 0.0), Vector3(-0.1, 0.0, 0.0))

		# AND A IS STANDING ON B. That makes the carry order put one of them first
		# in the step loop, which is the exact confound the separate pickup pass
		# exists to remove. The answer must not change because of it.
		a.position = b.position + Vector3(0.0, PlayerBody.HALF_HEIGHT * 2.0, 0.0)
		a.position.x = b.position.x + 0.9
		return
	if phase_frame == 10:
		eq(world.hats_worn_by(2).size(), 1, "the NEARER player takes it")
		eq(world.hats_worn_by(1).size(), 0, "and the further one does not")
		_advance(2)

# --- 3. A dead heat goes to the lower peer id ---------------------------------

func _phase_dead_heat() -> void:
	if phase_frame == 1:
		# Exactly symmetric about the hat. This is not a contrived case: it is
		# what two players converging on the same hat from opposite sides produce,
		# and without a stated tie-break it is decided by dictionary order.
		_stage(Vector3(0.5, 0.0, 0.0), Vector3(-0.5, 0.0, 0.0))
		return
	if phase_frame == 10:
		var total: int = world.hats_worn_by(1).size() + world.hats_worn_by(2).size()
		eq(total, 1, "a dead heat still produces exactly one winner")
		eq(world.hats_worn_by(1).size(), 1,
			"and it is the lower peer id, so the tie-break is stated rather than incidental")
		finish()

# --- helpers ------------------------------------------------------------------

# One hat on open deck, with the two players placed relative to it.
func _stage(offset_a: Vector3, offset_b: Vector3) -> void:
	world._hats.clear()
	var at: Vector3 = world.grid.cell_surface_world(Vector2i(25, 9)) + Vector3(0.0, 0.3, 0.0)
	recorded["hat"] = world._hats.spawn_loose(at)
	for body in [a, b]:
		body.velocity = Vector3.ZERO
		body.state = PlayerBody.State.WALK
		body.grounded = true
	a.position = at + offset_a + Vector3(0.0, 0.7, 0.0)
	b.position = at + offset_b + Vector3(0.0, 0.7, 0.0)
