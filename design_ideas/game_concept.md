# Game concept

Written 2026-08-08. The first pass at what this game is, derived from the
concept brief plus the consequences that fall out of it. Anything marked
**[open]** is a question the design has not answered yet; anything marked
**[proposal]** is a suggestion that has not been agreed.

## One line

Drop-in co-op for 2–4 friends climbing a continuous, endlessly rising bridge,
where the only tools are shoving each other and roping each other together.

## Pillars

1. **You cannot climb the bridge alone.** Not "it is harder alone" — the
   geometry is authored so that specific obstacles have no single-player
   solution. A ramp too steep to walk up is passable only by being shoved up it,
   or by roping a player who is already up there.
2. **Every tool is aimed at another player as readily as at the world.** Shove
   pushes a stone, a ball, or your friend. Rope grabs an anchor, or your friend.
   There is no "help" verb and no "attack" verb; there is one set of verbs and
   the intent is entirely in where you point them.
3. **Comedy comes from committed actions.** A shove cannot be steered or
   cancelled. Tumbling takes control away for a moment. The bus rotates who is
   driving without telling them. The humour is that everyone can see the
   disaster coming and nobody can stop it.
4. **Losing is a setback, not an ending.** Falling off, being washed away, or
   dropping to zero health interrupts the group; it does not end the run.

## The verbs

### Move
Free analog movement, walking speed. Ordinary, responsive, unremarkable — it is
the baseline that makes the committed actions feel committed.

### Shove
A run locked to one of the four compass directions. The player accelerates to
dash speed and **cannot steer, slow, or cancel**. It ends when it hits
something, leaves the deck, or runs out of distance.

On hitting something, momentum transfers:

| target | result |
|---|---|
| another player | target is launched along the dash axis; shover stops |
| a pillar stone | stone moves one cell along the axis if the destination is clear; shover stops |
| a plinko ball | ball is launched; shover keeps some momentum |
| a wall or an unmovable stone | shover stops, small recoil |
| nothing (edge of deck) | shover leaves the bridge |

The direction lock is what makes this a *compass* and not a dodge: you commit to
an axis, and everything downrange of that axis is in play. See
`physics_and_authority.md` for why the transfer rules are hand-written game
rules rather than emergent rigid-body results.

**This constrains the camera.** A compass-locked dash is unusable with a
free-look camera — "north" has to mean the same thing every frame. The camera is
therefore **fixed-yaw**, looking along the bridge. This is not a small
consequence and it is not negotiable while the dash is compass-locked.

### Rope
A real, soft, simulated rope — a chain that drapes when slack, straightens as it
goes tight, and swings when something on the end of it is thrown. It pulls and
never pushes. Full design, including how a simulated rope stays affordable in a
game with rewind-and-replay, is in `rope.md`.

- **At the world:** an anchor to swing from or pull yourself toward.
- **At a player:** the two are tied together until either releases. Either one
  can dash to yank the other.
- **The rope does not lift anyone.** A yank is a horizontal tug; a player dragged
  into the side of a step just slams into it. What gets a partner up is that they
  are *hanging from a ledge* and you dash **away** from it — the pull runs from
  them at the lip to you standing back from it, which points up and over, and
  then they mantle. The vertical component comes from the geometry, not from the
  rope pulling upward. This is why the ledge mechanic is built first.
- **Being roped is defensive.** A tumble that would have carried you off the
  bridge becomes a swing that leaves you dangling off the side instead. Tying up
  is something you do *before* the plinko starts, and the reason to bother.
- **Catching:** a player who has gone over an edge can be caught mid-fall. A
  dash is strong enough to pull the catcher over too, which is the joke.

### Special
A pickup with a fixed number of uses. Common, disposable, and picking up a new
one drops the spent one where you stand. Specials complement shove and rope; they
never replace them. **One slot**, which is the whole balance: carrying one
special is not carrying any other.

| special | what it is |
|---|---|
| shotgun | ranged shove, several uses |
| sword | melee, arcs, hits more than one thing |
| thrown bomb | area knockback, arrives late |
| anchoring shield | plant it; blocks or absorbs |
| **legs** | **jump one full block high, a few times** |

The first four are **committed actions aimed at something** — press, and the
world resolves what happened, exactly like a shove. Legs are not: they modify
ordinary movement. That difference is small in design and large in engineering;
see below and `implementation_plans/roadmap.md` M12.

#### Legs, and the jump that was removed

*(Added 2026-08-08.)* M3 removed jump outright, and `sim_config.gd` still carries
the reason: *"a small ledge stops being a co-op moment the instant everyone can
hop it."* That argument is intact, and Legs do not contradict it, because it is
an argument about a **capability everyone has at all times**. Legs make jumping a
**resource**: a few charges, one slot, one player, gone when spent.

- **One full block — 2 m, one layer.** A player with legs can put themselves on
  the next level unaided. That is the point of the item.
- **Legs are a shortcut, never an ascender.** A layer must still be solo-passable
  by authored terrain — a ladder, a bouncer, a walkable ramp — with legs
  credited for nothing. This is not conservatism, it is E1b applied to items
  instead of players: a special is contested and disposable, so a route that
  *requires* legs strands the three party members who did not get the pickup,
  which is the exact failure E1b exists to prevent. `SegmentValidator` therefore
  does not learn about legs, and its two rise budgets stand unchanged.
- **The failure mode to watch is abundance, not power.** If legs become common
  enough that someone always has a pair, M3's objection returns in full and the
  steep-ramp beat quietly stops happening. That is a content-density decision,
  not a code one, and it is the thing to check in playtest.

**Dashing while airborne is intended and stays** *(decided 2026-08-08)*, and legs
change nothing about it. You can already run off any ledge and dash mid-air
today — nothing checks `grounded` in `_begin_shove` — so the combo is live and
available to everyone with no pickup at all.

What legs add is only **height**. Descending has always been free: walk off. It
is *up* that the bridge gates, which is the asymmetry the item is sold on.

## The punishment

**Tumble.** The main "you got hit" state, and a **pinwheel rather than a slide**.
A hard hit throws a chaotic, bouncing body that KEEPS its momentum instead of
decelerating politely to a stop. It is not damage so much as displacement, and on
a bridge with holes in it displacement is the threat — a tumble that slid to a
halt would not be one.

There is no separate "swing" state. A tumbling player on the end of a taut rope
swings because that is what a body on a line does; it falls out of the
constraint rather than being a behaviour anyone wrote.

**Health.** A small pool of hit points. Every obstacle collision costs at least
one. Hearts are scattered along the bridge and are **first come, first served** —
like pickups, they are a thing to communicate about rather than a thing to
collect.

**Falling is the failure, and the ledge grab is the rescue.** *(Decided — see
`mvp_success_criteria.md` D2.)* Shoved over an edge while still near the deck,
you catch the ledge and hang there on a bleed-out timer. You cannot pull
yourself up; only a teammate's rope gets you back. Launched clear of the deck —
knocked several cells into the air — you never reach a ledge and you simply
fall.

That asymmetry is the point: **whether your friends can save you is decided by
how you got hit, not by how fast they react.** A shove along the deck leaves you
hanging and rescuable. A plinko ball to the chest launches you and nobody can do
anything about it. Standing near an edge is legibly risky, and a successful
rescue is earned rather than routine.

A player who falls is **returned by a drone and dropped next to another
player**, which is a setback and a laugh rather than an ending.

**A grace window after any hit.** Without one, a single tumble that bounces you
through a pillar field drains the whole health bar before you regain control —
the player never made a decision and lost everything. Short invulnerability
after each hit is close to mandatory once tumble and plinko exist together.

**Zero health puts you DOWN, on a bleed-out.** *(Decided.)* You collapse where
you fell — immobile, no verbs — and a timer runs. A teammate who reaches you in
time revives you at minimum health; if nobody does, the drone returns you, the
same way falling ends. Health therefore has its own distinct failure with real
tension, and a floor underneath it: a lone player is never stuck, only slower to
get back.

`LEDGE_HANG` and `DOWNED` are the same machinery — immobile, a countdown, a
teammate who can end it early, the drone if nobody does. Built once, used twice.

## The bridge

A continuous 3D grid of blocks that steps upward as you progress, so the sense
of climbing never resolves. The structure itself is the level design: holes to
fall through, sections with no parapet, rivers that push you sideways, ramps too
steep to walk, and fields of stacked stone pillars.

Pillars are load-bearing in two senses. They are what plinko balls ricochet off,
and they are pushable — a dashing player can shove a stone into the next cell,
or through a hole, where it falls away. Rearranging the bridge is a verb.

Full grid model, units, and the segment authoring format are in
`bridge_grid.md`.

## The main obstacle: plinko

A shooter — a cylinder pillar with a barrel on its business end — lobs balls up
the bridge at a fixed speed and a varying angle. They land, ricochet down through
the pillar fields under the bridge's own pitch, and arrive back at the group.
They are a continuous, semi-random pressure that makes standing still expensive,
which is what forces the party up into terrain they have not solved yet.

Balls are **slow, and dodgeable on sight**. The threat is not reaction time; it
is that one is still coming while you are busy, on a bridge full of holes to be
knocked into.

**A dashing player bats a ball away and takes nothing.** Any other contact is
knockback, `TUMBLE`, and a hit point — every ball that connects tumbles you.
There is no glancing/solid distinction; the interesting choice is *do I commit to
a dash*, not *was that hit hard enough*. Full design in `plinko.md`.

## Bus mode

Set-piece sections where the bridge deck is surfaced as a road. Players board a
bus; the first aboard drives. **The driver loses every other verb** — go, steer,
reverse, nothing else. Everyone else keeps rope, shove and specials and fights
off whatever the road throws at them.

Any player can press *switch*, which **rotates every seat on the bus**. Nobody is
told. The comedy is a player discovering they are driving by noticing the bus is
no longer going straight.

Post-MVP — see the roadmap — but it is worth knowing now, because "the driver
loses their verbs" implies the verb set has to be suppressible per-player, and
"seats rotate" implies player→role is data rather than something baked into the
avatar.

## Session shape

**Drop-in co-op, online, 2–4 players.** Each player has their own screen and
their own camera; this is not a shared-screen couch game. That is visible in the
HUD design: your own health and abilities top-left, your friend's top-right — a
layout that only makes sense per-player.

Drop-in means a player can join a run already in progress, which means the world
must be able to hand a newcomer a complete snapshot of itself. That is a
constraint on how world state is stored from the first line of the grid model,
not a feature to add later. See `physics_and_authority.md`.

## Resolved, and what is still open

**Resolved 2026-08-08** — full statements and their consequences are in
`mvp_success_criteria.md`:

- **A run is an endless climb with banked checkpoints.** The bridge is assembled
  from a pool of authored segments by tag and difficulty; progress banks every
  few segments, and a wipe restarts there rather than at the bottom.
- **Falling is the failure; the ledge grab is the rescue.** See above.
- **A soft leash holds the party loosely together**, which also settles bridge
  streaming: one window around the group, never per-player.
- **Zero health is DOWNED on a bleed-out**, revivable by a teammate who reaches
  you, and the drone if nobody does. `LEDGE_HANG` and `DOWNED` share one piece of
  machinery.
- **The ledge catch is automatic**, because it fires most often while the player
  is mid-tumble with no control to answer a prompt with.
- **The rope is really simulated** — soft, drapes, swings — with its shape
  cosmetic and its force authoritative. See `rope.md`.
- **Shove is a continuous dash on a grid-aligned axis** — only pushed stones snap
  to cells — which settles the camera as fixed-yaw.

**Still open:**

1. **Where does difficulty come from over time?** Denser plinko, nastier
   geometry, faster rise, fewer hearts — or a mix on a curve. This is the core
   question of the level-design milestone (M10).
2. **Is there a second ramp grade** too steep even to be shoved up, so the only
   answer is the rope? That would give two distinct grades of cooperation
   instead of one.
3. **Does the rope wrap?** A simulated rope will lie across a pillar; making it
   *catch* on one and shorten its effective length is a separate mechanic, and
   the one that would make wrapping tactical. Deferred until the basic rope has
   been played with — see `rope.md`.
5. **Is a run scored, and how?** *(Recorded 2026-08-08 as an intent, deliberately
   left open.)* A run is currently measured only in distance and checkpoints
   reached. The intent is that it eventually also carries a **score**, banked at
   each checkpoint alongside progress, and that **hats** (see
   `implementation_plans/m8_5_hats.md`) are its first source: you are paid for
   optional risk you took and held on to. What the units are, whether the score
   is per-player or per-party, and whether anything else feeds it are all
   unanswered and do not need answering yet.

   **What this obliges M8 to leave room for, and nothing more:** checkpoint
   banking should snapshot an *extensible* per-player record rather than a
   distance integer, and the bank should be a **hook other systems can attach
   to** rather than a closed function. That is a shape, not a feature — it costs
   M8 nothing today and it is what stops scoring from reopening M8 later.
