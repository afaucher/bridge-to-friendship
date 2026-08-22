extends "res://scripts/test_support/test_case.gd"

# THE WEAPON YOU ALWAYS HAVE.
#
# Every gun in this game is a special: one slot, a magazine, and when it runs out
# you are holding nothing and there is nothing to do but walk to the next rack.
# The sidearm is the answer to that, and its three rules are the test:
#
#   1. IT IS THERE WHEN THE HANDS ARE EMPTY, and it fires. No pickup, no ammo.
#   2. IT CANNOT BE DROPPED OR SPENT, because it is not an item at all -- it
#      lives on the PLAYER, so the pickup/drop/spend lifecycle never sees it.
#      Picking a special up puts it away; the special running out brings it back
#      the same tick.
#   3. ACCURATE ONCE, WILD IF YOU LEAN ON IT. A tapped shot lands where you point
#      it; a held trigger walks. The mechanic is the RELATIONSHIP between the
#      fire rate and the cooling -- a shot adds more heat than the gap between
#      shots sheds -- so both halves are measured, not just the wild one.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PEER := 774411203

var world: Node3D = null
var body: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 40.0
	world = Node3D.new()
	world.name = "SidearmWorld"
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

func _clear_bullets() -> void:
	for b in world._bullets:
		if is_instance_valid(b):
			b.queue_free()
	world._bullets.clear()

# Hold the trigger for `ticks` and report the widest angle any round came out at.
func _burst(ticks: int) -> Dictionary:
	_clear_bullets()
	var aimed: Vector3 = world.aim_direction(body, world._sidearm_of(body))
	world._current_input[PEER] = PlayerInput.make(
		world.tick, Vector2.ZERO, SimConfig.ACTION_SPECIAL_HELD)
	# THE PEAK, NOT THE VALUE AT THE END. Heat sheds every tick, so reading it
	# after the loop reads it most of an interval after the last shot -- the first
	# draft did that and reported 0.85 for a weapon that had reached 1.0, which
	# looks exactly like tuning being wrong instead of the sample being late.
	var hottest := 0.0
	for _t in ticks:
		world._step_sidearm(PEER, body)
		hottest = maxf(hottest, body.pistol_heat)
	var widest := 0.0
	for b in world._bullets:
		if is_instance_valid(b):
			widest = maxf(widest, rad_to_deg(b.velocity.normalized().angle_to(aimed)))
	return {"rounds": world._bullets.size(), "widest": widest, "heat": hottest}

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < 4:
		return
	done = true
	_test_it_is_there_with_empty_hands()
	_test_a_special_puts_it_away_and_running_out_brings_it_back()
	_test_tapped_is_accurate_and_held_is_not()
	_test_it_does_not_out_gun_the_weapons_you_go_and_find()
	_test_it_is_held_clear_of_the_body()
	finish()

# --- 1. Always there ----------------------------------------------------------

func _test_it_is_there_with_empty_hands() -> void:
	eq(world._specials.held_by(PEER), null, "the player starts with an empty slot")
	var sidearm: Node3D = world._sidearm_of(body)
	if not check(sidearm != null, "and carries a sidearm node all the same"):
		return
	check(sidearm.get_node_or_null("Barrel") != null,
		"which has a BARREL, so `_muzzle_of` and `aim_direction` take it "
		+ "unchanged -- the round leaves the barrel it is drawn leaving, and the "
		+ "laser sight points where the shot goes, with no special case")

	body.pistol_heat = 0.0
	body.pistol_timer = 0.0
	var shot: Dictionary = _burst(1)
	eq(int(shot["rounds"]), 1,
		"and it FIRES with nothing in the slot -- which used to be a bare "
		+ "`continue`, so an empty-handed player had no verb at all")

# --- 2. Not an item -----------------------------------------------------------

func _test_a_special_puts_it_away_and_running_out_brings_it_back() -> void:
	var gun: Node = world._specials.spawn_loose(body.position, SpecialBody.Kind.MACHINE_GUN)
	gun.hold(PEER)
	world._pose_held_special(gun, body)
	world._pose_sidearms()
	check(not world._sidearm_of(body).visible,
		"a special in the slot puts the sidearm away -- the visibility rule asks "
		+ "the same question the firing branch does, so a player never sees a "
		+ "pistol they cannot fire")

	# SPENT MEANS GONE, and the sidearm is back the same tick -- no pickup, no
	# respawn, nothing to wait for. That is what "not an item" buys.
	world._specials.destroy(gun)
	world._pose_sidearms()
	check(world._sidearm_of(body).visible,
		"and the moment the special is gone it is back")
	body.pistol_heat = 0.0
	body.pistol_timer = 0.0
	eq(int(_burst(1)["rounds"]), 1, "firing again immediately, with no ammo to find")

# --- 3. The mechanic ----------------------------------------------------------

func _test_tapped_is_accurate_and_held_is_not() -> void:
	# TAPPED: cold every time, because the timer gates the rate and the heat has
	# a second to bleed off between shots.
	var tapped := 0.0
	for _i in 6:
		body.pistol_heat = 0.0
		body.pistol_timer = 0.0
		tapped = maxf(tapped, float(_burst(1)["widest"]))

	# HELD: the trigger down for a couple of seconds.
	# FOUR SECONDS, WHICH IS WHAT "KEEP FIRING" MEANS. A shot adds 0.34 and the
	# 0.30 s gap between shots sheds 0.24, so the climb is about a tenth per round
	# and saturating takes ten of them. The first draft held for two seconds,
	# reached 0.79, and failed an assertion about the TOP of the range -- the
	# weapon was working and the burst was short.
	body.pistol_heat = 0.0
	body.pistol_timer = 0.0
	var held: Dictionary = _burst(240)

	print("[sidearm] tapped worst %.2f deg | held %d rounds, worst %.2f deg, heat %.2f"
		% [tapped, int(held["rounds"]), float(held["widest"]), float(held["heat"])])

	check(tapped <= SimConfig.PISTOL_SPREAD_DEG + 0.01,
		"a tapped shot is as accurate as the weapon gets (%.2f of %.2f degrees) "
			% [tapped, SimConfig.PISTOL_SPREAD_DEG]
		+ "-- one at a time is the whole reason to carry it")
	check(int(held["rounds"]) > 3,
		"holding the trigger really does empty rounds (%d)" % int(held["rounds"]))
	check(float(held["widest"]) > tapped * 4.0,
		"and they go MUCH wider than a tapped one (%.2f against %.2f degrees)"
			% [float(held["widest"]), tapped])
	check(float(held["heat"]) > 0.9,
		"because a held trigger climbs to the top of the heat range (%.2f) -- the "
			% float(held["heat"])
		+ "mechanic is that a shot adds more than the gap between shots sheds, so "
		+ "a HELD trigger heats and a TAPPED one does not")

	# AND IT COOLS. Without this the weapon would be accurate exactly once per
	# life, which is a different and much worse gun.
	var hot: float = float(held["heat"])
	world._current_input[PEER] = PlayerInput.empty(world.tick)
	for _t in 120:
		world._step_sidearm(PEER, body)
	print("[sidearm] after 2 s off the trigger: heat %.2f (was %.2f)"
		% [body.pistol_heat, hot])
	check(body.pistol_heat < 0.05,
		"and letting go cools it back down (%.2f from %.2f) -- trigger discipline "
			% [body.pistol_heat, hot]
		+ "buys the accurate shot back, which is what makes the heat a decision "
		+ "rather than a countdown")

# --- AND IT IS THE FALLBACK, NOT THE BEST GUN IN THE GAME ---------------------
#
# THE BUG THIS EXISTS TO STOP SHIPPED ONCE. The sidearm went out at a 0.30 s
# interval against the machine gun's 0.40, at the same 1 damage -- so the free,
# unlimited, undroppable weapon did 3.3 damage a second to the machine gun's 2.5,
# at the same accuracy. There was no reason to pick a machine gun up ever again.
#
# NOTHING ABOUT IT FELT WRONG, which is the point. It was a good pistol; it was
# just quietly better than the thing you cross a bridge to find, and no assertion
# in this file or any other compared the two. Arithmetic on the constants is the
# only thing that catches that, so it lives here rather than waiting for somebody
# to notice a weapon nobody picks up.
func _test_it_does_not_out_gun_the_weapons_you_go_and_find() -> void:
	# Damage per second with the trigger held, which is the mode a sidearm must
	# not win: the machine gun's entire job is sustained fire.
	var pistol_dps: float = float(SimConfig.PISTOL_DAMAGE) / SimConfig.PISTOL_FIRE_INTERVAL
	var mg_dps: float = float(SimConfig.MG_DAMAGE) / SimConfig.MG_FIRE_INTERVAL
	var rifle_dps: float = float(SimConfig.RIFLE_DAMAGE) / SimConfig.RIFLE_FIRE_INTERVAL
	print("[sidearm] held dps -- pistol %.1f, machine gun %.1f, rifle %.1f"
		% [pistol_dps, mg_dps, rifle_dps])

	check(pistol_dps < mg_dps,
		"a held sidearm does LESS damage a second than a machine gun (%.1f "
			% pistol_dps
		+ "against %.1f) -- it is unlimited and undroppable, so if it also out-"
			% mg_dps
		+ "damaged the gun you have to find, the gun you have to find would be "
		+ "furniture")
	check(pistol_dps < rifle_dps,
		"and less than a rifle (%.1f against %.1f)" % [pistol_dps, rifle_dps])
	check(SimConfig.PISTOL_SPREAD_HOT_DEG > SimConfig.MG_SPREAD_DEG,
		"and spamming it is WIDER than a machine gun (%.1f against %.1f degrees) "
			% [SimConfig.PISTOL_SPREAD_HOT_DEG, SimConfig.MG_SPREAD_DEG]
		+ "-- worse on both axes, so holding the trigger is never the answer")

	# THE RELATIONSHIP THAT MAKES THE HEAT EXIST AT ALL, asserted as arithmetic
	# because it is one subtraction away from silently vanishing. Slowing the
	# weapon to 0.45 s without raising the per-shot heat would have put the gain
	# (0.34) below the per-interval loss (0.36): a held trigger would COOL, the
	# spread would never open, and every constant would still look deliberate.
	var gain: float = SimConfig.PISTOL_HEAT_PER_SHOT
	var loss: float = SimConfig.PISTOL_HEAT_DECAY * SimConfig.PISTOL_FIRE_INTERVAL
	print("[sidearm] per shot: heat +%.2f, cooling -%.2f over the interval" % [gain, loss])
	check(gain > loss,
		"a held trigger gains more heat than the gap between shots sheds (+%.2f "
			% gain
		+ "against -%.2f) -- without that the weapon has no mechanic, and it "
			% loss
		+ "would fail silently rather than obviously")

	# AND A TAP HAS TO BE AFFORDABLE. If staying cold took longer than a fight
	# lasts, the accurate mode would be theoretical.
	var tap_gap: float = SimConfig.PISTOL_HEAT_PER_SHOT / SimConfig.PISTOL_HEAT_DECAY
	print("[sidearm] staying cold needs %.2f s between shots" % tap_gap)
	check(tap_gap < 1.0,
		"and staying accurate costs under a second between shots (%.2f) -- a tap "
			% tap_gap
		+ "you cannot afford in a fight is not a mode, it is a footnote")

# --- 5. It is held CLEAR of the body ------------------------------------------
#
# Reported from play 2026-08-22 as "the pistol looks like it is in the body", and
# it was: the Grip sits BACK from the Sidearm node toward the torso, so at the old
# offset its centre was 0.364 m from a hull of radius 0.4 and the box around it
# was almost entirely inside the player. Only the barrel ever stuck out.
#
# ASSERTED AS GEOMETRY, NOT AS THE NUMBER. A test that restates the offset in
# player.tscn agrees with whatever that file says and catches nothing; what has to
# stay true is that the nearest corner of the grip is outside the hull, which is a
# claim about the two of them together and survives either being retuned.

func _test_it_is_held_clear_of_the_body() -> void:
	var grip := body.get_node_or_null("Facing/Sidearm/Grip") as MeshInstance3D
	check(grip != null, "the sidearm has a grip to measure")
	if grip == null:
		return
	# Local to the player, so the body's own axis is x = z = 0 whatever it is doing.
	var at: Vector3 = body.to_local(grip.global_position)
	var box: BoxMesh = grip.mesh as BoxMesh
	var half: float = 0.0
	if box != null:
		half = maxf(box.size.x, box.size.z) * 0.5
	var radial: float = Vector2(at.x, at.z).length()
	var hull: float = 0.4          # the player cylinder, mesh and collider alike
	print("[sidearm] grip %.3f m from the axis, nearest corner %.3f, hull %.3f"
		% [radial, radial - half, hull])
	check(radial - half > hull,
		"the grip is held outside the body (%.3f m clear) -- it used to sit "
			% (radial - half - hull)
		+ "inside the hull with only the barrel showing")
	# AND NOT FLUNG OUT AT ARM'S LENGTH, which would pass the line above and look
	# just as wrong the other way.
	check(radial < hull * 2.0,
		"and still looks held rather than floating beside you (%.3f m)" % radial)
