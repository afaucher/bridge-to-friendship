extends "res://scripts/test_support/test_case.gd"

# M12. The special slot: taking one, and the one-slot rule.
#
# The claims:
#   1. Walking over a special takes it.
#   2. ONE SLOT. Walking over a second while holding one SWAPS: the new one is
#      held, the old one is dropped where you stand, and the dropped one KEEPS ITS
#      REMAINING AMMO. That last part is what makes a half-spent weapon on the
#      deck a real decision instead of litter.
#   3. A TUMBLING player takes none. Collecting mid-tumble removes the cost of the
#      tumble, which is the same rule hats follow.
#   4. Going DOWNED (or hanging off a ledge) DROPS it on the deck. You need both
#      hands, and a weapon held hostage while your friends come for you is the
#      worst version of being out of the game. Dropped, not destroyed — it is a
#      reason for somebody to walk over, and it is contestable while you are out.
#   5. Falling out of the world DESTROYS what you were holding. Not dropped where
#      you went over: that would rescue the one failure the design does not
#      rescue, and leave a free weapon at the spot that just killed you.
#
# CLAIM 2 IS THE ONE CARRYING THE DESIGN. "Carrying one special is not carrying
# any other" is the whole balance of the category per game_concept.md §Special --
# a slot that silently accepted a second weapon would make the rule a comment.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var a: CharacterBody3D = null
# STANDING SAFELY ON THE DECK, AND LOAD-BEARING. A solo player leaving the world
# is the whole party being out, which is a WIPE -- and a wipe clears every special
# in existence, so phase 4 would report "the weapon is gone" whether or not the
# fall rule exists at all. Caught by A/B: with destroy_held_special removed, the
# one-player version of this test still passed. Exactly the trap test_hat_tumble
# hit, which is why it is worth writing down twice.
var b: CharacterBody3D = null
var phase: int = 0
var phase_frame: int = 0
var recorded: Dictionary = {}

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "SpecialWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 3)
	a = world.player_body(1)
	b = world.player_body(2)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0:
		return
	phase_frame += 1
	match phase:
		0: _phase_walk_over_one()
		1: _phase_one_slot()
		2: _phase_tumbling_takes_none()
		3: _phase_going_down_drops_it()
		4: _phase_falling_destroys_it()

func _advance(next: int) -> void:
	phase = next
	phase_frame = 0

# --- 1. Taking one --------------------------------------------------------------

func _phase_walk_over_one() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		recorded["first"] = _drop_at(a.position)
		return
	if phase_frame == 5:
		var held: Node = world.special_held_by(1)
		check(held != null, "walking over a special takes it")
		eq(held, recorded["first"], "and it is the one that was lying there")
		eq(held.mode, SpecialBody.Mode.HELD, "the special knows it is held")
		eq(held.ammo, SimConfig.MG_AMMO, "and arrives loaded")
		_advance(1)

# --- 2. One slot ----------------------------------------------------------------

func _phase_one_slot() -> void:
	if phase_frame == 1:
		# Spend some of the held weapon by hand, so the swap has a number to carry
		# that is not the full magazine -- a test where both weapons are full
		# cannot tell "kept its ammo" from "reset to full".
		world.special_held_by(1).ammo = 17
		return
	if phase_frame == 2:
		recorded["second"] = _drop_at(a.position)
		return
	if phase_frame == 8:
		var held: Node = world.special_held_by(1)
		eq(held, recorded["second"], "walking over a second special swaps to it")

		# ONE SLOT, MEASURED RATHER THAN ASSUMED: count every special this peer
		# holds, not just the one the lookup happens to return first.
		var holding: int = 0
		for s in world._specials.all():
			if is_instance_valid(s) and s.mode == SpecialBody.Mode.HELD and s.owner_peer == 1:
				holding += 1
		eq(holding, 1, "and holds exactly ONE -- carrying one is not carrying another")

		var dropped: Node = recorded["first"]
		check(is_instance_valid(dropped), "the old one still exists")
		check(dropped.mode != SpecialBody.Mode.HELD, "and is no longer in anyone's hands")
		eq(dropped.ammo, 17, "dropped with the rounds it had left, not reset")
		check(dropped.position.distance_to(a.position) > 0.05,
			"and dropped clear of the body -- two bodies at one point fall through the floor")
		_advance(2)

# --- 3. A tumbling player takes nothing -----------------------------------------

func _phase_tumbling_takes_none() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		_drop_at(a.position + Vector3(0.0, 0.0, -0.2))
		# Tumble AFTER it is down, so the only difference from phase 1 is the state
		# the player is in.
		a.begin_tumble(Vector3(0.0, 1.0, 0.0))
		return
	if phase_frame == 20:
		eq(a.state, PlayerBody.State.TUMBLE, "the player is tumbling")
		check(world.special_held_by(1) == null,
			"and rolls over a special without collecting it")
		_advance(3)

# --- 4. Going down puts it on the deck -------------------------------------------
#
# Asked for in playtest. TUMBLE keeps it and LEDGE_HANG and DOWNED do not, and the
# line between them is the point: a tumble is being knocked about, and a tool that
# leaves your hand every time a plinko ball connects is never in your hand during
# the only fight it is for. Hanging and downed are being out of the game, and
# holding the only weapon on the bridge hostage while your friends come for you is
# the worst version of that.
#
# DROPPED, NOT DESTROYED. The weapon lying beside a downed player is a reason for
# somebody to walk over -- and it is contestable while they are out, which is the
# good version of this.

func _phase_going_down_drops_it() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		_drop_at(a.position)
		return
	if phase_frame == 6:
		check(world.special_held_by(1) != null, "armed")
		# Straight to DOWNED. Getting there through five hits is test_rescue's job;
		# what is pinned here is what ENTERING the state does to the slot.
		a.begin_downed()
		return
	if phase_frame == 10:
		eq(a.state, PlayerBody.State.DOWNED, "the player is down")
		check(world.special_held_by(1) == null, "and is no longer holding their special")
		eq(world.special_count(), 1, "which is on the deck rather than destroyed")
		_advance(4)

# --- 5. Falling takes it with you ------------------------------------------------

func _phase_falling_destroys_it() -> void:
	if phase_frame == 1:
		_clear()
		_park(Vector2i(25, 9))
		_drop_at(a.position)
		return
	if phase_frame == 6:
		check(world.special_held_by(1) != null, "armed again")
		eq(world.special_count(), 1, "with one special in the world")
		# Straight out of the bottom of the world. The drone-return path is what
		# notices, and it is the path that must not leave a free weapon behind.
		a.position = Vector3(a.position.x, SimConfig.FALL_KILL_Y - 5.0, a.position.z)
		return
	if phase_frame == 30:
		check(world.special_held_by(1) == null, "falling out of the world takes it with you")
		eq(world.special_count(), 0,
			"destroyed rather than dropped -- no free weapon at the spot that killed you")
		finish()

# --- helpers --------------------------------------------------------------------

func _park(cell: Vector2i) -> void:
	_park_body(a, cell)
	# Well clear: b must not win a pickup contest a is supposed to win, and must
	# not be dragged off the deck by the leash while a is falling.
	_park_body(b, Vector2i(cell.x + 4, cell.y))

func _park_body(body: CharacterBody3D, cell: Vector2i) -> void:
	body.position = world.grid.cell_surface_world(cell) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	body.state = PlayerBody.State.WALK
	body.grounded = true
	body.health = SimConfig.MAX_HEALTH

func _clear() -> void:
	world._specials.clear()

# Placed already settled, so it is collectable this instant.
func _drop_at(at: Vector3) -> Node:
	return world._specials.spawn_loose(at)
