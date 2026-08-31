extends Node

# Stage 0 of the art bake-off: render the CONTROL IMAGES that every generated
# style is seeded from. See design_ideas/art_direction.md.
#
# THE MANIFEST IS THE ARTEFACT, NOT THE IMAGES. art/shots.json says what to
# render and from where; re-running it six months from now reproduces the same
# framings, which is the only reason a before/after comparison means anything.
#
# THIS CANNOT RUN IN THE GATE. `--headless` disables all rendering, so there is
# no image to save -- and the headless viewport is 64x64 besides. It is a
# WINDOWED run on a dev box, deliberately not a test.
#
# It renders into a SubViewport rather than grabbing the window, so the output
# resolution is whatever the manifest says regardless of the size of the window
# the OS gave us. The window is incidental; the SubViewport is the camera.

const SceneLighting = preload("res://scripts/ui/scene_lighting.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const GunnerBody = preload("res://scripts/sim/gunner_body.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const BridgeCameraScript = preload("res://scripts/ui/bridge_camera.gd")
# Read off the SCRIPT, never off an instance: enum values are script constants,
# and `instance.Enum.VALUE` raises at runtime and silently aborts the rest of
# the function.
const RusherBody = preload("res://scripts/sim/rusher_body.gd")
const BusBody = preload("res://scripts/sim/bus_body.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const RoundMachine = preload("res://scripts/sim/round_machine.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const CharacterStyle = preload("res://scripts/sim/character_style.gd")
const Corpse = preload("res://scripts/sim/corpse.gd")

# How far a body's ORIGIN sits above the deck it is standing on. A manifest's
# `at` y is added on top of this, so 0 means "on the ground" and 2.6 means "2.6 m
# in the air" regardless of how high the bridge is at that point.
const REST_HEIGHT := {
	"player": 0.9,
	"rusher": 0.7,
	"skirmisher": 0.85,
	"turret": 0.45,
	# A bus sits ON the deck: its origin is the underside of its wheels.
	"bus": 0.0,
}
const REST_DEFAULT := 0.6

# Two passes per shot. BEAUTY is what the image model is seeded with; FLAT is
# unshaded albedo, which in a game whose every material is a flat colour is
# also a serviceable colour-ID mask for compositing later.
#
# There is no depth pass yet: nothing in the Gemini path consumes one. It is the
# input the ComfyUI fallback would need, and it goes in on the day that fallback
# is built rather than being carried unused until then.
const PASS_BEAUTY := "beauty"
const PASS_FLAT := "flat"

var _main: Node = null
var _manifest: Dictionary = {}
var _out_dir: String = "res://tmp/shots"
var _viewport: SubViewport = null
var _written: int = 0
var _grid_width: int = GridConfig.DEFAULT_WIDTH

func setup(main: Node, manifest_path: String) -> void:
	_main = main
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		printerr("[SHOTS] cannot open manifest: ", manifest_path)
		get_tree().quit(1)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("[SHOTS] manifest is not a JSON object: ", manifest_path)
		get_tree().quit(1)
		return
	_manifest = parsed
	_out_dir = str(_manifest.get("output_dir", _out_dir))
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_run()

func _run() -> void:
	var studio: Dictionary = _manifest.get("studio", {})
	var items: Array = studio.get("items", [])
	var scenes: Array = _manifest.get("scenes", [])
	var total: int = items.size() + scenes.size()
	print("[SHOTS] manifest: %d studio items, %d scene shots -> %s" % [items.size(), scenes.size(), _out_dir])

	for i in items.size():
		var item: Dictionary = items[i]
		# UNCONDITIONAL heartbeat: nothing about the shot can gate it, so a hang
		# is distinguishable from a slow render.
		print("[SHOTS] %d/%d studio %s" % [i + 1, total, item.get("name", "?")])
		await _render_studio(studio, item)

	for i in scenes.size():
		var shot: Dictionary = scenes[i]
		print("[SHOTS] %d/%d scene %s" % [items.size() + i + 1, total, shot.get("name", "?")])
		await _render_scene(shot)

	print("[SHOTS] wrote %d files to %s" % [_written, _out_dir])
	get_tree().quit(0)

# --- Studio: one element on neutral ground -----------------------------------
#
# No scale prop in frame, deliberately. A metre stick would be restyled along
# with everything else and would come back as a decorated object; the scale
# ticks belong on the contact sheet, where they are HTML and cannot be
# hallucinated.

func _render_studio(studio: Dictionary, item: Dictionary) -> void:
	var size: Vector2i = _size_of(item.get("size", studio.get("size", _manifest.get("size", [1024, 1024]))))
	var stage := _make_viewport(size, true)

	stage.add_child(SceneLighting.build())
	stage.add_child(_ground(float(item.get("ground", 12.0))))

	# A CORPSE INSTEAD OF A SCENE, and the one studio item that is allowed to run.
	#
	# Everything else here is instanced with PROCESS_MODE_DISABLED and photographed
	# where it stands -- a rusher left to run its own frame would charge a target
	# that does not exist. A death animation is the exception, because the thing
	# being photographed IS the running: the pile has to fall for a stated number
	# of seconds before the shutter, or every scattered frame is the intact one.
	#
	# So it gets a real floor as well. _ground() is a MeshInstance with no collider
	# -- fine for a still, and debris dropped onto it would fall forever.
	if item.has("corpse"):
		await _render_corpse(studio, item, stage)
		return

	var scene_path: String = str(item.get("scene", ""))
	var subject: Node3D = null
	if scene_path != "":
		var packed: PackedScene = load(scene_path)
		if packed == null:
			printerr("[SHOTS] cannot load ", scene_path)
			_drop_viewport()
			return
		subject = packed.instantiate()
		# Instanced for its LOOK, not to be simulated: the bodies here have no
		# GameWorld to be driven by, and a rusher left to run its own frame would
		# charge a target that does not exist.
		subject.process_mode = Node.PROCESS_MODE_DISABLED
		stage.add_child(subject)
		subject.rotation_degrees = Vector3(0, float(item.get("yaw", 0.0)), 0)
		subject.position = Vector3(0, float(item.get("lift", 0.0)), 0)
		_dress(subject, item)

	var focus := Vector3(0, float(item.get("focus_y", 0.9)), 0)
	var cam := _camera(studio, item, focus)
	stage.add_child(cam)

	await _capture(item.get("name", "item"))
	_drop_viewport()

# Per-item fiddling that cannot live in the scene file: which special silhouette
# to show, and what colour a player is. The tint is DUPLICATED onto the instance
# -- sub-resources are shared between instances, so tinting in place would
# repaint every copy, which is the same trap special_body.gd documents.
func _dress(subject: Node3D, item: Dictionary) -> void:
	if item.has("special_kind") and subject.has_method("apply_kind_look"):
		subject.kind = int(item["special_kind"])
		subject.apply_kind_look()

	# A CHARACTER, THROUGH ITS OWN apply_look. Not by reaching into the node tree:
	# that function builds the eyes, the nose colour and the accessory together
	# from one seed, and a shot that assembled them by hand would be rendering
	# something no player can ever be wearing.
	#
	# It also runs BEFORE the tint below on purpose -- apply_look installs a
	# per-instance body material, so a tint applied first would be thrown away.
	var dressed_as_character := false
	if (item.has("accessory") or item.has("character_seed")) and subject.has_method("apply_look"):
		var body := CharacterStyle.DEFAULT_BODY
		var chosen: Array = item.get("tint", [])
		if chosen.size() == 3:
			body = Color(chosen[0], chosen[1], chosen[2])
		subject.apply_look(body, int(item.get("character_seed", 1)),
			str(item.get("accessory", CharacterStyle.ACCESSORY_NONE)))
		dressed_as_character = true

	var tint: Array = item.get("tint", [])
	# NOT `return` ABOVE, so an `attach` on a character still runs. An early exit
	# here would have made accessory and hat silently exclusive, which is exactly
	# the kind of "works for the case I tried" that a manifest hides.
	if tint.size() == 3 and not dressed_as_character:
		var node := subject.get_node_or_null(str(item.get("tint_node", "Mesh"))) as MeshInstance3D
		if node != null and node.material_override != null:
			var mat: StandardMaterial3D = node.material_override.duplicate()
			mat.albedo_color = Color(tint[0], tint[1], tint[2])
			node.material_override = mat

	for extra in item.get("attach", []):
		var packed: PackedScene = load(str(extra.get("scene", "")))
		if packed == null:
			continue
		var child: Node3D = packed.instantiate()
		child.process_mode = Node.PROCESS_MODE_DISABLED
		subject.add_child(child)
		child.position = _vec3(extra.get("at", [0, 0, 0]))
		child.rotation_degrees = Vector3(0, float(extra.get("yaw", 0.0)), 0)

# --- Scene: a posed moment in the real world ---------------------------------
#
# Everything is placed EXPLICITLY and captured two frames later. Nothing is
# played until it looks good -- a shot nobody can reproduce is not a control
# image, and the whole point of Stage 0 is that the same manifest gives the same
# frame after the art has changed.

func _render_scene(shot: Dictionary) -> void:
	var world := Node3D.new()
	world.name = "ShotWorld"
	world.set_script(GameWorldScript)
	_main.add_child(world)
	world.segment_paths = [str(shot.get("segment", "res://segments/playtest_bridge.seg"))]
	world.start(true, 1, false)

	# A BRIDGE HAS NO LIGHTING OF ITS OWN -- .seg files describe structure and
	# nothing else -- so an unlit shot comes out as brown silhouettes in a grey
	# void. GameWorld adds a sun only when `view_active`, and we deliberately do
	# not set that: it would also take the local player's saved hat off disk and
	# put it on peer 1, which makes the frame depend on whose machine rendered
	# it. Same lighting rig, added explicitly instead.
	world.add_child(SceneLighting.build())

	# A SHOT THAT CONTAINS A BUS HAS TO BE IN A MODE THAT ALLOWS ONE.
	#
	# The world is RUNNING while it is being photographed, so `_process_buses`
	# takes a tick like everything else -- and a pool that is switched off does
	# not merely decline to build, it CLEARS UP. So a bus placed by the manifest
	# was created, positioned, and freed again before the first frame was drawn,
	# and the shot came back as an empty deck with the riders standing on it.
	# That is the mode system working exactly as designed, arriving somewhere
	# nobody thought about.
	for actor in shot.get("actors", []):
		if str(actor.get("type", "")) == "bus":
			world.round_machine.round_index = 0
			world.round_machine.state = RoundMachine.State.RUNNING
			world.run_modes = [GameMode.BLANK]
			break

	_grid_width = world.grid.width
	# The spawn ring sits at the START of the first segment, where there is no
	# bridge behind you -- framed by the game camera that is half a screen of
	# empty sky. anchor_offset walks the whole shot up-bridge, actors and camera
	# together, so the frame is full of deck.
	var anchor: Vector3 = world.spawn_point(int(shot.get("anchor_spawn", 0))) + _vec3(shot.get("anchor_offset", [0, 0, 0]))
	anchor.y = _deck_y(world, anchor)
	var posed: Array = []
	var focus_body: Node3D = null
	for actor in shot.get("actors", []):
		var node: Node3D = _place_actor(world, actor, anchor)
		if node != null:
			posed.append(node)
			# The game camera frames the LOCAL PLAYER's body, so a shot that
			# framed the deck instead would sit most of a metre low. First player
			# in the manifest stands in for "the local player".
			if focus_body == null and str(actor.get("type", "")) == "player":
				focus_body = node

	# RIDERS LAST. A seat is a function of where the bus ended up, so planting
	# has to come after every actor has been positioned -- doing it inside the
	# bus's own branch would seat everybody at the origin.
	for bus in world._buses:
		if is_instance_valid(bus):
			world._plant_riders(bus)

	var size: Vector2i = _size_of(shot.get("size", _manifest.get("size", [1600, 900])))
	var stage := _make_viewport(size, false)
	_scene_camera(stage, shot, anchor, world, focus_body)

	await _capture(shot.get("name", "shot"))

	_drop_viewport()
	# STOPPED, SILENCED, THEN FREED IMMEDIATELY -- in that order, and not with
	# queue_free(). queue_free() defers to the end of the frame, so the world we
	# have finished with keeps taking physics frames while the NEXT one is being
	# built; its bodies are mid-teardown by then, and `players[peer].carrier`
	# reads a freed instance, which raises on the typed assignment rather than
	# returning null. That spammed the log with a backtrace pointing at
	# _carry_order, which has nothing wrong with it.
	world.stop()
	world.process_mode = Node.PROCESS_MODE_DISABLED
	_main.remove_child(world)
	world.free()

func _scene_camera(stage: Node, shot: Dictionary, anchor: Vector3, world: Node3D, focus_body: Node3D) -> void:
	var offset: Variant = shot.get("camera_offset", null)
	if offset != null:
		# An explicit override, for a shot that deliberately is not the player's
		# view -- an establishing shot, say.
		var free_cam := Camera3D.new()
		free_cam.position = anchor + _vec3(offset)
		stage.add_child(free_cam)
		free_cam.look_at(anchor + _vec3(shot.get("look_offset", [0, 1, 0])), Vector3.UP)
		free_cam.fov = float(shot.get("fov", 55.0))
		return

	# The default, and the one that matters: an ACTUAL BridgeCamera, configured
	# the way GameWorld configures it. Copying its pitch and distance as numbers
	# into this manifest would be two places to change and one of them would get
	# missed -- and a control image framed differently from the game is a control
	# image of something nobody plays.
	var cam := Camera3D.new()
	cam.set_script(BridgeCameraScript)
	cam.bridge_width_cells = _grid_width
	stage.add_child(cam)
	# ITS OWN _physics_process HAS TO BE TURNED OFF, or nothing below sticks: with
	# no focus_target it snaps to `_last_focus`, which is Vector3.ZERO, so every
	# shot came back framed on the origin no matter where the actors were. The
	# symptom was the actors moving up-bridge while the frame did not, which
	# reads as "anchor_offset is not wired up" and is nothing of the kind.
	cam.set_physics_process(false)
	# Positioned by hand rather than by waiting for its _physics_process: this
	# runs between frames, and the camera would otherwise spend the capture
	# lerping toward the party from wherever it started.
	# focus_position() reads focus_target.position -- the player's position in the
	# WORLD's space -- and desired_position() then drops X so the camera rides the
	# centre line. Reproduced exactly, including which space it is in: GameWorld
	# holds its own camera as a child, ours has to live under the SubViewport to
	# render there, so the world's transform is applied by hand instead of by the
	# scene tree.
	var focus: Vector3 = focus_body.position if focus_body != null else anchor + Vector3(0.0, REST_HEIGHT["player"], 0.0)
	focus += _vec3(shot.get("focus_nudge", [0, 0, 0]))
	# Typed out rather than inferred: cam._offset comes off an attached script, so
	# it is a Variant to the parser and `:=` is a parse error on that expression.
	var local: Vector3 = Vector3(0.0, focus.y, focus.z) + cam._offset
	cam.global_transform = world.global_transform * Transform3D(
		Basis.from_euler(Vector3(-deg_to_rad(cam.pitch_deg), 0.0, 0.0)), local)

func _place_actor(world: Node3D, actor: Dictionary, anchor: Vector3) -> Node3D:
	var offset: Vector3 = _vec3(actor.get("at", [0, 0, 0]))
	var kind: String = str(actor.get("type", ""))
	# THE BRIDGE RISES, so a flat y offset from the spawn point buries anything
	# placed up-bridge of it -- which read as "the rushers are tiny" rather than
	# as "the rushers are underground". Every actor is placed on the deck that is
	# actually beneath it, and the manifest's y is height ABOVE that deck.
	var at := Vector3(anchor.x + offset.x, anchor.y, anchor.z + offset.z)
	at.y = _deck_y(world, at) + float(REST_HEIGHT.get(kind, REST_DEFAULT)) + offset.y
	var yaw: float = float(actor.get("yaw", 0.0))
	var node: Node3D = null

	match kind:
		"player":
			var peer: int = int(actor.get("peer", 1))
			world._spawn_player(peer, int(actor.get("spawn_index", peer - 1)))
			node = world.player_body(peer)
			if node != null and actor.has("tint"):
				var tint: Array = actor["tint"]
				var mesh := node.get_node_or_null("Mesh") as MeshInstance3D
				if mesh != null and mesh.material_override != null:
					var mat: StandardMaterial3D = mesh.material_override.duplicate()
					mat.albedo_color = Color(tint[0], tint[1], tint[2])
					mesh.material_override = mat
		"rusher":
			node = world._spawn_rusher(at)
			# A rusher WAKES UNDERGROUND and rises over RUSHER_RISE_SECONDS, so
			# a still captured two frames later is a red tip poking out of the
			# deck -- which reads as "the rusher did not spawn" rather than as
			# "the rusher is still coming up". A posed frame wants the finished
			# telegraph, so put it straight into CHASE standing on the deck.
			if node != null:
				node.state = RusherBody.State.CHASE
				node.state_timer = 0.0
		"bus_post":
			# A post, put down through the grid's own spawner so the shot shows the
			# thing the builder makes rather than a fresh instance posed by hand.
			world.grid._spawn_bus_post(world.grid.cell_of_world(at))
			node = world.grid.bus_posts()[world.grid.bus_posts().size() - 1]
		"mode_post":
			world.grid._spawn_mode_post(world.grid.cell_of_world(at))
			node = world.grid.mode_posts()[world.grid.mode_posts().size() - 1]
		"bus":
			# THE ONE ACTOR THAT IS ABOUT THE OTHER ACTORS. A bus with nobody on it
			# says nothing about the question it exists to answer, which is whether
			# a rider reads as being IN it. So it takes a roster, and the riders
			# are planted after every actor is placed -- see _render_scene, where
			# that has to happen because a seat is a function of where the bus
			# ended up and this runs before the position is applied below.
			node = BusBody.new()
			world.add_child(node)
			node.name = "ShotBus"
			for peer in actor.get("riders", []):
				node.board(int(peer))
			world._buses.append(node)
		"skirmisher":
			node = world._spawn_gunner(at, GunnerBody.Kind.SKIRMISHER)
		"turret":
			node = world._spawn_gunner(at, GunnerBody.Kind.TURRET)
		_:
			# Anything else is a plain scene dropped in at a position: balls,
			# hats, pickups, props. Frozen so a still stays still.
			var packed: PackedScene = load(str(actor.get("scene", "")))
			if packed == null:
				printerr("[SHOTS] unknown actor type '%s' and no scene" % kind)
				return null
			node = packed.instantiate()
			world.add_child(node)

	if node == null:
		return null
	node.global_position = at
	if node is Node3D:
		node.rotation_degrees = Vector3(0, yaw, 0)
	if node is RigidBody3D:
		node.freeze = true
	if node.has_method("set_facing_yaw"):
		node.set_facing_yaw(deg_to_rad(yaw))
	return node

# One corpse, aged by a stated number of seconds of real physics before the
# shutter. `corpse` is {kind, scatter_seconds, burst}: `burst` true photographs
# what a BLAST leaves (scattered from the first frame), false what a bullet
# leaves (a pile standing until something touches it, which in a studio nothing
# ever does).
func _render_corpse(studio: Dictionary, item: Dictionary, stage: Node) -> void:
	var spec: Dictionary = item["corpse"]
	var kinds := {
		"rusher": Corpse.Kind.RUSHER,
		"zombie": Corpse.Kind.ZOMBIE,
		"skirmisher": Corpse.Kind.SKIRMISHER,
		"turret": Corpse.Kind.TURRET,
	}
	var kind_id: int = int(kinds.get(str(spec.get("kind", "rusher")), Corpse.Kind.RUSHER))

	stage.add_child(_studio_floor(float(item.get("ground", 12.0))))

	# LIFTED SO IT STANDS ON THE FLOOR. A corpse is placed at the dead body's
	# ORIGIN, which for every one of these is the middle of the body -- so in the
	# game it is already correct and here it needs the half-height the deck would
	# otherwise have supplied.
	var burst: bool = bool(spec.get("burst", false))
	var corpse: Node3D = Corpse.spawn(stage, kind_id,
		Vector3(0.0, float(item.get("lift", 0.9)), 0.0),
		deg_to_rad(float(spec.get("body_yaw", 0.0))),
		deg_to_rad(float(spec.get("aim_yaw", 0.0))),
		Vector3(0.0, -0.4, 0.0), burst, 12345, int(spec.get("fragments", 0)))
	if corpse == null:
		printerr("[SHOTS] no corpse for kind ", kind_id)
		_drop_viewport()
		return
	if bool(spec.get("scatter", false)) and not burst:
		corpse.scatter(Vector3(0.6, -0.2, 0.4), 1.0)

	var focus := Vector3(0, float(item.get("focus_y", 0.0)), 0)
	var cam := _camera(studio, item, focus)
	stage.add_child(cam)

	# LET IT FALL. Physics frames, not render frames -- the corpse ages on
	# _physics_process like everything else in this game.
	var ticks: int = int(round(float(spec.get("scatter_seconds", 0.0)) * 60.0))
	for _i in range(ticks):
		await get_tree().physics_frame

	await _capture(item.get("name", "corpse"))
	_drop_viewport()

# A COLLIDER FOR THE GROUND THAT IS ALREADY THERE. _render_studio has added the
# _ground() mesh by the time this runs; a still life needs nothing more, and
# debris needs something to land on. Mesh-free on purpose -- two coplanar ground
# planes is z-fighting across the whole frame.
func _studio_floor(extent: float) -> Node3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = "StudioFloor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(extent, 1.0, extent)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(shape)
	return floor_body

# --- Plumbing ----------------------------------------------------------------

func _make_viewport(size: Vector2i, own_world: bool) -> Node:
	_viewport = SubViewport.new()
	_viewport.size = size
	_viewport.transparent_bg = false
	# A studio cell is its own little world; a scene shot has to see the
	# GameWorld that is already standing in the main window's world.
	_viewport.own_world_3d = own_world
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	_main.add_child(_viewport)
	return _viewport

func _drop_viewport() -> void:
	if _viewport != null:
		_viewport.queue_free()
		_viewport = null

func _capture(name: Variant) -> void:
	for pass_name in [PASS_BEAUTY, PASS_FLAT]:
		_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED if pass_name == PASS_BEAUTY else Viewport.DEBUG_DRAW_UNSHADED
		# Two frames, not one: the first is where the viewport is configured and
		# the second is the one that actually contains it.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image: Image = _viewport.get_texture().get_image()
		var path: String = "%s/%s.%s.png" % [_out_dir, str(name), pass_name]
		var err: int = image.save_png(path)
		if err != OK:
			printerr("[SHOTS] save failed (%d): %s" % [err, path])
		else:
			_written += 1

func _camera(studio: Dictionary, item: Dictionary, focus: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	var yaw: float = deg_to_rad(float(item.get("cam_yaw", studio.get("cam_yaw", 35.0))))
	var pitch: float = deg_to_rad(float(item.get("cam_pitch", studio.get("cam_pitch", -26.0))))
	var dist: float = 12.0
	var dir := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
	cam.position = focus + dir * dist
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = float(item.get("ortho_size", studio.get("ortho_size", 3.0)))
	cam.near = 0.1
	cam.far = 100.0
	cam.look_at_from_position(cam.position, focus, Vector3.UP)
	return cam

func _ground(extent: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(extent, extent)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.62, 0.60)
	mat.roughness = 1.0
	var node := MeshInstance3D.new()
	node.name = "StudioGround"
	node.mesh = plane
	node.material_override = mat
	return node

# Top of the deck under a world-space point. The grid is PITCHED, so grid-local
# and world coordinates are not the same thing -- go through the grid's own
# transform both ways rather than assuming they are.
func _deck_y(world: Node3D, at: Vector3) -> float:
	var grid: Node3D = world.grid
	if grid == null:
		return at.y
	var cell: Vector2i = grid.cell_of_world(at)
	# A HOLE HAS NO SURFACE, and a body placed on one is a body dropped into the
	# void -- which renders as a tiny distant speck rather than as an absence, so
	# it reads as "the actor did not spawn". Say so and leave it at party height.
	if not grid.is_solid(cell):
		printerr("[SHOTS] actor at %v is over a hole (cell %v) -- placed at party height instead" % [at, cell])
		return at.y
	return grid.cell_surface_world(cell).y

func _size_of(value: Variant) -> Vector2i:
	var arr: Array = value if typeof(value) == TYPE_ARRAY else [1024, 1024]
	if arr.size() < 2:
		return Vector2i(1024, 1024)
	return Vector2i(int(arr[0]), int(arr[1]))

func _vec3(value: Variant) -> Vector3:
	var arr: Array = value if typeof(value) == TYPE_ARRAY else []
	if arr.size() < 3:
		return Vector3.ZERO
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
