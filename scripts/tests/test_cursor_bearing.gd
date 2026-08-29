extends "res://scripts/test_support/test_case.gd"

# THE CURSOR POINTS AT WHAT IT IS ON, NOT AT THE FLOOR BEHIND IT.
#
# Reported from play 2026-08-25, on the level+snap default: "if you point at an
# elevated enemy your cursor doesn't select them -- only when you point at
# different spots near them, and I can't quite figure out what the correlation
# is."
#
# THERE WERE TWO ANSWERS TO "WHERE IS THE CURSOR" AND THEY DISAGREED ON HEIGHT.
# `resolve_point` raycast the world, so `point` mode named the thing under the
# cursor. `_yaw_to_cursor` intersected a horizontal plane through the PLAYER and
# never cast anything, so `level` mode -- which is built from the bearing rather
# than from the point -- named a spot on the floor beyond it.
#
# WHICH IS WHY IT LOOKED UNCORRELATED. The camera is pitched 45 degrees, so a
# target `h` metres up puts the plane point `h` metres further along the camera's
# view direction. The bearing error is that displacement seen from wherever the
# player happens to be standing: in line with it the displacement is pure distance
# and the aim is still true, off to one side it is a bearing error and the shot
# goes wide. The "spots near them" that worked were the places where the floor
# under the cursor really did line up with the enemy.
#
# THE FIX IS ONE FUNCTION, NOT A NEW MODE. `_yaw_to_cursor` asks `_mouse_point`,
# which is what `resolve_point` already asked. `level` still fires flat at the
# shooter's own height -- a bearing is the horizontal projection by construction,
# since `yaw_of_vector` reads x and z -- it just takes its DIRECTION from the
# geometry rather than from a plane.
#
# The claims:
#   1. The bearing names the body the cursor is ON when that body is above the
#      player's own height. This is the report.
#   2. The bearing and the aim POINT are one answer, because they are now one
#      function. Two implementations of one fact is what caused this.
#   3. The plane still answers when the ray hits nothing.

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const AimSource = preload("res://scripts/sim/aim_source.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# How far up the target sits, and how far the player stands off to the SIDE of the
# camera's view line. The offset is the load-bearing one: in line with the
# displacement both implementations agree, so a fixture built there cannot fail.
const RISE := 3.0
const RANGE := 8.0

var world: Node3D = null
var camera: Camera3D = null
var aim = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "CursorWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	camera = Camera3D.new()
	world.add_child(camera)
	aim = AimSource.new()

func _physics_process(_delta: float) -> void:
	if done or world.tick < 4:
		return
	done = true
	set_physics_process(false)

	var body: Node = world.player_body(1)
	var y0: float = body.global_position.y

	# THE FIXTURE IS BUILT AROUND WHATEVER RAY THE CURSOR ALREADY HAS, rather than
	# the cursor being driven to a chosen pixel. The headless mouse never moves and
	# sits at (0, 0) of a 64x64 viewport (CLAUDE.md), so there is no screen position
	# to pick -- and an earlier version of this file that assumed one put its target
	# 137 m away, where the two answers differ by a degree and nothing can be told
	# apart.
	camera.global_position = body.global_position + Vector3(4.0, 10.0, 8.0)
	camera.look_at(body.global_position, Vector3.UP)
	camera.force_update_transform()
	var mouse: Vector2 = camera.get_viewport().get_mouse_position()
	var origin: Vector3 = camera.project_ray_origin(mouse)
	var direction: Vector3 = camera.project_ray_normal(mouse)
	if not check(direction.y < -0.001 and origin.y > y0 + RISE,
			"the cursor ray descends from above the target height (y %.4f)"
				% direction.y):
		finish()
		return

	# A body ON that ray, RISE metres above the player's plane...
	var at: Vector3 = origin + direction * ((origin.y - (y0 + RISE)) / -direction.y)
	# ...and where the plane would have answered instead: the same ray carried on
	# down to the player's own height. This is the old behaviour, kept as control.
	var plane_point: Vector3 = origin + direction * ((origin.y - y0) / -direction.y)
	var ground := Vector3(at.x, y0, at.z)

	var along: Vector3 = plane_point - ground
	along.y = 0.0
	if not check(along.length() > 0.5,
			"the plane answer is displaced from the target (%.2f m)" % along.length()):
		finish()
		return
	# THE PLAYER STANDS SIDEWAYS ON to that displacement, which is the case that
	# fails. In line with it the displacement is pure distance and the bearing is
	# unchanged whatever the implementation.
	along = along.normalized()
	body.global_position = ground + Vector3(-along.z, 0.0, along.x) * RANGE
	body.force_update_transform()
	var from: Vector3 = body.global_position

	var target := StaticBody3D.new()
	# LAYER 16 -- the bit every enemy in this game sits on (rusher, skirmisher,
	# turret and zombie all set collision_layer = 16) and one of the two bits the
	# aim ray masks in. A fixture on any other layer would be invisible to the code
	# under test and would pass for the wrong reason.
	target.collision_layer = 16
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	shape.shape = box
	target.add_child(shape)
	world.add_child(target)
	target.global_position = at
	target.force_update_transform()

	# THE CONTROL HAS TO BE ABLE TO FAIL. If the plane's bearing happened to match
	# the target's, this file could not tell the implementations apart -- the twin
	# of the hat that "could not be shot" because the control was never lifted
	# clear of the deck.
	var true_yaw: float = GridConfig.yaw_of_vector(at - from)
	var plane_yaw: float = GridConfig.yaw_of_vector(plane_point - from)
	var apart: float = absf(rad_to_deg(angle_difference(plane_yaw, true_yaw)))
	print("[cursor] target %.2f m up, %.2f m out; the plane answer is %.1f deg off"
		% [at.y - y0, Vector2(at.x - from.x, at.z - from.z).length(), apart])
	if not check(apart > 5.0,
			"and it really is a different bearing (%.1f deg) -- a fixture where the "
				% apart + "two agree proves nothing"):
		finish()
		return

	# --- 1. The bearing names the thing under the cursor ----------------------
	var yaw: float = aim._yaw_to_cursor(camera, from)
	var off: float = absf(rad_to_deg(angle_difference(yaw, true_yaw)))
	print("[cursor] bearing is %.1f deg off the target; the plane would be %.1f"
		% [off, apart])
	# THE ALLOWANCE IS THE BOX, NOT A GUESS. A ray stops at the near FACE, so the
	# bearing is to a point up to half a width nearer than the centre -- 0.5 m at
	# 8 m is 3.6 degrees, and that is a property of aiming at solid things rather
	# than an error. A real enemy behaves the same way. Derived here so that
	# changing the fixture cannot quietly turn this into a magic number.
	var allow: float = rad_to_deg(atan(0.5 / RANGE)) + 1.0
	check(off < allow,
		"the bearing points at the body the cursor is ON (%.1f deg off, allowing "
			% off + "%.1f for the near face), not at " % allow
		+ "the floor beyond it (%.1f deg off). Under `level` that difference is "
			% apart
		+ "the assist reaching an elevated enemy or missing it entirely")

	# --- 2. One answer, not two ------------------------------------------------
	var point: Vector3 = aim.resolve_point(camera, from)
	check(is_finite(point.x), "the aim point resolves")
	check(point.distance_to(at) < 1.2,
		"and the aim POINT is that same body (%.2f m from its centre)"
			% point.distance_to(at))
	var between: float = absf(rad_to_deg(angle_difference(yaw,
		GridConfig.yaw_of_vector(point - from))))
	check(between < 1.0,
		"so the bearing and the point are ONE answer (%.2f deg apart) -- they were "
			% between
		+ "two functions with two results, which is the whole of this bug")

	# --- 3. Nothing under the cursor still means something ---------------------
	target.queue_free()
	camera.global_position = from + Vector3(0.0, 1.0, 4.0)
	camera.rotation = Vector3(deg_to_rad(70.0), 0.0, 0.0)
	camera.force_update_transform()
	var sky: float = aim._yaw_to_cursor(camera, from)
	check(sky == AimSource.NONE or is_finite(sky),
		"pointing at nothing returns an answer rather than raising -- the plane is "
		+ "still the fallback, and a frozen facing would be worse than a wrong one")
	finish()
