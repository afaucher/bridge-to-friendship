extends Node3D

# A round in flight. Asked for in playtest: "the bullets should be physical balls,
# not just lines."
#
# NOT A PHYSICS BODY, and not a raycast either. It is the third option, and it is
# better than both here:
#
#   * A RIGID BODY would put ten-plus objects a second into a contact graph that
#     already holds balls, stones, rushers, hats and specials -- and every body in
#     it is another chance for two machines to order contacts differently. A small
#     fast one also tunnels, which is the classic bullet-as-rigid-body bug.
#   * A HITSCAN RAY (what this shipped as first) is exact and invisible. The whole
#     point of the feedback is that a round you cannot see is not a round.
#
# So: it MOVES ITSELF one tick at a time, and the world sweeps a single ray along
# the segment it just covered. That is exact -- it cannot pass through anything at
# any speed -- costs one ray per round per tick, and puts nothing in the contact
# graph. What you see is a ball; what decides the hit is the segment it flew.
#
# HOST-AUTHORITATIVE AND NEVER PREDICTED, like a plinko ball. Clients are told
# where each round is and simulate none of them.

const SimConfig = preload("res://scripts/sim/sim_config.gd")

# Host-assigned and monotonic. Same rule as every other mid-run object here: a
# round is created by somebody pulling a trigger, so creation order is not agreed
# between machines.
var bullet_id: int = 0

var velocity: Vector3 = Vector3.ZERO
var age: float = 0.0

# WHERE IT LEFT THE BARREL. Kept because range is then a distance in metres --
# `age * speed` stands in for one only until the speed changes, and the speed has
# changed twice already. It is also the only honest way to ask "did this round
# come out of the gun", which is a thing playtest had an opinion about.
var origin: Vector3 = Vector3.ZERO

# Whose round this is. Carried so a hit can be attributed, and so the shooter's
# own body is excluded from the first sweep -- the muzzle sits about a metre in
# front of them, but a body that walks forward into its own round would otherwise
# shoot itself.
var owner_peer: int = 0
var shooter_rid: RID = RID()

# A ROCKET IS A ROUND THAT EXPLODES, which is why it is this script and not a new
# one. It travels the same way, it is swept the same way, and it is replicated the
# same way; the only thing it does differently is what happens at the far end of
# the raycast. Everything else about a rocket -- the speed, the cadence, the
# scarcity -- is tuning.
var explodes: bool = false

func launch(from: Vector3, direction: Vector3, peer: int, rid: RID,
		as_rocket: bool = false) -> void:
	explodes = as_rocket
	position = from
	origin = from
	velocity = direction.normalized() * (SimConfig.ROCKET_SPEED if as_rocket 		else SimConfig.MG_BULLET_SPEED)
	owner_peer = peer
	shooter_rid = rid
	age = 0.0
	_face_travel()

# Advance one tick and report where it came FROM, so the world can sweep the
# segment. Returning the origin rather than storing it keeps "where it was" from
# ever getting out of step with "where it is".
func step() -> Vector3:
	var from: Vector3 = position
	age += SimConfig.TICK_DELTA
	# A LITTLE DROP, not none. Perfectly flat rounds read as a laser, and this game
	# is full of arcs -- a plinko ball, a shoved player, a dislodged hat. At 45 m/s
	# over the 30 m range that is about 20 cm of fall, which is felt at the far end
	# and invisible at the near one.
	velocity.y -= SimConfig.GRAVITY * SimConfig.MG_BULLET_DROP * SimConfig.TICK_DELTA
	position += velocity * SimConfig.TICK_DELTA
	_face_travel()
	return from

# Point the whole node down its own line of travel, so the tail authored along +Z
# trails behind without anything having to position it. The ball is a sphere, so
# turning it costs nothing visually.
func _face_travel() -> void:
	if velocity.length_squared() < 0.0001:
		return
	var forward: Vector3 = velocity.normalized()
	# looking_at fails outright on a forward parallel to up, which a round fired
	# straight down a ramp is not far from.
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	basis = Basis.looking_at(forward, up)

# Out of range, out of time, or off the bottom of the world.
#
# RANGE IS A DISTANCE, measured from where it left the barrel. It could be derived
# from age and speed instead, and that stands in for a range only until the speed
# changes -- which it has now done twice.
func is_spent() -> bool:
	if origin.distance_to(position) > SimConfig.MG_RANGE:
		return true
	var lifetime: float = SimConfig.ROCKET_LIFETIME if explodes 		else SimConfig.MG_BULLET_LIFETIME
	return age > lifetime or position.y < SimConfig.FALL_KILL_Y

# Clients are TOLD where a round is; they never simulate one.
#
# The DIRECTION is derived from the step it just took, because the snapshot does
# not carry velocity and does not need to -- a tail pointing the wrong way is the
# only thing that would notice, and two positions are enough to fix that.
func apply_remote(at: Vector3) -> void:
	var moved: Vector3 = at - position
	position = at
	if moved.length_squared() > 0.0001:
		velocity = moved / SimConfig.TICK_DELTA
		_face_travel()
