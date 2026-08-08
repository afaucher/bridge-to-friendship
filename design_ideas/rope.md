# The rope

Decided 2026-08-08. Supersedes the one-paragraph sketch in `game_concept.md`.

## It is a real, soft, simulated rope

Not a rigid tether. A chain of particles with distance constraints between
consecutive links, solved a fixed number of iterations per tick, pinned at each
end to whatever it is attached to. It drapes when slack, straightens as it goes
tight, and swings when something on the end of it is thrown.

The obvious objection to simulating a rope in a host-authoritative game with
rewind-and-replay is a good one: a chain of N particles is N x 6 floats of state,
and chaotic systems amplify divergence, which is precisely what replay is worst
at. The resolution is that **the rope's SHAPE and the rope's FORCE are two
different things, and only one of them has to be authoritative.**

### The shape is cosmetic and is simulated everywhere

Every machine runs the same particle chain, pinned to the two endpoint bodies.
Those endpoints already arrive in the snapshot, because they are players (or a
world anchor, which does not move). So a client can produce a perfectly good rope
without being told anything about it.

If two machines' ropes drape a few centimetres differently, nothing in the game
notices. Nobody dies because a rope sagged. **The rope is therefore NOT in
`capture_state()`, NOT in the snapshot, and NOT replayed** — which removes the
entire netcode objection at a stroke, and is why this is affordable at all.

A client that joins mid-swing simply starts its rope straight and lets it settle;
a fraction of a second later it matches.

### The force is a designed rule and is host-authoritative

What the rope DOES to the bodies on its ends does not come out of the particle
sim. It comes from one measurement — how much longer the rope wants to be than
its maximum — and one rule:

- **Slack does nothing.** A rope shorter than its length is a decoration.
- **Taut pulls, and never pushes.** Over-length by any amount and both ends are
  drawn toward each other along the line between them.
- **The pull is capped**, so a rope cannot fling anyone at a speed the rest of
  the game has no answer for.

Keeping the force out of the particle solver is what makes a shove-yank feel the
same every time. It is the same choice the rest of the game makes: momentum
transfer is a legible rule, not a solver outcome. See
`physics_and_authority.md`.

**[open]** Wrapping. A simulated rope will *visually* lie across a pillar, but it
will not catch on one unless the particles collide with the world. Particle
collision is affordable; making a wrapped rope shorten its effective length —
which is what would make wrapping tactical — is a separate mechanic. Deferred
until the basic rope is playtested.

## Grabbing

Fire at the nearest valid target within range and inside a forward cone. Valid
targets: another player, a pillar stone, a ledge lip, and world anchors. Aim
assist snaps to the best candidate — this is a party game and a co-op rope that
demands precision is a co-op rope nobody uses.

Player-to-player is the case that matters: it ties the two together until either
releases.

## Pulling someone up: the answer to "how do they climb?"

This was the open question, and it is why **the ledge mechanic is built before
the rope** (see the roadmap's build order). A yank on its own does not get anyone
onto anything — it is a horizontal tug, and a player dragged into the side of a
2 m step just slams into it.

The full move, in order:

1. **B is below or over the edge.** Either standing at the bottom of something
   too steep to climb, or already falling past a lip.
2. **B catches the ledge**, or is pulled into a position where they catch it.
   This is M5's `LEDGE_HANG` — a player near a lip with a rope pulling them
   toward it ends up hanging from it.
3. **A dashes away from the edge.** The rope goes taut, and the pull is along the
   rope — which, from B hanging at the lip toward A standing back from it, points
   **up and over**. That is where the vertical component comes from: not from the
   yank being upward, but from the geometry of pulling toward someone who is
   already up there.
4. **B mantles.** Once the pull has lifted B's body clear of the lip, they
   auto-climb onto the deck. A hanging player cannot mantle unaided — that is the
   whole point of the ledge-hang — but a hanging player *being pulled* can.

So the rope does not lift anyone. It converts the puller's dash into a pull along
a line, and the ledge does the rest. Which means the mechanic that has to exist
first is the ledge, not the rope.

**A dash is strong enough to pull the catcher over too**, which is the joke, and
falls out of the same rule: the pull acts on both ends.

## Being on the end of a rope when you get hit

There is no separate `SWING` state, and the earlier design that had one was
wrong. A hard hit puts a player in **`TUMBLE`** — a chaotic, pinwheeling,
bouncing ball that keeps its momentum rather than sliding to a stop. If a rope
happens to be attached, the rope catches them at maximum length and they swing.

The swing is not a behaviour anyone wrote. It is what a tumbling body on the end
of a taut line does, and it comes free from the constraint. Two states that
describe the same physical situation would only ever drift apart.

That is also what makes being roped **defensive**: tied to a friend or an anchor,
a tumble that would have carried you off the bridge becomes a swing that ends
with you dangling off the side instead. Tying up is a thing you do *before* the
plinko starts, and the reason to do it.
