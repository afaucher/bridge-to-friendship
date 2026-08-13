extends RefCounted

# Every number the simulation runs on, in one place.
#
# These are game-feel values, not physical ones -- gravity here is 2.4x Earth
# because a game about being launched off a bridge wants a fast, readable arc,
# not a floaty one. Where a value is doing something non-obvious it says so.
#
# Tuning happens HERE and nowhere else. A magic number in a step function is a
# number nobody will find when the feel is wrong.

# --- Tick ---------------------------------------------------------------------
# The sim tick IS the physics tick. This is load-bearing, not a coincidence:
# CharacterBody3D.move_and_slide() takes its delta from the physics frame, so a
# reconciliation replay of N ticks inside a single frame only reproduces the
# original N frames if the tick and the physics step are the same duration.
# project.godot pins physics to 60 Hz; if that changes, this changes with it.
const TICK_RATE := 60
const TICK_DELTA := 1.0 / 60.0

# --- Walking ------------------------------------------------------------------
const WALK_SPEED := 6.0
const WALK_ACCEL := 60.0      # reaches full speed in 0.1s -- responsive, not floaty
const WALK_FRICTION := 50.0   # stops in 0.12s, so releasing input reads as a stop

# A permanent gentle push into the floor while grounded.
#
# NOT cosmetic. A body resting with velocity.y == 0 does not reliably register a
# floor collision in move_and_slide, so is_on_floor() flickers -- and everything
# downstream flickers with it: the grounded flag, and therefore the carrier
# probe, so a player standing on a walking friend loses its carrier every other
# tick and slides off. Also what keeps a player glued to the pitched bridge and
# to a ramp instead of skipping down it.
const FLOOR_STICK := 2.0
const GRAVITY := 24.0

# THERE IS NO JUMP. Space is the dash. The design's traversal verbs are shove and
# rope, and a jump would quietly solve obstacles that are supposed to need a
# second player -- a small ledge stops being a co-op moment the instant everyone
# can hop it. Removed deliberately; do not add one back without deciding what it
# does to the ascender grades in bridge_grid.md.

# Above this the deck is not walkable and you need a shove or a rope. THE
# NUMBER IS THE CO-OP GATE: a gentle ramp (1 height unit per 2 m cell, ~27 deg)
# is walkable alone, a steep one (2 units per cell, 45 deg) is not, so authoring
# "you need each other here" is authoring a slope. Enforced by the body's
# floor_max_angle, and mirrored in SegmentValidator.
const MAX_WALK_ANGLE_DEG := 40.0

# --- Shove --------------------------------------------------------------------
# The signature verb: a run locked to a compass axis that cannot be steered,
# slowed or cancelled.
#
# SPEED AND DURATION ARE A PAIR, and the distance is the thing being chosen:
# 56 m/s for 0.1 s is 5.6 m, a little under three cells. Short enough to be a
# committed jab at something specific rather than a way to cross the bridge, and
# fast enough to read as a snap rather than a run.
#
# 0.1 s is SIX TICKS. That is close to the floor of what a fixed 60 Hz tick can
# express -- a shorter dash would start quantising badly (five ticks is 17% less
# distance, not 5%). If it ever needs to be shorter, the tick rate is what has to
# change, not this number.
#
# 0.93 m of travel per tick is comfortably inside a 2 m cell and a 0.8 m body, so
# move_and_slide's sweep still catches everything; it does not tunnel.
const SHOVE_SPEED := 56.0
const SHOVE_DURATION := 0.1
# What a shoved PLAYER receives. Lower than the dash itself so a chain of players
# shoving each other decays instead of accelerating forever.
const SHOVE_TRANSFER_SPEED := 11.0
const SHOVE_TRANSFER_LIFT := 2.5   # a little upward, so a hit reads as a launch
# Cooldown after a dash ends, so shove is a committed decision rather than a
# faster way to walk.
const SHOVE_COOLDOWN := 0.35

# How fast a pushed stone slides to its new cell. Presentation only -- the grid
# records the new cell the instant the push is legal.
const STONE_PUSH_SPEED := 6.0

# Anything below this has left the world.
const FALL_KILL_Y := -30.0

# --- Health -------------------------------------------------------------------
const MAX_HEALTH := 5

# Invulnerability after any hit. Without it a single tumble through a pillar
# field drains the whole bar before the player regains control -- they never made
# a decision and lost everything. Close to mandatory once tumble and plinko
# exist together.
const HIT_GRACE := 0.75

# --- Tumble -------------------------------------------------------------------
# A PINWHEEL, NOT A SLIDE. A hard hit throws a chaotic bouncing body that KEEPS
# its momentum: on a bridge full of holes the threat is displacement, not damage,
# and a tumble that decelerates politely is not a threat at all.
const TUMBLE_BOUNCE := 0.55        # how much speed survives an impact
const TUMBLE_FRICTION := 1.2       # per second, while rolling on the ground
const TUMBLE_MIN_SECONDS := 0.5    # you do not pop straight back up
const TUMBLE_MAX_SECONDS := 5.0    # ...but you are never stuck rolling forever
const TUMBLE_RECOVER_SPEED := 3.5  # must have slowed to this to stand up
const TUMBLE_SPIN_RATE := 9.0      # radians/sec of MESH spin; the collider never tips

# --- Ramp launch: the co-op gate, made to actually work -----------------------
#
# A ramp too steep to walk is a WALL as far as the engine is concerned, so a
# shoved player bounced off it and went nowhere -- measured 0.05 m of climb
# against the 1.55 m needed. And even riding it perfectly, the shove transfer
# does not carry enough energy: clearing a 2 m rise wants ~10 m/s of vertical,
# which is ~14 m/s along a 45-degree slope.
#
# So a steep ramp is a LAUNCHER. A body that arrives with momentum is redirected
# up the slope and thrown, rather than projected onto it (which loses energy to
# the cosine) or bounced off it (which loses the point).
#
# ONLY WHILE TUMBLING, and that restriction IS the co-op gate. A dash is a
# horizontal run that slams into the ramp face; being THROWN by a teammate is
# what carries you up it. Let a dash launch you too and a lone player can climb
# the steep ramp unaided, and every authored "you need each other here" beat
# stops meaning anything.
const RAMP_LAUNCH_MIN_SPEED := 6.0     # arrive slower than this and it is just a wall
const RAMP_LAUNCH_SPEED := 16.0        # what you leave at, along the slope
const RAMP_LAUNCH_MAX_ANGLE_DEG := 75.0  # steeper than this is a wall, not a ramp

# --- Ledges and rescue --------------------------------------------------------
# The catch is AUTOMATIC (no input): it fires most often while the player is
# mid-tumble with no control, so a prompt they could not answer would read as the
# game cheating.
#
# The asymmetry these two numbers create IS the design: shoved along the deck and
# you catch the lip and are rescuable; launched clear of it and you simply fall.
# Whether your friends can save you is decided by how you got hit.
const LEDGE_CATCH_REACH := 1.4     # how far below a lip you can still reach it
const LEDGE_CATCH_MAX_SPEED := 16.0  # arriving faster than this and you miss

# Both waiting-to-be-rescued states run a countdown and end in the drone.
const LEDGE_HANG_SECONDS := 8.0

# After letting go, you cannot grab again for this long.
#
# WITHOUT IT THE HANG NEVER ENDS. release_ledge drops the body at lip.y minus its
# own half-height -- 0.9 m below the lip, well inside LEDGE_CATCH_REACH -- so on
# the very next tick it is still falling slowly beside a solid neighbour and
# catches the SAME lip again. The timer restarts and the player hangs forever.
# Found in playtest 2026-08-10; it had never been exercised because the only test
# of the hang hauls the player up long before the timer runs out.
#
# 0.5 s is comfortably more than enough: 0.3 s of fall already puts the body
# 2.0 m under the lip against a 1.4 m reach. The margin is for a body that
# released while scraping the wall rather than dropping cleanly.
#
# It also, deliberately, stops a released player catching a DIFFERENT lip
# immediately below. A hang is one chance per fall -- if it runs out, you fall.
const LEDGE_REGRAB_COOLDOWN := 0.5
const DOWNED_SECONDS := 15.0

# Revive is by PROXIMITY, not by rope: M5 ships before M4, and a downed player
# whose only rescue needed a mechanic that does not exist would be unrescuable.
const REVIVE_RADIUS := 2.5
const REVIVE_SECONDS := 1.5
const REVIVE_HEALTH := 1

# Hauling a hanging player up, by a teammate standing at the lip. Quicker than a
# revive -- you are grabbing an arm, not resuscitating anyone.
#
# THE SAME STAND-IN AS PROXIMITY REVIVE, for the same reason. A hanging player
# whose only rescue is the rope is unrescuable while the rope does not exist, and
# an unrescuable state is a dead end that reads as a bug. When M4 lands, the rope
# does this at RANGE -- reaching someone you cannot stand next to, or catching
# them mid-fall -- and this stays as the cheap close-range version.
#
# It does not weaken the co-op gate: it still takes a second player. What a
# hanging player still cannot do is get themselves out.
const LEDGE_HAUL_SECONDS := 0.8

# How long the drone takes to put a lost player back next to a teammate.
const DRONE_RETURN_SECONDS := 3.0

# --- Hearts -------------------------------------------------------------------
const HEART_PICKUP_RADIUS := 1.2
const HEART_HEAL := 1

# --- The run ------------------------------------------------------------------

# How many segments a run starts with, and how far ahead of the party it keeps
# building. The bridge is endless; it is simply built lazily.
const RUN_INITIAL_SEGMENTS := 3
const RUN_LOOKAHEAD_SEGMENTS := 2

# Progress banks every N segments. A wipe restarts there rather than at the
# bottom -- the design's "endless climb with banked checkpoints".
const CHECKPOINT_EVERY_SEGMENTS := 2

# --- The soft leash -----------------------------------------------------------
#
# Players separate freely up to SOFT, past which a straggler is helped forward,
# and past HARD they are simply moved. It guarantees the co-op stays possible,
# keeps the party in one camera, and is what makes streaming one window around
# the group instead of one per player.
const LEASH_SOFT := 40.0
const LEASH_HARD := 70.0
# How much of a walk's worth of help a lagging player gets. Deliberately gentle:
# a leash you can feel dragging you is worse than one you cannot.
const LEASH_ASSIST := 3.0

# --- Plinko -------------------------------------------------------------------
# See design_ideas/plinko.md.

const BALL_RADIUS := 0.6

# ONE SOURCE OF VARIANCE: the angle. Every ball leaves at the same speed, so
# every arc is the same size and the field has a learnable rhythm -- a player can
# watch one ball and know roughly where the next goes. Randomising speed as well
# would make each shot individually unreadable, and a hazard nobody can read is a
# tax rather than an obstacle.
const PLINKO_LAUNCH_SPEED := 10.0
const PLINKO_CONE_DEG := 70.0

# Bounce, and a proportional drag that decides the ROLLING speed. Gravity along
# the bridge's 4-degree pitch is ~1.67 m/s^2, so terminal roll is about
# 1.67 / drag -- at 0.35 that is roughly 4.8 m/s, comfortably under a player's
# 6 m/s walk. Balls have to be outrunnable: the threat is that one is still
# coming while you are busy, not that it is faster than you.
const PLINKO_BOUNCE := 0.5

# Below this approach speed a contact is a ROLL, not a bounce. Resting on the
# deck still reports a floor collision every tick, and treating those as bounces
# multiplies the tangential roll away in a fraction of a second -- which presents
# as "the friction is far too high" while the friction is doing nothing wrong.
const PLINKO_BOUNCE_MIN_SPEED := 1.5

# Proportional drag, which sets the ROLLING speed: gravity along the bridge's
# 4-degree pitch is ~1.67 m/s^2, so terminal roll is about 1.67 / drag. At 0.25
# that is ~6.7 m/s -- a shade above a player's 6 m/s walk, so a ball on your tail
# cannot simply be out-walked in a straight line and has to be dodged sideways,
# which is the play the design asks for.
const PLINKO_ROLL_DRAG := 0.25

const PLINKO_FIRE_INTERVAL := 2.5
const PLINKO_BALL_LIFETIME := 25.0
# A backstop, not a design value. If firing ever outruns despawning, this is what
# stops a runaway from becoming a frame-rate problem instead of a bug report.
const PLINKO_MAX_BALLS := 24

# A ball has to still be MOVING to hurt. Below this it is just an object you
# bumped into -- it still collides physically and gets in your way, it simply
# does not tumble you or cost a hit point.
#
# THE ONLY JOB OF THIS NUMBER IS TO EXCLUDE A BALL THAT HAS STOPPED. It went in
# at 4.0, which is under the ~6.7 m/s terminal roll and looked defensible on
# paper -- and playtest came straight back with "now they are way too safe",
# because most balls in a real field have bounced off something and are well
# under terminal. 2 m/s is a third of a walking pace: visibly, obviously spent.
#
# It is NOT the glancing/solid split the design deliberately dropped. That was an
# invisible threshold in the MIDDLE of the dangerous range, where two hits that
# looked identical did different things. This is the line where a ball stops
# being dangerous at all, and a ball trickling to a halt visibly has nothing
# left.
const PLINKO_MIN_HIT_SPEED := 2.0

const PLINKO_DAMAGE := 1
# What a hit throws you at. Reuses the shove transfer so a ball and a friend
# knock you about the same amount -- one knockback rule, not two.
const PLINKO_KNOCKBACK := SHOVE_TRANSFER_SPEED
const PLINKO_KNOCKBACK_LIFT := SHOVE_TRANSFER_LIFT
# A dashing player bats the ball away this fast.
const PLINKO_DEFLECT_SPEED := 16.0
# One ball cannot hit the same player twice in a row without leaving first.
const PLINKO_HIT_COOLDOWN := 0.5

# --- Rushers ------------------------------------------------------------------
#
# The first DESTRUCTIBLE hazard: shove deflects it, only a weapon ends it early.
# See design_ideas/hazards.md. Everything before this was deflectable, which made
# the ranged specials weak by construction -- a shotgun was a shove from further
# away, and the shove is free.

const RUSHER_RADIUS := 0.5
const RUSHER_HEIGHT := 1.4

# Close enough that waking one reads as YOUR mistake, far enough that the rise
# has time to matter.
const RUSHER_TRIGGER_RADIUS := 6.0

# THE TELEGRAPH, and the reason this is fair. Same rule as plinko's slow balls:
# the threat announces itself before it can touch you. Long enough to back off,
# short enough to be worth reacting to rather than ignoring.
const RUSHER_RISE_SECONDS := 1.0

# Above WALK_SPEED (6.0), so it cannot be strolled away from -- that is what
# makes it a decision. A rounding error against SHOVE_SPEED (56), so committing
# an axis still beats it.
const RUSHER_SPEED := 8.0

# One dash buys a breath, not an escape.
const RUSHER_STAGGER_SECONDS := 2.0
const RUSHER_DEFLECT_SPEED := 14.0

# The floor that stops a weaponless player being ground down: outliving one is
# desperate but always available. Counted from SPAWN, so the rise is inside it --
# a second of a ten-second budget, and one clock is easier to reason about than
# two.
const RUSHER_LIFETIME := 10.0

# It reaches you, tumbles you, and is spent. Expending itself is what stops a
# single rusher chain-tumbling someone who is already out of control and has no
# way to answer.
const RUSHER_HIT_RADIUS := 1.1
const RUSHER_DAMAGE := 1
const RUSHER_KNOCKBACK := SHOVE_TRANSFER_SPEED
const RUSHER_KNOCKBACK_LIFT := SHOVE_TRANSFER_LIFT

# A cap, for the same reason PLINKO_MAX_BALLS exists: authored density is a
# content decision, and this is the backstop for getting it wrong.
const RUSHER_MAX := 12

# --- Hats ---------------------------------------------------------------------
#
# The first thing in the game that rewards taking a risk you did not have to
# take. See implementation_plans/m8_5_hats.md. Every number here is a starting
# value with a stated reason and every one is expected to move in playtest.

# A little wider than the 0.4 m body radius, so walking NEAR a hat gets it and
# nobody has to aim at one.
const HAT_PICKUP_RADIUS := 0.7

# Tall enough to read as absurd from across a 60 m bridge, short enough that the
# top hat is still on screen.
const HAT_MAX_STACK := 5
const HAT_HEIGHT := 0.35

# How long after a hat lands before it can be picked up again.
#
# THE WHOLE POINT IS THAT A DISLODGE AND A RE-COLLECT ARE NOT THE SAME EVENT. A
# tumbling player rolls through their own scattered hats; without this they would
# scoop them back up on the way past and the tumble would cost nothing.
const HAT_SETTLE_GRACE := 0.5

# Below this a hat is considered to have stopped, and the settle grace starts.
const HAT_SETTLE_SPEED := 0.8

# What a dislodged stack scatters at. Spreads over roughly two cells, so a stack
# lands as a spread you have to walk to rather than a pile you re-collect in one
# step.
const HAT_SCATTER_SPEED := 4.0
const HAT_SCATTER_LIFT := 4.5

# A segment's worth of debris. An endless run scattering hats leaks bodies
# forever, so the oldest loose hat is culled when this is exceeded.
const HAT_MAX_LOOSE := 24

# --- How a stack leans --------------------------------------------------------
#
# A stack of hats is not a rod. Each hat leans a LITTLE against the one below it
# and the lean ACCUMULATES up the tower, so a five-stack tips five times as far
# at the top as at the bottom -- which is the whole reason to have a tall stack
# on screen at all. It is cosmetic to the last decimal: nothing here is in
# capture_state(), nothing is on the wire, and no lean angle has ever decided
# anything.

# PER HAT, RELATIVE TO THE ONE BELOW IT. Five of these compose to 25 degrees at
# the top of a full stack -- obvious in motion, and still nowhere near a topple.
#
# In degrees, like MAX_WALK_ANGLE_DEG and for the same two reasons: it is the
# unit the number was chosen in, and a `const` may not call deg_to_rad().
const HAT_LEAN_MAX_DEG := 5.0

# A SECOND-ORDER SPRING, deliberately underdamped. Critically damped, a stack
# eases back upright like a menu animation; at roughly half of critical it
# overshoots once or twice and reads as a wobble, which is the joke.
#
# Stiffness is omega squared: 90 is about 1.5 Hz, roughly what a tall soft thing
# does. Damping 9 puts it near zeta 0.47.
const HAT_LEAN_STIFFNESS := 90.0
const HAT_LEAN_DAMPING := 9.0

# THE DRIVE IS AN IMPULSE PER UNIT OF VELOCITY CHANGE, NOT A FORCE PER UNIT OF
# ACCELERATION, and that is not a stylistic choice.
#
# A hat leans because the head under it changed speed and the hat did not. On the
# host that change arrives one tick at a time; on a CLIENT a remote player's
# velocity is a step function -- it only moves when a snapshot lands, every
# SNAPSHOT_INTERVAL_TICKS. Dividing by dt to get an acceleration would therefore
# make the same 6 m/s change produce a lean several times larger on a client than
# on the host, for no reason a player could ever understand. An impulse is the
# integral, so it does not care whether the change arrived in one tick or eight.
#
# 0.08 rad/s per m/s: a standing start (6 m/s over ~6 ticks) peaks near three
# degrees, and a 56 m/s dash pegs the clamp -- which is exactly the ranking those
# two events should have.
const HAT_LEAN_KICK := 0.08

# --- Specials -----------------------------------------------------------------
#
# A pickup with a fixed number of uses, ONE SLOT, dropped when spent. See
# game_concept.md §Special for the model and implementation_plans/m12_machine_gun.md
# for the first one built.

# A little wider than a hat's 0.7 m. You should not miss the only weapon on the
# bridge by 10 cm, and unlike a hat there is never a second one to catch instead.
const SPECIAL_PICKUP_RADIUS := 0.9

# A dropped special is not collectable until it has stopped and waited. Same rule
# and same reason as hats: a swap must not be a way to pick your own weapon
# straight back up.
const SPECIAL_SETTLE_SPEED := 0.8
const SPECIAL_SETTLE_GRACE := 0.5

# A third of HAT_MAX_LOOSE. Specials are rarer by design -- "contested and
# unevenly distributed" is the property the whole one-slot rule rests on.
const SPECIAL_MAX_LOOSE := 8

# --- The machine gun ----------------------------------------------------------
#
# THE CADENCE IS THE WEAPON. A round is one plinko ball; what neither the shove
# nor anything else in the game can do is apply pressure CONTINUOUSLY.

# Eight seconds of held trigger. Long enough to settle one fight, short enough
# that it is not also the answer to the next one.
#
# Cut from 60 as the rate came down, twice, so the magazine stays about the same
# length of trigger-holding rather than becoming three times as long.
const MG_AMMO := 20

# 2.5 rounds a second, 24 ticks apart.
#
# SLOWED TWICE AFTER PLAYTEST, from 10/sec and then from 4/sec. At the original
# rate the individual round did not exist -- it was a beam, and everything
# downstream of "you can see a round coming" stopped being true with it. This is
# far enough apart that each one is a thing somebody fired, which is also what
# makes the spread below mean anything: dispersion you cannot resolve into
# separate rounds is only a lower hit rate.
#
# It has stopped being a machine gun in the literal sense and that is fine. What
# was asked for was continuous pressure, and pressure at a rate you can read is
# the version that plays.
const MG_FIRE_INTERVAL := 0.4

# HOW WIDE THE CONE IS, in degrees off the aim.
#
# WIDENED FROM 4 ON PLAYTEST, which changes what the weapon is rather than just
# how accurate it is. At 4 degrees everything inside about eight metres was a
# guaranteed hit and the cone only mattered at range. At 10 it is 0.35 m of
# scatter at two metres, 0.7 at four, and over five metres at thirty -- so a
# body-width target is a certainty at point blank, a coin flip across a lane, and
# suppression at the far end of the bridge.
#
# Range therefore costs accuracy with NO falloff curve, no accuracy stat and no
# second number to defend: the geometry does all of it.
#
# HORIZONTAL ONLY. See MG_SPREAD_VERTICAL_DEG.
const MG_SPREAD_DEG := 10.0

# The cone is an ELLIPSE, not a circle: wide across, narrow up and down.
#
# It was a round 10 degree cone, which meant a round could go two metres over
# somebody's head at thirty. That is the wrong axis to be inaccurate on -- the
# bridge is a narrow strip and everything worth shooting stands on it, so
# horizontal scatter reads as a weapon that sprays and vertical scatter reads as a
# weapon that is broken. Five to one is enough to be visible without ever throwing
# a round somewhere silly: 2 degrees is 20 cm at 6 m, inside a body's height.
const MG_SPREAD_VERTICAL_DEG := 2.0

# --- What a round is ----------------------------------------------------------

# 22 m/s, slowed from 45 after playtest. Under four times a walking player and
# well under half a dash, which is the point: a round is now something you WATCH
# cross the gap, and at long range something a moving target can be out from under
# by the time it arrives. That is the whole reason these are balls and not lines.
#
# It crosses the 30 m range in about 1.4 s.
const MG_BULLET_SPEED := 22.0

# A fraction of gravity. Flat rounds read as a laser, and every other arc in this
# game -- a plinko ball, a shoved player, a dislodged hat -- is an arc.
#
# SMALL, and it had to shrink when the speed did: drop goes with the SQUARE of
# flight time, so the same fraction that gave 20 cm at 45 m/s gives five metres at
# 22. This is about a metre over the full range -- a visible lob at distance, and
# eight centimetres at the four-metre range where fights actually happen.
const MG_BULLET_DROP := 0.05

# Comfortably longer than range / speed, so the RANGE is what stops a round and
# this is only the backstop for one fired off the side of the bridge.
const MG_BULLET_LIFETIME := 1.6

# WHAT A ROUND DOES TO A PLINKO BALL. Asked for in playtest.
#
# An impulse rather than a set velocity, unlike the dash's deflect: a dash is a
# player deciding where that ball goes, and a round is a nudge that ADDS to
# whatever the ball was already doing. Against a 2 kg ball this is about 5 m/s,
# a third of PLINKO_DEFLECT_SPEED -- shooting a ball moves it, batting it away
# with your body still does more.
const MG_BALL_PUSH := 10.0

# The rifle's range from hazards.md, deliberately. This is not the long-range
# special, so it must not out-reach the one that is.
const MG_RANGE := 30.0

const MG_DAMAGE := 1

# Below SHOVE_TRANSFER_SPEED (11) and just under its lift (2.5): being shot
# pushes you around, being dashed into still throws you further. A weapon that
# out-displaced the game's signature verb would replace it rather than complement
# it, which game_concept.md's "specials never replace shove and rope" forbids.
const MG_KNOCKBACK := 8.0
const MG_KNOCKBACK_LIFT := 2.0

# (There was an MG_TRACER_SECONDS here. Rounds are real objects now, so the line
# that stood in for one is gone -- see scripts/sim/bullet.gd.)

# --- Input action bits --------------------------------------------------------
# One tick's actions travel as a single int. Edge-triggered actions (jump, and
# later shove/rope) are set for exactly the tick they were pressed, which is what
# preserves "just pressed" semantics through a reconciliation replay.
const ACTION_SHOVE := 1 << 0
const ACTION_ROPE := 1 << 1
const ACTION_SPECIAL := 1 << 2
const ACTION_SWITCH := 1 << 3

# HELD, not pressed -- set for every tick the trigger is down.
#
# A SEPARATE BIT FROM ACTION_SPECIAL, and the separation is the point. The
# roadmap requires ACTION_SPECIAL to stay edge-triggered for exactly one tick or
# a reconciliation replay re-fires it and burns charges -- that warning is about
# LEGS, which are predicted. A gun is not: firing is resolved by the host and
# never replayed, so a level-triggered bit costs nothing here. Making
# ACTION_SPECIAL itself level-triggered would have quietly spent the invariant
# legs still need.
const ACTION_SPECIAL_HELD := 1 << 4

# --- Networking ---------------------------------------------------------------
# How far the client's prediction may drift from the host's authoritative frame
# before we rewind and replay. Too small and the client replays constantly for no
# visible benefit; too large and players see themselves in the wrong place.
const CORRECTION_EPSILON := 0.05

# Every input packet repeats the last few inputs. Input goes over an unreliable
# channel, and a dropped packet carrying an edge-triggered action bit is a jump
# (later: a shove) that the player pressed and the game never performed. Repeats
# make that need three consecutive losses instead of one.
const INPUT_REDUNDANCY := 3

# Ring buffer depth for unacknowledged inputs and their predicted states. At
# 60 Hz this is ~2s of history, far more than any survivable round trip.
const HISTORY_TICKS := 128

# Ticks between authoritative snapshots. 1 = every tick, which is correct and
# wasteful; the design doc flags the real rate as open, to be decided against a
# measurement rather than a guess. Correctness first, bandwidth later.
const SNAPSHOT_INTERVAL_TICKS := 1

# How often the FULL stone list goes out. In between, only stones that are
# actually moving are sent -- a run is mostly scenery standing still, and sending
# all of it every tick measured 4595 bytes, over ENet's 1392-byte MTU. Half a
# second is the worst a client can hold a stale stone cell for.
const STONE_RESYNC_TICKS := 30
