extends RigidBody3D

# A LIVE THING ON THE DECK. A thrown grenade today; the land mine lands here too,
# because what the two share is most of what they are -- a small body somewhere on
# the bridge that is going to explode, and that everybody can see and walk away
# from.
#
# ONE SCRIPT, TWO KINDS, and that is a considered position rather than the default
# one -- turret_body.gd was split out of exactly this shape an hour before this was
# written. The test applied there: does the second kind need STATE the first has no
# use for? Here it does not. Both are a body with a countdown; they disagree only
# about what starts the countdown, which is one branch in `_should_detonate`. If a
# mine grows an owner it will not trigger for, or a disarm, the answer changes and
# this splits the same way the gunners did.
#
# A RIGID BODY, like a plinko ball and a dropped special: where a thrown thing
# bounces to is physics rather than a designed rule, and it is host-authoritative
# and never predicted, so the determinism objection does not apply.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

enum Kind { GRENADE, MINE }

# Host-assigned and monotonic, never a creation-order index -- these are created
# mid-run, so creation order is not agreed between machines.
var deployable_id: int = 0

var kind: int = Kind.GRENADE

# WHO THREW IT, and it does NOT make them safe. Carried because a blast wants to
# know its source for the damage model, and because a mine will eventually want
# to not arm under its own owner's feet. Friendly fire is on: an explosive that
# cannot hurt the party is a free button, and this game's whole comedy is the
# party being a hazard to itself.
var thrower: int = 0

# Seconds until it goes off. For a grenade this is the fuse and runs from the
# moment it leaves the hand.
var timer: float = 0.0

var detonated: bool = false

func _ready() -> void:
	gravity_scale = SimConfig.GRAVITY / 9.8
	continuous_cd = true

	# IT LANDS WHERE IT WAS THROWN, AND STAYS THERE. The first version let it roll
	# a little for flavour and it rolled 2.4 m down the deck's 4-degree pitch
	# during a 1.4 s fuse -- which quietly moved every grenade out of the place the
	# player chose, and moved the shortest throw clean outside its own blast. A
	# grenade is PLACED, not bowled; the plinko ball is the thing in this game
	# whose whole job is to roll.
	lock_rotation = true
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 1.0
	physics_material_override.bounce = 0.0
	physics_material_override.rough = true

	# ZERO, deliberately. Damping acts in the air as well as on the deck, and the
	# throw solves an exact ballistic arc for the distance the player asked for --
	# any drag at all makes every throw land short of its own tuning value.
	linear_damp = 0.0

func throw_from(at: Vector3, velocity: Vector3, peer: int) -> void:
	kind = Kind.GRENADE
	thrower = peer
	timer = SimConfig.GRENADE_FUSE
	position = at
	linear_velocity = velocity

# One sim tick of the countdown. Returns true on the tick it should go off; the
# world owns the blast itself, because a blast reaches other pools and this object
# has no business knowing about them.
func step() -> bool:
	if detonated:
		return false
	timer = maxf(0.0, timer - SimConfig.TICK_DELTA)
	if not _should_detonate():
		return false
	detonated = true
	return true

func _should_detonate() -> bool:
	return timer <= 0.0

func blast_radius() -> float:
	return SimConfig.BLAST_RADIUS

func is_gone() -> bool:
	return detonated or position.y < SimConfig.FALL_KILL_Y

# THROWN BY A BLAST, NOT SET OFF BY ONE. A chain reaction is a great deal of
# consequence for one button, and the fuse already gives a second grenade its own
# moment. It is debris like everything else.
func receive_hit(hit) -> bool:
	if hit.kind != Hit.Kind.EXPLOSIVE:
		return false
	apply_central_impulse(hit.launch_for(position))
	return true

# Clients are TOLD where it is; they never simulate one. The timer rides along so
# a client can eventually show a fuse running down without asking.
func capture_state() -> Array:
	return [deployable_id, kind, position, timer]

func apply_state(s: Array) -> void:
	position = s[2]
	timer = float(s[3])
	freeze = true
