extends "res://scripts/test_support/test_case.gd"

# THE MERCHANT. You stand at him and press E, he takes the top hat off your tower
# and gives back one three and a half times taller, once. See
# design_ideas/merchant.md.
#
# IT USED TO BE A DASH, and the note that justified it argued the verb was
# deliberate: committed, aimed, and impossible to do by walking past. All true,
# and reported anyway -- "it is really easy to miss them and dash off a cliff."
# A dash is 56 m/s over 5.6 m, so a near miss at a shopkeeper standing near an
# edge cost the run. E is edge-triggered and nobody presses it by accident either.
#
# The claims, in the order they are measured:
#   1. His layer is in the PLAYER'S MASK, and a real dash at him actually STOPS.
#      A blocker that exists is not a blocker that blocks, and this project has
#      now paid five times for one wrong bit in a mask. Still a dash, because
#      this claim is about him being SOLID and has nothing to do with trading.
#   2. A press trades: the TOP hat goes, a tall one arrives in its slot, the rest
#      of the tower is untouched, and he is spent afterwards.
#   3. A second press does nothing. One sale each is what makes him contested.
#   3b. AND A DASH ALONE DOES NOT TRADE. The half of the change a rig that still
#      dashes on its way in cannot see by itself: every phase below approaches at
#      speed, so without this one the file would pass unchanged if the dash still
#      did the selling.
#   4. HE REFUSES A TALL HAT -- you keep everything -- AND HE IS STILL UNSPENT.
#      A refused trade that burns the sale is a merchant the next player finds
#      empty for no reason they can see.
#   5. A player with no hats gets nothing, loses nothing, and does not spend him.
#   6. ...and then a real trade with that same merchant SUCCEEDS. That last one
#      is the control: without it, "still unspent" in 4 and 5 is a boolean nobody
#      has shown can still be cashed, and the whole file would pass against a
#      merchant who was broken from the start.
#
# EVERY PHASE RESETS THE STACK. A long sweep is a fixture that gets dirtier as it
# runs (2026-08-14), and here the dirt would be the previous phase's trophy
# sitting on top and silently turning phase 3 into phase 4.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# The two merchants authored into test_merchant.seg, in grid cells. Two of them,
# because "one sale per merchant" is a claim about one merchant and not about the
# species: with a single shopkeeper, "spent" and "the feature never worked" read
# identically.
const MERCHANT_A := Vector2i(10, 5)
const MERCHANT_B := Vector2i(20, 5)
# A THIRD, PLANTED. The fixture carries two and both are spent by the phases
# above, and the dash-alone control needs one nobody has touched -- the same
# reason test_bus_post plants its own post through the grid's own spawner.
const MERCHANT_C := Vector2i(4, 5)

var world: Node3D = null
var a: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0

# The dash, as one edge-triggered tick. Held longer it would be a rig that walks
# the player off the map, which is its own note in CLAUDE.md.
var _dash_pending: bool = false
# When the trade press goes in, in world ticks. -1 is "nothing queued".
var _use_at_tick: int = -1
var _move: Vector2 = Vector2.ZERO

func setup(main) -> void:
	timeout_seconds = 60.0
	world = Node3D.new()
	world.name = "MerchantWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_merchant.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	a = world.player_body(1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		if _dash_pending:
			_dash_pending = false
			return PlayerInput.make(t, _move, SimConfig.ACTION_SHOVE)
		# AND THE PRESS THAT ACTUALLY TRADES, a few ticks behind the approach.
		# Separated from the dash rather than folded into it because they are now
		# two different things: the dash is how the player GETS there and the
		# press is the trade. On the tick of the dash the body is still 2 m away
		# and out of reach, which is the whole reason for the delay.
		if _use_at_tick >= 0 and world.tick >= _use_at_tick:
			_use_at_tick = -1
			return PlayerInput.make(t, Vector2.ZERO, SimConfig.ACTION_USE)
		return PlayerInput.empty(t)

	# THE MASK BIT, ASSERTED DIRECTLY AND NOT INFERRED FROM A POSITION. A dash
	# that sails through the shopkeeper and a dash that misses him look the same
	# from a coordinate; naming the fault here means the assertion below does not
	# have to be explained.
	var merchant: Node = world.grid.merchant_at_cell(MERCHANT_A)
	if not check(merchant != null, "the `$` glyph builds a merchant body"):
		finish()
		return
	check(merchant.collision_layer & a.collision_mask != 0,
		"the merchant's layer is in the player's mask -- a layer nothing masks is "
		+ "a collider made of nothing, and every test that only asks whether he "
		+ "EXISTS passes the whole time")

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_trade()
		1: _phase_spent()
		2: _phase_refuses_a_tall_hat()
		3: _phase_no_hats()
		4: _phase_the_control()
		5: _phase_a_dash_alone_is_not_a_trade()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1 + 2. A dash stops on him and takes the top hat -------------------------

func _phase_trade() -> void:
	if phase_frame == 1:
		_reset(MERCHANT_A)
		return
	# One hat per tick, so which one is on top is unambiguous rather than a
	# property of whatever order the pickup pass happened to sweep in.
	if phase_frame == 2 or phase_frame == 3:
		_give_hat()
		return
	if phase_frame == 8:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 2, "the player starts the trade wearing two hats"):
			finish()
			return
		_recorded_bottom = int(worn[0].style_id)
		_recorded_top_id = int(worn[1].hat_id)
		_recorded_z = a.global_position.z
		_dash_at(MERCHANT_A)
		return
	if phase_frame == 30:
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_A)
		var worn: Array = world.hats_worn_by(1)

		# HE IS A WALL, and this is measured on the body rather than assumed from
		# the trade. The dash covers 5.6 m and started 2 m away, so a player who
		# passed through him would be a clear metre beyond -- and the trade would
		# still have fired, because the contact is what calls it.
		check(a.global_position.z > merchant.global_position.z,
			"a dash under power STOPS on the merchant rather than passing through "
			+ "him (player z %.2f, merchant z %.2f)"
				% [a.global_position.z, merchant.global_position.z])
		check(a.global_position.z < _recorded_z,
			"and it really did travel toward him first (%.2f -> %.2f)"
				% [_recorded_z, a.global_position.z])

		eq(worn.size(), 2, "the tower is the same height after the trade: one hat "
			+ "in, one hat out")
		check(world._hats.by_id(_recorded_top_id) == null,
			"the hat you paid with is destroyed, not dropped -- a payment you can "
			+ "walk back over is not a payment")
		eq(int(worn[0].style_id), _recorded_bottom,
			"the hat UNDER the payment is untouched: the price is one hat, flat")
		check(not worn[0].is_tall(), "and it is still an ordinary hat")
		check(worn[1].is_tall(),
			"and a tall hat is standing in the slot the payment came out of")
		near(worn[1].slot_height(), SimConfig.HAT_HEIGHT * SimConfig.TALL_HAT_SLOTS,
			0.0001, "occupying TALL_HAT_SLOTS of tower")
		check(not merchant.can_trade(), "and the merchant is spent")
		_advance(1)

var _recorded_bottom: int = 0
var _recorded_top_id: int = 0
var _recorded_z: float = 0.0

# --- 3. One sale each ---------------------------------------------------------
#
# WITH A FRESH ORDINARY HAT, which is the whole reason this phase resets. Dashing
# in again wearing the trophy from phase 1 would be refused by the TALL rule and
# prove nothing about spent-ness -- two rules, one reading, and the test could not
# say which one answered.

func _phase_spent() -> void:
	if phase_frame == 1:
		_reset(MERCHANT_A)
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 8:
		_recorded_top_id = int(world.hats_worn_by(1)[0].hat_id)
		_dash_at(MERCHANT_A)
		return
	if phase_frame == 30:
		var worn: Array = world.hats_worn_by(1)
		eq(worn.size(), 1, "a second dash into a spent merchant costs nothing")
		eq(int(worn[0].hat_id), _recorded_top_id, "the same hat is still on your head")
		check(not worn[0].is_tall(), "and it is still the ordinary one -- he has "
			+ "nothing left to give")
		_advance(2)

# --- 4. He will not take a tall hat -------------------------------------------

func _phase_refuses_a_tall_hat() -> void:
	if phase_frame == 1:
		_reset(MERCHANT_B)
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 3:
		_give_hat(HatStyle.TALL_FIRST)
		return
	if phase_frame == 8:
		var worn: Array = world.hats_worn_by(1)
		if not eq(worn.size(), 2, "the player wears [ordinary, tall] going in"):
			finish()
			return
		check(worn[1].is_tall(), "with the tall one on top -- the top is what pays")
		_recorded_bottom = int(worn[0].hat_id)
		_recorded_top_id = int(worn[1].hat_id)
		_dash_at(MERCHANT_B)
		return
	if phase_frame == 30:
		var worn: Array = world.hats_worn_by(1)
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_B)
		eq(worn.size(), 2, "he refuses a tall hat and you lose nothing")
		eq(int(worn[0].hat_id), _recorded_bottom, "the same hats, in the same order")
		eq(int(worn[1].hat_id), _recorded_top_id,
			"including the tall one -- you cannot launder one trophy into another")
		# THE HALF THAT MATTERS. A refusal that spends the sale is worse than a
		# refusal that does not work at all: the next player finds an empty
		# shopkeeper and nothing in the game explains why.
		check(merchant.can_trade(),
			"and REFUSING DOES NOT SPEND HIM -- the sale is still there for the "
			+ "next player, who has done nothing wrong")
		_advance(3)

# --- 5. Nothing to pay with ---------------------------------------------------

func _phase_no_hats() -> void:
	if phase_frame == 1:
		_reset(MERCHANT_B)
		return
	if phase_frame == 4:
		eq(world.hats_worn_by(1).size(), 0, "the player is bare going in")
		_recorded_z = a.global_position.z
		_dash_at(MERCHANT_B)
		return
	if phase_frame == 26:
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_B)
		eq(world.hats_worn_by(1).size(), 0,
			"a player with no hats gets nothing: he sells for a hat and there is "
			+ "no other currency")
		check(merchant.can_trade(),
			"and does not spend him either -- a shopkeeper used up by somebody who "
			+ "could not pay is a shopkeeper wasted on nobody")

		# THE COLLIDER, ISOLATED. This is the one dash in the file where the trade
		# does nothing at all, so the body stopping is the mask and the box and
		# nothing else.
		check(a.global_position.z > merchant.global_position.z,
			"and he still STOPS you -- with the trade doing nothing, this reading "
			+ "is the collider on its own (player z %.2f, merchant z %.2f)"
				% [a.global_position.z, merchant.global_position.z])
		check(a.global_position.z < _recorded_z, "having travelled toward him")
		_advance(4)

# --- 6. The control: that merchant can still be cashed ------------------------

func _phase_the_control() -> void:
	if phase_frame == 1:
		_reset(MERCHANT_B)
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 8:
		_dash_at(MERCHANT_B)
		return
	if phase_frame == 30:
		var worn: Array = world.hats_worn_by(1)
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_B)
		# AND THE CONTROL HAS TO BE ABLE TO SUCCEED. Two phases above asserted this
		# merchant was still open; if he had never been able to trade, both would
		# have passed anyway and the file would be green over a dead feature.
		if not eq(worn.size(), 1, "the merchant two refusals left alone still trades"):
			finish()
			return
		check(worn[0].is_tall(), "and hands over a tall hat like the first one did")
		check(not merchant.can_trade(), "and is spent now, having actually sold")
		phase = 5
		phase_frame = 0
		return

# --- 3b. AND A DASH ALONE DOES NOT TRADE ----------------------------------------
#
# THE HALF THIS FILE CANNOT SEE BY ITSELF. Every phase above approaches the
# shopkeeper at speed, because that is still how a player gets to one -- so if
# the dash had gone on doing the selling, not one assertion in the file would
# have moved. The control that makes the change real is a dash with NO press
# behind it.
#
# Same shape as the half-a-gate note in CLAUDE.md: when a rule has two halves,
# test the half nobody would think to write down.
func _phase_a_dash_alone_is_not_a_trade() -> void:
	if phase_frame == 1:
		if world.grid.merchant_at_cell(MERCHANT_C) == null:
			world.grid._spawn_merchant(MERCHANT_C)
		_reset(MERCHANT_C)
		return
	if phase_frame == 2:
		_give_hat()
		return
	if phase_frame == 8:
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_C)
		if not check(merchant != null and merchant.can_trade(),
				"there is an untouched merchant to dash at"):
			finish()
			return
		# THE DASH WITHOUT THE PRESS. `_dash_at` queues both; this is the approach
		# on its own.
		_move = Vector2(0.0, -1.0)
		_dash_pending = true
		return
	if phase_frame == 30:
		var merchant: Node = world.grid.merchant_at_cell(MERCHANT_C)
		var worn: Array = world.hats_worn_by(1)
		print("[merchant] after a dash with no press: %d hats worn, still open %s"
			% [worn.size(), merchant.can_trade()])
		check(a.global_position.z > merchant.global_position.z,
			"the dash really reached him (player z %.2f, merchant z %.2f) -- a "
				% [a.global_position.z, merchant.global_position.z]
			+ "dash that fell short would satisfy the two claims below by missing")
		eq(worn.size(), 1,
			"a dash into him with no press costs nothing (%d hats) -- arriving is "
				% worn.size()
			+ "not buying any more, and every other phase in this file arrives the "
			+ "same way")
		check(merchant.can_trade(),
			"and he is still open, so the sale was not silently burnt either")
		finish()

# --- helpers ------------------------------------------------------------------

# Two cells down-bridge of a merchant, standing still, with an empty head and a
# full dash meter. Down-bridge is +z, so the dash below travels -z into him.
func _reset(cell: Vector2i) -> void:
	world._hats.clear()
	_move = Vector2.ZERO
	_dash_pending = false
	a.global_position = world.grid.cell_surface_world(cell) + Vector3(
		0.0, 1.0, GridConfig.CELL_SIZE)
	a.velocity = Vector3.ZERO
	a.state = PlayerBody.State.WALK
	a.grounded = true
	# The dash has a cooldown AND a charge count, and both bite across phases:
	# five dashes in one test is more than DASH_CHARGES.
	a.shove_cooldown = 0.0
	a.dash_charges = SimConfig.DASH_CHARGES

# WALK INTO HIM, THEN PRESS E. Two actions now, and the split is the change:
# dashing into the shopkeeper used to BE the trade, and it is now just how you
# arrive. The dash is kept because the claim about him being a WALL is measured
# off it -- a body under power has to stop on him -- and because arriving at speed
# is still how a player gets to a merchant in a hurry.
#
# EIGHT TICKS BEHIND. On the tick the dash is issued the body is 2 m away and
# outside USE_REACH; the dash covers that in a fraction of its 0.1 s and then
# stops dead against him.
func _dash_at(_cell: Vector2i) -> void:
	# Straight up-bridge, which is where _reset put him relative to the player.
	_move = Vector2(0.0, -1.0)
	_dash_pending = true
	_use_at_tick = world.tick + 8

# A hat placed on the player, already settled, collected by the ordinary pickup
# pass rather than by hand -- a test that hand-builds its own input has not tested
# the caller, and the caller is usually where the bug is.
func _give_hat(style: int = -1) -> Node:
	return world._hats.spawn_loose(a.global_position, style)
