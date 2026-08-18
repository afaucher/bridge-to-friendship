extends "res://scripts/test_support/test_case.gd"

# TWO GUNS AT OPPOSITE ENDS OF ONE AXIS.
#
# They exist for the M20 aim A/B. Point aiming and the assist are both bets about
# PRECISION, and the machine gun is a poor instrument for judging a precision
# change: a 10-degree cone hides an aiming error the same way it hides the muzzle
# offset. So one weapon forgives aim completely and one punishes it.
#
# WHAT IS ASSERTED IS THE RELATIONSHIP, not the numbers. "The rifle is tighter
# than the machine gun" survives every tuning pass; "the rifle is 0.4 degrees"
# fails the first time somebody turns the dial, and would have to be updated by
# the person whose change it is supposed to be checking.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const SpecialBody = preload("res://scripts/sim/special_body.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

const PEER := 11

var world: Node3D = null
var body: CharacterBody3D = null
var done := false

func setup(main) -> void:
	timeout_seconds = 30.0
	world = Node3D.new()
	world.name = "GunWorld"
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

func _arm(kind: int) -> Node:
	for s in world._specials.all():
		world._specials.destroy(s)
	var w: Node = world._specials.spawn_loose(body.position, kind)
	w.hold(PEER)
	w.fire_timer = 0.0
	world._pose_held_special(w, body)
	return w

# Fire once and report the widest angle any round came out at, plus how many.
func _volley(kind: int) -> Dictionary:
	for b in world._bullets:
		if is_instance_valid(b):
			b.queue_free()
	world._bullets.clear()
	var w: Node = _arm(kind)
	match kind:
		SpecialBody.Kind.SHOTGUN: world._step_shotgun(body, w, true)
		SpecialBody.Kind.RIFLE: world._step_rifle(body, w, true)
		SpecialBody.Kind.HEAVY: world._step_heavy(body, w, true)
		_: world._step_machine_gun(body, w, true)
	var aimed: Vector3 = world.aim_direction(body, w)
	var widest := 0.0
	var damage := 0
	for b in world._bullets:
		if not is_instance_valid(b):
			continue
		var off: float = rad_to_deg(b.velocity.normalized().angle_to(aimed))
		widest = maxf(widest, off)
		damage = int(b.damage)
	return {"rounds": world._bullets.size(), "widest": widest, "damage": damage}

func _physics_process(_delta: float) -> void:
	if done or body == null or world.tick < 4:
		return
	done = true

	# MANY VOLLEYS, because a cone is a distribution. One shotgun pull could put
	# every pellet dead centre and one rifle round could take its worst roll, and a
	# single sample of each would compare two dice throws rather than two weapons.
	var mg := 0.0
	var rifle := 0.0
	var shot := 0.0
	var pellets := 0
	for _i in 12:
		mg = maxf(mg, float(_volley(SpecialBody.Kind.MACHINE_GUN)["widest"]))
		rifle = maxf(rifle, float(_volley(SpecialBody.Kind.RIFLE)["widest"]))
		var v: Dictionary = _volley(SpecialBody.Kind.SHOTGUN)
		shot = maxf(shot, float(v["widest"]))
		pellets = int(v["rounds"])
	print("[guns] worst spread over 12 volleys -- mg %.2f deg, rifle %.2f deg, shotgun %.2f deg"
		% [mg, rifle, shot])

	# --- The rifle is the precise one --------------------------------------------
	check(rifle < mg,
		"the rifle is tighter than the machine gun (%.2f vs %.2f degrees) -- which "
			% [rifle, mg]
		+ "is the whole reason it exists: a 10-degree cone hides an aiming error, "
		+ "so it cannot judge a change to aiming")
	check(rifle < 1.0,
		"and tight enough that a miss is the player's (%.2f degrees)" % rifle)
	var one: Dictionary = _volley(SpecialBody.Kind.RIFLE)
	eq(int(one["rounds"]), 1, "it fires a single round")
	check(int(one["damage"]) > SimConfig.MG_DAMAGE,
		"that hits harder than a machine gun round (%d vs %d) -- the trade is a "
			% [int(one["damage"]), SimConfig.MG_DAMAGE]
		+ "miss costing a second rather than a bullet")
	check(SimConfig.RIFLE_FIRE_INTERVAL > SimConfig.MG_FIRE_INTERVAL,
		"and comes round more slowly")

	# --- The shotgun is the forgiving one ----------------------------------------
	eq(pellets, SimConfig.SHOTGUN_PELLETS,
		"one trigger pull sends the whole fistful")
	check(shot > mg,
		"through a cone WIDER than the machine gun's (%.2f vs %.2f degrees)"
			% [shot, mg])
	# THE SHOT IS THE UNIT, NOT THE PELLET. Seven pellets a pull with a per-pellet
	# magazine would be an ammunition counter nobody can read.
	var w: Node = _arm(SpecialBody.Kind.SHOTGUN)
	var before: int = int(w.ammo)
	world._step_shotgun(body, w, true)
	eq(int(w.ammo), before - 1,
		"and costs ONE ammo, not seven -- the shot is the thing the player counts")

	# --- Both are real specials --------------------------------------------------
	for kind in [SpecialBody.Kind.SHOTGUN, SpecialBody.Kind.RIFLE]:
		var armed: Node = _arm(kind)
		check(armed.ammo > 0, "%s arrives loaded (%d)" % [armed.kind_name(), armed.ammo])
		check(armed.kind_name() != "?", "and has a name for the HUD slot")
	# AUTHORABLE, or they exist only in a test. Both glyphs resolve, and they
	# resolve to DIFFERENT things -- two glyphs one keypress apart that mean the
	# same kind is the typo nobody spots in a grid of them.
	eq(GridConfig.CONTENT_GLYPHS.get("w"), GridConfig.Content.PICKUP_SHOTGUN,
		"`w` authors a shotgun")
	eq(GridConfig.CONTENT_GLYPHS.get("f"), GridConfig.Content.PICKUP_RIFLE,
		"and `f` a rifle")
	_test_the_heavy_gun()
	finish()

# --- The heavy gun, which is the only one that charges you to hold it -----------

func _test_the_heavy_gun() -> void:
	var heavy := 0.0
	for _i in 12:
		heavy = maxf(heavy, float(_volley(SpecialBody.Kind.HEAVY)["widest"]))
	var mg := 0.0
	for _i in 12:
		mg = maxf(mg, float(_volley(SpecialBody.Kind.MACHINE_GUN)["widest"]))
	print("[guns] heavy spread %.2f deg against the machine gun %.2f" % [heavy, mg])

	check(heavy > mg,
		"the heavy gun is LESS accurate than the machine gun (%.2f vs %.2f degrees)"
			% [heavy, mg])
	check(SimConfig.HEAVY_FIRE_INTERVAL < SimConfig.MG_FIRE_INTERVAL,
		"and faster")
	check(SimConfig.HEAVY_AMMO > SimConfig.MG_AMMO,
		"and deeper (%d rounds against %d)" % [SimConfig.HEAVY_AMMO, SimConfig.MG_AMMO])

	# THE PRICE, WHICH IS THE WHOLE REASON IT IS INTERESTING. Every other special
	# in this game is strictly better than empty hands, so picking one up has never
	# been a decision.
	var w: Node = _arm(SpecialBody.Kind.HEAVY)
	world._apply_carry_weight()
	check(body.carry_speed < 1.0,
		"holding it slows you down (%.2f of normal)" % body.carry_speed)

	# AND THE PRICE IS PAID BY THE LEGS, not just recorded. A scalar nothing reads
	# is a scalar that does nothing, which is the shape of five collision-mask bugs
	# in this project.
	var walked_heavy: float = _walk_for(60)
	world._specials.destroy(w)
	world._apply_carry_weight()
	eq(body.carry_speed, 1.0, "putting it down gives the speed back")
	var walked_free: float = _walk_for(60)
	print("[guns] one second of walking: %.2f m carrying the heavy gun, %.2f m without"
		% [walked_heavy, walked_free])
	check(walked_heavy < walked_free * 0.95,
		"and a body carrying it really covers less ground (%.2f m against %.2f m)"
			% [walked_heavy, walked_free])

# Walk straight for `ticks` and report the distance actually covered.
func _walk_for(ticks: int) -> float:
	body.position = world.grid.cell_surface_world(Vector2i(7, 2)) + Vector3(0.0, 1.0, 0.0)
	body.velocity = Vector3.ZERO
	var start: Vector3 = body.global_position
	for _t in ticks:
		body.step(Vector2(0.0, -1.0), 0)
	return start.distance_to(body.global_position)
