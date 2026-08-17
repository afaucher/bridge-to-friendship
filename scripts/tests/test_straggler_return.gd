extends "res://scripts/test_support/test_case.gd"

# WHERE A STRAGGLER IS PUT WHEN THE ROUND CLOSES ON THEM.
#
# Reported from playtest 2026-08-15: the second player was left behind, and when
# the round closed they were teleported OFF THE SIDE OF THE BRIDGE, hanging on
# the outside of the wall.
#
# So this prints the whole chain rather than guessing at it -- which corridor the
# machine thinks it is in, the cell _lobby_point resolves to, whether that cell is
# solid, the point handed to respawn_at, and where the body actually ended up and
# in what state.
#
# ON A REAL ASSEMBLED RUN, because the fixtures are solid everywhere and the
# thing being reported is a body landing somewhere there is no deck.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const RUN_SEED := 20260815

# Two of Godot's own shape -- big, random, and nothing like 2.
const PEER_B := 874231905
const PEER_C := 231907744

var world: Node3D = null
var a: CharacterBody3D = null
var b: CharacterBody3D = null
var c: CharacterBody3D = null
var frames: int = 0
var reported: bool = false
var dropped: bool = false
var hurt: bool = false

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "StragglerWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.assemble_run = true
	world.run_seed = RUN_SEED
	world.start(true, 1, false)
	# REALISTIC PEER IDS. Godot's multiplayer hands out large random ints, and
	# locally they are 1 and 2 -- which is exactly why this bug survived a local
	# playtest of the machine and appeared the first time somebody played it over
	# a network.
	world._spawn_player(1, 0)
	world._spawn_player(PEER_B, 1)
	world._spawn_player(PEER_C, 2)
	a = world.player_body(1)
	b = world.player_body(PEER_B)
	c = world.player_body(PEER_C)
	for peer in [1, PEER_B, PEER_C]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)

func machine():
	return world.round_machine

func _park(body: CharacterBody3D, x: int, row: int) -> void:
	body.position = world.grid.cell_surface_world(Vector2i(x, row)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO

func _physics_process(_delta: float) -> void:
	if a == null or world.tick == 0 or reported:
		return
	frames += 1

	# Open the round: both onto the lobby's exit band.
	if machine().state == RoundMachine.State.LOBBY and frames > 4:
		if machine().target_row < 0:
			return
		_park(a, 4, machine().target_row)
		_park(b, 8, machine().target_row)
		_park(c, 11, machine().target_row)
		return

	# A alone reaches the far band. B is LEFT BEHIND, deliberately, in the middle
	# of the section -- which is the reported case.
	if machine().state == RoundMachine.State.RUNNING and frames > 8:
		if machine().target_row < 0:
			return
		_park(a, 5, machine().target_row)
		return

	# HURT EVERYBODY BEFORE THE ROUND ENDS, so "full health in the lobby" is a
	# claim with something to prove -- a rig that never takes damage cannot tell a
	# heal from a body that was never hit. A is the one who REACHES the strip,
	# which is the case that used to keep its damage: the straggler loop skips
	# anybody who made it.
	#
	# IN CLOSING, NOT RUNNING: the RUNNING branch below parks A on the strip and
	# RETURNS, so a block after it never runs -- which is how the first version of
	# this managed to assert on a party that had never been hit.
	if machine().state == RoundMachine.State.CLOSING and not hurt:
		hurt = true
		a.health = 2
		b.health = 2
		c.health = 2

	if machine().state == RoundMachine.State.CLOSING:
		# THE STATE A REAL STRAGGLER IS IN. Standing on the deck was the first
		# version of this and it lands fine -- the reported case is somebody who
		# went over the edge and is on the drone timer when the window expires,
		# which is by far the commonest way to be left behind.
		# TWO stragglers, which is the case that matters: one lands wherever the
		# lane maths says, and two land in the SAME PLACE if it says the same
		# thing twice.
		machine().close_timer = minf(machine().close_timer, 0.05)
		return

	if machine().state != RoundMachine.State.SCORING:
		return

	reported = true
	var grid: Node = world.grid
	print("[straggler] rear=%d target=%d" % [machine().rear_row, machine().target_row])
	for peer in [PEER_B, PEER_C]:
		var body: Node = world.player_body(peer)
		print("[straggler] peer %d -> lane cell %s, ended at cell %s state %d"
			% [peer, grid.entry_spawn_cell(peer), grid.cell_of_world(body.position),
				body.state])

	# THE LANE MATHS TAKES AN INDEX, NOT A PEER ID. entry_spawn_cell computes
	# `width/2 - 3 + index*2` and clamps -- so any peer id above about nine
	# resolves to the outermost column, and EVERY straggler resolves to the SAME
	# one.
	check(grid.entry_spawn_cell(PEER_B) != grid.entry_spawn_cell(PEER_C),
		"two stragglers get two different lanes (%s vs %s)"
			% [grid.entry_spawn_cell(PEER_B), grid.entry_spawn_cell(PEER_C)])

	# WHICH IS THIS PROJECT'S OLDEST TRAP. Two perfectly coincident bodies
	# depenetrate into a degenerate normal and are driven DOWN THROUGH THE FLOOR
	# (CLAUDE.md) -- and on the way past the deck the ledge catch grabs the lip,
	# which is "hanging off the outside of the bridge".
	check(b.position.distance_to(c.position) > 0.5,
		"and are not stacked on each other (%.2f m apart)"
			% b.position.distance_to(c.position))
	for peer in [PEER_B, PEER_C]:
		var body: Node = world.player_body(peer)
		check(body.state != PlayerBody.State.LEDGE_HANG,
			"a straggler is STANDING in the lobby, not hanging off the side of it")
		check(grid.is_solid(grid.cell_of_world(body.position)),
			"on solid deck (cell %s)" % grid.cell_of_world(body.position))

	# FULL HEALTH, BY EVERY ROUTE INTO THE LOBBY, AND AT THE MOMENT THE ROUND ENDS.
	#
	# All three were on 2 when the round closed. The four ways in used to give four
	# answers -- keep your damage if you reached the strip, one hit point if you
	# were a straggler, full from a wipe, and everybody topped up ten seconds later
	# when the lobby state opened. The cost of a lost round is the GROUND, which the
	# return already takes back.
	#
	# ASSERTED DURING SCORING ON PURPOSE. The board is up and the party is already
	# standing in the lobby; waiting for the LOBBY state would pass against the old
	# build, because `_restock_lobby` healed them then and always did.
	check(hurt, "the rig really damaged the party first")
	eq(a.health, SimConfig.MAX_HEALTH,
		"the player who REACHED the strip is on full health in the lobby -- the "
		+ "straggler loop skips anyone who made it, so this is the route that used "
		+ "to arrive still hurt")
	for peer in [PEER_B, PEER_C]:
		eq(world.player_body(peer).health, SimConfig.MAX_HEALTH,
			"and so is a straggler, rather than the single hit point REVIVE_HEALTH "
			+ "used to give them")
	finish()
