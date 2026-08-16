# Sound

Written 2026-08-16. The sound effect roster, in priority order, derived from the
events the simulation actually emits today. There is currently **no audio in this
project at all** — no bus layout, no `AudioStreamPlayer` of any kind, no
listener. This is the list to build against, not a gap analysis of an existing
mix.

Anything marked **[unbuilt]** belongs to a mechanic that does not exist yet
(rope M4, water M7, bus M11) and should not be commissioned until it does.

## The rule that sets the order

**A sound earns its slot by carrying information the player cannot get any other
way.** Not by being the loudest moment, and not by being the most fun to make.
Four properties of this game turn that from a platitude into an ordering:

1. **The camera is fixed-yaw and frames a 60 m structure the whole party has to
   see.** Things therefore happen outside your *attention* constantly, even when
   they are technically on your screen. Audio is the only channel that addresses
   a player who is looking somewhere else.
2. **Every player has their own screen** (`game_concept.md` §Session shape), so
   your teammates' crises are invisible to you by construction.
   `teammate_markers.gd` exists precisely because a friend is often off-camera —
   and a marker still requires you to be reading the edge of the screen.
3. **Displacement is the threat, not damage** (`hazards.md`). A sound that warns
   you something is about to *move* you is worth more than one that confirms you
   lost a hit point, because the hit point is already on the HUD and the
   displacement is what kills.
4. **The telegraph is the fairness contract.** Slow visible balls, the 1 s rusher
   rise, a gunner's readable cadence — the design repeatedly pays for warning
   time. **Every one of those telegraphs currently has exactly one channel.** A
   telegraph you have to be looking at is half a telegraph.

So the order runs: **incoming displacement you cannot see → teammate state you
cannot see → your own committed verbs → confirmation of things already on screen
→ texture.**

---

## P0 — Threat telegraph

The tier that changes whether the game is fair. Each of these currently
communicates through one visual channel only.

| # | sound | why it is P0 |
|---|---|---|
| 1 | **Plinko ball bounce** — deck, pillar, parapet; pitch/weight by impact speed | **The single highest-value sound in the game.** The ricochet path *is* the hazard (`plinko.md`), it is semi-random, and it arrives from behind and above. Each bounce is a free positional ping telling you where the field is going. Needs a real variant set — it is the most-fired sound by an order of magnitude |
| 2 | **Shooter launch (the lob)** | A ball is "dodgeable on sight"; a launch thunk tells you one exists *before* sight. Fires from `_launch_ball` |
| 3 | **Rusher emergence from mound** | `RUSHER_RISE_SECONDS` is 1.0 and its entire job is to be a telegraph. The wake radius is 6 m — comfortably outside where you are looking |
| 4 | **Rusher charge loop** — moving emitter, no pitch-up (it holds one speed) | A committed straight-line body running at you. Locating it by ear is the answer |
| 5 | **Skirmisher shot** and **turret shot** — *distinct*, and matching their cadences (1.2 s vs 2.0 s) | Cadence is the defining property of these two (`hazards.md`: "persistence rather than pressure"). If they sound alike, the split is inaudible and the player cannot tell which threat model they are in |
| 6 | **Turret acquire / traverse** | The one hazard that ignores the free verb, so "it has seen me" must be knowable. Also the tell for the `TURRET_ARC_DEG` seam — a gun that audibly stops tracking as you flank it is the arc mechanic teaching itself |
| 7 | **Spike block wind-up**, then **spike strike** | `SPIKE_PERIOD` 2.0 s on dormant-looking deck. A lethal floor cell with no audible wind-up is the least fair thing in the game |
| 8 | **Bullet near-miss / whiz-by** | Rounds are slow balls, so a miss is survivable information: someone is shooting at you and you have time to move |
| 9 | **Mine arm** (`MINE_ARM_SECONDS` 1.0) and **proximity trigger** | Friendly fire is on and mines are placed by teammates. The arm is the only warning anyone gets |
| 10 | **Grenade bounce + fuse burn** (`GRENADE_FUSE` 1.4 s) | It is lobbed over cover, so it frequently arrives from somewhere you were not watching. The fuse is the countdown |

## P1 — Teammate state

Second tier only because it is smaller, not because it matters less. This is the
co-op channel, and it currently has none.

| # | sound | why |
|---|---|---|
| 11 | **Teammate catches a ledge** | The rescue window has opened and `LEDGE_HANG_SECONDS` is 8.0. Whether your friend is saved "is decided by how they got hit, not by how fast they react" (`game_concept.md`) — but *someone still has to notice*. This sound is the difference between the rescue mechanic firing and it being decorative |
| 12 | **Teammate goes DOWNED** | `DOWNED_SECONDS` 15.0. Same argument, longer clock |
| 13 | **Ledge / downed bleed-out escalation** | A countdown someone else must answer needs urgency you can hear from across the bridge |
| 14 | **Teammate revived / hauled up** | Closes the loop. Without it the rescuer is the only one who knows it worked |
| 15 | **Teammate lost — fall, drone return** | `DRONE_RETURN_SECONDS` 3.0. The party needs to know it is a player down for three seconds |
| 16 | **Per-player timbral tag on 11–15** | Four players, four screens. *Who* is in trouble is half the information, and the HUD only carries it for one friend (top-right) |

## P2 — Your own committed verbs

The comedy tier. "Comedy comes from committed actions" — a sound that lands the
instant a decision becomes irreversible is what sells commitment.

| # | sound |
|---|---|
| 17 | **Dash launch** — must read as *uncancellable*. One transient, no ramp |
| 18 | **Dash cooldown ready** (`SHOVE_COOLDOWN` 0.35 s) — small, but this is the answer-verb's availability, and `hazards.md` records a whole bug about players not knowing they had spent it |
| 19 | **Dash impact, five variants**: into a player (launch), into a stone (the one-cell shunt), into a ball (bat away, you keep momentum), into a wall (recoil), into **nothing** (the whiff off the edge — the funniest one, and the only one that needs no impact at all) |
| 20 | **Machine gun fire loop** — 2.5/sec held, the cadence weapon. Plus **dry click** at zero ammo |
| 21 | **Rocket launch + flight** — flat, fast, committed; deliberately unlike the grenade |
| 22 | **Grenade charge-hold + release** — the throw is fraction-based, so the hold wants an audible charge |
| 23 | **Shield plant** — a commitment to standing still |
| 24 | **Special pickup / drop / swap** — picking one up drops the spent one, and one slot is the whole balance. The swap is a decision and should sound like one |
| 25 | **Heart pickup** — first-come-first-served, "worth shouting about" per `art_direction.md` |
| 26 | **Hat: don, dislodge, destroy** — hats are the score hook and are stealable; a hat coming off you is a loss you may not see |
| 27 | **Footsteps + landing**, surface-varied (deck / ramp / [unbuilt] water) |

## P3 — Consequence to yourself

Lower priority than it looks: your health is on the HUD, `crisis_flash.gd`
already exists, and the tumble is extremely visible. These confirm; they do not
inform.

| # | sound |
|---|---|
| 28 | **Take damage — three variants by `Hit.Kind`**: IMPACT, BULLET, EXPLOSIVE. The kinds have genuinely different answers (cover stops only one), so teaching them by ear is worth the three assets |
| 29 | **Hit grace active** (`HIT_GRACE` 0.75 s) — brief, so you know you can move through the next thing |
| 30 | **Tumble: enter, tumbling loop, settle** — the pinwheel keeps its momentum; the loop should not decay politely either |
| 31 | **Your own ledge catch** — automatic, fired mid-tumble when you have no control, so it is the first thing telling you the run is not over |
| 32 | **Your own collapse to DOWNED** |
| 33 | **Long fall** — the failure with no rescue, and the one that should be audibly different from a ledge catch at the moment it commits |
| 34 | **Drone return + drop** |
| 35 | **Blast** — a hook already exists (`_blast_seen`, `blast_effect.gd`), which makes this cheap |

## P4 — Round structure

| # | sound |
|---|---|
| 36 | **Round closing warning** (`CLOSE_SECONDS` 30.0) — a hard deadline that closes behind stragglers. A deadline with no audio is a deadline half the party will miss |
| 37 | **Gate crossed / round start** |
| 38 | **Checkpoint banked** |
| 39 | **Scoring board open** (`SCORE_SECONDS` 10.0) |
| 40 | **Wipe** |
| 41 | **Barrier wall raise** — a wall appearing is a rule change and should announce itself |
| 42 | **Lobby vs. running ambience swap** — the state machine *is* the menu, so the state should be audible |

## P5 — World texture

| # | sound |
|---|---|
| 43 | **Wind at height**, scaled by how high the bridge has risen — the sense of climbing is the game's core sensation and it currently resolves only visually |
| 44 | **Bridge creak / structural groan** |
| 45 | **Stone push grind**, and **stone falling away through a hole** — rearranging the bridge is a verb; it should sound like one |
| 46 | **Ladder climb**, **bouncer** |
| 47 | **[unbuilt]** water flow and wash-away (M7); rope creak, tension, snap (M4); bus engine, road, seat rotation (M11) |

## P6 — UI

| # | sound |
|---|---|
| 48 | Menu navigate / confirm / back |
| 49 | Player joined / left the lobby — drop-in means this happens mid-run |
| 50 | Ready check, name announce |

---

## Engineering notes the roster implies

Three things that will cost time if they are discovered during the build instead
of before it.

**A SOUND FIRED FROM A PREDICTED CODE PATH PLAYS AGAIN ON EVERY CORRECTION.**
This is the trap most likely to bite. `_reconcile` rewinds a mispredicted client
and replays every unacknowledged input inside one frame — and `game_world.gd`
already documents that replaying the tick carrying `ACTION_SHOVE` re-enters the
dash. A `play()` sitting in `_begin_shove` therefore fires once per correction,
inside a single frame, on a machine where `corrections` climbs. The dash, the
weapon fire, the tumble entry and every damage sound are all on predicted paths.
Sounds must be emitted from a layer that is idempotent per (event id, tick), or
from the host-side event path only.

**THE EVENTS THAT ARE ALREADY RELIABLE RPCs ARE EXACTLY THE EVENTS THAT WANT
SOUNDS**, and this is the useful half of the note above. `_blast_seen`,
`_mound_taken`, `_hats_destroyed`, `_special_dropped`, `_take_special`,
`_wear_hat` and the rusher/gunner spawn-and-death pairs are already discrete,
already agreed between machines, and already fired exactly once. The design
reason is identical to the audio reason: a discrete event that matters gets a
reliable message. Prefer hanging sound off these over inventing a parallel
notification path.

**Headless must stay silent and must stay testable.** The gate runs dozens of
parallel Godot processes; audio has to no-op under `--headless` without any
gameplay script branching on it. And per the HUD precedent — a UI script that
nothing instantiates ships having never run once — at least one test should
construct the audio layer so a bad stream path or a Godot-3-era property is
caught in the gate rather than on a player's machine.

**Asset count.** Roughly 50 distinct events, but the *effort* is not evenly
spread: item 1 alone (plinko bounces) wants a proper multi-sample variant set
with speed-mapped weight, because it fires more than everything in P2 combined.
Budget for that one like a system, not like a sound.
