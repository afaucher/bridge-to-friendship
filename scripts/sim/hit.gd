extends RefCounted

# One hit. See design_ideas/damage_model.md.
#
# THE THING DEALING DAMAGE STOPS KNOWING WHAT IT HIT. Before this, harm was dealt
# at five call sites that each hand-coded what they did to each kind of target --
# and _resolve_round_hit had grown a chain of "what are you?" questions
# (has_method("deflect") and "ball_id" in target, then has_method("begin_rise"),
# then "peer_id" in target) written by the machine gun about everything else in
# the game. Five new sources against three new targets would have made that eight
# questions in five places.
#
# Now a source builds one of these and hands it over. Each body answers for
# itself in its own receive_hit(), where the rule sits next to the reason for it.

enum Kind {
	# A body arrived: a dash, a rusher's contact, a plinko ball. THE ONLY KIND
	# THAT MOVES TERRAIN -- a pillar is pushed a cell by something running into
	# it, and by nothing else except a blast.
	IMPACT,
	# A round. THE ONLY KIND STOPPED BY COVER, which is what makes cover an
	# answer at all.
	BULLET,
	# A grenade, a mine. THE ONLY KIND THAT REACHES UNDER AND AROUND -- past a
	# shield's arc, and down onto a mound that has nothing above ground to shoot.
	EXPLOSIVE,
	# Reserved and unbuilt: a saw-blade, something falling. Named now so the enum
	# does not have to change on the day hazards.md's roster advances.
	CRUSH,
}

var kind: int = Kind.IMPACT
var amount: int = 0

# WHERE IT CAME FROM, AS A POINT -- not a direction, and this is the most
# load-bearing field here.
#
# A shield blocks "harm coming from a certain direction", which is a question
# about where a hit ORIGINATED relative to the body. A direction of travel cannot
# answer that for a blast, which has a centre and no travel at all. Everything
# else derives from the point: knockback is the flattened vector away from it,
# which is right for a round (where it struck), for a contact (the other body)
# and for an explosion (its centre) without any of them having to think about it.
var from: Vector3 = Vector3.ZERO

var push: float = 0.0
var lift: float = 0.0

# Whose hit this is: a peer id, or 0 for the world. Carried so an enemy's round
# and a player's round are the same object with different owners.
var source: int = 0

# EXPLICITLY TYPED, not inferred. `.new()` on a GDScript returns Variant, and this
# project treats inference-from-Variant as an error -- so `var h := ...` here does
# not merely warn, it fails the compile of every script that preloads this one.
static func make(kind: int, amount: int, from: Vector3, push: float, lift: float,
		source: int = 0) -> RefCounted:
	var script: GDScript = load("res://scripts/sim/hit.gd")
	var h: RefCounted = script.new()
	h.kind = kind
	h.amount = amount
	h.from = from
	h.push = push
	h.lift = lift
	h.source = source
	return h

# The way this hit throws something standing at `at`. Flattened, because every
# knockback in this game is horizontal with a fixed lift -- a blast that launched
# people vertically would be a different mechanic.
func direction_to(at: Vector3) -> Vector3:
	var away := Vector3(at.x - from.x, 0.0, at.z - from.z)
	if away.length_squared() < 0.0001:
		# Dead centre. Any direction is as correct as any other, and returning
		# zero would silently drop the knockback -- which for a body standing
		# exactly on a mine is the one case that must not be gentle.
		return Vector3(0.0, 0.0, 1.0)
	return away.normalized()

# The launch a receiver should apply, given where it is.
func launch_for(at: Vector3) -> Vector3:
	var dir := direction_to(at)
	return Vector3(dir.x * push, lift, dir.z * push)
