extends CharacterBody3D

# A simulated player.
#
# This body does NOT decide when to run. It exposes step() and someone else
# (GameWorld) calls it: on the host for every player, on a client for the local
# player only, as a prediction. That inversion is the whole point -- the same
# function produces the authoritative result and the predicted one, so they
# cannot drift apart by being two different pieces of code.
#
# THE INTEGRATOR IS OURS. Velocity is explicit, response rules are hand-written,
# and only the sweep (move_and_slide) is Godot's. Momentum transfer here is a set
# of designed, legible rules -- "a dash into a stone moves it exactly one cell" --
# not whatever a rigid-body solver produces from a contact manifold.

const SimConfig = preload("res://scripts/sim/sim_config.gd")
const GridConfig = preload("res://scripts/grid/grid_config.gd")
const Hit = preload("res://scripts/sim/hit.gd")
# Safe: character_style.gd preloads nothing but core/hash.gd, which preloads
# nothing at all, so this cannot close the class cycle CLAUDE.md warns HANGS a
# run rather than failing it. Keep it that way -- it is a leaf on purpose, which
# is what lets both the sim and the menu import it.
const CharacterStyle = preload("res://scripts/sim/character_style.gd")
# A VIEW SCRIPT, PRELOADED BY A SIM ONE, and deliberately: the bar over this
# body's head is already a view built here, colours and all, and the alternative
# is a second copy of the crisis palette. crisis_flash.gd preloads nothing, so it
# cannot close a class cycle -- see CLAUDE.md on what a new preload can cost.
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")

# The states, and the body's two dimensions, live in actor/player/player_states.gd
# so the components can name them without a preload cycle. Aliased here.
const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State

@export var peer_id: int = 1

var state: int = State.WALK
var state_timer: float = 0.0

# Time until the next self-revive attempt is allowed. Host-side only -- it is
# consumed where the attempt is judged (GameWorld._try_self_revive) and ticked
# there too, so it never has to agree with anything on a client.
var self_revive_cooldown: float = 0.0

# WHICH WINDOW THIS PARTICULAR CRISIS GOT. Set once when the state is entered and
# never touched again, so the miss penalty cannot move the window it is punishing
# you for missing. On the wire, because the client draws the line from it.
var self_revive_seed: int = 0

# Our own floor flag, refreshed from is_on_floor() after every move_and_slide.
#
# NOT a convenience wrapper. is_on_floor() is derived state living inside the
# CharacterBody3D, and apply_state() cannot touch it -- so a client that rewinds
# to an airborne authoritative frame would replay its first tick still believing
# it was standing, take the grounded branch, and diverge from the host on tick
# one of every correction.
var grounded: bool = false

# Where this player is pointing, as a free yaw in radians (0 = north = up the
# bridge). A shove pressed with no aim and no movement goes THIS way -- a dash
# that refuses to fire because nothing was held reads as a dropped input.
#
# WAS ONE OF FOUR COMPASS AXES until the aim revision. The four-way lock existed
# because the only pointing device was the movement stick, so the dash had to be
# readable from a direction the player was also using to walk; snapping to a
# quarter turn made that unambiguous. With a mouse or a right stick the aim is
# stated outright, and the snap becomes a thing that fights the player instead of
# helping them.
#
# Cells are still cardinal. See GridConfig.yaw_to_direction, and the stone push
# in GameWorld.resolve_shove_contact -- a stone moves one CELL, and a cell has
# four neighbours however you were pointing when you hit it.
var facing: float = 0.0
var shove_yaw: float = 0.0
var shove_cooldown: float = 0.0
# DASHES IN HAND, and the clock on the next one back. Both are in capture_state:
# the dash GATE reads them, and SHOVE is a state a client predicts for itself, so
# a body that replayed without them would allow a dash the host refused and
# correct every tick afterwards.
# WHERE THE CURSOR IS IN THE WORLD (M20), refreshed every tick from the input.
#
# NOT IN capture_state, and that is the point: it is an INPUT like `move`, not
# state. It changes only where a shot is aimed, never how the body steps, and the
# bearing half of it is already carried by `facing`, which IS replicated. A replay
# that re-runs step() with the recorded input reproduces it exactly.
var aim_point: Vector3 = Vector3.INF

# HOW FAST THIS BODY WALKS, AS A FRACTION. 1.0 unless something heavy is being
# carried; GameWorld sets it from what is in the player's hands.
#
# A SCALAR, NOT THE ITEM. Nothing about a carried thing lives on PlayerBody -- see
# special_pool.held_by, which is what keeps items out of capture_state by
# construction rather than by discipline. This is the CONSEQUENCE of carrying
# something, which is a different fact and one the body legitimately owns.
#
# AND IT IS IN capture_state, because it changes how the body STEPS. A client
# predicting its own movement replays the last N ticks; without this the replay
# would apply today's weight to ticks taken before the gun was picked up, and
# GameWorld.corrections would climb every time somebody swapped weapons.
var carry_speed: float = 1.0

# --- The sidearm (M24) --------------------------------------------------------
#
# ON THE PLAYER, NOT IN THE WORLD. Every other gun is a SpecialBody: an item with
# a magazine, one slot, dropped when replaced and destroyed when spent. The
# pistol cannot be dropped, never runs out, and is back the instant a special is
# gone -- which is not a rule you bolt onto an item, it is a statement that this
# is not one. So it lives here, and the whole pickup-drop-spend lifecycle never
# has to make an exception for it.

# HOW WILD IT HAS GONE, 0 (cold, accurate) to 1 (hot, useless). A shot adds
# PISTOL_HEAT_PER_SHOT and it bleeds off at PISTOL_HEAT_DECAY per second.
#
# CAPTURED, so a client's HUD can show it. Nothing about firing is predicted --
# the host decides every round -- but the meter is on screen the whole time, and
# a meter that only moves when a snapshot happens to land reads as broken.
var pistol_heat: float = 0.0
var pistol_timer: float = 0.0

# CALLING FOR HELP. Counts down while the call is up; the HUD, the offscreen
# markers and the sound all read it, and it is the only thing this feature adds to
# the simulation.
#
# ON THE BODY RATHER THAN IN AN RPC, which is what makes it replicate for free: it
# rides `capture_state` like everything else about a player, so a remote client
# knows a teammate is calling by the same route it knows where they are standing.
# An event RPC would have been a second mechanism, and one that a dropped packet
# silently loses -- a cry for help is exactly the message that must not be the one
# that goes missing.
var call_timer: float = 0.0
var call_cooldown: float = 0.0
var dash_charges: int = SimConfig.DASH_CHARGES
var dash_refill: float = 0.0

# --- Riding -------------------------------------------------------------------
#
# Anything standing on another sim body is CARRIED by it: from the rider's point
# of view the thing underneath is not moving. Godot will not do this for us --
# CharacterBody3D inherits platform motion only from bodies the physics server
# tracks as platforms, so one CharacterBody3D standing on another just gets left
# behind as the lower one walks out from under it.

var carrier: Node = null          # what we are standing on, if it is a sim body
var motion_delta: Vector3 = Vector3.ZERO   # how far we moved in our last step

# --- Health and rescue --------------------------------------------------------

var health: int = SimConfig.MAX_HEALTH
var invulnerable: float = 0.0     # counts down after any hit

# While hanging: the compass direction from this body toward the deck it caught,
# which is the way a mantle has to go.
var hang_dir: int = GridConfig.DIR_NORTH

# Counts down after letting go of a lip; no grab is possible while it runs. See
# SimConfig.LEDGE_REGRAB_COOLDOWN -- without it a released player re-catches the
# lip they just let go of on the next tick and hangs forever.
#
# CAPTURED STATE, because it gates a state transition: a client replaying a
# correction without it would re-grab on a tick the host did not.
var ledge_cooldown: float = 0.0

# How long a teammate has been stood next to this body while it waits to be
# rescued. Shared by LEDGE_HANG and DOWNED, because they are the same machinery.
var rescue_progress: float = 0.0

const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE

# Set by GameWorld at spawn. The world owns the momentum-transfer rules, because
# they are rules about the world and not about any one body.
var world: Node = null

func _ready() -> void:
	# The co-op gate, enforced by the engine: a slope steeper than this is not a
	# floor, so a player walking at it slides back down and needs a shove or a
	# rope instead.
	floor_max_angle = deg_to_rad(SimConfig.MAX_WALK_ANGLE_DEG)

	# RIDER TRANSPORT USES GODOT'S BUILT-IN moving-platform support (the default
	# platform_floor_layers), not our ride(). Chosen deliberately for less code;
	# two known costs, both acceptable for now and both cheap to revisit because
	# ride() is still on this class and unused:
	#
	#   1. It is ONE TICK STALE -- Godot applies the platform's PREVIOUS step of
	#      motion, so a rider lags its carrier by a tick (~10 cm at walking
	#      speed, more while accelerating).
	#   2. It lives in engine-internal state that capture_state() cannot restore,
	#      so a client reconciliation replay cannot reproduce it exactly. Same
	#      class of trap as is_on_floor(); watch GameWorld.corrections if riding
	#      ever happens during networked play.
	#
	# What it does NOT solve is the carrier being blocked by its own rider --
	# that is still handled in GameWorld's step loop.

	# The status bar draws a SubViewport onto a Sprite3D, which is how Godot does
	# world-space UI. The texture has to be wired up in code: a ViewportTexture
	# pointing at a node's own child cannot be set from the scene file.
	#
	# No material duplication needed any more, and that is one of the reasons for
	# the shape. The bar's two halves are ColorRect NODES now, so every avatar
	# owns its own; the previous mesh version shared its materials across every
	# instance of player.tscn and had to clone them per body or one player's bar
	# re-tinted the whole party's.
	var bar := get_node_or_null("StatusBar") as Sprite3D
	if bar != null:
		var vp := bar.get_node_or_null("SubViewport") as SubViewport
		if vp != null:
			bar.texture = vp.get_texture()

# --- Simulation ---------------------------------------------------------------

# Advance exactly one tick. Takes no delta on purpose: move_and_slide() reads the
# delta from the physics frame, so this is only correct when the sim tick and the
# physics tick are the same duration -- which is what lets a client replay N
# ticks inside one frame and land where N frames put it.
# --- The shield ----------------------------------------------------------------
#
# SHIELD STATE LIVES ON THE BODY, and it has to: it changes how the body STEPS,
# and CLAUDE.md's rule is that anything affecting stepping is in capture_state()
# or replays diverge. `shield_yaw` in particular persists across ticks -- it is
# captured once when the shield goes up -- so deriving it per tick was never an
# option.
#
# `has_shield` is the exception and is NOT state: it is an input, like `move`,
# answering "is the thing in your hands a shield". The world sets it each tick
# from the special slot, because the slot is not the body's business.
var has_shield: bool = false
var shielding: bool = false
var shield_yaw: float = 0.0

# LEGS (M17 phase 6). `has_legs` is an input exactly as `has_shield` is, and set
# by the same refresh — with the ammo folded in, because "can I launch" is one
# question and asking it in two places is how the two machines end up disagreeing
# about whether a launch happened.
var has_legs: bool = false
# THE PRESS EDGE, and it IS state: it persists across ticks, so it rides
# capture_state or a replaying client re-launches on a tick the host did not.
# One button serves every special (see the four-meanings note in GameWorld); legs
# are the one that fires on the way DOWN and must not repeat while held, or four
# charges are gone in four ticks.
var special_was_held: bool = false
# Raised by the launch, lowered by the host when it charges for it. NOT in
# capture_state deliberately: it is written on the tick it happens and read on the
# next, so a client that replays it writes a flag nothing on that machine reads.
# THE BODY DECIDES, THE WORLD BILLS — one predicate, in one place. A world that
# re-derived "did they launch" from the inputs would be a second copy of a
# condition that has to match this one forever.
var legs_fired: bool = false

# Is this hit refused? `hit.from` is a POINT for exactly this reason -- a shield
# gates by where something CAME FROM, which no direction-only hit could answer.
func shield_blocks(hit) -> bool:
	if not shielding:
		return false
	var flat := Vector2(position.x - hit.from.x, position.z - hit.from.z)
	# THE PROXIMITY RULE IS ABOUT BLASTS, and now says so. Its own reasoning always
	# was — "a blast beneath your feet has no direction to be in, and a mine is
	# how you answer somebody who has decided to stop moving" — but it was applied
	# to every kind, and a SHOOTER standing next to you is not a mine. Being
	# flanked is the counter to a shield; walking up close is not, or a skirmisher
	# beats the answer to skirmishers by taking one step forward.
	# A SHIELD DOES NOT STOP THE FLOOR. Spikes come UP THROUGH the ground you are
	# standing on; there is no direction to hold a slab against, and the arc test
	# below would happily "block" them from whichever side the cell centre
	# happened to be on. Refused outright rather than by distance, because
	# distance is not what makes it unblockable.
	#
	# This was a REGRESSION for a few hours on 2026-08-16: scoping the proximity
	# rule to blasts (correct, for gunfire) quietly made CRUSH blockable at over a
	# metre, contradicting the note _spike_hits has always carried. Two rules that
	# happened to share one condition, separated by a change aimed at neither.
	if hit.kind == Hit.Kind.CRUSH:
		return false
	if hit.kind == Hit.Kind.EXPLOSIVE 			and flat.length() < SimConfig.SHIELD_MIN_BLOCK_DISTANCE:
		return false
	# The yaw pointing FROM the player TOWARD the source, against the yaw the
	# shield was raised at.
	var toward: float = GridConfig.yaw_of_vector(Vector3(-flat.x, 0.0, -flat.y))
	return absf(wrapf(toward - shield_yaw, -PI, PI)) <= deg_to_rad(SimConfig.SHIELD_ARC_DEG) * 0.5

func step(move: Vector2, actions: int, aim: float = INF,
		aim_at: Vector3 = Vector3.INF) -> void:
	aim_point = aim_at
	var before := position
	state_timer += SimConfig.TICK_DELTA
	shove_cooldown = maxf(0.0, shove_cooldown - SimConfig.TICK_DELTA)
	ledge_cooldown = maxf(0.0, ledge_cooldown - SimConfig.TICK_DELTA)
	_tick_dash_charges()

	invulnerable = maxf(0.0, invulnerable - SimConfig.TICK_DELTA)
	call_timer = maxf(0.0, call_timer - SimConfig.TICK_DELTA)
	call_cooldown = maxf(0.0, call_cooldown - SimConfig.TICK_DELTA)

	# ANSWERED IN EVERY STATE, deliberately. The moments worth calling from are the
	# ones where you have no other verb -- hanging off a ledge, downed, tumbling
	# across a gap -- so a call gated on WALK would be a call you cannot make when
	# you need it. It changes nothing about movement, so there is nothing for a
	# state to disagree with.
	if (actions & SimConfig.ACTION_CALL) != 0 and call_cooldown <= 0.0:
		call_timer = SimConfig.CALL_SECONDS
		call_cooldown = SimConfig.CALL_COOLDOWN

	# Tracked for EVERY state, not just walking. Being tumbled while holding the
	# button and coming back up still holding it must not launch you: the edge is
	# the press, and you did not press it again.
	var special_held: bool = (actions & SimConfig.ACTION_SPECIAL_HELD) != 0

	match state:
		State.WALK:
			_step_walk(move, actions, aim)
		State.SHOVE:
			_step_shove()
		State.TUMBLE:
			_step_tumble()
		State.LEDGE_HANG:
			_step_hang()
		State.CLIMB:
			_step_climb(move)
		State.DOWNED:
			pass          # immobile; the world runs the countdown and the rescue
		_:
			_step_inert()

	# NO AUTOMATIC REPEAT. There was one, re-issuing on the cooldown for as long as
	# the countdown ran, and it is deliberately gone (2026-08-23): the crisis
	# announces itself ONCE, and after that a call is something the player asks for.
	#
	# A cry that repeats on its own is not the player speaking, it is an alarm --
	# and an alarm attached to somebody who is simply still down says nothing that
	# the bar and the marker are not already saying, continuously, for free. What
	# a fresh call carries is that the person CHOSE to ask again, which is exactly
	# what a repeat would have destroyed by making every call look automatic.

	# THE LEDGE CATCH IS A PROPERTY OF THE FALL, NOT OF HOW IT STARTED.
	#
	# It lived inside _step_tumble until 2026-08-10, so it was reachable ONLY by
	# being kicked, shot or rushed -- dash across a gap, fall short, and you
	# dropped past a lip you were touching with no grab, because your own dash
	# ends in WALK and WALK never asked. Reported from playtest as "is grabbing
	# specific to kicks?", and it was.
	#
	# Nothing in D2 says that. It defines the rescue by TRAJECTORY -- over an edge
	# but still near the deck catches; launched clear of it does not -- and
	# _try_catch_ledge already tests exactly that: not rising, under
	# LEDGE_CATCH_MAX_SPEED, over a hole with solid deck within reach below. Those
	# gates do the whole job. The state check on top of them only made two
	# identical-looking falls behave differently for a reason no player can see,
	# which is the same thing the glancing/solid split was thrown out for.
	#
	# SHOVE is deliberately not in this list. A dash is 56 m/s, so the speed gate
	# refuses it anyway -- but stating it here means lowering SHOVE_SPEED later
	# cannot quietly make dashes catchable and delete "a dash off the deck is a
	# dash off the deck".
	if not grounded and (state == State.WALK or state == State.TUMBLE):
		_try_catch_ledge()

	motion_delta = position - before
	carrier = _find_carrier()
	_point_nose()
	_sync_mesh()

	# Lowered LAST, after the state that read it has run. A press held across a
	# tumble is still one press.
	special_was_held = special_held

# Turn the facing marker to where the player is pointing. Driven from `facing`,
# which is captured state, so it survives a reconciliation replay rather than
# being animated independently on each machine.
#
# ASSIGNED, NEVER INTERPOLATED. The yaw is written straight through with no turn
# rate and no smoothing -- see aim_source.gd for why: on a fixed camera the
# cursor IS the aim, so anything that eases toward it reads as input lag.
# --- The bleed-out counter over a downed player's head ------------------------
#
# COSMETIC, AND THEREFORE NOT IN step(). A client steps only its own predicted
# body; every other player is drawn from applied snapshots. A counter updated in
# the sim tick would be frozen over precisely the teammate a rescuer is running
# toward -- the one moment it exists for.
#
# `state_timer` rides capture_state(), so a remote body already carries the right
# number and this only has to read it.

func _process(_delta: float) -> void:
	sync_downed_timer()

const StatusBar = preload("res://scripts/sim/actors/player/status_bar.gd")
var overhead_bar = StatusBar.new(self)
const BAR_HEALTH_FILL = StatusBar.BAR_HEALTH_FILL
const BAR_HEALTH_BACK = StatusBar.BAR_HEALTH_BACK
const BAR_RESCUE_FILL = StatusBar.BAR_RESCUE_FILL
const BAR_RESCUE_BACK = StatusBar.BAR_RESCUE_BACK
const BAR_HAUL_FILL = StatusBar.BAR_HAUL_FILL
const BAR_HAUL_BACK = StatusBar.BAR_HAUL_BACK
const BAR_PIXELS = StatusBar.BAR_PIXELS



# The bar over this head -- see actors/player/status_bar.gd. Public so a test can
# drive it on a chosen frame.
func sync_downed_timer(at_seconds: float = -1.0) -> void:
	overhead_bar.sync_downed_timer(at_seconds)

# What a status bar is saying about this body, shared by the bar and the HUD.
func status_bar() -> Dictionary:
	return overhead_bar.status_bar()

# --- The rescue clocks: see actors/player/rescue_clock.gd -----------------------

const RescueClock = preload("res://scripts/sim/actors/player/rescue_clock.gd")
var rescue = RescueClock.new(self)

func health_fraction() -> float:
	return rescue.health_fraction()

func haul_fraction() -> float:
	return rescue.haul_fraction()

func rescue_fraction() -> float:
	return rescue.rescue_fraction()

func self_revive_gate() -> float:
	return rescue.self_revive_gate()

func self_revive_hit() -> bool:
	return rescue.self_revive_hit()

func self_revive_mark() -> float:
	return rescue.self_revive_mark()

func self_revive_mark_width() -> float:
	return rescue.self_revive_mark_width()

func rescue_total() -> float:
	return rescue.rescue_total()

func rescue_seconds_left() -> float:
	return rescue.rescue_seconds_left()

func rescue_seconds_left_text() -> String:
	return rescue.rescue_seconds_left_text()

func _point_nose() -> void:
	var nose := get_node_or_null("Facing") as Node3D
	if nose == null:
		return
	# The marker points along -Z at rest, which is yaw 0, and GridConfig's yaw
	# convention is Godot's own rotation about +Y -- so this is a direct write
	# with no correction term.
	nose.rotation.y = facing

	# THE SHIELD RIDES THE SAME PIVOT, so it faces where the shield was raised
	# without a second angle to keep in step -- while shielding, `facing` IS
	# `shield_yaw` (see _step_walk), which is what makes that free.
	#
	# Driven from here rather than from the world because a REMOTE player's shield
	# has to appear too, and a remote player is never stepped: they are posed by
	# apply_state, which calls _sync_mesh, which is one line from here. Wiring it
	# into the step alone would have shown the shield only to its owner.
	var wall := nose.get_node_or_null("Shield") as Node3D
	if wall != null:
		wall.visible = shielding

# Where a dash would go if it were pressed right now.
#
# THE ORDER IS THE DESIGN. Aim wins, because a player holding a direction on the
# mouse or right stick has said where they want to go and nothing should overrule
# that. Movement is the fallback for a keyboard-only player with no aiming device
# -- their dash follows their feet, which is exactly what it did before this
# revision. Facing is the last resort so that a dash pressed with nothing at all
# held still fires: a verb that silently refuses reads as a dropped input, and
# this one is on a cooldown that would then be spent for nothing.
func _aim_yaw(move: Vector2, aim: float) -> float:
	if is_finite(aim):
		return aim
	if move.length_squared() > 0.04:
		return GridConfig.yaw_of(move)
	return facing

func _step_walk(move: Vector2, actions: int, aim: float) -> void:
	var dt := SimConfig.TICK_DELTA

	# PUSHING INTO A LADDER CLIMBS IT. No dedicated button: "climb the thing you
	# are standing against" is a button nobody presses, and the stick already says
	# everything the move needs.
	if _try_grab_ladder(move):
		return

	# LEGS: STRAIGHT UP, ON THE PRESS. Decided here, in the function a client
	# replays, for the same reason the shield is — an impulse applied from outside
	# would be missing on every replayed tick, and a correction on your own body's
	# vertical velocity is the most visible kind there is.
	#
	# GROUNDED ONLY. Not a fuel tank: two launches stacked would clear anything the
	# generator can build, and an edge that clears ANY height is not a shortcut past
	# geometry, it is a way to ignore geometry.
	var wants_legs: bool = has_legs 		and (actions & SimConfig.ACTION_SPECIAL_HELD) != 0
	if wants_legs and not special_was_held and grounded:
		velocity.y = SimConfig.LEGS_LAUNCH
		grounded = false
		legs_fired = true
		special_was_held = true
		move_and_slide()
		return

	# ANCHORED. Raised on the tick the trigger goes down and dropped when it comes
	# up; while it is up the body does not move and does not turn, so the direction
	# chosen at the moment of raising is the direction committed to.
	#
	# Decided here rather than in the world because a client REPLAYS this function
	# with stored inputs during reconciliation -- a shield applied from outside
	# would be missing on every replayed tick, and the correction it caused would
	# look exactly like lag.
	var wants_shield: bool = has_shield 		and (actions & SimConfig.ACTION_SPECIAL_HELD) != 0
	if wants_shield and not shielding:
		shielding = true
		shield_yaw = aim if is_finite(aim) else facing
	elif not wants_shield:
		shielding = false
	if shielding:
		facing = shield_yaw
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y = -SimConfig.FLOOR_STICK if grounded else velocity.y - SimConfig.GRAVITY * dt
		move_and_slide()
		grounded = is_on_floor()
		return

	# Facing is INDEPENDENT of movement now: you strafe one way while pointing
	# another. Only fall back to the direction of travel when there is no aiming
	# device saying otherwise.
	if is_finite(aim):
		facing = aim
	elif move.length_squared() > 0.04:
		facing = GridConfig.yaw_of(move)

	if (actions & SimConfig.ACTION_SHOVE) != 0 and shove_cooldown <= 0.0 and dash_charges > 0:
		_spend_dash()
		_begin_shove(move, aim)
		_step_shove()
		return

	# No jump: Space is the dash. See the note in SimConfig -- a jump would
	# quietly solve obstacles that are meant to need a second player.
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * dt

	# Input is world-space: the camera is fixed-yaw, so "north" is the same
	# direction on every screen and there is no camera basis to agree on.
	var wish := Vector3(move.x, 0.0, move.y)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var target := wish * SimConfig.WALK_SPEED * carry_speed
	# THE CURRENT, ADDED TO WHAT YOU WANTED rather than to where you are. Walking
	# upstream is possible and visibly worse than walking on deck; standing still
	# carries you off. Both halves are the design -- water you cannot make headway
	# against is a wall, and water that leaves a stationary body alone is scenery.
	target += _water_push()
	# AND ANYTHING PULLING. Added to what you WANTED, like the current -- so
	# walking against it is possible at the rim and hopeless in the core, which is
	# the whole of what keeps an enemy with no telegraph fair.
	target += _swallow_pull()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := SimConfig.WALK_ACCEL if wish.length_squared() > 0.0 else SimConfig.WALK_FRICTION
	horizontal = horizontal.move_toward(target, rate * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	# BEFORE THE SLIDE, BOTH OF THEM. `move_and_slide` removes the into-surface
	# component of the velocity and moves the body, so afterwards neither number
	# says what was attempted -- and every judgement about an impact in this
	# project that read them afterwards has been a bug. See CLAUDE.md.
	var wanted := Vector3(velocity.x, 0.0, velocity.z) * dt
	var was_at := global_position

	move_and_slide()
	grounded = is_on_floor()
	_try_step_up(was_at, wanted)

# WHICH WAY THE WATER UNDER YOU IS RUNNING, and how hard.
#
# Asked of the GRID, which owns the answer: a multi-source flood from every place
# the water leaves the bridge gives each cell a distance to the nearest outlet,
# and the flow is downhill on that field. So the direction is a property of the
# channel's shape, the divide of a two-ended channel is calm, and a landlocked
# pond does not flow at all.
#
# PURE, SO IT REPLAYS. Position in, world geometry out, nothing remembered -- the
# same property the step-up above needed and for the same reason: a correction on
# your own body is the most visible kind there is.
# PURE, SO IT REPLAYS. Position in, world state out, nothing remembered -- the
# same property the current and the step-up both needed, and for the same reason:
# a correction on your own body's position is the most visible kind there is.
func _swallow_pull() -> Vector3:
	if world == null or not world.has_method("swallow_pull_at"):
		return Vector3.ZERO
	return world.swallow_pull_at(global_position)

func _water_push() -> Vector3:
	if world == null or world.grid == null or not grounded:
		return Vector3.ZERO
	var cell: Vector2i = world.grid.cell_of_world(global_position)
	var flow: Vector3 = world.grid.water_flow_at(cell)
	if flow == Vector3.ZERO:
		return Vector3.ZERO
	return flow * SimConfig.WATER_PUSH_SPEED * world.grid.water_speed_at(cell)

# A LIP UNDER `STEP_UP_HEIGHT` IS WALKED OVER, NOT WALKED INTO.
#
# Reported as "you can't step out of water so you get stuck": a water cell's top
# is 0.4 m below its nominal height, so the pond was a hole you could enter and
# not leave. `SegmentValidator` never noticed because water and deck share a grid
# height and the rise reads as zero -- an oracle certifying a movement the player
# did not have, for the second time here.
#
# THE BOUND IS THE SAFETY ARGUMENT, and it lives on the constant. Nothing an
# authored level can express is under a metre, so this cannot reach any of them.
#
# `CharacterBody3D` HAS NO STEP HEIGHT, so this is the probe by hand: lift, try
# the blocked motion up there, then drop back down and see what it lands on. Each
# leg has to be refused for its own reason -- no headroom, still blocked, nothing
# underneath -- and the last one is what stops this being a way to walk onto thin
# air at the top of a wall.
#
# PURE, SO IT REPLAYS. It reads the body's position and the world's collision
# geometry and nothing else, so it adds nothing to `capture_state()` and a client
# re-running this tick reaches the same answer. That is a property worth keeping:
# a correction on your own body's position is the most visible kind there is.
func _try_step_up(was_at: Vector3, wanted: Vector3) -> void:
	# ONLY WHILE WALKING ON SOMETHING. A step-up in the air is a second jump, and
	# this game deliberately has no first one.
	if not grounded or wanted.length_squared() < 0.000001:
		return
	# BLOCKED, rather than merely slowed. A body that made most of its move met
	# nothing worth climbing; one that made almost none is against a wall.
	var moved := Vector3(global_position.x - was_at.x, 0.0, global_position.z - was_at.z)
	if moved.length() > wanted.length() * 0.5:
		return

	var lift := Vector3(0.0, SimConfig.STEP_UP_HEIGHT, 0.0)
	var probe := global_transform
	if test_move(probe, lift):
		return                       # no headroom to rise into
	probe.origin += lift
	if test_move(probe, wanted):
		return                       # still a wall up there, so it is a wall
	probe.origin += wanted
	var landing := KinematicCollision3D.new()
	if not test_move(probe, -lift, landing):
		return                       # nothing to stand on: this was an edge, not a step
	# WHERE THE DROP ACTUALLY STOPPED, not where it was aimed. `get_travel` is the
	# part of the descent that happened before the floor, so the body lands ON the
	# lip rather than hovering the full step above it.
	global_position = probe.origin + landing.get_travel()
	grounded = true

# --- Shove: see actors/player/shove.gd -------------------------------------------

const Shove = preload("res://scripts/sim/actors/player/shove.gd")
var shove = Shove.new(self)

func _begin_shove(move: Vector2, aim: float) -> void:
	shove.begin(move, aim)

func _step_shove() -> void:
	shove.step()

func end_shove() -> void:
	shove.end()

func receive_shove(yaw: float) -> void:
	shove.receive(yaw)

func _boosted_up_a_ramp(axis: Vector3) -> bool:
	return shove.boosted_up_a_ramp(axis)

# --- Climbing: see actors/player/climb.gd ----------------------------------------

const Climb = preload("res://scripts/sim/actors/player/climb.gd")
var climb = Climb.new(self)

func _step_climb(move: Vector2) -> void:
	climb.step(move)

func _ladder_face(cell: Vector2i) -> Vector3:
	return climb.ladder_face(cell)


func _ladder_cell() -> Vector2i:
	return climb.ladder_cell()

func _ladder_foot(cell: Vector2i) -> float:
	return climb.ladder_foot(cell)

func _try_grab_ladder(move: Vector2) -> bool:
	return climb.try_grab(move)

# --- Tumble -------------------------------------------------------------------

# --- Tumble: see actors/player/tumble.gd -----------------------------------------

const Tumble = preload("res://scripts/sim/actors/player/tumble.gd")
var tumble = Tumble.new(self)

func _step_tumble() -> void:
	tumble.step()

func _try_ramp_launch(normal: Vector3, approach: Vector3) -> bool:
	return tumble.try_ramp_launch(normal, approach)

func begin_tumble(launch: Vector3) -> void:
	tumble.begin(launch)

# THE WHOLE STACK GOES, not the top hat.
#
# Popping one would make hats a slowly-eroding counter. Popping the stack makes
# carrying five a running, escalating, visible bet -- the only version that
# produces the moment this milestone exists for. It also means the reward curve
# and the risk curve are the same curve, so there is no second balancing lever.
#
# It inherits an asymmetry the design already has rather than inventing one: HOW
# HARD YOU GOT HIT DECIDES WHAT IT COSTS YOU. A shove that launches you but leaves
# you in WALK keeps your hats; a hit solid enough to tumble you does not. Same
# legibility rule as D2's ledge-grab-versus-launched, so a player who has learned
# one has learned the other.
func _pop_hats() -> void:
	if world != null and world.has_method("dislodge_hats"):
		world.dislodge_hats(self)

# YOU LET GO OF YOUR WEAPON WHEN YOU NEED BOTH HANDS. Asked for in playtest.
#
# Called from LEDGE_HANG and DOWNED and deliberately NOT from TUMBLE, which is the
# line the whole rule sits on: a tumble is being knocked about, and a tool that
# leaves your hand every time a plinko ball connects is never in your hand during
# the only fight it is for. Hanging and downed are different -- you are out of the
# game until somebody comes for you, and holding the only weapon on the bridge
# hostage while they do is the worst version of that.
#
# Hats pop in all three, because hats ARE the bet.
func _drop_special() -> void:
	if world != null and world.has_method("drop_special_of"):
		world.drop_special_of(self)

func _end_tumble() -> void:
	tumble.end()

# THE MESH ANGLE IS DERIVED FROM STATE, never left over from an earlier one.
#
# It used to be an accumulator that each exit from TUMBLE had to remember to
# clear, and one route did not: falling off the world and being drone-returned
# sets state = WALK from GameWorld directly, so the body came back standing at a
# jaunty angle for the rest of the run. Every route that ever reaches WALK would
# have to be found and fixed, forever, including ones that do not exist yet.
#
# Asking "what should the mesh look like right now" instead makes the wrong
# answer unreachable rather than merely absent, and costs one branch a tick.
# Called from step() AND from apply_state(), so a client shown a remote player
# who stopped tumbling somewhere it never simulated also puts them upright.
func _sync_mesh() -> void:
	_point_nose()
	if state == State.TUMBLE:
		_spin_mesh()
	else:
		_reset_mesh()

# The MESH pinwheels; the collider never tips. A rolling player has to stay
# something a friend can stand on -- see design_ideas/3d_conventions.md.
func _spin_mesh() -> void:
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh == null:
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	# Spin about the axis perpendicular to travel, so the body rolls the way it
	# is going rather than spinning on the spot.
	var axis := Vector3(velocity.z, 0.0, -velocity.x)
	if axis.length_squared() < 0.001:
		return
	mesh.rotate(axis.normalized(), SimConfig.TUMBLE_SPIN_RATE * SimConfig.TICK_DELTA * minf(speed / 10.0, 1.5))

func _reset_mesh() -> void:
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh != null:
		mesh.rotation = Vector3.ZERO

# --- Looks --------------------------------------------------------------------

const CharacterModel = preload("res://scripts/sim/actors/player/character_model.gd")
var model = CharacterModel.new(self)
# The model's materials, for the tests that check a colour reached the mesh.
var _body_material: StandardMaterial3D:
	get: return model.body_material
var _nose_material: StandardMaterial3D:
	get: return model.nose_material


# HOW THIS PLAYER LOOKS -- see actors/player/character_model.gd.
func apply_look(body_colour: Color, character_seed: int = 0, accessory: String = "none") -> void:
	model.apply_look(body_colour, character_seed, accessory)



# --- Ledges -------------------------------------------------------------------

# --- Ledges: see actors/player/ledge.gd ------------------------------------------

const Ledge = preload("res://scripts/sim/actors/player/ledge.gd")
var ledge = Ledge.new(self)

func _try_catch_ledge() -> bool:
	return ledge.try_catch()

func _begin_hang(lip: Vector3, dir: int) -> void:
	ledge.begin_hang(lip, dir)

func _step_hang() -> void:
	ledge.step()

func mantle() -> bool:
	return ledge.mantle()

func release_ledge() -> void:
	ledge.release()

# --- Damage -------------------------------------------------------------------

# Returns true if the hit landed. The grace window is the reason it might not:
# without it one tumble through a pillar field costs the whole bar.
# EVERY KIND HURTS THE SAME, and that is deliberate rather than unfinished. The
# punishment vocabulary in hazards.md is four verbs wide on purpose, and a player
# who has to learn that bullets hurt differently from blasts is learning a table
# instead of a game. What differs is the PUSH, which the source chooses.
#
# The grace window is the gate, and it is the whole reason the tumble rides on
# take_damage's answer: without that, a burst from the machine gun would tumble
# somebody sixty times a second while dealing damage once.
func receive_hit(hit) -> bool:
	if is_awaiting_rescue():
		return false
	# REFUSED ENTIRELY -- no damage and no knockback. A shield that stopped the
	# damage but not the shove would be worthless in a game whose threat model is
	# being moved somewhere you did not choose.
	if shield_blocks(hit):
		return false
	if not take_damage(hit.amount):
		return false
	if hit.push > 0.0 or hit.lift > 0.0:
		begin_tumble(hit.launch_for(position))
	return true

func take_damage(amount: int) -> bool:
	if amount <= 0 or invulnerable > 0.0:
		return false
	if state == State.DOWNED:
		return false          # already out; nothing left to take
	health = maxi(0, health - amount)
	invulnerable = SimConfig.HIT_GRACE
	if health == 0:
		begin_downed()
	return true

func heal(amount: int) -> bool:
	if health >= SimConfig.MAX_HEALTH or state == State.DOWNED:
		return false
	health = mini(SimConfig.MAX_HEALTH, health + amount)
	return true

func begin_downed() -> void:
	state = State.DOWNED
	state_timer = 0.0
	rescue_progress = 0.0
	health = 0
	velocity = Vector3.ZERO
	# The special only. Hats keep the rule M8.5 gave them -- they pop on TUMBLE and
	# LEDGE_HANG -- and DOWNED is almost always reached through a tumble that has
	# already taken them. Changing that is a separate decision from this one.
	_drop_special()
	# AND IT CALLS FOR HELP BY ITSELF. Asked for 2026-08-23, right after the manual
	# call shipped, and it is the obvious half: the state where you most need
	# somebody is also the state where you are least likely to be composed enough
	# to press a key for it -- you have just been tumbled off something.
	#
	# THE COOLDOWN IS CLEARED RATHER THAN CONSULTED, which is the whole point of
	# "at least once". A player who called two seconds before going down would
	# otherwise be the one player whose collapse is silent, and that is exactly
	# backwards.
	_call_for_help_automatically()
	_roll_self_revive_window()

# ONE WINDOW PER CRISIS, fixed at the moment the crisis starts. The world tick is
# the seed because it is a number both machines already agree on -- but it is
# STORED rather than re-derived later, for the reason in self_revive_gate().
# THE COOLDOWN IS CLEARED RATHER THAN CONSULTED, which is the whole point of "at
# least once". A player who called two seconds before going down -- or before
# losing their footing -- is the likeliest caller there is, and under a consulted
# cooldown they would be the one player whose crisis is silent.
func _call_for_help_automatically() -> void:
	call_cooldown = 0.0
	call_timer = SimConfig.CALL_SECONDS

func _roll_self_revive_window() -> void:
	self_revive_seed = int(world.tick) if world != null else 0
	self_revive_cooldown = 0.0

func revive() -> void:
	state = State.WALK
	state_timer = 0.0
	rescue_progress = 0.0
	health = SimConfig.REVIVE_HEALTH
	invulnerable = SimConfig.HIT_GRACE

# Put this body back in play somewhere. The drone return and a checkpoint restart
# after a wipe are the two callers, and they used to do it by assigning seven
# fields each from GameWorld -- two hand-written lists of what a respawn means.
#
# THE TWO LISTS HAD ALREADY DRIFTED. The drone return cleared `grounded` and
# forgot `rescue_progress`; the checkpoint restart did the exact opposite. Both
# forgot the mesh. None of that is a hard bug to write -- it is the inevitable
# one, because nothing anywhere said what the full set was. It says so here now.
func respawn_at(where: Vector3, restored_health: int) -> void:
	position = where
	velocity = Vector3.ZERO
	state = State.WALK
	state_timer = 0.0
	grounded = false          # dropped in, not standing; the first step settles it
	rescue_progress = 0.0
	health = restored_health
	invulnerable = SimConfig.HIT_GRACE
	# Coming back on cooldown reads as a dropped input on the first dash after a
	# respawn, which is exactly when someone is most likely to try one.
	shove_cooldown = 0.0
	# FULL DASHES ON A RESPAWN, for the same reason the cooldown is cleared: coming
	# back with nothing in hand reads as a dropped input at the exact moment
	# somebody is most likely to reach for one.
	dash_charges = max_dashes()
	dash_refill = 0.0
	visible = true
	_sync_mesh()

func is_awaiting_rescue() -> bool:
	return state == State.DOWNED or state == State.LEDGE_HANG

func _step_inert() -> void:
	if not grounded:
		velocity.y -= SimConfig.GRAVITY * SimConfig.TICK_DELTA
	move_and_slide()
	grounded = is_on_floor()

# --- Riding -------------------------------------------------------------------

# Move with whatever this body is standing on, before it takes its own step.
func ride(delta: Vector3) -> void:
	if delta != Vector3.ZERO:
		position += delta

# What is directly underneath, if it is a sim body worth being carried by.
#
# A downward ray rather than the last move_and_slide's collision list: a body
# resting motionless can produce ZERO slide collisions, so reading the collision
# list would drop the carrier on exactly the frames where standing still on a
# friend matters most. The ray is a function of position alone, which is what
# lets a reconciliation replay re-derive the same answer instead of needing it
# in the snapshot.
func _find_carrier() -> Node:
	if not grounded:
		return null
	var space := get_world_3d().direct_space_state
	var from := global_position
	var to := global_position - Vector3(0.0, HALF_HEIGHT + FOOT_PROBE, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	query.collision_mask = collision_mask
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider = hit.get("collider")
	# Only bodies that can transport a rider. Static deck needs no carrying, and
	# asking it to would be a null check away from a crash.
	if collider != null and collider.has_method("ride"):
		return collider
	return null

# --- State capture ------------------------------------------------------------
#
# The complete simulation state of this body. Everything a reconciliation replay
# needs to rewind and re-run, and everything a snapshot carries. A field that
# affects stepping and is NOT here makes replays diverge, and the tell is
# GameWorld.corrections climbing every tick instead of sitting near zero.
#
# Position is LOCAL, not global: the wire format must not encode where a world
# happens to sit in someone's scene tree.

# HOW MANY DASHES ARE LEFT, and the clock on the next one.
#
# THE CAP IS A DEBUG KNOB, so it is read rather than stored -- turning it down
# mid-round has to take charges away rather than leave somebody holding nine.
# `tuned` returns whatever the registry holds and falls back to the constant, so
# an unregistered key still plays the shipped game.
func max_dashes() -> int:
	return maxi(1, int(DebugSettings.tuned("dash_charges", SimConfig.DASH_CHARGES)))

# THE CLOCK RUNS WHENEVER YOU ARE BELOW THE CAP, and is started by SPENDING rather
# than by running dry -- see the note in SimConfig. Spending is also the only
# thing that starts it, which is why _spend_dash sets it rather than this.
func _tick_dash_charges() -> void:
	var cap: int = max_dashes()
	dash_charges = mini(dash_charges, cap)
	if dash_charges >= cap:
		dash_refill = 0.0
		return
	if dash_refill <= 0.0:
		# Below the cap with no clock running: the knob was just turned UP. Start
		# one rather than handing the charges over instantly.
		dash_refill = SimConfig.DASH_REFILL_SECONDS
	dash_refill -= SimConfig.TICK_DELTA
	if dash_refill > 0.0:
		return
	dash_charges += 1
	dash_refill = SimConfig.DASH_REFILL_SECONDS if dash_charges < cap else 0.0

func _spend_dash() -> void:
	# STARTED ON THE FIRST SPEND AND NOT RESTARTED BY LATER ONES. Dashing again
	# while a charge is already on its way back must not push it further away --
	# that would make holding two dashes worse than holding one.
	if dash_refill <= 0.0:
		dash_refill = SimConfig.DASH_REFILL_SECONDS
	dash_charges = maxi(0, dash_charges - 1)

# rescue_progress is the one field here that step() never reads, so it cannot
# make a replay diverge. It is carried because the HUD has to DRAW it, and it is
# incremented only by GameWorld._tick_haul/_tick_revive -- i.e. only on the host.
# Left out (as it was until M9) the "a teammate is pulling you up" bar exists on
# exactly one machine in the session, and every client shows an empty bar and no
# error, which looks precisely like a rescue that is not happening.
func capture_state() -> Array:
	return [position, velocity, state, state_timer, grounded, shove_yaw, shove_cooldown,
		facing, health, invulnerable, hang_dir, rescue_progress, ledge_cooldown,
		shielding, shield_yaw, special_was_held, dash_charges, dash_refill,
		carry_speed, pistol_heat, pistol_timer, call_timer, self_revive_seed]

func apply_state(s: Array) -> void:
	position = s[0]
	velocity = s[1]
	state = int(s[2])
	state_timer = float(s[3])
	grounded = bool(s[4])
	shove_yaw = float(s[5])
	shove_cooldown = float(s[6])
	facing = float(s[7])
	health = int(s[8])
	invulnerable = float(s[9])
	hang_dir = int(s[10])
	rescue_progress = float(s[11])
	ledge_cooldown = float(s[12])
	# Tolerated short, so a blob from before the shield existed still applies
	# rather than aborting the rest of this function on an out-of-range read.
	if s.size() > 20:
		pistol_heat = float(s[19])
		pistol_timer = float(s[20])
	# Tolerant tail read, the house pattern: a blob from before the call existed
	# leaves a player not calling rather than aborting the rest of this function.
	if s.size() > 21:
		call_timer = float(s[21])
	# The window this crisis rolled. A blob from before it existed leaves the seed
	# at whatever it was rather than aborting the rest of this function -- the
	# house pattern, and the reason a tail field is safe to add.
	if s.size() > 22:
		self_revive_seed = int(s[22])
	if s.size() > 18:
		carry_speed = float(s[18])
	if s.size() > 17:
		dash_charges = int(s[16])
		dash_refill = float(s[17])
	if s.size() > 15:
		special_was_held = bool(s[15])
	if s.size() > 14:
		shielding = bool(s[13])
		shield_yaw = float(s[14])
	# The mesh angle is not on the wire -- it is cosmetic, and derivable. But it
	# must be derived HERE too: a remote player is shown by applying snapshots,
	# never by stepping, so without this a client keeps drawing a friend spinning
	# after the host has stood them back up.
	_sync_mesh()

# There is no per-player camera. The game has ONE camera, owned by the world,
# fixed-yaw and locked to the bridge's centre line -- see
# scripts/ui/bridge_camera.gd. Per-avatar cameras were removed with it, which
# also retires the "last avatar spawned wins the viewport" hazard entirely.
