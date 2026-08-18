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

# CLIMBING A LADDER (M17 phase 6).
#
# SLOWER THAN WALKING, deliberately. A ladder is the compact way up -- it climbs
# any height in one cell where a ramp needs a cell per unit -- and the price of
# that compactness is TIME, spent somewhere you cannot dodge, shove or shoot.
# That is what makes a ladder a decision rather than a free shortcut, and it is
# why a ladder is the right answer for a tall climb in a tight space and the
# wrong one under fire.
const CLIMB_SPEED := 3.0
# How close to the ladder's cell centre counts as being on it. Generous: fumbling
# for a ladder you are standing next to is not the interesting kind of difficulty.
# A body pressed against the cliff stops one radius short of the face, which is
# already 1.4 m from the ladder cell's CENTRE -- so a tighter reach than this
# means walking at a ladder and bouncing off it, which is the fumbling that is
# not the interesting kind of difficulty.
const CLIMB_REACH := 1.7
# Cleared this far above the deck at the top before the climb hands back to WALK,
# so a climber steps ONTO the landing rather than into its edge.
const CLIMB_EXIT_LIFT := 0.35

# ELEVATORS (M17 phase 9). A platform that runs between the deck it stands on and
# the deck it serves, forever, on its own clock.
#
# THERE IS NO BUTTON, and that is the design rather than a shortcut. 2b treats an
# elevator as "always available with a time cost" for completability -- a party
# can WAIT -- and a called elevator is only that if the call is free. A button
# turns a time cost into a state, and a state can be left in the wrong one by
# somebody who has already gone.
#
# VERTICAL ONLY, which is what makes this the cheap version of the phase the plan
# feared. See BridgeGrid._spawn_elevator.
const ELEVATOR_RISE_TICKS := 100
# HOW LONG IT WAITS AT EACH END, and it is the number a rider can FAIL.
#
# Playtest 2026-08-16: "you can't walk over the lip at the top to the next
# block." At 70 ticks the platform stopped for 1.17 s, and crossing a 2 m cell
# at WALK_SPEED takes 0.33 s of that — so the window was fine for somebody
# already moving and unforgiving of anybody who had to notice they had arrived
# first. Miss it and the platform is descending, which turns the step off into a
# climb up a lip that is not climbable, because there is no step-up in this game.
#
# 2.5 s instead. A lift is the slow way up by design; the part that is supposed
# to cost time is the WAIT, not a reaction test at the end of it.
const ELEVATOR_DWELL_TICKS := 150

# MUTABLE TERRAIN (M17 phase 8). One mechanism — a cell stops being solid —
# with two triggers, which is what makes "destroyable squares" and "timed blocks"
# one feature rather than two.
#
# THE DELAY IS THE WHOLE MECHANIC. A cell that vanished the instant it was touched
# would be an invisible instant-death line; half a second is long enough to see it
# start to go, decide, and run. What a crumble asks is "commit", not "guess".
const CRUMBLE_DELAY := 0.5
# AND IT COMES BACK, which is not politeness. 2b: an edge that exists ONCE makes a
# run completable once, and a party of four where the first across drops the floor
# strands the other three with nothing to tell them why. Restoring turns it back
# into what the flood already assumes it is: available, at a cost in time.
const CRUMBLE_RESTORE := 4.0
# A timed block on its own clock. Solid for most of the cycle, so a row of them
# is a rhythm to cross rather than a coin flip.
const TIMED_PERIOD_TICKS := 180
const TIMED_SOLID_TICKS := 115

# LEGS (M17 phase 6). A special that launches you straight up.
#
# ITS WHOLE JOB IS TO BE A SHORTCUT AND NEVER A ROUTE. Legs are expendable, and
# per 2a-i of design_ideas/world_generation.md an edge gated by a consumable may
# only ever be a shortcut — a section that REQUIRED one would become impossible
# at the moment the last charge is spent, with the party stuck in it and nothing
# telling them why. That rule is enforced by an absence: SegmentValidator.party_of
# has no `has_legs` field, so the crossability flood cannot see this at all.
#
# CLEARS THREE HEIGHT UNITS. Chosen against what the deck is made of rather than
# for feel: a bare step up is a wall at ANY height (there is no mantle in this
# game), so anything that clears more than one is already a shortcut past
# geometry that otherwise needs a ramp, a ladder or a teammate. Three is enough
# to be worth carrying and short of the tallest thing the generator builds.
# TUNED FOR DWELL, NOT FOR APEX, and the first pass got that wrong: sqrt(2gh) for
# h = 3.25 puts the apex a hand's width over a three-unit step and leaves 0.29 s
# above the lip -- barely enough to travel the metre needed to land ON it, and a
# rise that only just clears something is a rise that mostly does not. At 13.9 the
# apex is 4.0 m and the feet spend 0.58 s above 3.0, which is what actually gets
# you across. It is also why FOUR units is out of reach: the apex is exactly 4 and
# the dwell there is zero.
const LEGS_LAUNCH := 13.9
const LEGS_AMMO := 4
# Airborne steering is the walk step's business and unchanged, so a player who
# holds the stick carries WALK_SPEED through the arc — about 3 m forward by the
# apex, which is a cell and a half. That is what lands you ON the deck rather
# than against its face, and it is why there is no forward impulse here.

# A BOOST UP A SLOPE, as distinct from a shove into open air. Slower and with
# more lift than a tumble: the point is to ARRIVE somewhere, not to be launched,
# and the receiving player keeps control the whole way. See
# PlayerBody.receive_shove -- the same dash produces both, and which one you get
# is decided by what is in front of you.
const BOOST_CARRY_SPEED := 7.0
const BOOST_LIFT := 7.5
const SHOVE_TRANSFER_LIFT := 2.5   # a little upward, so a hit reads as a launch
# Cooldown after a dash ends, so shove is a committed decision rather than a
# faster way to walk.
const SHOVE_COOLDOWN := 0.35

# HOW MANY DASHES YOU HOLD, and how fast they come back.
#
# CHARGES AND COOLDOWN ARE DIFFERENT LIMITS AND BOTH ARE KEPT. SHOVE_COOLDOWN
# bounds the RATE -- you cannot spend three in a third of a second -- and this
# bounds the TOTAL. Without charges the dash was free and infinite, which made it
# the answer to everything: the counter to a rusher, the way across a gap, and the
# way out of any mistake. Without the cooldown, three charges would be one
# three-length dash.
#
# THE REFILL STARTS WHEN YOU SPEND, not when you run dry. Waiting for empty before
# the clock starts punishes the player who paced themselves and rewards the one
# who dumped all three, which is backwards.
const DASH_CHARGES := 3
const DASH_REFILL_SECONDS := 5.0

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
# ENOUGH FOR A WHOLE ROUND PLUS THE LOBBY IT ENDS ON, or the party walks into a
# boundary that has not been appended yet and the round machine has no target.
# SegmentPool.SECTIONS_PER_ROUND + 2 is that, and the +1s are the two lobbies.
const RUN_INITIAL_SEGMENTS := 7
# The run extends by a whole round at a time for the same reason: a lookahead
# smaller than a round means the far boundary appears mid-round, which is fine
# for the sim and looks like the bridge being built in front of you.
const RUN_LOOKAHEAD_SEGMENTS := 6

# SPIKE BLOCKS (M17). A full cycle, and how much of it the spikes are OUT for.
#
# A THIRD OUT, TWO THIRDS SAFE, on a two-second cycle. The number that matters is
# the SAFE window, not the dangerous one: it has to be long enough to walk a cell
# through, or the block is not a hazard with a rhythm, it is a wall that
# occasionally lets you past. Two thirds of two seconds is four times what a walk
# across a cell costs, which is room to hesitate.
const SPIKE_PERIOD := 2.0
const SPIKE_OUT_FRACTION := 0.34
const SPIKE_DAMAGE := 1
# HOW FAR FROM THE BLOCK'S OWN CENTRE, and until 2026-08-16 it was measured from
# the block's four NEIGHBOURS instead — which put the one safe spot in the
# middle of the spikes and a hurt ring from 0.7 m to 3.3 m out. Measured, sampling
# every 25 cm along a line out from the centre:
#
#   0.0m ...XXXXXXXXXXX... 4.0m        X = hurt
#
# So the game drew spikes standing up out of one cell and hurt you everywhere
# except on them, out to more than a cell and a half beyond the block. Reported
# from playtest as an elevator injury: a lift two cells away put a rider inside
# that ring with no threat visible anywhere near them.
#
# Half a cell: a body whose centre is over the block. It is deliberately NOT the
# body's radius added on — clipping the edge of a spike square with your
# shoulder should not cost health when the whole point is that the danger is a
# thing you can see and stand off.
const SPIKE_REACH := 1.0
# And how far ABOVE the deck they reach: the spikes themselves (0.8) plus a
# standing body's half height, so somebody stood on the block is caught and
# somebody carried over it — on a lift, or mid-launch on legs — is not.
# Passing over a hazard whose whole silhouette is below your feet should be
# exactly as safe as it looks.
const SPIKE_TOP_REACH := 1.7

# THE ROUND BARRIER (M16). Two metres, matching the parapet: it has to stop a
# dash, which is the only verb that could otherwise carry a player through, and
# it must not be so tall that the party cannot see the lobby they are waiting to
# enter. Wider than any bridge so it cannot be walked around at the parapet.
const ROUND_WALL_HEIGHT := 2.0
# Transparent blue. Alpha low enough to read the deck through it -- the wall says
# "not yet", and a wall you cannot see past says "never".
const ROUND_WALL_COLOUR := Color(0.30, 0.60, 1.00, 0.28)

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

# HALVED FROM 8.0 ON 2026-08-14, and the note it replaces said the opposite: "above
# WALK_SPEED (6.0), so it cannot be strolled away from -- that is what makes it a
# decision". At 4.0 it CAN be strolled away from, and the playtest that asked for
# this had the debug console's rusher_speed_pct to try 100 / 75 / 50 / 25 with --
# 50 was the answer, unambiguously.
#
# WHY THE OLD ARGUMENT STOPPED HOLDING: it was written when a rusher was the only
# enemy in the game, so it had to supply all the pressure by itself and being
# outrunnable would have made it ignorable. The bridge is busier now -- a
# skirmisher that holds a band, a turret that owns a piece of deck, plinko, and
# three specials that all ask the player to stand somewhere specific. A rusher no
# longer has to be the thing that stops you strolling, and at 8.0 it was the thing
# that stopped you doing anything else.
#
# What it costs, stated plainly so the next playtest knows what to watch: a lone
# player on an empty stretch can now simply walk away from one. That is only
# acceptable while the rest of the bridge is asking for their attention, so if
# enemies are ever thinned out again, this number goes back up with them.
#
# Still a rounding error against SHOVE_SPEED (56), so committing an axis beats it.
const RUSHER_SPEED := 4.0

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

# HOW CLOSE A BALL COUNTS AS A HIT. Added to the PLAYER'S RADIUS, so this is the
# slop on top of real contact rather than the whole reach.
#
# Real contact is BALL_RADIUS + PlayerBody.RADIUS = 0.6 + 0.4 = 1.0 m. At 1.1 the
# test fires at 1.5 m, which is deliberately forgiving -- a hazard that demands
# exact contact reads as a hazard that misses.
#
# It was written inline as `BALL_RADIUS + 0.5` at the one place that used it, and
# that place added the player's HALF-HEIGHT (0.9) rather than its RADIUS (0.4) --
# the body's tallness standing in for its width. So the real test was 2.0 m,
# TWICE the geometry, and the 2026-08-13 playtest reported it as balls hitting
# from a distance while sailing past. Fixed 2026-08-14; test_plinko walks a ball
# in at 1.9 m and requires it to miss.
const PLINKO_HIT_RADIUS := 1.1

# Tall enough to read as absurd from across a 60 m bridge, short enough that the
# top hat is still on screen.
#
# RAISED 5 -> 7 on 2026-08-16, with HAT_LEAN_MAX_DEG deliberately left alone. The
# lean accumulates up the tower at 5 degrees a hat, so the top now tips 35 rather
# than 25 — further from upright and still a long way from lying down, which is
# the direction the joke wants.
#
# IT IS ALSO A HIT COLUMN NOW, which it was not when 5 was chosen: a worn hat is
# a target, HAT_HEIGHT tall each, so a full stack puts 2.45 m of score above your
# head where anything on high ground can reach it. Seven is a bigger silhouette
# as well as a bigger bet, and that is the trade rather than a side effect.
const HAT_MAX_STACK := 7

# HOW WIDE A HAT IS TO A BULLET (2026-08-16). Between the crown's collider radius
# (0.26) and the brim's (0.42): a round that clips the brim of a hat you can see
# should take it, and one that passes a hand's width clear should not.
const HAT_HIT_RADIUS := 0.4
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

# HOW CLOSE A SHOT HAS TO PASS AN ENEMY BEFORE THE ASSIST TAKES IT (M20).
#
# One body width. A rusher is 0.5 m in radius, so this is "the round was going to
# graze it anyway" rather than "the round was in the same postcode".
#
# TIGHT ON PURPOSE. Pointing at the ground near something slow is the correct
# play for an area weapon -- a rocket is easier to land behind a rusher than on
# one -- and a generous bubble would drag every one of those shots onto the
# target and quietly delete the decision. If a playtest says the assist does not
# help enough, this is the number; the thing to watch while raising it is whether
# the rocket stops being placeable.
const AIM_SNAP_RADIUS := 0.6

const MG_DAMAGE := 1

# --- Two more guns, for the M20 aim A/B ---------------------------------------
#
# THEY EXIST TO SIT AT OPPOSITE ENDS OF ONE AXIS. Point aiming and the assist are
# both bets about PRECISION, and the machine gun is a poor instrument for judging
# a precision change: a 10-degree cone hides an aiming error the same way it hides
# the muzzle offset. So one weapon forgives aim completely and one punishes it,
# and the same playtest answers whether the new aim helps at both ends.
#
# THE SHOTGUN: a fistful of pellets, wide, cheap, and lethal at a range where
# aiming barely matters. It is the control for "does point aim make things worse
# when you did not need it".
const SHOTGUN_PELLETS := 7
const SHOTGUN_SPREAD_DEG := 9.0
# WIDER VERTICALLY THAN ANYTHING ELSE, and on purpose: a spread that is flat is a
# LINE, which on a bridge that climbs in layers is a weapon that cannot cover a
# ramp. This is the one gun whose cone should look like a cone.
const SHOTGUN_SPREAD_VERTICAL_DEG := 6.0
const SHOTGUN_DAMAGE := 1
const SHOTGUN_FIRE_INTERVAL := 0.85
# EIGHT SHOTS, NOT TWENTY. Seven pellets a trigger pull is 56 rounds of ammunition
# accounting; the SHOT is the unit the player counts, so the magazine is counted
# in shots and each one is a decision.
const SHOTGUN_AMMO := 8

# THE RIFLE: one round, almost exactly where you pointed, slowly. It is the
# instrument the aim A/B actually needs -- with a 0.4-degree cone the shot lands
# where the aim says and nothing hides a mistake, so if point aiming is better the
# rifle is where it will show first.
const RIFLE_SPREAD_DEG := 0.4
const RIFLE_SPREAD_VERTICAL_DEG := 0.2
const RIFLE_DAMAGE := 3
# SLOWER THAN THE ROCKET. The trade is explicit: the machine gun fires 2.5 times a
# second for 1 damage, the rifle once a second for 3. Damage per second is close;
# what differs is whether a miss costs you a round or a second.
const RIFLE_FIRE_INTERVAL := 1.0
const RIFLE_AMMO := 10

# Below SHOVE_TRANSFER_SPEED (11) and just under its lift (2.5): being shot
# pushes you around, being dashed into still throws you further. A weapon that
# out-displaced the game's signature verb would replace it rather than complement
# it, which game_concept.md's "specials never replace shove and rope" forbids.
const MG_KNOCKBACK := 8.0
const MG_KNOCKBACK_LIFT := 2.0

# (There was an MG_TRACER_SECONDS here. Rounds are real objects now, so the line
# that stood in for one is gone -- see scripts/sim/bullet.gd.)

# --- Gunners: the skirmisher and the turret -----------------------------------
#
# TWO ENEMIES, NOT ONE WITH A FLAG. They share how a round leaves a barrel
# (gunner_body.gd) and nothing else: the numbers below are deliberately separate
# because the engagement profiles are the whole difference between them.

# THE DISTANCE A SKIRMISHER WANTS. Comfortably inside MG_RANGE (30) so its rounds
# actually arrive, and far enough that closing it is a decision rather than a
# step. The band is the dead zone either side, without which it jitters back and
# forth across a single preferred distance forever.
const SKIRMISHER_RANGE := 14.0
const SKIRMISHER_BAND := 3.0

# Slower than a walk (6). It has to be: an enemy that can hold its range against a
# walking player can hold it forever, and then closing is not an answer. You catch
# it by walking at it, which is the counter-play the whole design wants.
const SKIRMISHER_SPEED := 4.0

# Slower than the player's machine gun (0.4). Being shot at from range should be
# pressure you can walk through, not a wall.
const SKIRMISHER_FIRE_INTERVAL := 1.2

# FURTHER AND SLOWER, because a turret cannot reposition. Its threat is
# PERSISTENCE, not pressure: it owns a piece of the bridge for as long as it is
# alive, and the player pays for crossing that piece in distance rather than in
# reaction time. Reach one third longer than a skirmisher's and a cadence nearly
# twice as slow is what that trade looks like in numbers.
const TURRET_RANGE := 19.0
const TURRET_FIRE_INTERVAL := 2.0

# THE ARC IT CAN SWING THROUGH, centred on the facing it was bolted at. 360 is
# what shipped before turrets were their own type, so it is the default -- the
# mechanism lands here as a seam, and narrowing it is a slider in the debug
# console rather than an argument in a design doc. Below about 90 a turret stops
# being a hazard and becomes a door, which is a real design available on purpose.
const TURRET_ARC_DEG := 360.0

# --- The rocket launcher ------------------------------------------------------
#
# DIRECT FIRE, and that is the whole reason it exists beside the grenade. A
# grenade goes OVER things -- it is lobbed, it arcs above a 2 m pillar for most of
# its flight, it lands and waits. A rocket goes AT things: flat, fast, and it
# detonates where it touches. The two are the same damage from opposite
# directions, and the choice between them is a question about the shape of the
# problem rather than about power.
#
# So it is the answer to a TURRET -- the one hazard that is bolted down, in the
# open, and needs cover or a weapon -- and it is the wrong tool for anything
# behind a parapet, which is exactly where the grenade is right.

# TWO. It is the most powerful thing a player can carry and the pickup is meant to
# be an event; a third shot would make it a weapon rather than a decision.
const ROCKET_AMMO := 2

# Fast enough to feel like a direct-fire weapon, slow enough to WATCH -- both
# because a rocket you cannot see coming is a rocket nobody can dodge, and
# because playtest asked for slower rounds and was right.
const ROCKET_SPEED := 22.0

# Slower than the machine gun by a wide margin. Two shots at this cadence is
# roughly one every three seconds, which is the pace of a decision.
const ROCKET_FIRE_INTERVAL := 1.4

# Seconds before it gives up. At 22 m/s that is 33 m, a little past MG_RANGE, so
# the practical limit is line of sight rather than a timer.
const ROCKET_LIFETIME := 1.5

# --- Explosions ---------------------------------------------------------------
#
# Shared by every EXPLOSIVE source -- grenades and mines when they land. The
# damage model says what a blast DOES to each thing; these are what it does it
# with.

# Two hit points, against a five-point bar. A blast is the biggest single thing
# in the game and still not half a life, because HIT_GRACE means a player caught
# by two in quick succession only pays for one.
const BLAST_DAMAGE := 2

# HARDER THAN ANYTHING ELSE, and that is the point of an explosion in a game whose
# threat model is displacement: above SHOVE_TRANSFER_SPEED (11) so a blast throws
# you further than a teammate's dash, with more lift so it reads as being picked
# up rather than shoved along.
const BLAST_PUSH := 15.0
const BLAST_LIFT := 5.0

# How far a blast reaches. Two cells: big enough that it is worth throwing at a
# GROUP, which is what makes an explosive different from a gun, and small enough
# that the thrower can be outside it at any charge above the minimum.
const BLAST_RADIUS := 4.0

# --- Grenades -----------------------------------------------------------------
#
# THE VERB IS HOLD-TO-ADJUST-DISTANCE, asked for by name. That makes the grenade
# the first special whose interesting decision is made BEFORE the button comes
# up: a gun asks where to point, this asks how far, and getting it wrong is a
# blast at your own feet rather than a missed shot.

const GRENADE_AMMO := 4

# Seconds of hold to travel from the near throw to the far one. Long enough to be
# a decision you can see yourself making, short enough to make under fire.
const GRENADE_CHARGE_TIME := 1.2

# THE NEAR THROW IS INSIDE YOUR OWN BLAST, deliberately. A tap must be able to
# hurt you: without that, holding the button longer is strictly better and the
# "adjust" half of the verb is decoration. BLAST_RADIUS is 4.
const GRENADE_MIN_RANGE := 3.0
const GRENADE_MAX_RANGE := 16.0

# Thrown UP as well as out, on a fixed arc, so range is set by speed alone. A
# lobbed arc is also what lets a grenade clear a parapet that a bullet cannot,
# which is the geometry answer the specials are supposed to add.
const GRENADE_THROW_ANGLE_DEG := 40.0

# WHERE IT LEAVES THE HAND: out in front of the thrower's own capsule, or the
# first thing a grenade does is bounce off its owner, and up at chest height.
#
# BOTH OF THESE ARE IN THE RANGE SOLUTION, and leaving them out is not a rounding
# error: released 1.2 m up, a grenade aimed with the level-ground formula overflew
# GRENADE_MIN_RANGE by 80% -- it landed at 5.5 m, outside its own 4 m blast, which
# quietly deleted the "a tap can hurt you" rule that the whole hold-to-adjust verb
# rests on. Measured 2026-08-14; caught because the test asserted the DESIGN claim
# (the near throw is inside the blast) rather than the arithmetic.
# MOVED OUT FROM 0.7 when grenades started bouncing off bodies. A player's radius
# is 0.4 and a grenade's is 0.18, so 0.7 left 12 cm of clear air between the two
# -- fine while people were transparent to it, thin once they are not, and thinnest
# in exactly the case that matters: a slow throw made while walking forwards, where
# the thrower is chasing their own grenade at nearly its speed.
const GRENADE_THROW_FORWARD := 0.9
const GRENADE_RELEASE_HEIGHT := 1.2

# From the button coming up to the bang. It is a fuse and NOT a contact
# detonation: a live grenade on the deck for a moment is what gives everybody --
# thrower included -- the chance to move, and moving is this game's whole
# vocabulary of answers.
const GRENADE_FUSE := 1.4

# --- Land mines ---------------------------------------------------------------
#
# THE VERB IS PLACING SOMETHING IN ADVANCE. A grenade asks how far; a mine asks
# WHEN -- it is the only thing in the game a player can spend now to be paid back
# later, and the arming delay is the entire reason that is a skill rather than a
# melee attack with extra steps.

const MINE_AMMO := 3

# HARMLESS FOR A SECOND. Asked for by name, and it is what stops a mine being a
# reach-out-and-touch weapon: place one under something and you have merely put an
# object on the deck. It also means the player is standing on their own live mine
# for a full second, which is the joke and the risk in one.
const MINE_ARM_SECONDS := 1.0

# Tight -- half the blast it sets off. A mine you can trip from outside its own
# damage would be a thing that goes off "near" you, and near is not a word this
# game's threat model can use.
const MINE_TRIGGER_RADIUS := 1.6

# DROPPED AT YOUR FEET, JUST IN FRONT. Far enough forward to clear the player's own
# 0.4 m radius so you can see what you just put down, close enough that it is
# still "here" rather than thrown.
const MINE_DROP_FORWARD := 0.9

# How far below the feet to look for something to rest it on. A mine is PLACED --
# it sits on the deck exactly where it was put and does not fall, roll or settle,
# because "roughly where I pressed the button" is not good enough for the one
# object whose whole value is being in a spot the player chose.
const MINE_GROUND_PROBE := 1.5

# HELD, LIKE THE MACHINE GUN, and on the same button. A tap lays one; holding lays
# them on a cadence. Slow enough that emptying the pouch is a decision you can feel
# yourself making rather than something that happens in three frames.
const MINE_PLACE_INTERVAL := 0.6

# --- The shield ---------------------------------------------------------------
#
# THE ONLY SPECIAL THAT TAKES SOMETHING AWAY FROM YOU. It anchors you where you
# stand and refuses everything arriving from the direction you chose. In a game
# whose threat model is DISPLACEMENT, refusing to be displaced is the strongest
# thing a player can do -- so it has to cost the one resource this game actually
# spends, which is being somewhere else in a moment.

# Deployments, not seconds. One press, one use, held as long as you like: there is
# no timer because standing still IS the timer. A bridge that has to be crossed,
# with hazards arriving from behind as well, prices a long hold all by itself.
const SHIELD_AMMO := 3

# WIDE ENOUGH TO BE A DECISION, NARROW ENOUGH TO BE FLANKED. Roughly the front
# quadrant: two players back to back cover each other, one player alone does not
# cover themselves.
const SHIELD_ARC_DEG := 110.0

# A SHIELD STOPS WHAT IS COMING AT YOU, NOT WHAT IS ALREADY UNDER YOU. Anything
# originating closer than this is unblockable, whatever the angle -- which is
# exactly the counter the damage model names: a blast beneath your feet has no
# direction to be in, and a mine is how you answer somebody who has decided to
# stop moving.
const SHIELD_MIN_BLOCK_DISTANCE := 1.0

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
