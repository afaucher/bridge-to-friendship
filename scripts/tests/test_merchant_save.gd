extends "res://scripts/test_support/test_case.gd"

# A TALL HAT DOES NOT SURVIVE A LAUNCH, and that is a rule about WHICH HAT IS
# SAVED rather than a guard on saving. See design_ideas/merchant.md finding 5 --
# this file exists because the obvious implementation is wrong, and wrong in the
# direction that makes the merchant free.
#
#   * Guarding _remember_hat with an early return on a tall style leaves whatever
#     was on disk BEFORE. Own one ordinary hat, trade it, and the trade consumed
#     it while the guard rejected the trophy -- so the file still names the hat
#     you just spent, and the next launch hands it straight back. Invisible until
#     somebody restarts the game, and free forever after.
#   * Saving NONE whenever the top is tall throws away an ordinary hat you are
#     still wearing, in a stack of [ordinary, tall].
#
# So the claims are about the DISK, read back through HatConfig, and the first is
# the one the naive guard passes:
#   1. Trading your only hat leaves the disk naming NOTHING -- not the hat you
#      paid with.
#   2. [ordinary, tall] saves the ordinary one: the trophy does not evict a hat
#      you still own.
#   3. [tall] alone saves NONE.
#
# DRIVEN THROUGH THE REAL TRADE for case 1, not by calling the selection helper
# with a hand-built stack. A test that hand-builds its own input has not tested
# the caller, and both wrong implementations above live in the caller.
#
# Everything here writes to a DISPOSABLE path. A test that rewrote the real
# user:// file would quietly change the developer's own saved hat every time the
# gate ran.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")
const HatConfig = preload("res://scripts/hat_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const MERCHANT_A := Vector2i(10, 5)

var world: Node3D = null
var a: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var _dash_pending: bool = false
var _move: Vector2 = Vector2.ZERO
var _ordinary_style: int = 0

func setup(main) -> void:
	timeout_seconds = 60.0
	HatConfig.path_override = "user://test_merchant_save.cfg"
	HatConfig.reset()

	world = Node3D.new()
	world.name = "MerchantSaveWorld"
	world.set_script(GameWorldScript)
	# BEFORE add_child, because _ready() reads the disk into _remembered_hat and
	# only does so for a world somebody is looking at. Set afterwards, every
	# assertion below would be about a save path that never runs -- green, and
	# measuring nothing.
	world.view_active = true
	main.add_child(world)
	world.segment_paths = ["res://segments/test_merchant.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	a = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		if _dash_pending:
			_dash_pending = false
			return PlayerInput.make(t, _move, SimConfig.ACTION_SHOVE)
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_trading_your_only_hat()
		1: _phase_ordinary_under_tall()
		2: _phase_tall_alone()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. Trading your only hat -------------------------------------------------
#
# THE CASE THE NAIVE GUARD PASSES, and the reason this file exists.

func _phase_trading_your_only_hat() -> void:
	if phase_frame == 1:
		_reset()
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 8:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 1, "the player owns exactly one ordinary hat"):
			finish()
			return
		_ordinary_style = int(worn[0].style_id)
		# THE PRECONDITION, ASSERTED. Without this the case below could pass
		# because the disk was empty the whole time rather than because the trade
		# cleared it -- an instrument has to be shown capable of reporting the
		# wrong answer before its right answer means anything.
		eq(HatConfig.load_style(), _ordinary_style,
			"and acquiring it wrote it to disk: that is the hat the next launch "
			+ "would give back")
		_dash_at()
		return
	if phase_frame == 30:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 1, "the trade happened"):
			finish()
			return
		check(worn[0].is_tall(), "and the player is wearing the trophy")
		# THE WHOLE POINT.
		eq(HatConfig.load_style(), HatConfig.NONE,
			"trading your only hat leaves the disk naming NOTHING. Saving is a "
			+ "SELECTION, not a guard: a guard would have left the file naming the "
			+ "hat you just spent, and the next launch would hand it back -- the "
			+ "merchant free across sessions, and no symptom until a restart")
		check(HatConfig.load_style() != _ordinary_style,
			"and specifically not the hat that paid for the trade (%d)" % _ordinary_style)
		_advance(1)

# --- 2. [ordinary, tall] saves the ordinary one -------------------------------

func _phase_ordinary_under_tall() -> void:
	if phase_frame == 1:
		_reset()
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 3:
		_give_hat(HatStyle.TALL_FIRST)
		return
	if phase_frame == 12:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 2, "the player wears [ordinary, tall]"):
			finish()
			return
		check(not worn[0].is_tall() and worn[1].is_tall(), "in that order")
		eq(HatConfig.load_style(), int(worn[0].style_id),
			"a stack of [ordinary, tall] saves the ORDINARY one -- the trophy is "
			+ "not allowed to evict a hat you still own and are still wearing")
		_advance(2)

# --- 3. A tall hat alone saves nothing ----------------------------------------

func _phase_tall_alone() -> void:
	if phase_frame == 1:
		_reset()
		return
	if phase_frame == 2:
		_give_hat(HatStyle.TALL_FIRST)
		return
	if phase_frame == 12:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 1, "the player wears one tall hat and nothing else"):
			finish()
			return
		check(worn[0].is_tall(), "and it is the tall one")
		eq(HatConfig.load_style(), HatConfig.NONE,
			"a lone tall hat saves NONE -- it is yours for the run and the next "
			+ "session starts you bare")

		HatConfig.reset()
		HatConfig.path_override = ""
		finish()

# --- helpers ------------------------------------------------------------------

func _reset() -> void:
	world._hats.clear()
	_move = Vector2.ZERO
	_dash_pending = false
	a.global_position = world.grid.cell_surface_world(MERCHANT_A) + Vector3(
		0.0, 1.0, GridConfig.CELL_SIZE)
	a.velocity = Vector3.ZERO
	a.state = PlayerBody.State.WALK
	a.grounded = true
	a.shove_cooldown = 0.0
	a.dash_charges = SimConfig.DASH_CHARGES

func _dash_at() -> void:
	_move = Vector2(0.0, -1.0)
	_dash_pending = true

func _give_hat(style: int = -1) -> Node:
	return world._hats.spawn_loose(a.global_position, style)
