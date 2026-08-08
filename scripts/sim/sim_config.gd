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
const PLINKO_ROLL_DRAG := 0.35

const PLINKO_FIRE_INTERVAL := 2.5
const PLINKO_BALL_LIFETIME := 25.0
# A backstop, not a design value. If firing ever outruns despawning, this is what
# stops a runaway from becoming a frame-rate problem instead of a bug report.
const PLINKO_MAX_BALLS := 24

const PLINKO_DAMAGE := 1
# What a hit throws you at. Reuses the shove transfer so a ball and a friend
# knock you about the same amount -- one knockback rule, not two.
const PLINKO_KNOCKBACK := SHOVE_TRANSFER_SPEED
const PLINKO_KNOCKBACK_LIFT := SHOVE_TRANSFER_LIFT
# A dashing player bats the ball away this fast.
const PLINKO_DEFLECT_SPEED := 16.0
# One ball cannot hit the same player twice in a row without leaving first.
const PLINKO_HIT_COOLDOWN := 0.5

# --- Input action bits --------------------------------------------------------
# One tick's actions travel as a single int. Edge-triggered actions (jump, and
# later shove/rope) are set for exactly the tick they were pressed, which is what
# preserves "just pressed" semantics through a reconciliation replay.
const ACTION_SHOVE := 1 << 0
const ACTION_ROPE := 1 << 1
const ACTION_SPECIAL := 1 << 2
const ACTION_SWITCH := 1 << 3

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
