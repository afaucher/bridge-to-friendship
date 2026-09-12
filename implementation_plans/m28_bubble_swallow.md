# M28 — The Bubble Swallow

An ambush that eats your hats and keeps them.

It sits under the water with nothing showing. Come close and it surfaces and
starts pulling. While it holds you it swallows what you are carrying — and it
does not destroy any of it. Kill it and everything it took falls out.

---

## The four commitments, and what each one costs

These came from the brief and each one rules something out. Written down together
because two of them pull against each other and the resolution is the design.

**It stores what it eats.** Not a destroyer, a *bank*.

**It is one enemy, not a swarm.** So it has to be worth meeting on its own.

**It barely telegraphs.** No wind-up, no tell before it acts: proximity is the
trigger and the surfacing is the event.

**Picking it off at range must not work.** So it cannot be a thing you shoot
before it does anything.

### The last two are the same requirement, and the mechanism is being submerged

While it is under, it has **no hit shape at all** — not a tough target, not a
small one, *nothing to hit*. That is what makes sniping it impossible rather than
merely tedious, and it is the same fact that gives it no telegraph: there is
nothing on screen to read.

It surfaces when a player comes within its reach, and from that instant it is an
ordinary target. So the threat and the answer arrive in the same moment: you are
being pulled, and the thing pulling you is now shootable.

**A grenade does not reach it either.** No exception, no expensive route — while
it is under, nothing anybody can do touches it. Worth being absolute about,
because a single exception is what turns a legible rule into a superstition: one
player would try a blast, it would work, and everyone else would spend grenades
finding out that the timing has to be right.

**And "no hit shape" is not enough to make that true.** Bullets are refused by
having no collider, but `_blast_targets` does not ask about colliders at all — it
walks the pools by distance:

```
for group in [_rushers, _gunners, _zombies, _balls, _hats.all(), _specials.all(), _deployables]:
```

A swallow in a pool would be found there whatever its collision looks like. So
the exclusion has to be written on **both** paths, and a test that only fires a
bullet at a submerged swallow proves half of it. That is the same shape as every
collision-mask bug in CLAUDE.md: the thing is refused on the route somebody
checked and accepted on the one nobody did.

### Which means the fairness budget is spent on ESCAPABILITY, not on warning

Every other hazard here is fair because it tells you first — a rusher's charge, a
gunner's alert, the wind-up on a lunge. This one cannot, by design. So the thing
that has to carry the fairness is that **the pull is beatable at the edge**, and
that has to be arithmetic rather than a tuned feel:

- At the rim of its reach, the pull is **less than `WALK_SPEED`**. You walked in;
  you can walk out.
- Inside its core, the pull is **more than `WALK_SPEED`**. Once it has you, legs
  are not the answer and shooting is.

Written that way it is testable — sample the pull across a ring of radii and
assert where it crosses walking pace — and it cannot be quietly broken by
somebody nudging a constant later. That claim is the whole safety of the design.

---

## What it takes, and why that is the interesting part

**Loose things in reach are swallowed whole**: hats and specials lying on the
deck. Not pulled and then eaten — taken, the moment they are inside. A vacuum
reads as a vacuum, and an item sliding across the ground is a second motion
system for one effect.

**And it takes the hat off your head, once a second, while it has you.** The top
hat, the same one the merchant takes — so a tower is eaten from the top down and
you can watch it happen.

**With nothing to take it takes health instead.** One interval, two effects,
decided by whether there is a hat: otherwise a player who has already lost their
tower is immune to the thing that took it, which is the wrong way round.

### THE DRAIN IS THE CORE, NOT THE REACH — and that resolves the telegraph

You are eaten only where you cannot leave. Being pulled and being drained are
different zones, and the boundary between them is the one the arithmetic above
already draws:

| | |
|---|---|
| **Outside its reach** | nothing at all, and nothing to see |
| **The rim** | pulled, escapable by walking, *nothing taken* |
| **The core** | pulled unescapably, one hat per second |

**Which is the telegraph, and it is the only one this design can afford.** The
brief says it should not warn you before it acts — and it does not: the surfacing
is the first event. But between surfacing and losing anything there is a band you
can still walk out of, and that band is the warning. It is spent in the currency
this enemy has (distance) rather than the one it refuses (time).

One boundary doing two jobs is worth having on purpose: if the rim and the core
ever drift apart, the enemy stops being legible, because "am I being eaten" would
no longer be answerable by "can I still walk away".

### One second, and what should actually tune it

A second is the right order of magnitude and it is **not the number to tune**.
What matters is the drain against the **time to kill it**: winning an ordinary
fight should cost you a couple of hats held hostage, not your whole tower. So the
interval and the swallow's health are one decision, and the test should assert
the RELATIONSHIP — hats taken during a normal kill, not seconds per hat — because
this project has shipped literals that stopped meaning anything the day something
upstream moved.

And the drain can afford to be fast precisely **because it is recoverable**. A
hat inside a swallow you are about to kill costs nothing; the rate is not a
punishment, it is the size of the hostage. Which is what makes fleeing expensive
and standing and fighting correct, and that is the decision this enemy exists to
pose.

---

## It takes several hits, and it is the first thing here that does

**No enemy in this game has health.** A rusher, a gunner, a zombie and a turret
are all killed outright by one bullet; the only `health` field in the codebase is
on `PlayerBody`. So `_deliver` has a `has_health` branch that has **never been
true for an enemy** in the life of the project.

That is not a reason to avoid it — a hazard you have to shoot *while it is eating
you* has to survive the first shot or the fight does not exist. It is a reason to
know what else moves when it lands.

**The `damage` stat becomes reachable.** It was already found dead once: damage
was measured as health lost, no enemy had any, and an early return meant `damage`
and `kills` were both unreachable while every assertion about them said they
equalled zero. The early return went; the health path itself still has never run
against an enemy. So the first swallow makes a years-old code path live, and
"damage is counted when a swallow is shot" is a claim to make rather than a thing
to assume.

### Time to kill times the drain IS the hostage

These are not two numbers, they are one. Four hits at the pace of whatever you
are holding, against one hat a second, decides how much of your tower is inside
it when it dies — so the health and the interval have to be chosen together and
tested together.

**And it depends on the weapon**, which is a feature: a machine gun ends it in
under a second and a pistol does not, so being well armed is worth hats rather
than only being worth time. It also means the test has to say what it is holding,
or it is measuring the loadout and reporting it as balance.

### Several hits is what makes it a party fight

One shot and it would be a solo problem. Several, and somebody has to be **in the
field** while the others shoot — because the drain is what keeps a player there
and the surfacing is what keeps it shootable. The bait is a role, and it is the
same role the person losing hats is already playing.

Nothing has to be written for that. It falls out of the drain and the health being
separate numbers.

### So it dives when the field is empty, and remembers

Two consequences that have to be decided rather than discovered:

- **It re-submerges when nobody is in reach**, and goes untargetable again with
  the bank still inside it. So a party that backs off does not get to plink at it
  — the fight has to be held, which is what the bait is for.
- **Damage persists across a dive.** It does not heal. A party that softens it,
  retreats and comes back has made progress; healing would make a failed attempt
  worth nothing, and "you must win it in one go" is a harsher shape than this
  enemy needs when the hostage already provides the pressure.

### This is the only recoverable hat loss in the game

Falling **destroys** your tower, deliberately — `destroy_worn_hats` says so and
gives the reason: dropping them "would rescue the one failure the design does not
rescue". Being shot off drops them where you stood, which is a scramble.

A swallow does neither. It *holds* them, and killing it spills everything it has
taken. That makes it the one hazard where a bad thirty seconds is undoable, and
it is worth building precisely because it is different in kind from the others
rather than harder than them.

It also makes the swallow **a co-op moment with no new machinery**: the person
whose hats it holds may already be dead and returning, and somebody else killing
it hands them back. Nothing has to be written for that; it falls out of the bank
being a place rather than a debt.

### So fleeing is the real cost, not the damage

Run and you keep your body and lose the tower. The decision this poses is not
"fight or flee" — it is **fight now or lose them**, which is a better question
because it has no safe answer.

---

## What it must not quietly eat

**If nobody kills it, everything in it is lost.** That is the decision, and it is
what gives the enemy its weight: the bank is not a delayed refund, it is a wager.
Walk away and the hats are gone for good.

So the corridor sweep takes it and its contents — **it does not spill**. The
swallow is a level entity and belongs in `_discard_level_entities_past`, the
**fifth** pool to need adding there after hats, specials, deployables and corpses.

**But the loss has to be COUNTED, or it is a score that changes with no event.**
An earlier draft of this plan said a swept swallow should spill, for exactly that
reason; spilling is the wrong fix and the worry was right. A player who finds
three hats missing and nothing anywhere saying why has met a bug as far as they
can tell — this project has already shipped two counters that read zero for
rounds nobody could explain.

So the swallow records **whose** hat it took when it takes one, and a swallow
that leaves the world bumps `hats_lost` for each owner. Permanent, attributed,
and legible on the board afterwards. The rule is "you left it behind", not "your
hats evaporated".

---

## What it looks like

Everything in this game is a Godot primitive with a flat colour, read from a
fixed camera about 30 m up — so the top-down silhouette does the work and the
`art_direction.md` contract applies: a mesh may not lie about its collider, and
decorative overhang is allowed only where nothing collides.

Five loads on one object:

| part | primitive | what it MUST say |
|---|---|---|
| bubbles | 3 small spheres, **no collider** | something lives here — a *place*, not a warning |
| shell | translucent sphere, ~1.6–2.4 ⌀ | it is up, it is a target, and it is *full* |
| maw | dark disc on the **upper** face | which end eats |
| swallowed hats | the real hat meshes, **inside the shell** | whose, and how many |
| darkened water | tinted cells, two radii | where the point of no return is |

### The bank is the silhouette

The shell is translucent and the hats are visible through it, so **how much it is
worth is how big it is** and no UI is needed to say so. It grows as it eats — and
because a mesh may not lie about its collider, a fed swallow really is a bigger
target. That is risk and reward for free: the longer it eats, the easier it is to
hit and the more it is worth hitting.

### The field is tinted CELLS, and only once it surfaces

This project already made the plate-versus-ground choice once, on lap gates: a
plate laid on the deck was reported as an overlay, and they are coloured ground
squares now. The swallow is anchored to a cell, so its reach covers a fixed set of
cells and the same machinery draws them. No decal, no plate.

**The tint arrives WITH the surfacing.** The fairness of this enemy rests on the
player being able to tell the rim from the core — "can I still walk out" has to be
answerable by looking — but drawing that while it is submerged would give the
ambush away and turn the bubbles into a keep-out sign. So: no warning before it
acts, and complete information from the instant it does.

### The maw faces up, and the bubbles are the only thing under water

A mouth on the side is invisible from the only angle anybody has. It looks odd in
elevation and is right for the camera that exists.

The bubbles are a deliberate softening of "no telegraph" and worth naming as such:
they mark a place rather than an imminent action, and nothing about them can be
shot. A blank surface would be a purer ambush that teaches nobody anything.

### What it must not be mistaken for

The whole enemy vocabulary is one primitive and one flat colour, so reads are
silhouette plus hue — and the **plinko ball is also a sphere**. Four things
separate them, all of them load-bearing rather than decorative: the swallow is
pale and translucent against the ball's near-black, it is bigger and gets bigger,
it is only ever over water, and it has a maw.

---

## Where it lives

Submerged in a water cell, spawned by the dressing pass like every other hazard,
one per body of water rather than one per section.

**It does not drift.** Water flows now, and a floating ball in a channel would be
carried to the fall — which is either comic or a bug depending on the day. An
ambush predator holds its spot; it is anchored to the cell it was placed in.

**AND NOT BESIDE ANYTHING YOU HAVE TO STAND AT.** With no counter-play at all —
no sniping, no blast, no warning — an ambush placed on a spot the party *must*
occupy is not a hazard, it is a toll. The bus post, the mode selector and the
merchant are all places you stop and press a key, and the dressing pass already
keeps dangerous content clear of lifts for the same reason: never aim a hazard at
somebody with no verbs. A swallow within its own reach of one of those is that
rule broken by a hazard whose whole design is that you cannot pre-empt it.

**It should prefer a pool to a channel.** A pool is a place you cross with the
current changing under you, which is already the busiest water in the game; a
narrow channel is a place you are through in a second. Whether that preference is
worth encoding or whether random placement is fine is a playtest question, not a
design one.

---

## The interactions to measure, not reason about

Every one of these is new this week and none of them has been felt together.

- **The pull against the current.** Two forces on one body. A swallow downstream
  of you has the river helping it; one upstream is fighting it. That could be the
  best thing about the enemy or it could make it unreadable.
- **The pull against the step-up.** Being dragged into a bank you can now climb
  is either the escape or a way to skip the fight entirely.
- **Where the spill lands.** Kill one over a flowing channel and the hats land in
  the current — and the flow does not move loose items today. That open question
  from M27 phase 2 stops being optional here.
- **A downed or hanging player.** Being drained while unable to act is a
  different game from being drained while shooting, and probably a worse one.
- **The bus.** A rider is planted; a driver is steering. Whether a swallow can
  pull either is a rule, not an accident, and it needs deciding rather than
  discovering.

---

## Replication

The same split every pool here uses, for the same reason: **decisions go
reliably, motion rides the snapshot.**

- Existence, surfacing, death and **what it is holding** are decisions.
- Position rides the snapshot; it barely moves.
- The pull applied to a body must be a **pure function of the two positions**, so
  a client replaying a tick reaches the same answer and `corrections` does not
  climb. That is the same property the water push and the step-up both needed,
  and it is a claim to verify rather than assume.

---

## Phases

1. **The ambush.** Submerged and untouchable, surfaces on proximity, becomes an
   ordinary target, dives again when the field empties. The claims are that a
   bullet AND a blast both fail to reach it under water, that the same two hit it
   once it is up, and that damage survives a dive. Both weapons, because the two
   take different routes to a target and only one of them looks at colliders.
2. **The pull.** The rim/core arithmetic against `WALK_SPEED`, sampled across
   radii.
3. **The bank.** Swallowing loose things and the top hat, holding them, spilling
   on death — and spilling when swept. This is also where the first enemy with
   health makes `_deliver`'s damage path live, so the `damage` stat is asserted
   here rather than trusted.
4. **Placement.** The dressing pass, one per body of water.

## Open

*Nothing. Every question this plan opened has been answered:*

- *Worn hats, once a second while held, plus loose hats and specials off the
  ground.*
- *Several hits to kill — the first enemy here with health.*
- *A grenade cannot reach it submerged. No exception.*
- *If nobody kills it, everything in it is lost.*

What is left is not design, it is the list under **the interactions to measure**
above — and none of those can be settled by thinking about them.
