extends CharacterBody3D

# WHAT EVERY WALKING ENEMY IS. Rusher, zombie, skirmisher and turret each wrote
# these for themselves -- the same `kill()`, the same "killed or fallen off the
# world" test, the same "a round or a blast ends it, anything else is somebody
# else's business" dispatch, the same gravity-plus-FLOOR_STICK step -- and the
# copies had already drifted: the rusher alone never set `floor_max_angle`, so it
# kept Godot's 45-degree default and could walk the steep ramps that are this
# game's co-op gate (a steep ramp is exactly 45 degrees; see MAX_WALK_ANGLE_DEG).
#
# NO class_name, like everything else here: a subclass `extends` this by path.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")

# ITS NETWORK IDENTITY. Every kind used to carry its own field (`rusher_id`,
# `zombie_id`, `gunner_id`); those names survive as aliases on the subclasses so
# nothing that reads them has to change, but there is one field underneath.
var id: int = 0

# "This ended in an EVENT rather than by expiring" -- shot, blasted, or spent on
# a body. `_retire_enemy` reads it to decide whether a death earned a pile.
var killed: bool = false

# Its own grounded flag rather than `is_on_floor()`, refreshed after every move.
# See CLAUDE.md: `is_on_floor()` is derived state, and a resting body flickers it.
var grounded: bool = false

func _ready() -> void:
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

func kill() -> void:
	killed = true

# Removed from its pool this tick. Killed, fallen out of the world, or -- for a
# kind that has one -- past its lifetime.
func is_spent() -> bool:
	return killed or position.y < SimConfig.FALL_KILL_Y or _expired()

func _expired() -> bool:
	return false

# A ROUND OR A BLAST ENDS IT. Nothing here has health; every enemy dies to one
# hit. Anything else -- a dash, a ball, a body -- is the kind's own business.
func receive_hit(hit) -> bool:
	match hit.kind:
		Hit.Kind.BULLET, Hit.Kind.EXPLOSIVE:
			kill()
			return true
		_:
			return receive_impact(hit)

func receive_impact(_hit) -> bool:
	return false

# One tick of falling and moving. Stuck to the floor while grounded (a resting
# body flickers `is_on_floor()` otherwise), gravity while not.
func _apply_gravity_and_move() -> void:
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()
	_after_move()

func _after_move() -> void:
	pass

# Which corpse this leaves (a `Corpse.Kind`). Asked of the body so the world
# does not keep a table from pool to pile.
func corpse_kind() -> int:
	return 0
