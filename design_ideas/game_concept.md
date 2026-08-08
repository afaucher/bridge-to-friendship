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
Fire at a grab target; a taut line forms that pulls but never pushes.

- **At the world:** an anchor to swing from or pull yourself toward.
- **At a player:** the two are tied together until either releases. Either one
  can dash to yank the other — this is the primary way to get a partner up
  something they cannot climb.
- **While taut, you swing instead of tumbling.** Being roped is the answer to
  the game's main punishment, which is what makes tying up a defensive act and
  not just a traversal trick.
- **Catching:** a player who has gone over an edge can be caught mid-fall. A
  dash is strong enough to pull the catcher over too, which is the joke.

### Special
A pickup weapon with a fixed number of uses — shotgun, sword, thrown bomb,
anchoring shield. Common, disposable, and picking up a new one drops the spent
one where you stand. Specials complement shove and rope; they never replace
them.

## The punishment

**Tumble.** The main "you got hit" state. The player becomes a ball for a moment
— no control, rolling with whatever momentum arrived. It is not damage so much
as displacement, and on a bridge with holes in it, displacement is the threat.

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

**[open] What does zero health do?** The simplest unification is that it does
exactly what falling does: removed, then drone-returned. One failure resolution
instead of two. Confirm before M5.

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

A shooter drops spheres onto the bridge above the players. They bounce down
through the pillar fields toward the group. A glancing hit shoves; a solid hit
tumbles. They are a continuous, semi-random pressure that makes standing still
expensive, which is what forces the group to keep moving up into terrain they
have not solved yet.

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
- **Shove is a continuous dash on a grid-aligned axis** — only pushed stones snap
  to cells — which settles the camera as fixed-yaw.

**Still open:**

1. **What does zero health do?** Suggested: the same thing falling does.
2. **Where does difficulty come from over time?** Denser plinko, nastier
   geometry, faster rise, fewer hearts — or a mix on a curve. This is the core
   question of the level-design milestone (M10).
3. **Is there a second ramp grade** too steep even to be shoved up, so the only
   answer is the rope? That would give two distinct grades of cooperation
   instead of one.
4. **Is the ledge grab automatic or a button press?** Defaulting to automatic.
