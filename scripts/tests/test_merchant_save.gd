extends "res://scripts/test_support/test_case.gd"

# WHAT THE DISK SAYS YOU OWN IS WHAT YOU ARE WEARING -- the whole stack of it,
# tall hats included.
#
# THIS FILE USED TO ASSERT THE OPPOSITE, and the reversal is the point of reading
# it. Until 2026-08-23 a tall hat was deliberately excluded: it comes only from
# the merchant, so refusing to persist it made the trade a bet rather than a
# purchase (design_ideas/merchant.md finding 5). Overruled by the person whose
# game it is -- "it is more fun to keep your big hat" -- and the trade-off was
# named when it was overruled, which is the only way a reversal is worth
# anything.
#
# THE HARD-WON PART SURVIVES INTACT, and it is why this file still exists.
# Saving is a SELECTION FROM WHAT YOU WEAR, never a guard on writing:
#
#   * A guard with an early return leaves whatever was on disk BEFORE. Own one
#     ordinary hat, trade it away, and the trade consumed it while the guard
#     rejected the trophy -- so the file still names the hat you just spent and
#     the next launch hands it straight back. Invisible until somebody restarts,
#     and the merchant is free forever after.
#
# That failure is unchanged by the reversal: what makes it impossible is that the
# save is rebuilt from the worn stack every time, so a hat that is gone is gone.
#
# The claims, all about the DISK, read back through HatConfig:
#   1. Trading your only hat leaves the disk naming THE TROPHY and NOT the hat
#      you paid with. The second half is the one a naive guard fails.
#   2. [ordinary, tall] saves BOTH, bottom-first -- the stack you built is the
#      stack you get back.
#   3. [tall] alone saves the tall one, which is the reversed rule stated plainly.
#
# DRIVEN THROUGH THE REAL TRADE for case 1, not by calling the selection helper
# with a hand-built stack. A test that hand-builds its own input has not tested
# the caller, and the wrong implementation above lives in the caller.
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
		eq(HatConfig.load_styles(), [_ordinary_style],
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
		# THE WHOLE POINT, AND IT SURVIVED THE REVERSAL. The trophy is saved now,
		# so the first half of this reads the other way round -- but the second
		# half is the one that was ever load-bearing, and it is untouched.
		eq(HatConfig.load_styles(), [int(worn[0].style_id)],
			"trading your only hat leaves the disk naming THE TROPHY -- since "
			+ "2026-08-23 a tall hat persists like any other")
		check(not HatConfig.load_styles().has(_ordinary_style),
			"and specifically NOT the hat that paid for the trade (%d). Saving is "
				% _ordinary_style
			+ "a SELECTION FROM WHAT YOU WEAR, not a guard on writing: a guard "
			+ "would have left the file naming the hat you just spent, the next "
			+ "launch would hand it back, and the merchant would be free across "
			+ "sessions with no symptom until a restart")
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
		eq(HatConfig.load_styles(),
			[int(worn[0].style_id), int(worn[1].style_id)],
			"a stack of [ordinary, tall] saves BOTH, bottom-first -- the tower you "
			+ "built is the tower you get back. It used to save only the ordinary "
			+ "one, on the rule that a trophy must not evict a hat you still own; "
			+ "keeping the whole stack answers that objection by not choosing")
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
		eq(HatConfig.load_styles(), [int(worn[0].style_id)],
			"a lone tall hat is SAVED -- the reversed rule, stated plainly. It was "
			+ "yours for the run only, on the argument that persisting it made the "
			+ "trade a purchase rather than a bet; it is a purchase now, on purpose")

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
