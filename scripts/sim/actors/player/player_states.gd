extends RefCounted

# THE PLAYER'S STATES AND ITS SHAPE, in a file of their own so the player's
# components can name them without preloading player_body.gd -- which preloads
# them, and a preload cycle HANGS a run rather than failing it (CLAUDE.md).
# PlayerBody aliases every name here, so `PlayerBody.State.WALK` and
# `PlayerBody.HALF_HEIGHT` keep meaning what they always meant.
#
# Preloads nothing. Keep it that way.

enum State {
	WALK,        # full control
	SHOVE,       # committed dash along a compass axis
	# M5. A chaotic pinwheeling bounce that KEEPS its momentum rather than
	# sliding to a stop -- displacement is the threat on a bridge full of holes,
	# not the damage.
	#
	# There is no SWING state, and an earlier design that had one was wrong: a
	# tumbling player on the end of a taut rope swings because that is what a
	# body on a line does. It falls out of the constraint. Two states describing
	# the same physical situation only ever drift apart.
	TUMBLE,
	LEDGE_HANG,  # M5 -- caught a lip; cannot mantle unaided, can while pulled
	# M17 phase 6. On a ladder: vertical control, no gravity, and no verbs. The
	# glyph has been authorable since M2 and the validator has counted it as a way
	# up ever since -- with nothing to climb it, which is why SegmentValidator
	# carried LADDERS_CLIMBABLE = false until this state existed.
	CLIMB,
	DOWNED,      # M5
	BUS_DRIVER,  # M11 -- steering only
	BUS_RIDER,   # M11 -- verbs but no movement
}

const HALF_HEIGHT := 0.9          # matches the CylinderShape3D in player.tscn
# The other half of that cylinder, and it exists because leaving it implicit cost
# a real bug: the plinko hit test reached for HALF_HEIGHT as its horizontal term,
# so a body 0.8 m across was treated as 1.8 m across and balls connected from
# twice their own radius away. A body has two dimensions and the code should be
# able to name both.
const RADIUS := 0.4               # ditto -- the two are a pair, from one shape
const FOOT_PROBE := 0.25          # how far below the feet to look for a carrier
