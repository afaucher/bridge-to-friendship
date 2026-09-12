extends "res://scripts/test_support/test_case.gd"

# THE BUBBLE SWALLOW. See implementation_plans/m28_bubble_swallow.md.
#
# The claims, and each one is a rule from the plan rather than a behaviour that
# happens to hold:
#
#   1. SUBMERGED IS ABSOLUTE, ON BOTH ROUTES. A bullet cannot reach it because
#      there is no collider; a BLAST cannot either, and that needs saying
#      separately because `_blast_targets` walks the pools by distance and never
#      asks about colliders. A test that only fires a bullet proves half of it --
#      which is the shape of every collision-mask bug on record here.
#   2. IT SURFACES ON PROXIMITY AND DIVES WHEN THE FIELD EMPTIES, and damage
#      survives the dive: softening it and coming back is progress.
#   3. THE PULL IS BEATABLE AT THE RIM AND NOT IN THE CORE, asserted against
#      WALK_SPEED rather than against the constants -- this enemy has no wind-up
#      by design, so that relationship is the entire fairness of it.
#   4. THE DRAIN IS THE CORE ONLY. The band you can walk out of takes nothing;
#      that band is the only warning the design can afford.
#   5. THE BANK. It holds what it takes, spills it when killed, and takes it away
#      when it leaves the world unkilled -- attributed, because a score that
#      changes with no event is a bug as far as the player can tell.

const GameWorldScript = preload("res://scripts/sim/game_world.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const PlayerBody = preload("res://scripts/sim/player_body.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const SegmentPool = preload("res://scripts/grid/segment_pool.gd")
const GameMode = preload("res://scripts/sim/game_mode.gd")
const Hit = preload("res://scripts/sim/hit.gd")
const HatBody = preload("res://scripts/sim/hat_body.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const HazardDressing = preload("res://scripts/grid/hazard_dressing.gd")
const SegmentGen = preload("res://scripts/grid/segment_gen.gd")

const A := 41

var world: Node3D = null
var body: CharacterBody3D = null
var swallow = null
var done := false
var phase := 0
var _at := 0
var _move := Vector2.ZERO
var _home := Vector3.ZERO

func setup(main) -> void:
	timeout_seconds = 90.0
	world = Node3D.new()
	world.name = "SwallowWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, A, false)
	world_under_test(world)
	world._spawn_player(A, 0)
	world.scripted_inputs[A] = func(t: int) -> Array:
		return PlayerInput.make(t, _move, 0)
	body = world.players[A]
	_home = body.global_position

func _physics_process(_delta: float) -> void:
	if done or world.tick < 6:
		return
	match phase:
		0: _it_starts_under_water()
		1: _neither_weapon_reaches_it()
		2: _it_surfaces_when_you_come_close()
		3: _the_pull_is_beatable_at_the_rim()
		4: _and_not_in_the_core()
		5: _the_drain_is_the_core_only()
		6: _the_bank_spills_when_killed()
		7: _and_is_lost_when_it_is_not()
		8: _the_terrain_places_them()

# --- Setting up -----------------------------------------------------------------

func _put_swallow(offset: float) -> void:
	swallow = world._spawn_swallow(_home + Vector3(offset, 0.0, 0.0))

func _it_starts_under_water() -> void:
	_put_swallow(40.0)      # far away, so nobody has woken it
	if not check(swallow != null, "a swallow can be spawned"):
		done = true
		finish()
		return
	world._process_swallows()
	_it_actually_built_itself()
	print("[swallow] spawned 40 m away: surfaced %s" % swallow.surfaced)
	check(not swallow.surfaced,
		"it starts under water with nobody near it -- the ambush is the default "
		+ "state, not something it has to be put into")
	phase = 1

# EVERY PART EXISTS AND IS THE RIGHT SIZE.
#
# THIS CLAIM IS HERE BECAUSE TWO BUGS HID BEHIND ITS ABSENCE. A runtime error in
# GDScript aborts the rest of the function and changes neither the exit code nor
# the test marker -- so a wrong property name in `_build` left the shell unsized
# and every other claim in this file passed, twice, because none of them looked
# at the mesh. `SCRIPT ERROR` in the log and a green run is the exact shape
# CLAUDE.md records for a renamed field.
#
# Asserting the RADIUS rather than "the node exists" is what makes it work: the
# nodes are made before the line that failed, so a presence check would have
# passed too. The size is set by `_resize`, which is what never ran.
func _it_actually_built_itself() -> void:
	var shell: MeshInstance3D = swallow.get_node_or_null("Shell")
	var maw: MeshInstance3D = swallow.get_node_or_null("Maw")
	var bubbles = swallow.get_node_or_null("Bubbles")
	if not check(shell != null and maw != null and bubbles != null,
			"the swallow built a shell, a maw and its bubbles"):
		return
	var mesh := shell.mesh as SphereMesh
	print("[swallow] built: shell mesh radius %.2f, wanted %.2f; bubbles emitting %s"
		% [mesh.radius, swallow.radius(), bubbles.emitting])
	near(mesh.radius, swallow.radius(), 0.001,
		"the shell mesh is the size the body says it is (%.3f against %.3f) -- "
			% [mesh.radius, swallow.radius()]
		+ "`_resize` runs at the END of `_build`, so a runtime error anywhere "
		+ "above it leaves this wrong and every other claim in this file green")
	check(bubbles.emitting,
		"and the bubbles are running while it is under water -- the one thing "
		+ "that says something is alive down there")

# --- 1. Neither weapon reaches it ------------------------------------------------

func _neither_weapon_reaches_it() -> void:
	# THE BULLET ROUTE: a hit handed straight to the body, which is what a round
	# does once its ray has found something.
	var shot = Hit.new()
	shot.kind = Hit.Kind.BULLET
	shot.amount = 1
	shot.from = _home
	var took_shot: bool = swallow.receive_hit(shot)
	var health_after: int = swallow.health

	# THE BLAST ROUTE, WHICH IS THE ONE THAT NEEDED SAYING. `_blast_targets` walks
	# the pools by DISTANCE -- it never asks about colliders -- so a swallow in a
	# pool would be found by a grenade whatever its collision looks like. This is
	# the refusal that has to be written separately, and the half a bullet test
	# cannot see.
	var caught: Array = world._blast_targets(swallow.global_position, 6.0)
	print("[swallow] submerged: bullet took %s, blast found %d targets, health %d"
		% [took_shot, caught.size(), health_after])
	check(not took_shot,
		"a bullet does not reach a submerged swallow -- there is no collider for "
		+ "a round to find, and the body refuses one handed to it anyway")
	eq(health_after, SimConfig.SWALLOW_HEALTH,
		"and it took no damage (%d of %d)" % [health_after, SimConfig.SWALLOW_HEALTH])
	check(not caught.has(swallow),
		"and a BLAST centred on it does not find it either -- the blast pass walks "
		+ "the pools by distance and never asks about colliders, so this refusal "
		+ "has to be written on its own or the grenade is an exception nobody "
		+ "decided on")
	phase = 2

# --- 2. Surfacing, diving, and remembering ---------------------------------------

func _it_surfaces_when_you_come_close() -> void:
	swallow.global_position = _home + Vector3(SimConfig.SWALLOW_REACH - 1.0, 0.0, 0.0)
	world._process_swallows()
	var up: bool = swallow.surfaced
	var caught: Array = world._blast_targets(swallow.global_position, 6.0)

	# HURT IT, THEN SEND IT UNDER: damage has to survive a dive, or a party that
	# softens it and retreats has done nothing and the fight must be won in one go.
	var shot = Hit.new()
	shot.kind = Hit.Kind.BULLET
	shot.amount = 1
	shot.from = _home
	swallow.receive_hit(shot)
	var hurt: int = swallow.health
	swallow.global_position = _home + Vector3(60.0, 0.0, 0.0)
	world._process_swallows()

	print("[swallow] close: surfaced %s, blast found it %s; after a dive health %d"
		% [up, caught.has(swallow), swallow.health])
	check(up, "it surfaces when a player is within its reach")
	check(caught.has(swallow),
		"and a blast finds it once it is up -- the refusal is about being under "
		+ "water, not about being a swallow")
	check(not swallow.surfaced, "it dives again when the field empties")
	eq(swallow.health, hurt,
		"and it remembers the damage (%d) -- healing on a dive would make a "
			% swallow.health
		+ "failed attempt worth nothing, and the hostage already supplies the "
		+ "pressure")
	phase = 3
	_at = world.tick

# --- 3. The pull, against WALK_SPEED ---------------------------------------------

func _the_pull_is_beatable_at_the_rim() -> void:
	# ASSERTED AGAINST WALK_SPEED, NOT AGAINST THE CONSTANTS. The rule is that you
	# can walk out of the rim, and a claim about SWALLOW_PULL_RIM would still pass
	# the day somebody halved WALK_SPEED.
	swallow.global_position = _home + Vector3(30.0, 0.0, 0.0)
	world._process_swallows()
	swallow.set_surfaced(true)
	var rim: Vector3 = swallow.pull_at(swallow.global_position
		- Vector3(SimConfig.SWALLOW_REACH - 0.05, 0.0, 0.0))
	var core: Vector3 = swallow.pull_at(swallow.global_position
		- Vector3(SimConfig.SWALLOW_CORE - 0.2, 0.0, 0.0))
	var outside: Vector3 = swallow.pull_at(swallow.global_position
		- Vector3(SimConfig.SWALLOW_REACH + 2.0, 0.0, 0.0))
	print("[swallow] pull: rim %.2f, core %.2f, outside %.2f (walk %.2f)"
		% [rim.length(), core.length(), outside.length(), SimConfig.WALK_SPEED])
	check(rim.length() < SimConfig.WALK_SPEED,
		"at the rim the pull is under walking pace (%.2f against %.2f) -- you "
			% [rim.length(), SimConfig.WALK_SPEED]
		+ "walked in and you can walk out, and that is the only fairness an enemy "
		+ "with no wind-up can have")
	check(core.length() > SimConfig.WALK_SPEED,
		"in the core it is over walking pace (%.2f against %.2f) -- legs are not "
			% [core.length(), SimConfig.WALK_SPEED]
		+ "the answer there, shooting is")
	eq(outside.length(), 0.0, "and outside its reach there is nothing at all")
	phase = 4
	_at = world.tick

func _and_not_in_the_core() -> void:
	# THE SAME CLAIM ON A REAL BODY, walking away under power. The numbers above
	# are the rule; this is the rule happening to somebody.
	swallow.global_position = body.global_position + Vector3(1.2, 0.0, 0.0)
	world._process_swallows()
	if world.tick < _at + 4:
		return
	if world.tick == _at + 4:
		_move = Vector2(-1.0, 0.0)      # straight away from it
		_home = body.global_position
		return
	if world.tick < _at + 40:
		swallow.global_position = _home + Vector3(1.2, 0.0, 0.0)
		return
	_move = Vector2.ZERO
	var escaped: float = _home.x - body.global_position.x
	print("[swallow] held in the core, walking away gained %.2f m in 0.6 s" % escaped)
	check(escaped < 0.5,
		"a body in the core cannot walk out of it (%.2f m in 0.6 s) -- the pull "
			% escaped
		+ "beats walking there, which is what makes the fight the answer")
	phase = 5
	_at = world.tick

# --- 4. The drain is the core only ----------------------------------------------

func _the_drain_is_the_core_only() -> void:
	world._hats.clear()
	world.clear_round_stats()
	var hat: Node = world._hats.spawn_loose(body.global_position)
	world._wear_hat(int(hat.hat_id), A, 0)
	if not check(world.hats_worn_by(A).size() == 1, "the player is wearing one hat"):
		done = true
		finish()
		return

	# IN THE RIM, NOT THE CORE. Two seconds is two drain intervals; nothing should
	# happen at all.
	swallow.global_position = body.global_position 		+ Vector3(SimConfig.SWALLOW_REACH - 0.4, 0.0, 0.0)
	swallow.held_hats.clear()
	swallow.drain_timer = 0.0
	for i in 130:
		world._process_swallows()
		swallow.drain_timer += SimConfig.TICK_DELTA
	var kept: int = world.hats_worn_by(A).size()
	print("[swallow] two seconds in the RIM: %d hats worn, bank %d"
		% [kept, swallow.bank_size()])
	eq(kept, 1,
		"the rim takes nothing (%d hats left) -- you are eaten only where you "
			% kept
		+ "cannot leave, and the band you CAN walk out of is the only warning "
		+ "this design affords")
	eq(swallow.bank_size(), 0, "and its bank is still empty")

	# AND IN THE CORE.
	swallow.global_position = body.global_position + Vector3(0.6, 0.0, 0.0)
	swallow.drain_timer = 0.0
	for i in 70:
		world._process_swallows()
	print("[swallow] one second in the CORE: %d hats worn, bank %d"
		% [world.hats_worn_by(A).size(), swallow.bank_size()])
	eq(world.hats_worn_by(A).size(), 0, "the core takes the hat off your head")
	eq(swallow.bank_size(), 1, "and holds it rather than destroying it")
	_a_bite_is_one_unit()
	phase = 6
	_at = world.tick

# WITH NOTHING LEFT TO TAKE IT TAKES HEALTH, ONE UNIT AT A TIME.
#
# THE CLAIM IS THAT IT CANNOT ONE-SHOT YOU, and it exists because the first
# version could: the bite was written as 8 against a MAX_HEALTH of 5, so a player
# with no hats died on the first tick of the drain and every second after. Nothing
# caught it, because the drain phase above only ever tested a player who HAD a hat
# -- the branch that takes health had never run.
#
# Asserted as a RELATIONSHIP to MAX_HEALTH rather than as the number 1: the rule
# is that being bitten is a drain rather than an execution, and that stays true if
# somebody retunes the health bar.
func _a_bite_is_one_unit() -> void:
	check(SimConfig.SWALLOW_BITE_DAMAGE < SimConfig.MAX_HEALTH,
		"a bite cannot kill a full-health player outright (%d against %d) -- the "
			% [SimConfig.SWALLOW_BITE_DAMAGE, SimConfig.MAX_HEALTH]
		+ "bite is the health-shaped version of taking one hat, so it has to be "
		+ "one unit of something rather than all of it")

	# AND IT REALLY HAPPENS TO A HATLESS BODY. The branch had never been reached by
	# a test at all -- the drain phase above always gave the player a hat first.
	world._hats.clear()
	var before: int = int(body.health)
	swallow.global_position = body.global_position + Vector3(0.6, 0.0, 0.0)
	swallow.drain_timer = 0.0
	body.invulnerable = 0.0
	for i in 70:
		world._process_swallows()
	print("[swallow] a hatless second in the core: health %d -> %d (of %d)"
		% [before, int(body.health), SimConfig.MAX_HEALTH])
	check(int(body.health) < before,
		"a player with no hats is bitten rather than ignored (%d from %d) -- "
			% [int(body.health), before]
		+ "otherwise the thing that took your tower cannot touch you afterwards, "
		+ "which is the wrong way round")
	check(int(body.health) > 0,
		"and survives a single bite (%d left) -- a drain, not an execution"
			% int(body.health))

# --- 5. The bank ------------------------------------------------------------------

func _the_bank_spills_when_killed() -> void:
	var held: int = swallow.bank_size()
	if not check(held > 0, "there is something in the bank to spill (%d)" % held):
		done = true
		finish()
		return
	world._hats.clear()
	swallow.killed = true
	world._process_swallows()
	var loose := 0
	for hat in world._hats.all():
		if is_instance_valid(hat) and hat.mode != HatBody.Mode.WORN:
			loose += 1
	print("[swallow] killed while holding %d: %d loose hats on the ground"
		% [held, loose])
	eq(loose, held,
		"killing it spills everything it took (%d of %d) -- which is the whole "
			% [loose, held]
		+ "reason to stand and fight rather than walk away")
	phase = 7
	_at = world.tick

func _and_is_lost_when_it_is_not() -> void:
	# THE OTHER WAY OUT OF THE WORLD. A swallow swept with the corridor takes its
	# bank with it -- that is what makes the bank a wager -- but the loss has to be
	# ATTRIBUTED, or a player finds hats missing and nothing anywhere saying why.
	world._hats.clear()
	world.clear_round_stats()
	var doomed = world._spawn_swallow(_home + Vector3(0.0, 0.0, -8.0))
	doomed.swallow_hat(0, A)
	doomed.swallow_hat(1, A)
	var before: int = int(world.stats_of(A).get("hats_lost", 0))
	world._note_lost_bank(doomed)
	var after: int = int(world.stats_of(A).get("hats_lost", 0))
	print("[swallow] a bank left behind: hats_lost %d -> %d" % [before, after])
	eq(after - before, 2,
		"a swallow that leaves the world uneaten counts what it took (%d) -- the "
			% (after - before)
		+ "loss is permanent, which is the design, but a score that changes with "
		+ "no event anywhere is a bug as far as the player can tell")
	phase = 8


# --- 6. PLACEMENT ----------------------------------------------------------------
#
# THE LIVE CLAIM IS THAT THEY HAPPEN. Where a generator validates and rerolls, a
# bug is an ABSENCE -- and this pass has three ways to produce none (no water in
# the section, the rarity roll, every water cell too near a stop) so a rule
# asserted ABOUT swallows is a wall of green over an empty set until a count says
# otherwise. This file has already watched that happen twice with channel shapes.
#
# AND EVERY ONE IS IN WATER AND CLEAR OF A STOP. The second is the rule that
# follows from this enemy having no counter-play at all: it cannot be sniped, a
# blast cannot reach it, and it gives no warning -- so an ambush on a spot the
# party MUST occupy is a toll rather than a hazard.

func _the_terrain_places_them() -> void:
	var placed := 0
	var sections := 0
	var wet_sections := 0
	var dry := 0
	var near_a_stop := 0
	var doubled := 0
	for i in 90:
		var seg = SegmentGen.section(21, 7100 + i * 17, i + 1)
		if seg == null:
			continue
		sections += 1
		var has_water := false
		for z in seg.length:
			for x in seg.width:
				if seg.kind_at(x, z) == GridConfig.Kind.WATER:
					has_water = true
					break
			if has_water:
				break
		if has_water:
			wet_sections += 1
		var dressed = HazardDressing.dress(seg, "environmental", 7100 + i * 17, i)
		if seg.water_spawn_cells.size() > 1:
			doubled += 1
		for entry in seg.water_spawn_cells:
			var cell: Vector2i = entry[0]
			placed += 1
			if seg.kind_at(cell.x, cell.y) != GridConfig.Kind.WATER:
				dry += 1
			if not HazardDressing._clear_of_stops(seg, cell.x, cell.y):
				near_a_stop += 1
	print("[swallow] %d sections, %d with water, %d swallows placed"
		% [sections, wet_sections, placed])
	check(wet_sections > 0,
		"the sample has water in it at all (%d of %d) -- everything below is "
			% [wet_sections, sections]
		+ "about an empty set otherwise")
	check(placed > 0,
		"the dressing pass really places swallows (%d over %d wet sections) -- "
			% [placed, wet_sections]
		+ "there are three ways for this pass to produce none, and a rule "
		+ "asserted about swallows passes over every one of them")
	check(placed < wet_sections,
		"and not in every body of water (%d of %d) -- meeting one has to be an "
			% [placed, wet_sections]
		+ "event rather than a toll on every crossing")
	eq(dry, 0, "every one is in water (%d were not)" % dry)
	eq(doubled, 0,
		"and at most one to a section (%d had more) -- a section's water is one "
			% doubled
		+ "connected thing, so one per section is one per body")
	eq(near_a_stop, 0,
		"and none within reach of a merchant, a selector or a bus post (%d were) "
			% near_a_stop
		+ "-- with no sniping, no blast and no warning, an ambush on a spot the "
		+ "party must stand at is a toll rather than a hazard")
	_and_the_stop_rule_can_actually_refuse()
	done = true
	finish()

# THE CLAIM ABOVE IS NOT LIVE ON ITS OWN, and the A/B is the only thing that says
# so: with the clearance rule deleted the count stayed at zero, because no
# generated section happens to put water within three cells of a merchant or a
# post. A rule that protects against a case the sample never contains is a wall
# of green over an unreachable branch -- which this project has shipped twice.
#
# SO THE CASE IS BUILT. Every deck cell touching the water gets a bus post, so
# there is nowhere in that water more than one cell from a stop, and the pass is
# asked many times over. Refusing to place is then the only correct answer, and
# the count of ATTEMPTS is printed so "it never rolled one" cannot be mistaken for
# "it refused".
func _and_the_stop_rule_can_actually_refuse() -> void:
	var seg = null
	for i in 90:
		var candidate = SegmentGen.section(21, 7100 + i * 17, i + 1)
		if candidate == null:
			continue
		var wet := false
		for z in candidate.length:
			for x in candidate.width:
				if candidate.kind_at(x, z) == GridConfig.Kind.WATER:
					wet = true
					break
			if wet:
				break
		if wet:
			seg = candidate
			break
	if not check(seg != null, "there is a wet section to fence in"):
		return

	var posts := 0
	for z in seg.length:
		for x in seg.width:
			if seg.kind_at(x, z) != GridConfig.Kind.DECK:
				continue
			var beside := false
			for dir in 4:
				var n: Vector2i = Vector2i(x, z) + GridConfig.DIR_CELLS[dir]
				if n.x < 0 or n.x >= seg.width or n.y < 0 or n.y >= seg.length:
					continue
				if seg.kind_at(n.x, n.y) == GridConfig.Kind.WATER:
					beside = true
					break
			if beside:
				seg.contents[z][x] = GridConfig.Content.BUS_POST
				posts += 1

	var tried := 0
	var placed := 0
	for salt in 40:
		seg.water_spawn_cells.clear()
		tried += 1
		HazardDressing._place_water_dwellers(seg, 900 + salt * 7)
		placed += seg.water_spawn_cells.size()
	print("[swallow] water ringed by %d bus posts: %d placed over %d attempts"
		% [posts, placed, tried])
	check(posts > 0, "the water really got fenced in (%d posts)" % posts)
	eq(placed, 0,
		"a swallow is never placed in water a player has to stand beside (%d over "
			% placed
		+ "%d attempts) -- this is the case no generated section contains, so "
			% tried
		+ "without building it the rule passes with itself deleted")
