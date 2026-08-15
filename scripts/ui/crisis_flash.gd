extends RefCounted

# THE ONE FLASH. A player who needs help is announced in two places at once -- a
# triangle at the edge of the screen pointing at them, and the bar over their
# head -- and those two have to be the SAME signal or they are two signals.
#
# What "the same" means concretely, and why each part is here rather than at the
# call site:
#
#   THE SAME COLOUR. `RED` is the crisis red. The bar's countdown fill and the
#   downed marker are one constant, not two literals that happen to match today.
#   The HUD's second black bar (fixed 2026-08-15) is what two copies of one
#   decision looks like a month later.
#   THE SAME RHYTHM. `PERIOD` is the full cycle, half red and half white.
#   THE SAME PHASE. `now()` is a wall clock rather than an accumulated delta, so
#   every marker and every bar in the game blinks TOGETHER without anything being
#   threaded between them. Two independent accumulators started at different
#   moments produce two rhythms, and a screen with two rhythms on it reads as
#   broken rather than as urgent.
#
# RED TO WHITE, NOT RED TO NOTHING. The marker used to blink out entirely, which
# means half the time the thing you are being told to look at is not on screen --
# and the half you miss is as likely as the half you catch. Alternating between
# two solid colours keeps the arrow present for the whole cycle and still moves,
# and movement is what the eye actually picks up in a busy frame.
#
# EVERY FUNCTION TAKES ITS TIME AS AN ARGUMENT except `now()`. A clock read inside
# the decision would make all of this untestable -- CLAUDE.md's rule about not
# asserting anything the environment owns -- so the gate hands these a chosen
# point in the cycle and the game hands them the clock.

# One full cycle. Fast enough to catch the eye, slow enough not to strobe.
const PERIOD := 0.7

# The crisis red. Also PlayerBody.BAR_RESCUE_FILL -- the countdown over a downed
# player's head and the triangle pointing at them are the same colour because
# they are the same fact.
const RED := Color(1.00, 0.27, 0.16)

# The other half of the cycle. White because it is the furthest thing from every
# other colour on screen: the bridge is grey, the deck lights are warm, and
# nothing else in the game is pure white.
const PEAK := Color(1.00, 1.00, 1.00)

# A FRIEND WHO IS SIMPLY OUT OF SHOT. Green, steady, never flashing -- this is
# information and the red one is a summons, and a player has to be able to tell
# them apart at a glance without reading anything. If both moved, neither would
# mean anything.
const FRIEND := Color(0.35, 0.85, 0.42, 0.90)

# The clock the game flashes on. Wall time, deliberately: it is shared by every
# caller for free, and nothing about it is ever asserted.
static func now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

# True for the first half of each cycle, which is the BASE colour's half. A test
# that wants the ordinary colour asks for 0.0 and gets it.
static func on(seconds: float) -> bool:
	return fmod(seconds, PERIOD) < PERIOD * 0.5

# The base colour for half the cycle and white for the other half, keeping the
# base's alpha so a translucent marker stays translucent.
static func alternate(base: Color, seconds: float) -> Color:
	if on(seconds):
		return base
	return Color(PEAK.r, PEAK.g, PEAK.b, base.a)

# The fill colour for a bar built by PlayerBody.status_bar(). The `flash` flag is
# the BODY's decision -- a countdown flashes, a haul in progress does not, because
# one is asking for help and the other is telling you help has arrived. This
# function only knows how a flash looks.
static func fill_for(status: Dictionary, seconds: float) -> Color:
	var base: Color = status.get("fill", RED)
	if not bool(status.get("flash", false)):
		return base
	return alternate(base, seconds)
