extends "res://scripts/sim/actors/enemy_body.gd"

# AN ENEMY THAT CLIMBS OUT OF THE GROUND. The rusher (out of a mound) and the
# zombie (out of a grave) both rise, chase whoever they can see, are batted away
# by a dash, and burrow back when they have lived long enough. The rise, the age,
# the target and the impact rule were two copies of one another.
#
# `state` IS THE SUBCLASS'S OWN ENUM, and every one of them puts RISE at 0 -- the
# only value this file needs to name. A subclass says which state the rise ends
# in by overriding `_risen_state()`.

const RISE_STATE := 0

var state: int = RISE_STATE
var state_timer: float = 0.0
var age: float = 0.0
var target_peer: int = 0
var _emerge_from: Vector3 = Vector3.ZERO

func begin_rise(at: Vector3) -> void:
	_emerge_from = at
	position = at - Vector3(0.0, _rise_height(), 0.0)
	velocity = Vector3.ZERO
	state = RISE_STATE
	state_timer = 0.0
	age = 0.0
	_on_begin_rise()

# Called once per tick while rising. Cannot touch you and cannot be hurt by you
# (see `is_in_play`): the rise is the telegraph.
func _step_rise() -> void:
	var t: float = clampf(state_timer / _rise_seconds(), 0.0, 1.0)
	position = _emerge_from - Vector3(0.0, _rise_height() * (1.0 - t), 0.0)
	velocity = Vector3.ZERO
	if t >= 1.0:
		state = _risen_state()
		state_timer = 0.0
		_on_risen()

func is_in_play() -> bool:
	return state != RISE_STATE

func _expired() -> bool:
	return age > _lifetime()

# ANYTHING THAT IS NOT A ROUND OR A BLAST BATS IT AWAY -- a dash, a ball.
func receive_impact(hit) -> bool:
	deflect(hit.direction_to(position))
	return true

# --- What a kind says about itself ---------------------------------------------

func _rise_height() -> float:
	return 1.0

func _rise_seconds() -> float:
	return 1.0

func _lifetime() -> float:
	return INF

func _risen_state() -> int:
	return 1

func _on_begin_rise() -> void:
	pass

func _on_risen() -> void:
	pass

func deflect(_direction: Vector3) -> void:
	pass
