extends RigidBody3D

# A special: a pickup with a fixed number of uses, of which the machine gun is
# the first. See implementation_plans/m12_machine_gun.md and game_concept.md
# §Special.
#
# ONE RECORD IN EXACTLY ONE OF THREE MODES, the same model hat_body.gd uses and
# for the same reasons:
#
#   HELD    in somebody's hands, no physics, drawn on their Facing pivot
#   FLYING  just dropped, landing, NOT collectable
#   LOOSE   settled on the deck, collectable
#
# A RIGID BODY, like a plinko ball and a hat: what a dropped weapon does on the
# way down is physics rather than a designed rule, and specials are
# host-authoritative and never predicted, so the determinism objection does not
# apply.
#
# WHAT IS DELIBERATELY NOT HERE: anything that affects stepping. Firing does not
# move you -- there is no recoil, on purpose -- so no field on this object belongs
# in PlayerBody.capture_state(), and none of it is replayed. That is the roadmap's
# own split for M12, applied: the half of a special that affects walking is legs,
# and legs are not this.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

enum Mode { HELD, FLYING, LOOSE }

# WHICH SPECIAL. The pool, the slot, the drop rule and the HUD box are shared, so
# a new special is a different resolve function rather than a different object --
# what differs between them is what the BUTTON means, and that lives in the world.
# APPENDED, NEVER REORDERED. A kind's integer is what segment_builder resolves an
# authored glyph to and what the pickup travels as, so inserting one in the middle
# would silently turn every rocket in every level into a mine.
enum Kind { MACHINE_GUN, GRENADE, MINE, SHIELD, ROCKET, LEGS, SHOTGUN, RIFLE, HEAVY }

# Host-assigned and monotonic, NEVER a creation-order index. A special can be
# created mid-run by a swap, so creation order is not agreed between machines --
# the same trap hat_body.gd documents.
var special_id: int = 0

var kind: int = Kind.MACHINE_GUN

# THE RESOURCE. Fixed uses is the model every special shares, and this is it.
# It lives HERE rather than on the player because it belongs to the object: a
# gun dropped with 12 rounds left is picked up with 12 rounds left, which is what
# makes a half-spent weapon on the deck a real decision rather than litter.
var ammo: int = 0

var mode: int = Mode.LOOSE

# PLACED BY AN AUTHOR, not dropped by a player. It is the difference between the
# level and the litter, and the loose cap bounds only the litter -- see
# SpecialPool.step. Without it, authoring more pickups than SPECIAL_MAX_LOOSE
# silently deletes the oldest of them, which is the ones nearest the spawn.
var authored: bool = false

# Only meaningful while HELD.
var owner_peer: int = 0

# Seconds until the next round may leave. Host-side, and reset on pickup so a
# swap is not a way to fire faster.
var fire_timer: float = 0.0

# Counts down once the body has stopped moving. Only at zero is it collectable.
var settle_grace: float = 0.0

# --- The trigger, host-side ----------------------------------------------------
#
# THE EDGES ARE DERIVED HERE, FROM THE LEVEL BIT, rather than sent as their own
# action. A machine gun only ever asked "is it down"; a grenade needs "did it just
# come up", and the cheapest correct place to answer that is the object holding
# the trigger, once, on the host. Deriving it also means a special does not depend
# on a press packet ARRIVING -- a lost edge would silently do nothing, and this way
# the next tick's level bit still tells the truth.
var was_held: bool = false

# Seconds the trigger has been down. A grenade's throw distance; ignored by
# anything that fires on the way down.
var charge: float = 0.0

# 0..1 across GRENADE_CHARGE_TIME. What a HUD would draw, and what the throw reads.
func charge_fraction() -> float:
	return clampf(charge / SimConfig.GRENADE_CHARGE_TIME, 0.0, 1.0)

func _ready() -> void:
	gravity_scale = SimConfig.GRAVITY / 9.8
	continuous_cd = true
	# A DROPPED WEAPON MUST NOT ROLL. The deck is pitched 4 degrees by design, and
	# a body that keeps rolling never drops below SPECIAL_SETTLE_SPEED, so it never
	# becomes LOOSE and is never collectable -- a gun that runs away down the
	# bridge. Cost hat_body.gd a test to find; inherited here rather than
	# rediscovered.
	lock_rotation = true
	linear_damp = 0.6

func kind_name() -> String:
	match kind:
		Kind.MACHINE_GUN:
			return "MG"
		Kind.GRENADE:
			return "NADE"
		Kind.MINE:
			return "MINE"
		Kind.SHIELD:
			return "SHLD"
		Kind.ROCKET:
			return "RKT"
		Kind.LEGS:
			return "LEGS"
		Kind.SHOTGUN:
			return "SHOT"
		Kind.RIFLE:
			return "RIFLE"
		Kind.HEAVY:
			return "HEAVY"
	return "?"

# WHAT IT LOOKS LIKE ON THE DECK. One scene serves every kind -- the shape, the
# collision and the held-pivot geometry are identical -- so without this a shield
# lying on the ground is a machine gun lying on the ground, and the one-slot rule
# turns into a lottery.
#
# WARM MEANS IT HURTS SOMETHING, COOL MEANS IT PROTECTS YOU. Every hazard, every
# muzzle and every explosive on this bridge is warm; the shield is the only cool
# object in the game, which is a whole line of communication for free.
#
# The material is DUPLICATED first. Sub-resources are shared between instances of
# a scene, so tinting one in place would repaint every special in the world --
# including the ones already in somebody's hands.
# The node that IS this kind. Every silhouette exists in the scene from the start
# and five of the six are hidden -- see special.tscn for why they are not built
# on demand.
const SHAPE_NODES := {
	Kind.MACHINE_GUN: "Body",
	Kind.ROCKET: "Rocket",
	Kind.GRENADE: "Nade",
	Kind.MINE: "Mine",
	Kind.SHIELD: "Shield",
	Kind.LEGS: "Legs",
	# THE TWO NEW GUNS BORROW THE MACHINE GUN'S SILHOUETTE. They are a gun-shaped
	# thing with a barrel, which is the reading that matters on the deck, and the
	# COLOUR is what tells them apart -- the same job it already does for the five
	# kinds that share this scene. A distinct mesh each is an art task, not a
	# gameplay one, and this milestone is an A/B about aiming.
	Kind.SHOTGUN: "Body",
	Kind.RIFLE: "Body",
	Kind.HEAVY: "Body",
}

# ONE WRITE PER MESH, DECIDED BY THE MESH -- not one write per KIND.
#
# This used to loop over SHAPE_NODES and set `node.visible = (shape_kind == kind)`
# on each pass. That was correct while the mapping was one kind to one mesh, and
# it broke silently the moment four kinds started sharing "Body": every pass wrote
# that node's visibility, so the LAST kind in the dictionary decided it for
# everybody. HEAVY is last, so the heavy gun was the only one of the four with a
# body and the other three were a floating barrel.
#
# Reported from play as "the machine gun comes out with a grey body, but for the
# other three you can only see the barrel" -- and grey is the heavy's gunmetal,
# which is the tell: the gun with a body was the one whose entry ran last.
#
# THE GENERAL SHAPE IS WORTH THE NOTE: a lookup table whose VALUES repeat, walked
# by key, writing to the value. Every duplicate is a write, and only the last one
# survives. Deduplicating on the mesh name is what makes the loop say what it
# means -- "is this the mesh MY kind uses" -- rather than "am I the kind whose
# turn this is".
func apply_kind_look() -> void:
	var mine_node: String = str(SHAPE_NODES.get(kind, ""))
	var done: Dictionary = {}
	for shape_kind in SHAPE_NODES:
		var node_name: String = str(SHAPE_NODES[shape_kind])
		if done.has(node_name):
			continue
		done[node_name] = true
		var node := get_node_or_null(node_name) as MeshInstance3D
		if node == null:
			continue
		var mine: bool = node_name == mine_node
		node.visible = mine
		if mine and node.material_override != null:
			var mat: StandardMaterial3D = node.material_override.duplicate()
			mat.albedo_color = _kind_colour()
			node.material_override = mat
	# The barrel is the machine gun's tell and nobody else's: a thrown, placed or
	# raised thing does not point, and the rocket has its own tube.
	var barrel := get_node_or_null("Barrel") as MeshInstance3D
	if barrel != null:
		# EVERY GUN HAS ONE. It was the machine gun's tell when the machine gun was
		# the only thing that pointed; a shotgun and a rifle point too.
		barrel.visible = kind == Kind.MACHINE_GUN or kind == Kind.SHOTGUN or kind == Kind.RIFLE or kind == Kind.HEAVY

func _kind_colour() -> Color:
	match kind:
		Kind.GRENADE:
			return Color(0.95, 0.75, 0.15)   # the same hazard yellow it throws
		Kind.MINE:
			return Color(0.85, 0.22, 0.15)
		Kind.SHIELD:
			return Color(0.25, 0.52, 0.88)
		Kind.ROCKET:
			return Color(0.55, 0.62, 0.30)   # olive, the only military thing here
		Kind.LEGS:
			return Color(0.35, 0.85, 0.70)   # spring green, and the only mobility one
		Kind.SHOTGUN:
			return Color(0.80, 0.35, 0.10)   # a hotter, redder orange than the MG
		Kind.RIFLE:
			return Color(0.55, 0.80, 0.95)   # pale blue: the only PRECISE warm thing
		Kind.HEAVY:
			return Color(0.45, 0.42, 0.40)   # gunmetal, the only HEAVY-looking one
	return Color(0.95, 0.6, 0.15)            # the machine gun, unchanged

# Bookkeeping only -- the physics server moves a dropped special. Called once per
# sim tick by the pool.
func step() -> void:
	if mode != Mode.FLYING:
		return
	# "Landed" is a speed test rather than a contact test: a weapon that slid to a
	# halt against a parapet has landed just as much as one that dropped flat.
	if linear_velocity.length() > SimConfig.SPECIAL_SETTLE_SPEED:
		settle_grace = SimConfig.SPECIAL_SETTLE_GRACE
		return
	settle_grace = maxf(0.0, settle_grace - SimConfig.TICK_DELTA)
	if settle_grace <= 0.0:
		mode = Mode.LOOSE

# SCATTERED BY A BLAST, AND BY NOTHING ELSE. Gunfire deliberately cannot strip a
# friend's hat stack or knock the gun out of their hands -- that would put the
# whole M8.5 reward curve at the mercy of a stray round -- but debris thrown by an
# explosion is free and looks right.
#
# A HELD or WORN one is untouched: it is not in the world to be thrown.
func receive_hit(hit) -> bool:
	if hit.kind != Hit.Kind.EXPLOSIVE or mode == Mode.HELD:
		return false
	drop(position, hit.launch_for(position))
	return true

func is_collectable() -> bool:
	return mode == Mode.LOOSE and ammo > 0

func is_gone() -> bool:
	return position.y < SimConfig.FALL_KILL_Y

func is_spent() -> bool:
	return ammo <= 0

# Placed by an author, or spawned already settled. Collectable at once: nobody
# dropped it, so there is no re-collect to prevent.
func place_loose(at: Vector3) -> void:
	mode = Mode.LOOSE
	settle_grace = 0.0
	_set_simulated(true)
	position = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

# Dropped, because its holder picked up a different one. Lands, and is
# uncollectable until it settles -- so a swap is not a way to pick your own gun
# straight back up.
func drop(from: Vector3, velocity: Vector3) -> void:
	mode = Mode.FLYING
	settle_grace = SimConfig.SPECIAL_SETTLE_GRACE
	_set_simulated(true)
	position = from
	linear_velocity = velocity
	angular_velocity = Vector3.ZERO

# Into somebody's hands. The physics body stops existing as far as the world is
# concerned: frozen, no collision, positioned by whoever is holding it.
func hold(peer: int) -> void:
	mode = Mode.HELD
	owner_peer = peer
	settle_grace = 0.0
	# RESET ON PICKUP, so walking over a fresh gun does not fire a free round from
	# a timer that ran down while the last one was on the floor.
	fire_timer = SimConfig.MG_FIRE_INTERVAL
	_set_simulated(false)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rotation = Vector3.ZERO

func _set_simulated(simulated: bool) -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not simulated
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if shape != null:
		shape.disabled = not simulated

# Clients are TOLD where a loose special is; they never simulate one.
func apply_remote(new_mode: int, at: Vector3, remaining: int) -> void:
	mode = new_mode
	ammo = remaining
	_set_simulated(false)
	position = at
