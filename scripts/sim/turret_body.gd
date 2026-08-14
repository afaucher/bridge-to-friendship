extends "res://scripts/sim/gunner_body.gd"

# The gun that is bolted to the deck.
#
# THREE THINGS MAKE IT A DIFFERENT OBJECT rather than a skirmisher with a flag,
# and the third is the one that forced the split:
#
#   1. It does not move, so distance is the player's decision alone.
#   2. A DASH DOES NOTHING TO IT. Dashing a bolted-down gun must not work, or the
#      free verb answers the hazard and the weapon specials lose another customer
#      -- hazards.md warns about that twice. It is the first thing on this bridge
#      that genuinely wants cover or a weapon.
#   3. IT HAS A MOUNT FACING AND A FIRING ARC. It cannot simply turn to look at
#      you, which is the point: an arc is meaningless on something that can spin
#      freely, and it is what makes FLANKING an answer the geometry supplies for
#      free.
#
# ITS ENGAGEMENT PROFILE IS ITS OWN. It reaches further and fires slower than a
# skirmisher: it cannot reposition, so its threat is persistence rather than
# pressure, and a player crossing in front of it should be paying for distance
# rather than for reaction time.

const Conf = preload("res://scripts/sim/sim_config.gd")
const Grid = preload("res://scripts/grid/grid_config.gd")

# WHERE IT WAS BOLTED, and the axis its arc is measured from. Defaults to looking
# DOWN the bridge, which is the direction players arrive from. An authored per-
# turret facing is a glyph question and is deliberately not invented here -- the
# field exists so that answering it later changes a loader, not this file.
var mount_yaw: float = PI

func _init() -> void:
	kind = Kind.TURRET

func fire_range() -> float:
	return Conf.TURRET_RANGE

func fire_interval() -> float:
	return Conf.TURRET_FIRE_INTERVAL

# BOLTED DOWN. See the header -- this is the design position that makes a turret
# worth having at all.
func receive_impact(_hit) -> bool:
	return false

func move_for(_target: Node) -> void:
	velocity.x = 0.0
	velocity.z = 0.0

# IT SWINGS ONLY WITHIN ITS ARC, and rests against the edge of it when it cannot
# reach. That is what the player sees: a gun that stops tracking as you cross its
# limit, which is the tell that flanking has worked.
func aim_at(yaw: float) -> void:
	var half: float = deg_to_rad(arc_deg()) * 0.5
	facing = mount_yaw + clampf(wrapf(yaw - mount_yaw, -PI, PI), -half, half)

func can_bear_on(target: Node) -> bool:
	if target == null:
		return false
	var to_target := Vector3(target.position.x - position.x, 0.0,
		target.position.z - position.z)
	if to_target.length_squared() < 0.0001:
		return true
	var off: float = absf(wrapf(Grid.yaw_of_vector(to_target) - mount_yaw, -PI, PI))
	return off <= deg_to_rad(arc_deg()) * 0.5

# TUNABLE, AND 360 BY DEFAULT -- which is exactly the behaviour that shipped
# before the split, so this arrives as a seam rather than as a balance change.
# Narrowing it is one slider in the debug console, which is where the value should
# be FOUND rather than argued about.
func arc_deg() -> float:
	return DebugSettings.tuned("turret_arc_deg", Conf.TURRET_ARC_DEG)
