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
# slowed or cancelled. ~11 m of travel is about half a typical playable corridor,
# so one committed action crosses the play space to reach a friend.
const SHOVE_SPEED := 14.0
const SHOVE_DURATION := 0.8
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
