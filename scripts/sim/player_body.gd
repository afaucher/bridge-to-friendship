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
# A VIEW SCRIPT, PRELOADED BY A SIM ONE, and deliberately: the bar over this
# body's head is already a view built here, colours and all, and the alternative
# is a second copy of the crisis palette. crisis_flash.gd preloads nothing, so it
# cannot close a class cycle -- see CLAUDE.md on what a new preload can cost.
const CrisisFlash = preload("res://scripts/ui/crisis_flash.gd")

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
	DOWNED,      # M5
	BUS_DRIVER,  # M11 -- steering only
	BUS_RIDER,   # M11 -- verbs but no movement
}

@export var peer_id: int = 1

var state: int = State.WALK
var state_timer: float = 0.0

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

const HALF_HEIGHT := 0.9          # matches the CylinderShape3D in player.tscn
# The other half of that cylinder, and it exists because leaving it implicit cost
# a real bug: the plinko hit test reached for HALF_HEIGHT as its horizontal term,
# so a body 0.8 m across was treated as 1.8 m across and balls connected from
# twice their own radius away. A body has two dimensions and the code should be
# able to name both.
const RADIUS := 0.4               # ditto -- the two are a pair, from one shape
const FOOT_PROBE := 0.25          # how far below the feet to look for a carrier

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

# Is this hit refused? `hit.from` is a POINT for exactly this reason -- a shield
# gates by where something CAME FROM, which no direction-only hit could answer.
func shield_blocks(hit) -> bool:
	if not shielding:
		return false
	var flat := Vector2(position.x - hit.from.x, position.z - hit.from.z)
	if flat.length() < SimConfig.SHIELD_MIN_BLOCK_DISTANCE:
		return false
	# The yaw pointing FROM the player TOWARD the source, against the yaw the
	# shield was raised at.
	var toward: float = GridConfig.yaw_of_vector(Vector3(-flat.x, 0.0, -flat.y))
	return absf(wrapf(toward - shield_yaw, -PI, PI)) <= deg_to_rad(SimConfig.SHIELD_ARC_DEG) * 0.5

func step(move: Vector2, actions: int, aim: float = INF) -> void:
	var before := position
	state_timer += SimConfig.TICK_DELTA
	shove_cooldown = maxf(0.0, shove_cooldown - SimConfig.TICK_DELTA)
	ledge_cooldown = maxf(0.0, ledge_cooldown - SimConfig.TICK_DELTA)

	invulnerable = maxf(0.0, invulnerable - SimConfig.TICK_DELTA)

	match state:
		State.WALK:
			_step_walk(move, actions, aim)
		State.SHOVE:
			_step_shove()
		State.TUMBLE:
			_step_tumble()
		State.LEDGE_HANG:
			_step_hang()
		State.DOWNED:
			pass          # immobile; the world runs the countdown and the rescue
		_:
			_step_inert()

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

# Public so a test can drive it on a chosen frame. _process and _physics_process
# do not run in a guaranteed order relative to each other, so a test that only
# waited for a frame would be asserting against whichever happened to win.
# Drive the rescue bar over this body's head.
#
# A SCALE, NOT TEXT. This was a Label3D whose text was assigned every frame, and
# Label3D.text rebuilds the text mesh and re-rasterises its glyphs on every
# assignment -- changed or not. The game crawled for the whole time anybody was
# hanging: walk off an edge from a cold start and it stalled. Setting a scale
# costs a transform update and cannot regress into a per-frame raster.
#
# The simulation was never the problem, and measuring it said so before anything
# was changed: about 400 us a frame against a 16666 us budget, with the hang, the
# balls and the rushers all live. A headless gate does not rasterise glyphs, so
# the only instrument that could see this was somebody playing the game.
# What the bar says, in priority order. SILENCE IS A STATE: a healthy player
# shows nothing at all, because four permanent bars on a 60 m bridge become
# furniture and furniture does not get read. A bar appearing means somebody needs
# something.
const BAR_HEALTH_FILL := Color(0.30, 0.85, 0.35)   # health you still have
const BAR_HEALTH_BACK := Color(0.75, 0.15, 0.12)   # health you have lost
# THE SAME RED AS THE TRIANGLE POINTING AT THIS PLAYER, and the same constant
# rather than the same literal -- the marker at the edge of the screen and this
# bar are one fact reported twice, so they share one colour and one rhythm. See
# crisis_flash.gd.
const BAR_RESCUE_FILL := CrisisFlash.RED           # time left to reach them
const BAR_RESCUE_BACK := Color(0.03, 0.03, 0.04)   # time already gone
# SOMEBODY IS ON IT. Blue is the only colour on this bar that is not a warning,
# and it means the opposite of the other two: the red bar is a clock running out,
# and this one is a job being finished. A rescuer arriving has to be able to see
# from across the bridge that the person already crouched there is helping and not
# just standing.
const BAR_HAUL_FILL := Color(0.25, 0.60, 1.00)     # how much of the hold is done
const BAR_HAUL_BACK := Color(0.03, 0.03, 0.04)     # how much is still to go

# The bar's viewport, in pixels. The world size is this times the Sprite3D's
# pixel_size -- 200 x 30 at 0.006 is 1.2 m x 0.18 m.
const BAR_PIXELS := Vector2(200.0, 30.0)

# `at_seconds` is where in the flash cycle to draw. Negative means "read the
# clock", which is what the game passes; a test passes a chosen phase, because a
# colour that alternates twice a second is otherwise a coin toss to assert.
func sync_downed_timer(at_seconds: float = -1.0) -> void:
	var bar := get_node_or_null("StatusBar") as Sprite3D
	if bar == null:
		return
	var vp := bar.get_node_or_null("SubViewport") as SubViewport

	var status: Dictionary = status_bar()
	var fraction: float = float(status["fraction"])
	var seconds: float = at_seconds if at_seconds >= 0.0 else CrisisFlash.now()
	var fill: Color = CrisisFlash.fill_for(status, seconds)
	var back: Color = status["back"]
	if str(status["kind"]) == "":
		# Unhurt and in no trouble: say nothing, and STOP RENDERING. A viewport
		# left updating for a party of four healthy players is four render targets
		# redrawn every frame to show something nobody is looking at.
		bar.visible = false
		if vp != null:
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return

	bar.visible = true
	if vp != null:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var back_rect := bar.get_node_or_null("SubViewport/Back") as ColorRect
	if back_rect != null:
		back_rect.color = back
	var fill_rect := bar.get_node_or_null("SubViewport/Fill") as ColorRect
	if fill_rect != null:
		fill_rect.color = fill
		# THE WIDTH IS THE VALUE. Two ColorRects in a 2D viewport, so overlap is
		# settled by tree order and nothing else -- no depth, no distance sort, no
		# origin that moves as it drains.
		fill_rect.size = Vector2(BAR_PIXELS.x * clampf(fraction, 0.0, 1.0), BAR_PIXELS.y)

# THE ONE PLACE THAT DECIDES WHAT A STATUS BAR IS SAYING, and it is shared by the
# bar over this body's head and by the HUD. It used to be inline in
# sync_downed_timer, and the HUD grew its OWN pair of bars beside it -- which is
# how the HUD ended up drawing two at once, an orange countdown and a rescue bar
# that was pure black whenever nobody was helping. Two places expressing one rule
# is two places for it to differ, and it did.
#
# THREE STATES, IN PRIORITY ORDER, and the priority IS the design:
#
#   being helped   BLUE over black -- a hold filling up
#   in trouble     RED over black  -- a clock running down
#   injured        GREEN over red  -- health kept over health lost
#   healthy        nothing at all, and `kind` is ""
#
# BEING HELPED OUTRANKS BEING IN TROUBLE. Once somebody is crouched over you the
# countdown is no longer the thing anybody watching needs to know -- what they
# need is whether to come as well or go and deal with the rusher. The two also
# read as opposites at a glance, which is the point: red is draining, blue is
# filling.
#
# And rescue outranks injury: a hanging player's health is not the thing anybody
# needs, and they are on zero anyway once they are down.
#
# `kind` is what lets a caller take only the part it wants. The HUD already draws
# health as PIPS, so it shows this bar for "haul" and "rescue" and ignores
# "health" -- one bar, never two, and never a second one that is only ever black.
#
# `flash` IS SET ON EXACTLY ONE OF THEM. The red countdown alternates to white on
# crisis_flash's rhythm; nothing else does. That is the same signal as the
# triangle at the edge of the screen pointing at this player -- same red, same
# rhythm, same clock -- so a player who sees a blinking arrow and then finds the
# body it belongs to sees the marking they were already following, rather than
# two unrelated warnings about one person.
#
# The haul deliberately does NOT flash. Movement means "come here"; help is
# already there, and a second thing demanding attention would be pulling a third
# player toward a problem that is being solved.
func status_bar() -> Dictionary:
	var fraction: float = haul_fraction()
	if fraction >= 0.0:
		return {"kind": "haul", "fraction": fraction, "flash": false,
			"fill": BAR_HAUL_FILL, "back": BAR_HAUL_BACK}
	fraction = rescue_fraction()
	if fraction >= 0.0:
		return {"kind": "rescue", "fraction": fraction, "flash": true,
			"fill": BAR_RESCUE_FILL, "back": BAR_RESCUE_BACK}
	fraction = health_fraction()
	if fraction < 1.0:
		return {"kind": "health", "fraction": fraction, "flash": false,
			"fill": BAR_HEALTH_FILL, "back": BAR_HEALTH_BACK}
	return {"kind": "", "fraction": 0.0, "flash": false,
		"fill": BAR_HEALTH_FILL, "back": BAR_HEALTH_BACK}

func health_fraction() -> float:
	return clampf(float(health) / float(SimConfig.MAX_HEALTH), 0.0, 1.0)

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
	if rescue_progress <= SimConfig.TICK_DELTA:
		return -1.0
	match state:
		State.DOWNED:
			return clampf(rescue_progress / SimConfig.REVIVE_SECONDS, 0.0, 1.0)
		State.LEDGE_HANG:
			return clampf(rescue_progress / SimConfig.LEDGE_HAUL_SECONDS, 0.0, 1.0)
	return -1.0

# How much of the rescue window is LEFT, 1.0 down to 0.0, or -1 when this body is
# not waiting on anybody. Both states, each against its own clock -- 8 s hanging,
# 15 s downed -- so a full bar means the same thing in either.
func rescue_fraction() -> float:
	var left: float = rescue_seconds_left()
	if left < 0.0:
		return -1.0
	match state:
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
func rescue_seconds_left() -> float:
	match state:
		State.DOWNED:
			return maxf(0.0, SimConfig.DOWNED_SECONDS - state_timer)
		State.LEDGE_HANG:
			return maxf(0.0, SimConfig.LEDGE_HANG_SECONDS - state_timer)
	return -1.0

# WHOLE SECONDS, ROUNDED UP. A rescuer reads this from across a 60 m bridge while
# running, so it has to be legible at a glance rather than precise -- and ceil
# means it never shows "0" on somebody who is still savable.
func rescue_seconds_left_text() -> String:
	return str(int(ceil(maxf(0.0, rescue_seconds_left()))))

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

	if (actions & SimConfig.ACTION_SHOVE) != 0 and shove_cooldown <= 0.0:
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

	var target := wish * SimConfig.WALK_SPEED
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := SimConfig.WALK_ACCEL if wish.length_squared() > 0.0 else SimConfig.WALK_FRICTION
	horizontal = horizontal.move_toward(target, rate * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	move_and_slide()
	grounded = is_on_floor()

func _begin_shove(move: Vector2, aim: float) -> void:
	# A shove commits to the direction you were POINTING at the instant of the
	# press, and to nothing afterwards. The commitment is the design (see
	# _step_shove); what changed with free aim is only that the committed
	# direction is now any angle rather than one of four.
	shove_yaw = _aim_yaw(move, aim)
	facing = shove_yaw
	state = State.SHOVE
	state_timer = 0.0
	var axis: Vector3 = GridConfig.yaw_vector(shove_yaw)
	velocity.x = axis.x * SimConfig.SHOVE_SPEED
	velocity.z = axis.z * SimConfig.SHOVE_SPEED

func _step_shove() -> void:
	var dt := SimConfig.TICK_DELTA

	# The dash holds its speed along its axis and cannot be steered, slowed or
	# cancelled. Gravity still applies, so a dash off the deck is a dash off the
	# deck -- that commitment is where the comedy lives, and it is also why the
	# client does not predict this state: there is no input to mispredict.
	var axis: Vector3 = GridConfig.yaw_vector(shove_yaw)
	velocity.x = axis.x * SimConfig.SHOVE_SPEED
	velocity.z = axis.z * SimConfig.SHOVE_SPEED
	if grounded:
		velocity.y = -SimConfig.FLOOR_STICK
	else:
		velocity.y -= SimConfig.GRAVITY * dt

	move_and_slide()
	grounded = is_on_floor()

	var hit_something := false
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		# Only side-on contacts count. Running along the floor is not "hitting
		# something", and neither is clipping a ceiling.
		if absf(collision.get_normal().y) > 0.7:
			continue
		hit_something = true
		if world != null:
			world.resolve_shove_contact(self, collision.get_collider(), shove_yaw)

	if hit_something or state_timer >= SimConfig.SHOVE_DURATION:
		end_shove()

func end_shove() -> void:
	if state != State.SHOVE:
		return
	state = State.WALK
	state_timer = 0.0
	shove_cooldown = SimConfig.SHOVE_COOLDOWN
	velocity.x = 0.0
	velocity.z = 0.0

# Momentum arriving from someone else's dash. Called by the world, which owns
# the transfer rules.
func receive_shove(yaw: float) -> void:
	if state == State.DOWNED or state == State.LEDGE_HANG:
		return
	var axis: Vector3 = GridConfig.yaw_vector(yaw)
	# A dash arrives at 56 m/s. That is not a nudge -- it TUMBLES you, which is
	# where the comedy lives: the shoved player loses control and goes wherever
	# the bridge sends them.
	begin_tumble(Vector3(
		axis.x * SimConfig.SHOVE_TRANSFER_SPEED,
		SimConfig.SHOVE_TRANSFER_LIFT,
		axis.z * SimConfig.SHOVE_TRANSFER_SPEED))

# --- Tumble -------------------------------------------------------------------

func _step_tumble() -> void:
	var dt := SimConfig.TICK_DELTA
	velocity.y -= SimConfig.GRAVITY * dt

	# Ground friction only. Airborne, the body keeps everything it was given --
	# that is what makes a tumble carry you somewhere you did not want to go.
	if grounded:
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		horizontal = horizontal.move_toward(Vector3.ZERO, SimConfig.TUMBLE_FRICTION * dt * horizontal.length())
		velocity.x = horizontal.x
		velocity.z = horizontal.z

	# What the body was doing when it arrived. move_and_slide is about to remove
	# the into-surface part of it, and both the ramp launch and any honest
	# reading of an impact need the value from before that.
	var approach := velocity
	move_and_slide()
	grounded = is_on_floor()

	# BOUNCE off whatever it hits, rather than stopping dead against it. A
	# tumbling player ricocheting off a parapet and back into the pillar field is
	# the whole point; sliding to a halt at the first wall is not a threat.
	#
	# THIS ALSO SCRUBS SPEED EVERY TICK WHILE GROUNDED, and that is DELIBERATE --
	# do not "fix" it. A resting body reports a floor contact each tick, so this
	# applies the restitution repeatedly and a tumble settles quickly once it is
	# down. The plinko ball had the identical pattern and it was a bug there,
	# because a ball has to keep rolling; here it is the behaviour, and it was
	# kept after playtest (2026-08-08) in preference to the "correct" version.
	# Consistency with the ball is not worth a tumble that feels worse.
	for i in get_slide_collision_count():
		var normal := get_slide_collision(i).get_normal()
		# A steep ramp THROWS a thrown body up itself, rather than bouncing it
		# back down. Checked before the bounce, because bouncing is what used to
		# happen and it is why a shove up a ramp went nowhere.
		#
		# Judged on the APPROACH velocity, not the current one: move_and_slide has
		# already removed the into-surface component, so reading it back says the
		# body was barely moving toward a wall it just hit at 11 m/s.
		if _try_ramp_launch(normal, approach):
			break
		if velocity.dot(normal) < 0.0:
			velocity = velocity.bounce(normal) * SimConfig.TUMBLE_BOUNCE

	var slow_enough: bool = velocity.length() < SimConfig.TUMBLE_RECOVER_SPEED
	if state_timer >= SimConfig.TUMBLE_MAX_SECONDS \
			or (state_timer >= SimConfig.TUMBLE_MIN_SECONDS and grounded and slow_enough):
		_end_tumble()

# A ramp too steep to walk, hit with momentum, throws you UP it.
#
# This is the co-op gate working rather than merely existing: the negative half
# ("a lone player cannot walk up") is worthless on its own, because a wall nobody
# can climb passes it too. This is the half that makes a steep ramp a gate
# instead of a dead end -- "they tie each other together, one pushes the other up
# the ramp", from the original brief.
#
# Called only from TUMBLE, never from SHOVE. See RAMP_LAUNCH_MIN_SPEED.
func _try_ramp_launch(normal: Vector3, approach: Vector3) -> bool:
	# Moving into it, not sliding back down it.
	if approach.dot(normal) >= 0.0:
		return false
	if approach.length() < SimConfig.RAMP_LAUNCH_MIN_SPEED:
		return false

	# Steep enough to be a ramp rather than a floor, shallow enough to be a ramp
	# rather than a wall. A parapet must still stop you dead.
	var incline: float = rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
	if incline <= SimConfig.MAX_WALK_ANGLE_DEG or incline >= SimConfig.RAMP_LAUNCH_MAX_ANGLE_DEG:
		return false

	# Up the slope: world up, with the part pointing out of the surface removed.
	var up_slope: Vector3 = (Vector3.UP - normal * normal.y)
	if up_slope.length_squared() < 0.0001:
		return false
	# REDIRECTED, not projected. Projecting onto the slope costs a cosine of
	# speed, which is most of the energy needed to clear the climb.
	velocity = up_slope.normalized() * SimConfig.RAMP_LAUNCH_SPEED
	return true

func begin_tumble(launch: Vector3) -> void:
	if state == State.DOWNED or state == State.LEDGE_HANG:
		return
	state = State.TUMBLE
	state_timer = 0.0
	velocity = launch
	grounded = false
	_pop_hats()

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
	state = State.WALK
	state_timer = 0.0
	velocity.x = 0.0
	velocity.z = 0.0

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

# --- Ledges -------------------------------------------------------------------

# Catch a lip you are falling past. AUTOMATIC, no input: this fires most often
# mid-tumble, when the player has no control to answer a prompt with.
#
# Grid-based rather than a geometric probe, because the bridge IS a grid: "am I
# over a hole with solid deck beside me at about my height" is exactly the
# question, and it is a pure function of position, so a replay re-derives it.
func _try_catch_ledge() -> bool:
	if world == null or world.grid == null:
		return false
	if ledge_cooldown > 0.0:
		return false          # just let go of one; a hang is one chance per fall
	if velocity.y > 0.0 or velocity.length() > SimConfig.LEDGE_CATCH_MAX_SPEED:
		return false

	var grid: Node = world.grid
	var cell: Vector2i = grid.cell_of_world(position)
	if grid.is_solid(cell):
		return false          # still over deck; nothing to catch

	for dir in 4:
		var neighbour: Vector2i = cell + GridConfig.DIR_CELLS[dir]
		if not grid.is_solid(neighbour):
			continue
		var lip: Vector3 = grid.cell_surface_world(neighbour)
		# Level with the lip, or just below it. Far below and you are past it --
		# which is exactly the "launched clear of the deck" case that is meant to
		# have no rescue.
		if position.y > lip.y or lip.y - position.y > SimConfig.LEDGE_CATCH_REACH:
			continue
		_begin_hang(lip, dir)
		return true
	return false

func _begin_hang(lip: Vector3, dir: int) -> void:
	state = State.LEDGE_HANG
	state_timer = 0.0
	velocity = Vector3.ZERO
	grounded = false
	hang_dir = dir
	_pop_hats()
	# BEFORE the position is moved below, so it lands on the deck it was standing
	# on rather than in the hole the player is now dangling into. Not a rescue --
	# a hanging player still cannot reach it -- but a teammate can.
	_drop_special()
	# Hanging just off the edge on the hole side, head about level with the deck.
	var outward: Vector3 = GridConfig.DIR_VECTORS[dir]
	position = lip - outward * (GridConfig.CELL_SIZE * 0.5 + 0.35) - Vector3(0.0, HALF_HEIGHT, 0.0)

func _step_hang() -> void:
	# Nothing to simulate: a hanging player holds still. The world runs the
	# countdown, because letting go and being drone-returned are its business.
	velocity = Vector3.ZERO

# Climb onto the deck being hung from. A hanging player CANNOT call this on their
# own -- that is the whole point of the state. It exists for whatever is pulling
# them: the rope, in M4.
func mantle() -> bool:
	if state != State.LEDGE_HANG or world == null or world.grid == null:
		return false
	var grid: Node = world.grid
	var cell: Vector2i = grid.cell_of_world(position)
	var target: Vector2i = cell + GridConfig.DIR_CELLS[hang_dir]
	if not grid.is_solid(target):
		return false
	position = grid.cell_surface_world(target) + Vector3(0.0, HALF_HEIGHT + 0.05, 0.0)
	state = State.WALK
	state_timer = 0.0
	velocity = Vector3.ZERO
	grounded = true
	return true

# Let go, and fall. What happens when the hang timer runs out.
func release_ledge() -> void:
	if state != State.LEDGE_HANG:
		return
	state = State.TUMBLE
	state_timer = 0.0
	grounded = false
	# YOU LET GO; YOU DO NOT GET IT BACK. The body is released 0.9 m under the
	# lip, which is inside LEDGE_CATCH_REACH, so without this it grabs the same
	# lip again on the next tick and the countdown starts over -- forever.
	ledge_cooldown = SimConfig.LEDGE_REGRAB_COOLDOWN

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

# rescue_progress is the one field here that step() never reads, so it cannot
# make a replay diverge. It is carried because the HUD has to DRAW it, and it is
# incremented only by GameWorld._tick_haul/_tick_revive -- i.e. only on the host.
# Left out (as it was until M9) the "a teammate is pulling you up" bar exists on
# exactly one machine in the session, and every client shows an empty bar and no
# error, which looks precisely like a rescue that is not happening.
func capture_state() -> Array:
	return [position, velocity, state, state_timer, grounded, shove_yaw, shove_cooldown,
		facing, health, invulnerable, hang_dir, rescue_progress, ledge_cooldown,
		shielding, shield_yaw]

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
