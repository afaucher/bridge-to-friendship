# Hazards

Written 2026-08-08. What threatens the party, sorted by **what it does to you**
rather than by what it looks like, plus the specials that answer each. Anything
marked **[open]** is unanswered; numbers are starting values with a stated
reason, per house rules.

`plinko.md` owns the plinko field in detail; this document is the roster around
it.

## The four things a hazard can do

The punishment vocabulary is deliberately tiny, and every hazard is one of these
four in a costume:

| verb | what it means | the design's view of it |
|---|---|---|
| **displacement** | TUMBLE — a pinwheel that keeps its momentum | **the real threat.** On a bridge full of holes, being moved is worse than being hurt |
| **damage** | hit points, and `DOWNED` at zero | a countdown, not a wall — see M5 |
| **denial** | you cannot be there | terrain's job, mostly |
| **impairment** | degraded, but still in control | water; the only one that leaves you playing |

A hazard that only does **damage** is a tax. The game's threat model is
displacement, so a new hazard should be checked against this table before it is
built: if the answer is "it costs a hit point", it is not yet interesting.

## Deflectable versus destructible — the split that justifies weapons

*(Decided 2026-08-08, and it is the most consequential line in this document.)*

Until now everything hostile was **deflectable**. A plinko ball is batted away by
a dash; a stone is pushed a cell; a player is launched. Nothing could be
*removed*. That made the ranged specials weak by construction: a shotgun was a
shove you could do from further away, and the player already has a shove for
free.

Threats now come in two kinds:

- **Deflectable** — balls, barrels, stones, angry rocks, other players. Shove
  moves them. They persist.
- **Destructible** — enemies. Shove *deflects* them, buying time. Only being
  **shot** ends them.

That single distinction is what earns the weapon-special category its slot. There
is now a threat the base verbs cannot resolve, only postpone.

### The principle underneath it

**A special is never the only answer.** It has shown up three times now and is
worth stating outright:

- Legs are a shortcut, never an ascender — a layer stays solo-passable by terrain
  (`game_concept.md` §Special, and E1b).
- A rusher can be deflected by a dash and outlived by its own timer, so a player
  with no weapon is inconvenienced, never stranded.
- Hearts and revives already exist, so a healing special adds a better option and
  not a required one.

The reason is drop-in: specials are contested, disposable and unevenly
distributed, so anything that *requires* one strands the players who did not get
it. Specials make an answer **cleaner**, never **possible**.

## The roster

Cost tiers reflect what machinery already exists.

| hazard | what it really is | verb | cost |
|---|---|---|---|
| holes, falls | the terminal failure | denial | **shipped** |
| edges, ledges | denial with a rescue window | denial | **shipped** |
| plinko balls | see `plinko.md` | displacement + 1 dmg | M6 |
| water flow | lateral push, wash-away | impairment | M7 |
| **barrels** | a plinko ball that starts at rest | displacement | **~free** |
| **angry rocks** | a stone that shoves on proximity | displacement | low |
| **spikes** | must tumble, not just hurt | displacement | low |
| **sand** | must deny the *dash*, not slow you | impairment | low |
| **saw-blades** | the first authored moving body | displacement | medium |
| **damaged ground** | the first *mutable* deck cell | denial, late | high |
| **rushers** | the first destructible enemy | displacement | medium |
| **skirmisher** *(built 2026-08-14, alertness 2026-08-21)* | holds a distance and shoots | displacement + damage | **shipped** |
| **turret** *(built 2026-08-14)* | bolted down, shoots, ignores a dash | displacement + damage | **shipped** |
| **zombies** *(built 2026-08-21)* | a PACK, arriving in threes and ones | damage + chance of tumble | **shipped** |
| **spiders** | patrol, aggro, pathfinding | — | own milestone |

Three notes the table cannot carry:

**Barrels are the cheapest good hazard available.** The ball sim, the ricochet,
tumble-on-contact and the 4° pitch that rolls loose things back downhill all
exist for plinko. A barrel is a ball at rest. It gives the dash a fourth job and
it is the first hazard players aim at *each other*.

**Sand and spikes as originally sketched are both weaker versions of something
the game already has.** Sand-that-slows is a lesser water; spikes-that-hurt are a
tax. They become distinct hazards only as written above — sand is the one terrain
that takes a *verb* away, and spikes tumble.

**Damaged ground contradicts a written decision.** `bridge_grid.md` closes with
*"No destructible deck. Holes are authored, not created."* That is not a
preference: authored-static cells are what make a drop-in join cheap, so a
breakable cell means the snapshot grows a **deck diff** beside the stone list,
and the validator has to decide whether it floods the pre-break or post-break
bridge. Worth building — it is the only hazard that punishes standing still — but
it is a grid-model change scoped as one, not a hazard.

## Rushers

**Decided 2026-08-08.** The first enemy, and deliberately the *cheap* one:
spiders need pathfinding, patrol states and aggro. A rusher needs a direction.

**Built 2026-08-08.** `scripts/sim/rusher_body.gd`, woken and judged by
`GameWorld._process_rushers`, gated by `test_rusher`.

**It rises, then it runs at you.** An authored cell holds a dormant mound
(glyph **`m`**, provisional). A player within `RUSHER_TRIGGER_RADIUS` wakes it;
it takes `RUSHER_RISE_SECONDS` to emerge, and *that emergence is the telegraph* —
the same fairness rule as plinko's slow balls. Then it picks the nearest player
and moves straight at them. No pathfinding: a straight line on the deck, which is
all "rushes right at you" requires and is the entire reason this is affordable.

**But only at a player it can SEE.** *(Added 2026-08-08, during the build.)* A
straight-line chaser with no sight test walks into the near face of a pillar and
grinds there for its whole lifetime — measured at 3.3 m of travel into a pillar
over 45 ticks, versus 6.1 m down an open lane. That is the cost of being cheap,
and one raycast buys it back.

It earns more than it costs. **Breaking line of sight becomes a real answer**,
and it is the one that pairs with the burrow timer: putting something solid
between you and it turns "outlive it" from a formality into a plan. A rusher that
can see nobody simply *stands there* — it does not wander or search, because
searching is the pathfinding this design bought its way out of.

The same test gates the **wake**. Without that, a player passing on the far side
of a pillar spends the mound on a rusher that rises with nobody to run at, stands
for ten seconds and burrows — an authored hazard consumed without ever being one.

Deck and pillars block sight; **players do not**. Hiding behind a friend would
make the friend a shield, which is a mechanic this game has not decided to have —
and the one it does have for that is the shove.

**It walks into holes.** Also not an oversight. A straight line at a target
respects nothing in between, so leading one off an edge is the cheapest tool a
weaponless player has, and it makes the bridge's own geometry a weapon.

**It is faster than a walk and vastly slower than a dash.** You cannot simply
stroll away from it — that is what makes it a decision rather than an annoyance —
but it is nowhere near a dash, so committing an axis still beats it.

**Three answers, in descending order of grace:**

1. **Shoot it.** It dies. Clean, and the reason to be carrying a weapon.
2. **Dash it.** Deflected and staggered, buying `RUSHER_STAGGER_SECONDS`. It gets
   back up. Scrappy, free, available to everyone.
   **A staggered rusher is harmless — that is what "buying" means.** It stayed
   dangerous through its whole stagger until 2026-08-13, so the dash was a
   counter that lost: six ticks of dash bought a hundred and twenty ticks of a
   thing that could still tumble you, and `SHOVE_COOLDOWN` meant you could not
   answer it a second time. It is still *deflectable* while staggered — a dash
   re-deflects on each of its ticks, which is what carries it clear — just not
   lethal.
3. **Outlive it.** It burrows back down after `RUSHER_LIFETIME`. Desperate, but
   it is the floor that stops a weaponless solo player from being ground down —
   the "never the only answer" rule above, made concrete.

**On contact it tumbles you and expends itself.** Displacement, per the table;
expending itself so a single rusher cannot chain-tumble someone who is already
out of control and has no way to respond.

### Starting values

| constant | value | why |
|---|---|---|
| `RUSHER_TRIGGER_RADIUS` | 6 m (3 cells) | close enough that the trigger reads as *your* mistake, far enough to give the rise time to matter |
| `RUSHER_RISE_SECONDS` | 1.0 | the telegraph. Long enough to back off or line up a shot, short enough not to be ignorable |
| `RUSHER_SPEED` | 8.0 m/s | above `WALK_SPEED` (6.0) so it cannot be outwalked; a rounding error against `SHOVE_SPEED` (56) |
| `RUSHER_STAGGER_SECONDS` | 2.0 | one dash buys a breath, not an escape |
| `RUSHER_LIFETIME` | 10.0 | long enough to be a real problem; short enough that a weaponless player has a floor |

### Engineering shape

A rusher is a **free sim body**, host-authoritative and **never predicted** —
same class as a plinko ball, not a player. Its target selection is host-decided;
clients are told the result and invent nothing.

Two events are discrete and therefore **reliable**: spawn, and death. Position
rides the per-tick snapshot in world-local coordinates like everything else. Ids
are **host-assigned and monotonic**, not creation-order indices — a rusher is
created mid-run by a trigger, so the stone list's "both machines loaded the same
segments" trick does not apply. This is the same trap written up for hats.

## Zombies -- the first enemy that is a GROUP

**Decided and built 2026-08-21.** `scripts/sim/zombie_body.gd`, raised and judged
by `GameWorld._process_zombies`, gated by `test_zombie`, `test_zombie_walk` and
`test_zombie_replication`.

### What it is for

Every enemy before this one is answered by an individual reflex. A rusher runs a
straight line at one player, so it is answered by **moving sideways**, and that
answer is identical everywhere on the bridge. A skirmisher is answered by
**closing**. A turret is answered by **cover**. All three are decisions you make
about a body.

A pack cannot be answered by moving sideways, because sideways is where the next
one is. It asks for **ground** instead -- a chokepoint, a pillar at your back, a
blast spent early on a slab you can see -- which is a decision about the *level*
rather than about a body. Nothing in the game asked for that before, and it is
the first hazard that makes the terrain the answer rather than the setting.

### Threes and ones

The walk is the enemy. Every move is a **commitment**: a heading picked once at
the moment the move begins, then held until a fixed distance has been covered.
It never re-aims mid-move.

| move | angle off the line to you | distance |
|---|---|---|
| a **one** -- a shuffle | 60 degrees | one step (`ZOMBIE_STEP`, 1.4 m) |
| a **three** -- a lunge | 20 degrees | three of them |

Even odds between them, and a fresh coin for which side it leans. Both angles are
inside a right angle, so **every move closes the distance** -- it arrives, it just
never arrives from a direction you could have predicted. At even odds it banks
about 80% of the ground it walks, against a rusher's 100%.

The two moves are tuned to take about the same *time* (0.64 s and 0.60 s). What
varies between a one and a three is the ground covered, not the cadence: a lunge
that also lasted three times as long would read as the same shuffle played slowly,
and there would be nothing to react to.

**THE COMMITMENT IS THE COUNTERPLAY, and it is where the free answer comes from.**
Three steps of held heading is four metres of travel that has already been
decided, so a player who stands with a hole behind them is inviting a lunge to
finish somewhere there is no deck. That is not a rule anybody wrote -- it falls
out of the walk, and it is the reason the walk commits rather than steering.

### Contact: the one place it is not a rusher

A rusher **expends itself** on contact, and that rule exists so a single one
cannot chain-tumble somebody who is already out of control and has no way to
answer. With five, that rule protects nobody: the pack would land five hits and
delete itself inside a second.

So a zombie **recoils** instead -- knocked back off you, harmless for
`ZOMBIE_RECOVER_SECONDS`, and it has to close again. Paired with `HIT_GRACE`
(0.75 s) that is what makes a pack a *position* problem rather than a
damage-per-second problem: standing still in the middle of one costs about three
health, which is the right price for standing still in the middle of one.

And the tumble is a **chance** (`ZOMBIE_TUMBLE_CHANCE`, 0.35) rather than a
certainty, for the same reason. A rusher always tumbles you because it only ever
gets to do it once; a hazard that takes your control away *every* time it touches
you, repeatedly, is one you cannot play out of. Below the roll it is damage and
nothing else -- `receive_hit` tumbles on any push at all, so "no tumble" has to
mean no knockback, which reads as being bitten rather than run over.

Otherwise it is a rusher: a dash deflects it and takes nothing, only a weapon ends
it, and it rots on its own clock (`ZOMBIE_LIFETIME`, 22 s) so a weaponless player
is never stranded.

### The grave

One authored cell (`z`) is one **pack** of three to five -- the first content in
this game where a cell is worth more than a body, which is why it is stated in the
glyph table, in `SegmentBuilder.grave_cells` and in `BridgeGrid` rather than left
to be inferred. Spent once, like a mound, for the same reason: a grave that
refilled would make authored density a function of how long you loiter.

It opens on proximity at `ZOMBIE_TRIGGER_RADIUS` (9 m, further than a mound's 6)
behind the same line-of-sight test, and rises over `ZOMBIE_RISE_SECONDS` (1.4 s,
longer than a mound's 1.0). Both numbers are larger because a trigger radius is
really a *reading-time* budget: one rusher needs you to see it, a pack of five
needs you to see it **and decide where to stand**.

Unlike a mound, the slab **announces itself** -- mossy green, a headstone, an
object rather than disturbed earth. A rusher's whole warning is allowed to live in
the rise because a rusher is something you dodge; choosing ground is a decision
that has to be available *before* the trigger, not during it.

**A blast empties a grave and a bullet does nothing to it**, exactly like a mound:
it is flush with the deck, so there is nothing above ground for a round to hit,
and a blast reaches down. That asymmetry is worth much more here -- pre-empting a
rusher saves you one enemy, pre-empting a grave saves you three to five. A charge
spent on a slab you can see is now the best trade in the game, and it is assembled
entirely out of parts that already existed.

### The ring, and the trap it exists for

A pack rises on a ring of `ZOMBIE_PACK_RADIUS` (0.95 m) rather than on a point.
Two perfectly coincident bodies depenetrate into a degenerate normal that drives
**both** of them down through the deck -- CLAUDE.md records it measured -- and
this is the most concentrated instance of that trap the project has: five bodies,
one cell, one tick.

It has a consequence that reaches back into level design. With a 0.45 m body the
pack reaches 1.4 m from the centre and a cell is 2.0 m across, so **a grave spills
into its neighbours by construction**. Both the dressing pass and the validator
refuse a grave without deck on all eight sides, and `_spawn_pack` skips a slot
with nothing under it as a backstop. Without those, a member over a hole falls the
instant it exists and the authored encounter quietly arrives at half strength with
nothing anywhere reporting it.

### How they reach a generated run

Measured over 320 generated sections, 40 seeds, after the pass below was fixed:

| theme | graves/section | rushers | shooters | cover | ~bodies on the deck |
|---|---|---|---|---|---|
| horde | **3.32** | 1 | 0 | 12 | ~14 |
| survival | 0.81 | 6 | 1 | 5 | ~11 |
| firefight | 0 | 1 | 5 | 10 | ~8 |
| environmental | 0.78 | 1 | 0 | 2 | ~4 |
| quiet | 0 | 2 | 1 | 4 | ~3 |

About **half of all generated sections** now carry at least one grave.

**The first attempt at this budget was arithmetic on the wrong units.** It paid
for `survival: zombies 3` by cutting that theme's rushers from 6 to 3 -- one for
one, as if a grave were an enemy. A grave is three to five BODIES, so survival
went from roughly eight things on the deck to roughly fifteen: not a rebalance, a
different difficulty, arrived at silently and shipped. Survival now takes one
grave as an accent with its rusher budget restored, and a pack that wants to be
the whole table has one of its own.

**`horde` is the fifth theme and the first built around a single enemy.** Nothing
that shoots, because a pack asks the player to choose ground and hold it while a
shooter asks them to keep moving -- and asking for both at once is not a harder
decision, it is no decision. Its cover budget is the highest in the table and is
not there to stop bullets: a half wall is a StaticBody on layer 1, which makes it
a **sight blocker**, and a zombie that cannot see anybody has no target and stands
still. Cover is what lets a party break a pack into pieces and fight it a third at
a time. One rusher, because it is fast and straight where everything else there is
slow and crooked, so it punishes tunnel vision.

**A grave is the only content that occupies the cells it is not in.** The pack
reaches 1.4 m from the centre of a 2.0 m cell, so anything standing next door is
something the pack spawns inside. `_near_grave` therefore excludes every kind
-- not just the dangerous ones -- from a grave's eight neighbours, which is the
merchant's rule pointed the other way.

**And `segments/piece_zombie_choke.seg`** is the composition: a grave in an open
bay with a three-cell gate in a wall between it and the way you came. The gate is
BEHIND you, so the decision is whether to give up the metres you spent -- placed
ahead it would be a race, and a race has one right answer. The bay is deliberately
empty; a second answer in the middle of it would let a party solve the piece
without noticing the gate.

#### Two bugs the pack found in the dressing pass

Neither is about zombies. Both are the kind that only surface when something new
asks a harder question of old code.

**The placement stride was not coprime with the candidate list**, so the walk
revisited a short cycle instead of the whole thing. Over 320 sections, **68 of 117
budget shortfalls were this** -- worst case a list of 44 cells whose walk reached
2 of them. Spikes suffered most, because `environmental` asks for 14 and a cycle
of 3 cannot deliver 14 wherever it looks. The tell was a section reporting 115
candidate cells and placing zero. `theme_for`, twenty lines above, gets this
exactly right and explains why in a comment.

**A candidate list is a snapshot, and a rule about its own kind goes stale the
moment the first one lands.** `_candidates` runs once per kind, before any of that
kind exists. Harmless for everything built so far -- nothing cared how far it was
from another of itself -- and fatal for graves, which is two packs rising into
each other.

### Engineering shape

- **Its own pool and its own snapshot section**, not a `kind` flag on the rusher's.
  The gunners share a section because a skirmisher and a turret differ only in
  which scene to build; a zombie carries a sixth field (`move_kind`), and sharing
  would pad every rusher entry with a field it does not have for the life of the
  wire.
- **Facing is derived, not sent.** Each machine turns the body from its own
  position history. That is safe *because facing has no consequences* -- nothing
  reads `rotation`, no hit test uses it, and the collider is a cylinder. Contrast
  the elevator, which was derived from the tick and *was* load-bearing.
- **Its own RNG, never the global one.** Salted per zombie id, so a pack rising
  from one grave in one tick does not draw consecutive values from one stream and
  perform the same choreography.
- **`zombies` is budgeted in GRAVES, not bodies** -- the only entry in the theme
  table where those differ. A `zombies: 2` is six to ten enemies.

### Open questions

- **[open]** Is the lunge-off-the-edge answer discoverable, or does it only work
  once somebody has been told about it? It is the counterplay the committed
  heading exists to provide, and if players never find it the pack has no free
  answer but the dash.
- **[open]** Does a pack want a *leader* -- one member that never shuffles -- so
  the group has a shape rather than being five independent drunks? Cheap to try
  and easy to over-egg.
- **[open]** `ZOMBIE_MAX` is 16 and `_wake_graves` refuses to open a grave that
  cannot deliver a full pack, so two graves close together open one at a time.
  Probably right; has not been played.

## The two gunners

**Built 2026-08-14.** Two types over a shared base: `skirmisher_body.gd` and
`turret_body.gd` on `gunner_body.gd`. They share how a round leaves a barrel --
line of sight, cadence, dying to a weapon and not to a body -- and nothing else.

**They were one script with a kind flag for about an hour, and the arc is what
forced the split.** A firing arc is meaningless on something that can simply turn
to face you, so a turret needs a mount facing, a bearing test, and a gun that
rests when it cannot reach; none of that is a flag on a skirmisher. The rule the
episode leaves behind: *when the second kind starts needing state the first has no
use for, it stopped being a configuration.*

**They are the first enemies that make the GEOMETRY part of the fight.** A rusher
is answered by moving, so the answer is the same everywhere; these are answered by
breaking line of sight or by closing the distance, which are answers the bridge
has to supply. That is what they add that a third chaser would not.

**A skirmisher holds a band rather than a distance.** A dead zone either side of
`SKIRMISHER_RANGE`, without which it jitters back and forth across a single
preferred distance forever. It is deliberately **slower than a walk**: an enemy that can hold
its range against a walking player holds it forever, and then closing is not an
answer at all.

**It will not walk off the bridge in either direction.** A body that retreats from
you until it falls is a comedy nobody authored, and it hands the player a free kill
for walking forwards.

*Approaching was exempt until 2026-08-21*, on the argument that walking into the
party is what it is for. That was a **rusher's** argument wearing a skirmisher's
clothes: this document makes the walk-off-the-edge affordance specifically a
rusher's, because a rusher is otherwise endable only by a weapon, so baiting one
over a hole is the cheapest tool a weaponless player has. A skirmisher already has
two answers — close on it, or break line of sight — and did not need a third that
costs the player nothing but standing still. Both directions now ask the grid,
which also makes it consistent with searching and patrolling.

**The consequence to watch:** a skirmisher on the far side of a chasm now stops at
the lip and shoots across it, because it can neither close nor retreat. That is
coherent — flanking or shooting back is the answer — but it is a standing-off
behaviour that did not exist before, and it is what a playtest will notice first.

**A turret ignores `IMPACT`**, per the damage model -- dashing a bolted-down gun
must do nothing, or the free verb answers the hazard and the weapon specials lose
another customer. That makes it **the first hazard in the game that genuinely
requires cover or a weapon**, and therefore the first that can be authored into a
spot with no answer. A validator rule is owed and is not yet written.

**Its engagement profile is its own**, and that is the second reason it is a type
rather than a flag. `TURRET_RANGE` 19 against a skirmisher's 14, and a cadence of
2.0 s against 1.2 s: it cannot reposition, so its threat is **persistence rather
than pressure**. It owns a piece of the bridge until something kills it, and the
player pays for crossing that piece in distance rather than in reaction time.

**The firing arc is a seam, shipped at 360.** `TURRET_ARC_DEG` is the cone it can
swing through, centred on the facing it was bolted at; 360 is exactly the
behaviour that shipped before the split, so the mechanism arrives without a
balance change attached. Narrow it and **flanking becomes an answer the geometry
supplies for free** -- the tell is a gun that visibly stops tracking as you cross
its limit. Somewhere under about 90 degrees it stops being a hazard and becomes a
door, which is a real design and available on purpose. It is a slider in the debug
console because the right value is a thing to *find* in a playtest rather than
argue about here.

**What is not decided: where a turret's mount facing comes from.** It defaults to
looking down-bridge, the direction players arrive from. Per-turret authoring is a
glyph question -- the `T` glyph carries no direction today -- and the field exists
on the body so that answering it later changes a loader and not the enemy.

## Alertness — the telegraph the gunners never had *(built 2026-08-21)*

**They were the exception to a rule this document states twice.** A rusher spends
`RUSHER_RISE_SECONDS` coming out of the ground and that emergence is called *the*
telegraph; plinko balls are slow on purpose; the fairness argument in both places
is that a hazard has to announce itself before it can hurt you. A gunner picked
the nearest player it could see and fired on the tick its cadence allowed —
`fire_timer` starts at zero — so rounding a pillar at 8 m was a round in the chest
with no window to answer. Reported from play as *"the pink ones are very good
sharpshooters."*

**One scalar, not a state machine.** `alert` rises while a target is in sight and
falls while it is not, and firing requires it full. Three behaviours fall out of
one number rather than being written separately:

- **The wake window**, rolled per enemy between `GUNNER_WAKE_MIN` and
  `GUNNER_WAKE_MAX` (1–2 s). Random so two skirmishers who see you in the same
  frame do not fire in the same frame — a simultaneous volley reads as one big
  hit rather than as several enemies, and the stagger is what lets a player answer
  them one at a time.
- **Memory.** The fall takes `GUNNER_FORGET_SECONDS` (4 s), four times the longest
  rise, so half a second behind a pillar costs an eighth of its alertness and
  leaving entirely is forgotten in four seconds.
- **A cheap re-acquire, with no special case for it.** An enemy that lost you at
  0.6 resumes from 0.6. This is the one that matters for balance: if re-acquiring
  restarted the wake, bobbing in and out of cover would re-buy the whole window
  every time and cover would be an infinite stall rather than a decision.

**Nothing is drawn for it, and that is a decision.** The wake shipped with a glow
ramping up with `alert` and it was pulled the same day: *"it shouldn't
telegraph."* The window is a fairness margin, not an announcement — a hazard the
player can *answer* rather than one that warns them it is about to fire. What they
get is what a gun does anyway: **it turns to point at them**, from the first tick
of the wake. That is honest, it is already replicated in `facing`, and it is real
information rather than a badge — with two of them on a deck, the one looking at
you is the one to answer first.

Two consequences. `alert` is **host-only and not on the wire**, because with the
glow gone nothing client-side reads it. And the wake is *quiet*, so its length is
felt rather than seen: 1–2 s is short enough to be a beat and long enough to cross
a gap or get behind something, and if it wants tuning the evidence will be a
playtest report about being shot too fast, never a number in a log.

**With nobody to shoot, a skirmisher now patrols.** It used to stand exactly where
it was, forever. `hazards.md` argues that case for a *rusher* — searching is the
pathfinding a rusher bought its way out of — and it does not transfer to an enemy
whose whole job is holding a piece of ground. It wanders inside
`SKIRMISHER_PATROL_RADIUS` of where it was posted, at half its engaged speed, and
the difference between the two gaits is a read at the distance where the scene
file says you get "an outline and a colour and nothing else". A turret does not
patrol; it is bolted down.

**It asks the grid where the floor is, rather than casting a ray.** One predicate,
`footing_toward`, answers both "may I retreat out of my band" and "may I step there
on patrol" — the same question, and this project has twice paid for one fact having
two implementations that agreed until they did not. It refuses a bare step up for
the same reason `SegmentValidator._can_step` does: there is no step-up in this game.

**What is NOT decided: sight has no range limit.** A gunner sees any player with a
clear line, at any distance, exactly as before. That is deliberate for now — the
value of alertness is almost entirely in the case where sight is acquired suddenly
at close range, which a sight radius does not affect — but it does mean a
skirmisher will begin closing on somebody a long way off, and if that reads badly
in play the answer is a sight range rather than a change to any of the above.

## The rocket launcher — direct fire *(built 2026-08-15)*

**THE GRENADE GOES OVER THINGS; THE ROCKET GOES AT THEM.** They deal the identical
damage through the identical `blast_at`, and that is the point — the difference is
entirely the trajectory, so choosing between them is a question about the SHAPE of
the problem rather than about power.

- A grenade is lobbed at 40°, which puts it above a 2 m pillar for most of its
  flight. It clears cover, it lands, it waits. It is an area weapon and a timing
  weapon.
- A rocket flies flat and fast and detonates where it touches. It cannot get over
  anything, and it does not need to.

**So it is the answer to a TURRET** — bolted down, in the open, immune to the free
verb, and needing cover or a weapon. It is the wrong tool for anything behind a
parapet, which is exactly where the grenade is right. Two explosives with the same
payload and opposite geometry is a better roster than two power levels.

**It is a round, not a new object.** `bullet.gd` with `explodes = true`: same
flight, same per-tick sweep, same replication, and one branch at the far end of
the raycast. Everything else about it — 22 m/s, two shots, a 1.4 s cadence — is
tuning, and the tuning is what makes it feel like a decision rather than a
trigger.

**Two rounds only, and no spread.** The cone is what makes the machine gun a
suppression weapon; a rocket is one decision and it goes where it was pointed, or
the player is being asked to gamble both of them on a dice roll. It IS zeroed on
the aim ray the same way the machine gun is, because the barrel sits off-centre
and a rocket fired parallel to the aim line misses somebody standing dead ahead.

## The specials, revised## The specials, revised

| special | answers | note |
|---|---|---|
| **machine gun** *(built 2026-08-13)* | rushers, and a friend standing somewhere you would rather they were not | **the first special built**, and the first thing in the game that REMOVES a threat instead of postponing one. Its property is cadence: 2.5 rounds a second, held down, in a 10°-by-2° cone -- wide across, narrow up, because the bridge is a narrow strip and everything worth shooting stands on it. Rounds are **slow visible balls** — 22 m/s, a beat and a half to cross the full range — so at distance a moving target can be out from under one. Damage and knockback both gated by `HIT_GRACE`, so a burst downs somebody in about four seconds rather than half of one. A round also SHOVES a plinko ball, which cuts both ways: the field is partial cover now, and it is also something you can shoot at somebody. A pillar stops a round outright, which is the counter-play. Hanging or downed, you drop it |
| shotgun | rushers, crowds, close range | kills what is destructible |
| **rifle** | rushers and friends at distance | precision, not reach — the first tool that *helps* someone 30 m away without a rope, and equally the first that betrays them |
| sword | rushers, spiders, anything that comes to you | arcs, multi-target |
| thrown bomb | groups, delayed | |
| anchoring shield | water, knockback, holding a position | plant it; immovable **while planted and doing nothing else** |
| legs | spikes, sand, short gaps, one layer of height | traversal |
| **transfusion** *(name provisional)* | a teammate about to go `DOWNED` | gives them **your** hit points |

**Transfusion is a transfer, not a heal.** M5 already shipped proximity revive
and first-come-first-served hearts, so a third healing source would flatten the
rescue tension D2 exists to create. Giving away your *own* health is a different
act: it costs the giver, it can be overdone to the point of dropping yourself,
and — the actual reason it is in — **sacrifice is legible from across the
bridge** in a way that a heal is not.

**The knockback reducer was cut.** Two reasons. It is passive, so "fixed uses,
dropped when spent" does not apply and it breaks the one model every special
shares. And the entire game is displacement: an item that makes you harder to
displace makes you *less funny*. The version that survives is the anchoring
shield, which charges you a commitment for the same effect.

## The gap nobody has filled

**No hazard requires two players in two places at once.** The leash is a soft
rule; every hazard above is solvable by one competent player, and pillar 1 —
"the geometry is authored so that specific obstacles have no single-player
solution" — is currently carried entirely by the steep ramp.

A held gate, a pressure plate, something that must be weighed down while another
player crosses: an obstacle whose answer is **positional** rather than
**item-based**. That is the largest hole in the hazard design and the one that
most directly serves A1.

**[open]** It also sits awkwardly against E1b, which forbids a layer solvable
*only* by a cooperating pair, because drop-in means the party can be one player.
The resolution is probably that a co-op-only obstacle may gate a **reward or a
shortcut** but never the **route** — the same shape as legs. Confirm before
building one.

## Open questions

1. **[open]** Does a dash kill a rusher outright at full speed? Specified as no —
   deflect and stagger — so that the destructible/deflectable split stays clean.
   If playtest says a 56 m/s impact obviously ought to kill it, the split needs a
   different carrier and the weapons lose their exclusive job.
2. **ANSWERED 2026-08-08: a mound is spent.** Built that way, for the stated
   reason — a mound that refilled would make the hazard a function of how long
   you loiter rather than of where it was authored. The spent set is replicated:
   a reliable RPC when one wakes, and the whole set once on join, because a
   client that rebuilt the bridge from the seed has every mound including the
   used ones.
3. **[open]** Naming. "Rusher" is descriptive placeholder; `m` for its mound is
   mnemonic but unclaimed glyphs are getting scarce.
4. **[open]** Does transfusion work on a `DOWNED` teammate, or only to prevent
   one going down? Prevention-only is the more interesting item and keeps the
   revive as the thing you have to physically reach.
