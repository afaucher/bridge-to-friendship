extends RefCounted

# THE BAR OVER A PLAYER'S HEAD: health kept, a rescue clock running down, or a
# rescue being finished -- and nothing at all for a healthy player.
#
# COSMETIC, AND THEREFORE NOT IN step(). A client steps only its own predicted
# body; every other player is drawn from applied snapshots. A counter updated in
# the sim tick would be frozen over precisely the teammate a rescuer is running
# toward -- the one moment it exists for. `state_timer` rides capture_state(), so a
# remote body already carries the right number and this only has to read it.
#
# Part of PlayerBody, which forwards `sync_downed_timer` and `status_bar` here and
# aliases the colours for the tests that check them.

const PlayerStates = preload("res://scripts/sim/actors/player/player_states.gd")
const State = PlayerStates.State
const HALF_HEIGHT = PlayerStates.HALF_HEIGHT
const RADIUS = PlayerStates.RADIUS
const FOOT_PROBE = PlayerStates.FOOT_PROBE
const CrisisFlash = preload("res://scripts/present/vfx/crisis_flash.gd")

# The body this is part of. Untyped: preloading player_body.gd from here would
# close a class cycle.
var body = null

func _init(owner_body = null) -> void:
	body = owner_body

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
	var bar := body.get_node_or_null("StatusBar") as Sprite3D
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
	var fraction: float = body.haul_fraction()
	if fraction >= 0.0:
		return {"kind": "haul", "fraction": fraction, "flash": false,
			"fill": BAR_HAUL_FILL, "back": BAR_HAUL_BACK}
	fraction = body.rescue_fraction()
	if fraction >= 0.0:
		return {"kind": "rescue", "fraction": fraction, "flash": true,
			"fill": BAR_RESCUE_FILL, "back": BAR_RESCUE_BACK}
	fraction = body.health_fraction()
	if fraction < 1.0:
		return {"kind": "health", "fraction": fraction, "flash": false,
			"fill": BAR_HEALTH_FILL, "back": BAR_HEALTH_BACK}
	# UNHURT. `kind` is "" because the bar over this body's head says NOTHING here
	# -- that is the silence rule above. But the fraction and the colours are still
	# the honest answer to "what would a health bar show", because the HUD asks the
	# same question and always draws: a panel is a place you look deliberately, so
	# a full green bar there is a reading, while the same bar floating over a
	# healthy player in the world is furniture. One dictionary, two correct
	# behaviours, and neither caller has to know about the other's.
	return {"kind": "", "fraction": fraction, "flash": false,
		"fill": BAR_HEALTH_FILL, "back": BAR_HEALTH_BACK}
