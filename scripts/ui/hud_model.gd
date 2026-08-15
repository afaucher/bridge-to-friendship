extends RefCounted

# The HUD AS DATA. A pure function from world state to a plain dictionary.
#
# WHY THIS EXISTS SEPARATELY FROM hud.gd: the gate is headless, so nothing about
# a Control tree can be asserted, and a HUD checked by looking at it is a HUD
# that rots silently the first time a state enum moves. Every decision the HUD
# makes -- which countdown applies, what fraction is left, who is a friend, what
# order they come in -- lives here and is testable in milliseconds. hud.gd draws
# what this says and decides nothing.
#
# It is the same data/view split the grid already uses: the cell record is
# authoritative and the meshes follow.
#
# It is also the extension point. A rope slot (M4), a hat count (M8.5) and a
# special (M12) are new fields on these dictionaries, not new layout code.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")

# Fractions are 0..1 and are always "how full should the bar be":
#   bleed_out  1.0 = the whole timer left, 0.0 = about to expire
#   rescue     0.0 = nobody helping,       1.0 = about to be pulled out
#   grace      1.0 = just hit,             0.0 = hittable again
# NO_BAR means the bar does not apply and must not be drawn -- distinct from
# 0.0, which means it applies and is empty. Drawing an empty bar for a player who
# is simply walking would report a crisis that is not happening.
const NO_BAR := -1.0

static func build(world: Node, for_peer: int = -1) -> Dictionary:
	var model := {"active": false, "own": {}, "friends": []}
	if world == null or not world.running:
		return model
	var peer: int = for_peer if for_peer >= 0 else int(world.local_peer)
	var body: Node = world.player_body(peer)
	if body == null:
		# A client is told about avatars by a reliable RPC that has not
		# necessarily arrived. Not an error; there is simply nothing to draw yet.
		return model
	model["active"] = true
	model["own"] = _own_entry(world, peer, body)
	model["friends"] = _friend_entries(world, peer, body)
	return model

static func _own_entry(world: Node, peer: int, body: Node) -> Dictionary:
	return {
		"peer": peer,
		"steam_id": world.player_steam_id(peer),
		"name": world.player_name(peer),
		"health": int(body.health),
		"max_health": int(SimConfig.MAX_HEALTH),
		"state": int(body.state),
		"state_label": state_label(int(body.state)),
		"needs_help": bool(body.is_awaiting_rescue()),
		"grace": _fraction(float(body.invulnerable), SimConfig.HIT_GRACE),
		"bleed_out": bleed_out_fraction(body),
		"rescue": rescue_fraction(body),
		"slots": _slots(world, peer, body),
	}

static func _friend_entries(world: Node, peer: int, body: Node) -> Array:
	# SORTED BY PEER ID, not by dictionary order. Godot does not promise a
	# Dictionary iterates the same way on two machines, and a friend list that
	# reorders itself between frames is unreadable -- you reach for the row that
	# was there a moment ago.
	var ids: Array = world.players.keys().duplicate()
	ids.sort()

	var out: Array = []
	for id_key in ids:
		var other_peer: int = int(id_key)
		if other_peer == peer:
			continue
		var other: Node = world.players[other_peer]
		if other == null or not is_instance_valid(other):
			continue
		var to: Vector3 = other.position - body.position
		out.append({
			"peer": other_peer,
			"steam_id": world.player_steam_id(other_peer),
			"name": world.player_name(other_peer),
			"health": int(other.health),
			"max_health": int(SimConfig.MAX_HEALTH),
			"state": int(other.state),
			"state_label": state_label(int(other.state)),
			"needs_help": bool(other.is_awaiting_rescue()),
			"bleed_out": bleed_out_fraction(other),
			"rescue": rescue_fraction(other),
			"distance": to.length(),
			"bearing": bearing_to(to),
			# WHERE THEY ACTUALLY ARE. The bearing above is for the text row; a
			# screen marker has to be projected through the camera, and a compass
			# point cannot be. See teammate_markers.gd.
			"at": other.global_position,
			# What they are holding, as a short label -- D5's "each friend's name,
			# health and special". Empty means empty-handed, which is exactly the
			# thing worth knowing when a rusher is up: who can end it.
			"special": _friend_special(world, other_peer),
		})
	return out

static func _friend_special(world: Node, peer: int) -> String:
	if world == null or not world.has_method("special_held_by"):
		return ""
	var weapon: Node = world.special_held_by(peer)
	if weapon == null or not is_instance_valid(weapon):
		return ""
	return "%s %d" % [weapon.kind_name(), int(weapon.ammo)]

# --- Countdowns ---------------------------------------------------------------

# How much of the bleed-out is left. LEDGE_HANG and DOWNED are the same
# machinery with different durations, which is why one function answers both.
static func bleed_out_fraction(body: Node) -> float:
	var total: float = 0.0
	match int(body.state):
		PlayerBody.State.LEDGE_HANG:
			total = SimConfig.LEDGE_HANG_SECONDS
		PlayerBody.State.DOWNED:
			total = SimConfig.DOWNED_SECONDS
		_:
			return NO_BAR
	if total <= 0.0:
		return NO_BAR
	return clampf(1.0 - float(body.state_timer) / total, 0.0, 1.0)

# How far a teammate has got with pulling them out.
static func rescue_fraction(body: Node) -> float:
	var total: float = 0.0
	match int(body.state):
		PlayerBody.State.LEDGE_HANG:
			total = SimConfig.LEDGE_HAUL_SECONDS
		PlayerBody.State.DOWNED:
			total = SimConfig.REVIVE_SECONDS
		_:
			return NO_BAR
	if total <= 0.0:
		return NO_BAR
	return clampf(float(body.rescue_progress) / total, 0.0, 1.0)

static func _fraction(value: float, total: float) -> float:
	if total <= 0.0:
		return 0.0
	return clampf(value / total, 0.0, 1.0)

# --- Slots --------------------------------------------------------------------

# TWO ACTION SLOTS. D5 asked for three and the third was ROPE, drawn permanently
# blank against M4 landing -- removed 2026-08-15 because a box that has never
# filled and cannot fill is not "deliberately empty", it is furniture. It was
# reported from a playtest as a button that does nothing, which is exactly the
# report the empty-versus-broken distinction was meant to prevent.
#
# THE DISTINCTION ITSELF SURVIVES, and is better carried now: the SPECIAL slot
# genuinely varies at runtime -- empty-handed one moment and holding a rocket the
# next -- so "empty is a state, not an absence" is taught by a slot the player
# watches change rather than by one that never has.
#
# `ACTION_ROPE` stays reserved in sim_config: it is a wire constant, it costs a
# bit nobody is using, and renumbering the action bits to reclaim it would be a
# protocol change for no gain. When M4 lands, the slot comes back here.
static func _slots(world: Node, peer: int, body: Node) -> Array:
	return [
		{
			"id": "push",
			"label": "PUSH",
			"filled": true,
			"ready": float(body.shove_cooldown) <= 0.0,
			"cooldown": _fraction(float(body.shove_cooldown), SimConfig.SHOVE_COOLDOWN),
		},
		_special_slot(world, peer),
	]

# The one slot, read off the world rather than off the player. Nothing about a
# carried item lives on PlayerBody -- see special_pool.held_by, which is what
# keeps items out of capture_state() by construction rather than by discipline.
static func _special_slot(world: Node, peer: int) -> Dictionary:
	var slot := {"id": "special", "label": "SPECIAL", "filled": false, "ready": false,
		"cooldown": 0.0, "ammo": 0}
	if world == null or not world.has_method("special_held_by"):
		return slot
	var weapon: Node = world.special_held_by(peer)
	if weapon == null or not is_instance_valid(weapon):
		return slot
	slot["label"] = str(weapon.kind_name())
	slot["filled"] = true
	slot["ready"] = float(weapon.fire_timer) <= 0.0
	slot["cooldown"] = _fraction(float(weapon.fire_timer), SimConfig.MG_FIRE_INTERVAL)
	# THE NUMBER THAT MATTERS. Fixed uses is the model every special shares, so
	# "how many left" is the only question the slot really has to answer.
	slot["ammo"] = int(weapon.ammo)
	return slot

# --- Where is everyone --------------------------------------------------------

# Radians clockwise from up-bridge. The camera is FIXED-YAW looking along the
# bridge, so a world-space bearing is also a screen-space one and no camera basis
# has to be agreed on -- the same property that lets movement input be
# world-space.
#
# This exists because of D3: the party spreads to ~40 m across a 60 m structure,
# so a teammate is routinely off screen, and the moment that matters most is
# exactly when they are hanging off a lip somewhere nobody is looking. A panel
# that says someone needs rescuing but not where is half a feature.
static func bearing_to(offset: Vector3) -> float:
	# NORTH is up the bridge, which is -Z (see GridConfig).
	return atan2(offset.x, -offset.z)

static func state_label(state: int) -> String:
	match state:
		PlayerBody.State.SHOVE:
			return "SHOVE"
		PlayerBody.State.TUMBLE:
			return "TUMBLE"
		PlayerBody.State.LEDGE_HANG:
			return "HANGING"
		PlayerBody.State.DOWNED:
			return "DOWN"
		PlayerBody.State.BUS_DRIVER:
			return "DRIVING"
		PlayerBody.State.BUS_RIDER:
			return "RIDING"
	# WALK draws nothing: a label that is present in the ordinary case is a label
	# nobody reads in the exceptional one.
	return ""
