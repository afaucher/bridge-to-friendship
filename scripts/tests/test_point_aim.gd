extends "res://scripts/test_support/test_case.gd"

# M20: AIMING AT A POINT, AND THE CONTROL SURVIVING IT.
#
# The whole milestone is an A/B, so the first duty of this file is the boring
# half: with the knobs off, a shot leaves exactly as flat as it always has. An A/B
# whose control has drifted proves nothing, and "the tests still pass" is not the
# same claim -- none of them measured the PITCH of a round, because until now
# there was never any.
#
# Everything is asked of `aim_direction`, which is the one function the round, the
# rocket, the laser sight and the barrel all use. That is deliberate: a test that
# re-derived the direction would be checking its own arithmetic.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PEER := 9

var world: Node3D = null
var body: CharacterBody3D = null
var weapon: Node = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "PointAimWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_stats.seg"]
	world.start(true, 1, false)
	world._spawn_player(PEER, 0)
	body = world.player_body(PEER)
	body.position = world.grid.cell_surface_world(Vector2i(7, 2)) + Vector3(0.0, 1.0, 0.0)
	body.facing = 0.0
	world.scripted_inputs[PEER] = func(t: int) -> Array:
		return PlayerInput.empty(t)

func _arm() -> void:
	for s in world._specials.all():
		world._specials.destroy(s)
	weapon = world._specials.spawn_loose(body.position, SpecialBody.Kind.MACHINE_GUN)
	weapon.hold(PEER)
	weapon.fire_timer = 0.0
	world._pose_held_special(weapon, body)

func _mode(aim: String, assist: String) -> void:
	DebugSettings.set_choice("aim_mode", ["level", "point"].find(aim))
	DebugSettings.set_choice("aim_assist", ["off", "snap"].find(assist))

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < 4:
		return
	done = true
	_arm()

	_test_the_control_is_level()
	_test_point_mode_has_pitch()
	_test_point_mode_kills_the_muzzle_offset()
	_test_snap_takes_a_close_shot()
	_test_snap_leaves_a_deliberate_ground_shot_alone()
	_mode("level", "off")
	finish()

# --- The control -----------------------------------------------------------------

func _test_the_control_is_level() -> void:
	_mode("level", "off")
	# A POINT ON THE WIRE THAT LEVEL MODE MUST IGNORE. If the control ever starts
	# reading it, this is where it shows up -- and it is the assertion the whole
	# A/B rests on, because a drifted control makes the comparison meaningless.
	body.aim_point = body.global_position + Vector3(0.0, 8.0, -10.0)
	var direction: Vector3 = world.aim_direction(body, weapon)

	check(absf(direction.y) < 0.02,
		"with the knobs OFF a shot still leaves flat (y %.4f) -- an aim point on "
			% direction.y
		+ "the wire changes nothing, which is what makes the A/B a comparison "
		+ "rather than two different games")
	# AND STILL POINTS DOWN-BRIDGE. Flat is not enough on its own: a direction of
	# zero is also flat.
	check(direction.z < -0.9,
		"and still points where the body is facing (z %.3f)" % direction.z)

# --- Point mode ------------------------------------------------------------------

func _test_point_mode_has_pitch() -> void:
	_mode("point", "off")
	var high: Vector3 = body.global_position + Vector3(0.0, 6.0, -12.0)
	body.aim_point = high
	var up: Vector3 = world.aim_direction(body, weapon)
	check(up.y > 0.3,
		"aiming at a point above you tilts the shot UP (y %.3f) -- which is the "
			% up.y
		+ "whole feature: a skirmisher two decks up was unshootable")

	body.aim_point = body.global_position + Vector3(0.0, -5.0, -12.0)
	var down: Vector3 = world.aim_direction(body, weapon)
	check(down.y < -0.25,
		"and a point below you tilts it DOWN (y %.3f)" % down.y)

# --- The rocket complaint --------------------------------------------------------

func _test_point_mode_kills_the_muzzle_offset() -> void:
	# THE MEASUREMENT THAT MOTIVATED THE MILESTONE. The gun is held 0.22 m to one
	# side and both weapons converge on a zero 30 m away, so at rocket range the
	# round is still ~20 cm off the line the player drew. Measured before this
	# change: 21.7 cm at 1 m, 17.6 cm at 6.5 m -- four centimetres of correction
	# across the only metres a rocket ever flies.
	var target: Vector3 = body.global_position + Vector3(0.0, 0.0, -5.0)
	var muzzle: Vector3 = world._muzzle_of(weapon, body)

	_mode("level", "off")
	var level_miss: float = _miss(muzzle, world.aim_direction(body, weapon), target)

	_mode("point", "off")
	body.aim_point = target
	var point_miss: float = _miss(muzzle, world.aim_direction(body, weapon), target)

	print("[point aim] at 5 m the shot misses the aim point by %.1f cm in level "
		% (level_miss * 100.0) + "mode and %.1f cm in point mode"
		% (point_miss * 100.0))
	check(level_miss > 0.1,
		"level mode really does miss a close target by the muzzle offset (%.1f cm)"
			% (level_miss * 100.0))
	check(point_miss < 0.01,
		"and point mode puts the round THROUGH the point instead (%.2f cm) -- the "
			% (point_miss * 100.0)
		+ "zero becomes the target, so the offset is corrected at the range the "
		+ "shot is actually taken rather than only at thirty metres")

# How far the shot passes from `target`, measured perpendicular to its path.
func _miss(from: Vector3, along: Vector3, target: Vector3) -> float:
	var offset: Vector3 = target - from
	return (offset - along * offset.dot(along)).length()

# --- The assist -------------------------------------------------------------------

func _test_snap_takes_a_close_shot() -> void:
	var enemy: Node = _spawn_enemy(body.global_position + Vector3(0.4, 0.0, -6.0))
	_mode("point", "off")
	# Aimed at the ground just past the enemy, off to one side of it -- inside the
	# snap radius but NOT at it.
	body.aim_point = body.global_position + Vector3(0.0, 0.0, -8.0)
	var without: Vector3 = world.aim_direction(body, weapon)

	_mode("point", "snap")
	var with_assist: Vector3 = world.aim_direction(body, weapon)
	check(_miss(world._muzzle_of(weapon, body), with_assist, enemy.global_position)
			< _miss(world._muzzle_of(weapon, body), without, enemy.global_position),
		"snap pulls a near-miss onto the enemy's centre of mass")
	world._gunners.erase(enemy)
	enemy.queue_free()

func _test_snap_leaves_a_deliberate_ground_shot_alone() -> void:
	var enemy: Node = _spawn_enemy(body.global_position + Vector3(4.0, 0.0, -6.0))
	_mode("point", "snap")
	# WELL AWAY FROM IT. Pointing at the ground near something slow is the correct
	# play for an area weapon -- a rocket is easier to land behind a rusher than on
	# one -- and a generous bubble would drag this shot onto the target and quietly
	# delete the decision. This is the assertion that keeps the radius honest.
	var ground: Vector3 = body.global_position + Vector3(0.0, 0.0, -6.0)
	body.aim_point = ground
	var direction: Vector3 = world.aim_direction(body, weapon)
	check(_miss(world._muzzle_of(weapon, body), direction, ground) < 0.01,
		"and a shot deliberately aimed at open ground four metres from an enemy "
		+ "still goes to the ground -- the bubble is one body width, not a cone")
	world._gunners.erase(enemy)
	enemy.queue_free()

func _spawn_enemy(at: Vector3) -> Node:
	var enemy: Node = preload("res://scenes/skirmisher.tscn").instantiate()
	world.add_child(enemy)
	enemy.global_position = at
	world._gunners.append(enemy)
	return enemy
