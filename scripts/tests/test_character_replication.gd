extends "res://scripts/test_support/test_case.gd"

# "That one's me" -- across a real socket.
#
# THE CLAIM EVERY OTHER TEST IN THIS FEATURE CANNOT MAKE. test_character_config
# proves a colour survives a launch, test_character_style proves the nose stays
# visible against it, and test_character_screen proves the picker drives a
# preview. All three are equally true of a colour NOBODY ELSE CAN SEE, which
# would be the whole feature failing.
#
# The claims:
#   1. A client's chosen colour reaches the HOST.
#   2. The host's reaches the CLIENT.
#   3. The colour is on the BODY, not merely in a dictionary -- a replicated
#      value nothing paints with is a value with no picture.
#   4. Two players in one world wear TWO different colours. This is the one that
#      catches the shared sub-resource: player.tscn's Mat_1 belongs to the scene,
#      so a body painted through the node would paint the whole party, and every
#      other assertion here would still pass because they would all agree.
#   5. The nose follows the body it is on, derived per player.

const PORT := 28786
const NetHarness = preload("res://scripts/test_support/net_harness.gd")
const CharacterStyle = preload("res://scripts/sim/character_style.gd")

# Far apart from each other AND from the default, so no assertion can be
# satisfied by a value that was simply never changed.
const HOST_COLOUR := Color(0.90, 0.25, 0.20)
const CLIENT_COLOUR := Color(0.20, 0.85, 0.35)

var harness: Node = null
var frame: int = 0
var phase: int = 0
var host_world: Node = null
var client_world: Node = null
var client_peer: int = 0

func setup(_main) -> void:
	timeout_seconds = 30.0
	harness = NetHarness.new()
	add_child(harness)
	if not check(harness.start(PORT, 1), "harness starts (%s)" % harness.failure):
		finish()
		return
	harness.ready_to_run.connect(_on_ready)

func _on_ready() -> void:
	host_world = harness.host_world
	client_world = harness.client_worlds[0]
	client_peer = client_world.local_peer
	phase = 1

func _physics_process(_delta: float) -> void:
	if phase == 0:
		return
	frame += 1

	if phase == 1 and frame > 4:
		# A HARNESS WORLD HAS view_active FALSE, so neither end read a config file
		# and both are sitting on the default. That is deliberate -- the gate must
		# not touch the developer's save -- and it means the test has to state the
		# choice itself, which is also what makes the "before" meaningful.
		check(host_world.player_colour(1) == CharacterStyle.DEFAULT_BODY,
			"everybody starts on the default, so a change proves something")

		# EACH MACHINE CHOOSES ITS OWN AND ANNOUNCES IT, which is the real path: a
		# client submits to the host, the host owns the roster and republishes.
		host_world._chosen_body_colour = HOST_COLOUR
		host_world._announce_character()
		client_world._chosen_body_colour = CLIENT_COLOUR
		client_world._announce_character()
		phase = 2
		frame = 0
		return

	if phase == 2 and frame > 30:
		_test_the_dictionaries_agree()
		_test_the_bodies_are_painted()
		_test_two_players_are_not_one_material()
		_test_the_nose_follows_its_own_body()
		finish()

# --- 1 and 2. It crossed the socket, both ways --------------------------------

func _test_the_dictionaries_agree() -> void:
	check(host_world.player_colour(client_peer).is_equal_approx(CLIENT_COLOUR),
		"the client's choice reached the host -- got %s" % host_world.player_colour(client_peer))
	check(client_world.player_colour(1).is_equal_approx(HOST_COLOUR),
		"and the host's reached the client -- got %s" % client_world.player_colour(1))
	# The host is the owner, so its own entry must survive republishing somebody
	# else's -- a broadcast that rebuilt the dictionary from the sender would pass
	# the two assertions above and lose the host.
	check(host_world.player_colour(1).is_equal_approx(HOST_COLOUR),
		"and the host still knows its own")

# --- 3. It is on the body ------------------------------------------------------

func _test_the_bodies_are_painted() -> void:
	check(_worn(client_world, 1).is_equal_approx(HOST_COLOUR),
		"the client PAINTED the host's avatar -- got %s" % _worn(client_world, 1))
	check(_worn(host_world, client_peer).is_equal_approx(CLIENT_COLOUR),
		"and the host painted the client's -- got %s" % _worn(host_world, client_peer))

# --- 4. THE SHARED MATERIAL --------------------------------------------------
#
# Two bodies, one world, two colours. If apply_look wrote through the scene's
# sub-resource instead of making its own, both would report whichever was painted
# last -- and every assertion above would STILL PASS, because they only ever ask
# about one body at a time.

func _test_two_players_are_not_one_material() -> void:
	# Both read from the SAME world, on purpose: the bug is two bodies sharing one
	# material, and that is only visible from inside a single world.
	var mine: Color = _worn(host_world, 1)
	var theirs: Color = _worn(host_world, client_peer)
	check(not mine.is_equal_approx(theirs),
		"two players in ONE world wear two different colours -- %s and %s" % [mine, theirs])

	var host_body: Node = host_world.players.get(1)
	var client_body: Node = host_world.players.get(client_peer)
	if host_body != null and client_body != null:
		check(host_body._body_material != client_body._body_material,
			"because each avatar owns its material rather than sharing the scene's")

# --- 5. The nose is derived per body ------------------------------------------

func _test_the_nose_follows_its_own_body() -> void:
	var body: Node = host_world.players.get(client_peer)
	if not check(body != null, "the host has a body for the client"):
		return
	var nose: Color = body._nose_material.albedo_color
	check(nose.is_equal_approx(CharacterStyle.nose_colour(CLIENT_COLOUR)),
		"the marker is derived from the body it is on, not from anybody else's")
	check(CharacterStyle.luma_gap(nose, _worn(host_world, client_peer)) >= CharacterStyle.LUMA_GAP - 0.01,
		"and is still clear of it, on a colour chosen at runtime rather than in a sweep")

# What a body is actually wearing, read off the material the renderer uses.
func _worn(world: Node, peer: int) -> Color:
	var body: Node = world.players.get(peer)
	if body == null or body._body_material == null:
		return Color.TRANSPARENT
	return body._body_material.albedo_color
