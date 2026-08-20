extends "res://scripts/test_support/test_case.gd"

# THE MERCHANT'S HAT: a reserved band of style ids, and a slot three and a half
# times an ordinary one. See design_ideas/merchant.md findings 1 and 2.
#
# The claims:
#   1. THE BAND IS UNREACHABLE BY LUCK. Every hat in the game that is not handed
#      over a counter comes out of HatPool.spawn_loose, so "the only source is the
#      merchant" is a property of that function or it is a promise in a document.
#      Rolled through the real caller, not through the roll it happens to use.
#   2. ...and the band is reachable ON PURPOSE, which is the control. An
#      is_tall() that answered false for everything would satisfy claim 1 forever.
#   3. A tall hat occupies TALL_HAT_SLOTS of tower, an ordinary one exactly one,
#      and a stack of [ordinary, tall, ordinary] is spaced by EACH HAT'S OWN SLOT.
#   4. AND THE HIT COLUMNS TILE WITH NO GAP, sampled with real rounds every few
#      centimetres up the whole tower rather than once at the middle of each hat.
#
# CLAIM 4 IS THE ONE THIS FILE IS FOR. `HAT_HEIGHT` was never "how tall a hat is"
# -- it is how tall a SLOT is, and it was a bare constant at both the site that
# SPACES the tower and the site that sizes what a bullet can HIT. Per-hat slots
# mean both must ask the same function: take the spacing and leave the hit column
# on the constant and there is 0.88 m of visible hat with no collider in it, which
# is the 2026-08-16 gappy tower rebuilt on purpose. The report reads "I shot him
# in the big hat and nothing happened", and a test that samples one height per hat
# is green for the whole life of it.
#
# EVERY SAMPLE REBUILDS THE STACK. A round takes the hat it hit and everything
# above it, so sample N is fired at a tower sample N-1 already dismantled -- the
# fixture-gets-dirtier trap, and here it would silently turn "no gap" into "the
# first shot worked".

const GridConfig = preload("res://scripts/grid/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")
const PlayerInput = preload("res://scripts/sim/player_input.gd")
const HatStyle = preload("res://scripts/sim/hat_style.gd")
const GameWorldScript = preload("res://scripts/sim/game_world.gd")

# Fine enough that a gap the width of one ordinary slot could not hide between two
# samples: 5 cm against the 0.35 m an ordinary hat occupies.
const SAMPLE_STEP := 0.05

# ONE SAMPLE PER WINDOW: rebuild the tower, let it settle, fire, read.
#
# THE READ HAS TO OUTLAST THE FLIGHT, and the first version of this did not. A
# round leaves the muzzle 6 m out at MG_BULLET_SPEED (22 m/s), so it is in the air
# for 16 frames -- read 9 frames after firing, EVERY sample missed and the test
# reported 38 gaps in a tower that has none. A sampling window that closes before
# the event is the twin of a window that opens after it, and both read as the
# feature being broken.
const SAMPLE_FRAMES := 45
const FIRE_AT := 10

var world: Node3D = null
var victim: CharacterBody3D = null
var frames: int = 0
var phase: int = 0

# The heights to fire at, computed from the real tower once it is standing.
var _heights: Array = []
var _sample: int = 0
var _misses: Array = []

func setup(main) -> void:
	timeout_seconds = 120.0
	world = Node3D.new()
	world.name = "TallHatWorld"
	world.set_script(GameWorldScript)
	main.add_child(world)
	world.segment_paths = ["res://segments/test_flat.seg"]
	world.start(true, 1, false)
	world._spawn_player(1, 0)
	# A SECOND PLAYER PARKED FAR AWAY. A solo player going down is a wipe, and a
	# wipe clears every hat -- which would satisfy "the round took hats" for
	# entirely the wrong reason. Same trap test_hat_shot documents.
	world._spawn_player(2, 1)
	victim = world.player_body(1)
	world.player_body(2).position = (
		world.grid.cell_surface_world(Vector2i(27, 1)) + Vector3(0.0, 1.0, 0.0))
	for peer in [1, 2]:
		world.scripted_inputs[peer] = func(t: int) -> Array:
			return PlayerInput.empty(t)
	victim.position = world.grid.cell_surface_world(Vector2i(15, 5)) + Vector3(0.0, 1.0, 0.0)
	victim.velocity = Vector3.ZERO

	_check_the_reserved_band()
	_check_the_slot_sizes()

# --- 1 + 2. The band ----------------------------------------------------------

func _check_the_reserved_band() -> void:
	# THROUGH THE REAL SPAWN, because that is where the guard has to live. Rolling
	# HatStyle.random_ordinary_style() directly would test the roll and leave
	# spawn_loose free to go back to a raw randi() with nothing noticing.
	var leaked := 0
	var rolled: Array = []
	var lowest: int = 1 << 62
	for _i in 1000:
		var hat: Node = world._hats.spawn_loose(victim.position + Vector3(0.0, 40.0, 0.0))
		if hat.is_tall():
			leaked += 1
		rolled.append(int(hat.style_id))
		lowest = mini(lowest, int(hat.style_id))
	world._hats.clear()
	eq(leaked, 0,
		"1000 hats spawned through the ordinary path and NONE landed in the tall "
		+ "band -- the merchant being the only source is a property of the code, "
		+ "not a convention somebody has to remember")

	# AND A SAMPLE CANNOT PROVE AN ABSENCE. The band is 8 ids wide out of a
	# billion, so a thousand clean rolls is what a BROKEN guard looks like too --
	# it would take millions of spawns for the sample itself to mean anything.
	# What is actually being claimed is that the roll's FLOOR sits above the band,
	# so assert the floor and the boundary either side of it: those are exact, and
	# they are what makes the loop above evidence rather than decoration.
	check(lowest >= HatStyle.TALL_FIRST + HatStyle.TALL_STYLE_COUNT,
		"and the lowest id rolled (%d) is above the band entirely -- which is the "
			% lowest
		+ "real guarantee: a sample of a thousand cannot see a leak of eight in a "
		+ "billion, and would look exactly like this if the guard were gone")
	check(HatStyle.is_tall(HatStyle.TALL_FIRST + HatStyle.TALL_STYLE_COUNT - 1),
		"the last id INSIDE the band is tall -- an off-by-one here leaks a trophy "
		+ "into the catalogue")
	check(not HatStyle.is_tall(HatStyle.TALL_FIRST + HatStyle.TALL_STYLE_COUNT),
		"and the first id outside it is not -- the other end of the same fencepost")

	# AND THEY ARE NOT ALL ONE HAT. A random_ordinary_style() that returned a
	# constant would pass the line above perfectly.
	var distinct := {}
	for style in rolled:
		distinct[style] = true
	check(distinct.size() > 900,
		"and they are still varied (%d distinct in 1000) -- a roll pinned to one "
			% distinct.size()
		+ "value would satisfy the band rule and delete the hat catalogue")

	# THE CONTROL, and it has to be able to succeed: an is_tall() that answered
	# false for everything would make the assertion above unfalsifiable.
	var tall_seen := {}
	for _i in 400:
		var style: int = HatStyle.random_tall_style()
		check(HatStyle.is_tall(style), "a rolled tall style IS in the band (%d)" % style)
		tall_seen[style] = true
	eq(tall_seen.size(), HatStyle.TALL_STYLE_COUNT,
		"and the roll reaches every one of the %d trophies -- two players who both "
			% HatStyle.TALL_STYLE_COUNT
		+ "traded should not be wearing the identical hat")

# --- 3. The slot sizes --------------------------------------------------------

func _check_the_slot_sizes() -> void:
	near(HatStyle.slot_height(HatStyle.TALL_FIRST),
		SimConfig.HAT_HEIGHT * SimConfig.TALL_HAT_SLOTS, 0.0001,
		"a tall hat occupies TALL_HAT_SLOTS of tower")
	var ratio: float = HatStyle.slot_height(HatStyle.TALL_FIRST) / SimConfig.HAT_HEIGHT
	check(ratio >= 3.0 and ratio <= 4.0,
		"which is between three and four ordinary slots (%.2f) -- three is barely "
			% ratio
		+ "a statement and four starts swinging further than the head it is on")
	# EVERY hat in the band, not just the first: a band whose members disagree
	# about their own height is a tower whose spacing depends on which trophy you
	# were given.
	for i in HatStyle.TALL_STYLE_COUNT:
		near(HatStyle.slot_height(HatStyle.TALL_FIRST + i),
			HatStyle.slot_height(HatStyle.TALL_FIRST), 0.0001,
			"every trophy is the same height (style %d)" % (HatStyle.TALL_FIRST + i))
	# And an ordinary hat is exactly one slot however tall its MESH is -- the
	# catalogue runs 0.10 to 0.55 and always has.
	var ordinary: int = HatStyle.random_ordinary_style()
	near(HatStyle.slot_height(ordinary), SimConfig.HAT_HEIGHT, 0.0001,
		"and an ordinary hat still takes exactly one slot")

# --- 4. The tower, and the columns that tile ----------------------------------

func _physics_process(_delta: float) -> void:
	if victim == null or world.tick == 0:
		return
	frames += 1
	match phase:
		0: _phase_measure_the_tower()
		1: _phase_sweep_the_tower()

func _phase_measure_the_tower() -> void:
	if frames >= 10 and frames <= 12:
		_build_tower(frames - 10)
		return
	if frames == 40:
		var worn: Array = world._hats.worn_by(1)
		if not eq(worn.size(), 3, "the tower is [ordinary, tall, ordinary]"):
			finish()
			return
		check(not worn[0].is_tall() and worn[1].is_tall() and not worn[2].is_tall(),
			"with the trophy in the middle -- a tall hat on TOP would leave the "
			+ "gap above the tower where nothing can find it")

		# SPACED BY EACH HAT'S OWN SLOT. Centre to centre is half of mine plus half
		# of yours, which is what "the slots tile" means arithmetically.
		near(worn[1].global_position.y - worn[0].global_position.y,
			(worn[0].slot_height() + worn[1].slot_height()) * 0.5, 0.005,
			"the gap from the ordinary hat to the trophy is half of each")
		near(worn[2].global_position.y - worn[1].global_position.y,
			(worn[1].slot_height() + worn[2].slot_height()) * 0.5, 0.005,
			"and from the trophy to the hat above it, likewise -- one bare "
			+ "HAT_HEIGHT here would bury the top hat inside the tall one")

		for i in worn.size():
			var h: Node = worn[i]
			print("[tall hat] slot %d: y %.3f slot %.3f column %.3f..%.3f tall=%s"
				% [i, h.global_position.y, h.slot_height(),
					h.global_position.y - h.slot_height() * 0.5,
					h.global_position.y + h.slot_height() * 0.5, h.is_tall()])

		# THE SPAN TO SWEEP, AS OFFSETS ABOVE THE FOOT OF THE TOWER, and taken off
		# the real bodies rather than computed from the constants so that a spacing
		# bug cannot hide inside the sampling.
		#
		# RELATIVE, BECAUSE THE TOWER MOVES. The first version banked ABSOLUTE
		# heights here and fired at them for the rest of the run. By the time the
		# sweep began the player had settled 0.37 m onto the deck, taking its tower
		# with it -- so the last six samples were aimed at empty air above a column
		# that had descended out from under them, and the test reported six gaps in
		# a tower the diagnostics showed tiling perfectly. A height measured once is
		# a fact about that moment, not a fact about the fixture.
		var low: float = worn[0].global_position.y - worn[0].slot_height() * 0.5
		var high: float = worn[2].global_position.y + worn[2].slot_height() * 0.5
		# Inset by a hair at each end: the outermost millimetre of a collider is
		# the one place a solver is allowed to disagree with arithmetic, and this
		# test is about the metre in the MIDDLE.
		var offset: float = 0.02
		while offset < (high - low) - 0.02:
			_heights.append(offset)
			offset += SAMPLE_STEP
		check(_heights.size() > 30,
			"the tower is worth sweeping (%d samples over %.2f m)"
				% [_heights.size(), high - low])
		_advance(1)

func _phase_sweep_the_tower() -> void:
	var step: int = frames % SAMPLE_FRAMES
	if _sample >= _heights.size():
		if _misses.is_empty():
			print("[tall hat] %d heights swept over %.2f m, every one took a hat"
				% [_heights.size(), float(_heights[-1]) - float(_heights[0])])
		eq(_misses.size(), 0,
			("EVERY height up the tower is hittable -- a round that passes through "
			+ "it is hat with no collider in it, and the report is \"I shot him in "
			+ "the big hat and nothing happened\". Missed at these heights: %s")
				% str(_misses))
		finish()
		return
	if step == 1:
		world._hats.clear()
		_build_tower(0)
		return
	if step == 2 or step == 3:
		_build_tower(step - 1)
		return
	if step == FIRE_AT:
		var worn: Array = world._hats.worn_by(1)
		# A SAMPLE FIRED AT A TOWER THAT IS NOT STANDING IS NOT A SAMPLE. Scored
		# blind it reads as a gap, which is a failure that says the product is
		# broken when the rig is -- and this rig really did produce one, on the tick
		# after a shot that knocked the whole tower off. Retried rather than
		# tolerated, and bounded so a tower that never rebuilds fails loudly instead
		# of sweeping a hundred empty windows.
		if worn.size() != 3:
			_retries += 1
			if _retries > MAX_RETRIES:
				fail("the tower would not rebuild for sample %d (%d worn, player "
					% [_sample, worn.size()]
					+ "state %d) -- every reading after this one is meaningless"
						% victim.state)
				_sample = _heights.size()
			return
		_recorded_worn = worn.size()
		# THE FOOT OF THE TOWER AS IT IS NOW, not as it was when the offsets were
		# chosen. This is the line that makes the sweep independent of where the
		# player happens to be standing.
		_recorded_base = worn[0].global_position.y - worn[0].slot_height() * 0.5
		_fire_at_height(_recorded_base + float(_heights[_sample]))
		return
	if step == SAMPLE_FRAMES - 1:
		if _recorded_worn == 0:
			return
		var now: int = world._hats.worn_by(1).size()
		if now >= _recorded_worn:
			_misses.append("+%.2f" % float(_heights[_sample]))
			print("[tall hat] MISS at +%.2f (world y %.3f): worn %d -> %d"
				% [float(_heights[_sample]), _recorded_base + float(_heights[_sample]),
					_recorded_worn, now])
		_sample += 1
		_retries = 0
		_recorded_worn = 0

var _recorded_worn: int = 0
var _recorded_base: float = 0.0
var _retries: int = 0

const MAX_RETRIES := 4

func _advance(next: int) -> void:
	phase = next
	frames = 0

# --- helpers ------------------------------------------------------------------

# [ordinary, tall, ordinary], ONE PER CALL AND ONE CALL PER TICK, so which hat
# ends up in which slot is decided here rather than by whatever order the pickup
# pass happened to sweep three coincident hats in.
#
# The trophy goes in the MIDDLE, because that is where a gap has hats on both
# sides of it to be measured against -- on top, the space above it is outside the
# tower and nothing would notice.
func _build_tower(slot: int) -> void:
	var style: int = HatStyle.TALL_FIRST if slot == 1 else -1
	world._hats.spawn_loose(victim.position, style)

# Through _spawn_round and the sweep. A hand-built Hit would skip the raycast,
# and the raycast IS the thing under test.
func _fire_at_height(y: float) -> void:
	var muzzle: Vector3 = victim.position + Vector3(0.0, 0.0, -6.0)
	muzzle.y = y
	world._spawn_round(world.to_global(muzzle), Vector3(0.0, 0.0, 1.0), 0, RID())
