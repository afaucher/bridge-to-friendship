extends RefCounted

# THE RESCUE CLOCKS, READ: how much health is left, how far through a haul a
# rescuer is, how long until the drone comes, and the self-revive minigame's
# window. Every one is a pure function of the body's state -- nothing here writes
# anything -- which is why it can live outside the body without touching a replay.
# Part of PlayerBody, which forwards each question here.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

func health_fraction() -> float:
	return clampf(float(body.health) / float(SimConfig.MAX_HEALTH), 0.0, 1.0)

# How far through the HOLD a rescuer is, 0.0 up to 1.0, or -1 when nobody is
# holding. Each state against its own hold -- 0.8 s to haul someone off a lip,
# 1.5 s to get a downed player back on their feet -- so a full bar means the same
# thing in either.
#
# ZERO PROGRESS IS NOT "BEING HELPED". The hold RESETS the instant the helper
# steps outside REVIVE_RADIUS (see GameWorld._tick_revive: wandering off and back
# must not bank credit), so an empty blue bar would appear and vanish every time
# somebody walked past. Below one tick's worth, this says nobody is on it.
func haul_fraction() -> float:
	if body.rescue_progress <= SimConfig.TICK_DELTA:
		return -1.0
	match body.state:
		State.DOWNED:
			return clampf(body.rescue_progress / SimConfig.REVIVE_SECONDS, 0.0, 1.0)
		State.LEDGE_HANG:
			return clampf(body.rescue_progress / SimConfig.LEDGE_HAUL_SECONDS, 0.0, 1.0)
	return -1.0

# How much of the rescue window is LEFT, 1.0 down to 0.0, or -1 when this body is
# not waiting on anybody. Both states, each against its own clock -- 8 s hanging,
# 15 s downed -- so a full bar means the same thing in either.
func rescue_fraction() -> float:
	var left: float = rescue_seconds_left()
	if left < 0.0:
		return -1.0
	match body.state:
		State.DOWNED:
			return clampf(left / SimConfig.DOWNED_SECONDS, 0.0, 1.0)
		State.LEDGE_HANG:
			return clampf(left / SimConfig.LEDGE_HANG_SECONDS, 0.0, 1.0)
	return -1.0

# Seconds until the drone comes for this body, or -1 when it is not waiting for
# anybody.
#
# BOTH RESCUE STATES, not just DOWNED. It covered only DOWNED at first, and that
# made it a feature almost nobody would ever see: going down takes FIVE separate
# hits (MAX_HEALTH 5, one damage each) from the only two things that deal damage,
# with a grace window between them -- and falling does none at all. In a real
# playtest you hang off a lip or you fall; you very rarely bleed out. Reported as
# "I still can't see it", twice, after two fixes to how it was DRAWN.
#
# GameWorld already treats these as one situation wearing two hats -- same
# countdown, same teammate-can-end-it-early, same drone at the end. The thing
# over your head should not be the one place they are different.
# --- The self-revive minigame -------------------------------------------------
#
# THE COUNTDOWN BAR IS THE MARKER. Not a second sweeping thing beside it -- the
# bleed-out bar drains as it always did, one thin line sits somewhere along it,
# and the instant the draining edge crosses that line is the instant to press.
# ONE window per state: you get a chance, not a rhythm game.
#
# THE WINDOW IS AN ABSOLUTE TIME, so everything about it is a comparison against
# `state_timer` -- which already replicates, and which a client already predicts
# in step(). That is what keeps the bar a player is looking at and the countdown
# the host is judging on the same simulated tick.
#
# THE SEED IS STORED RATHER THAN DERIVED, and it cost a design round to see why.
# The obvious trick is to reconstruct the entry tick as `world.tick -
# state_timer / TICK_DELTA` and hash that, needing no new field. But a MISS adds
# to `state_timer` -- so the derived entry tick would move, the hash would change,
# and the single window would silently relocate: a second chance, out of the
# punishment for using the first. A stored seed cannot do that.
func self_revive_gate() -> float:
	var total: float = rescue_total()
	if total <= 0.0:
		return -1.0
	var h: int = (body.self_revive_seed * 2654435761 + body.peer_id * 40503) % 1000003
	var spread: float = SimConfig.SELF_REVIVE_LATEST - SimConfig.SELF_REVIVE_EARLIEST
	return total * (SimConfig.SELF_REVIVE_EARLIEST + spread * float(h % 1000) / 1000.0)

func self_revive_hit() -> bool:
	var gate: float = self_revive_gate()
	if gate < 0.0:
		return false
	var window: float = gate + SimConfig.SELF_REVIVE_WINDOW_SECONDS
	return body.state_timer >= gate and body.state_timer <= window

# WHERE TO DRAW THE LINE, in the same 0..1 the bar's own fill uses. The fill is
# `remaining / total`, so a gate at time g sits at `(total - g) / total` and the
# edge reaches it exactly when state_timer == g. One number, one meaning, and no
# arithmetic in the HUD that could disagree with the arithmetic in the rule.
func self_revive_mark() -> float:
	var gate: float = self_revive_gate()
	var total: float = rescue_total()
	if gate < 0.0 or total <= 0.0:
		return -1.0
	return clampf((total - gate) / total, 0.0, 1.0)

func self_revive_mark_width() -> float:
	var total: float = rescue_total()
	if total <= 0.0:
		return 0.0
	return SimConfig.SELF_REVIVE_WINDOW_SECONDS / total

# How long this state gives you in total. The denominator every fraction above
# divides by, and the one place the two countdowns are named together.
func rescue_total() -> float:
	match body.state:
		State.DOWNED:
			return SimConfig.DOWNED_SECONDS
		State.LEDGE_HANG:
			return SimConfig.LEDGE_HANG_SECONDS
	return -1.0

func rescue_seconds_left() -> float:
	match body.state:
		State.DOWNED:
			return maxf(0.0, SimConfig.DOWNED_SECONDS - body.state_timer)
		State.LEDGE_HANG:
			return maxf(0.0, SimConfig.LEDGE_HANG_SECONDS - body.state_timer)
	return -1.0

# WHOLE SECONDS, ROUNDED UP. A rescuer reads this from across a 60 m bridge while
# running, so it has to be legible at a glance rather than precise -- and ceil
# means it never shows "0" on somebody who is still savable.
func rescue_seconds_left_text() -> String:
	return str(int(ceil(maxf(0.0, rescue_seconds_left()))))
