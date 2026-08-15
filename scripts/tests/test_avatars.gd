extends "res://scripts/test_support/test_case.gd"

# Steam profile pictures in the HUD.
#
# EVERY ASSERTION HERE IS ABOUT A RELATIONSHIP, NEVER ABOUT A VALUE, and the
# first draft of this file is why. It demanded that our Steam id be 0 and that
# every portrait be hidden -- true on CI, false on a dev box with Steam running,
# which is exactly the failure CLAUDE.md records for display names. It passed the
# gate and failed the moment it ran beside a Steam client.
#
# A dev box HAS Steam and the gate does not. So whether a picture exists is an
# ENVIRONMENT fact and cannot be asserted in either direction. What can be
# asserted is that the code does the same correct thing in both worlds:
#
#   1. A Steam id reaches the HUD model, for yourself and for every friend -- and
#      it is the id NetworkManager reports, whatever that happens to be. That is
#      the whole publish path in one comparison. The id is published rather than
#      the picture because an avatar is a 64x64 image and cannot go on the
#      snapshot wire, while an id is a number and every machine that can see a
#      player already has their picture in Steam's own cache.
#   2. ASKING FOR AN AVATAR ANSWERS NULL OR A TEXTURE, AND NEVER RAISES. This is
#      the assertion that catches the obvious implementation -- calling Steam.*
#      from the HUD, which crashes on a machine with no client.
#   3. EVERY PORTRAIT SLOT IS SHOWN EXACTLY WHEN IT HAS A PICTURE. Not "hidden",
#      which is only true on CI: the invariant is that visibility tracks content,
#      so the layout is identical either way and a machine without Steam has the
#      same HUD minus faces rather than a degraded one.
#
# WHAT IS NOT COVERED, named rather than glossed: the id crossing the WIRE. With
# no Steam every id is 0, so a net test would assert 0 == 0 and prove nothing. The
# path is the one `player_names` already uses and is exercised by
# `test_hud_roster`; the id rides beside the name in the same dictionary and the
# same RPC.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const HudModel = preload("res://scripts/ui/hud_model.gd")
const HudScript = preload("res://scripts/ui/hud.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

var world: Node3D = null
var hud: CanvasLayer = null
var frames: int = 0

func setup(main) -> void:
	timeout_seconds = 20.0
	world = Node3D.new()
	world.name = "AvatarWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	world._spawn_player(2, 1)
	world.scripted_inputs[1] = func(t: int) -> Array:
		return PlayerInput.empty(t)
	world.scripted_inputs[2] = func(t: int) -> Array:
		return PlayerInput.empty(t)

	# THE REAL HUD, really built. Headless constructs the whole Control tree and
	# simply does not draw it, so this executes every line that touches a
	# TextureRect -- which is the point, since a view script the gate never
	# instantiates ships having never run once.
	hud = CanvasLayer.new()
	hud.set_script(HudScript)
	hud.world = world
	main.add_child(hud)

func _physics_process(_delta: float) -> void:
	frames += 1
	if frames < 6:
		return

	# --- 1. The id reaches the model ----------------------------------------
	var model: Dictionary = HudModel.build(world)
	check(model.get("active", false), "the HUD model is live")
	var own: Dictionary = model["own"]
	check(own.has("steam_id"), "your own row carries a Steam id")
	var friends: Array = model["friends"]
	check(friends.size() > 0, "and there is a friend to carry one too")
	if friends.size() > 0:
		check(friends[0].has("steam_id"), "a friend's row carries one as well")

	check(typeof(own.get("steam_id")) == TYPE_INT,
		"and it is an id rather than a name or a texture")

	# THE ID CAME FROM NetworkManager, which is the whole publish path in one
	# assertion -- and it holds on ANY machine. Asserting the VALUE (0, or some
	# particular account) would be asserting the environment, which is the trap
	# this test fell into on its first run: it demanded 0 and this dev box has a
	# Steam client, so it passed on CI and failed here. Assert the RELATIONSHIP.
	eq(int(own["steam_id"]), NetworkManager.steam_id_of_self(),
		"and it is OUR id, taken from NetworkManager rather than invented")

	# --- 2 and 3. No Steam is the ordinary case, not an error ----------------
	#
	# The call that would crash if the HUD reached past NetworkManager into Steam.*
	# on a machine with no client. Null OR a texture are both correct answers --
	# which one you get is an environment fact. That it never raises is the rule.
	var face: Variant = NetworkManager.steam_avatar(NetworkManager.steam_id_of_self())
	check(face == null or face is Texture2D,
		"asking for an avatar answers null or a texture, and never raises")

	# THE HUD IS THE SAME HUD EITHER WAY. Every slot exists, and each one is shown
	# exactly when it has something to show -- no gap in the layout, no
	# placeholder, nothing laid out differently on a machine without Steam.
	var faces: Array = _faces(hud)
	check(faces.size() > 0,
		"the HUD really built avatar slots (%d of them)" % faces.size())
	var shown := 0
	for f in faces:
		if f.visible != (f.texture != null):
			check(false, "a slot's visibility disagrees with whether it has a picture")
			finish()
			return
		if f.visible:
			shown += 1
	check(true,
		"and every slot is shown exactly when it has a picture (%d of %d showing)"
			% [shown, faces.size()])

	finish()

# Every TextureRect the HUD built, at any depth.
func _faces(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var node: Node = stack.pop_back()
		if node is TextureRect:
			out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out
