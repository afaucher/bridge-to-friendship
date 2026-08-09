# Plinko

Decided 2026-08-08. The bridge's main hazard, and the reason a party cannot stand
still.

## The shooter

A cylinder pillar with a **barrel** on its business end — no wider than the
pillar itself, just enough of a shape that it is obvious where the balls come
out. It reads as part of the pillar field rather than as a machine bolted onto
it, which matters because the field is also cover: a player should not have to
learn a separate silhouette to know which pillars are dangerous.

Authored with the `O` glyph, already parsed and collected by the loader. Shooters
sit **up-bridge of the field they feed**, so their output travels back down at
the party.

## Ejection: one source of variance, and it is the angle

Every ball leaves at the **same speed**. What changes is the **angle: up to 70
degrees off vertical**, in any direction.

Fixed speed is the deliberate half. It means every ball describes an arc of the
same size, so the field has a learnable rhythm — a player can watch one ball and
know roughly how far the next one goes. Randomising speed as well would make each
shot individually unreadable, and a hazard nobody can read is a tax rather than
an obstacle. The angle alone is enough to make the field never repeat.

**[open]** Whether the 70 degrees is a full cone (any azimuth) or a single plane.
A cone spreads across and along the bridge; confining it to the across-bridge
plane would give a purer left-right scatter that always lands at about the same
distance. Built as a cone with the plane a one-line change, because it is a
question for a playtest and not for a document.

## Balls are slow, and that is the point

Slow enough to be **dodged on sight**. The threat is not reaction time — it is
that a ball is still coming while you are trying to do something else, and that
the bridge is full of holes to be knocked into.

The whole bridge is pitched 4 degrees (see `bridge_grid.md`), so a ball that
lands anywhere rolls back down at the party under its own weight. Nothing has to
push it and no rule has to aim it — that pitch exists for this.

Pillars are cylinders precisely so balls ricochet smoothly off them rather than
jamming in a corner (see `scenes/stone.tscn`). A stuck ball is a dead ball.

## What a ball does to a player

**A dashing player bats it away.** Dash into a ball and it is deflected along the
dash axis, you take no damage, and **the dash keeps going** — unlike a dash into
a stone or a player, which ends on contact. That is deliberate: it gives the
shove a third job, turns the game's most committed action into a defensive one,
and rewards reading a ball early enough to commit to an axis.

**Otherwise it hits you.** Knockback along the ball's travel, straight into
`TUMBLE`, and one hit point.

**Unless it has run out of steam.** A ball must still be *closing on you* above a
minimum speed to count; below that it is an object you bumped into — it still
collides and gets in your way, it simply does nothing to you. *(Added 2026-08-08
after playtest: "very small ball taps feel too powerful". They were doing full
damage and a full tumble.)*

The speed measured is the **ball's** closing speed, not the relative speed. A
ball that has stopped is not made dangerous by you walking into it, and one
rolling away has already had its go.

This is not the glancing/solid split reintroduced. That was an invisible
threshold *inside* the dangerous range, where two hits that looked the same did
different things. This is the line where a ball stops being dangerous at all, and
it is legible from across the bridge: a ball trickling to a halt visibly has
nothing left. The threshold sits under the terminal roll speed, so any ball still
coming at you under the deck's pitch always hurts.

### This drops a distinction the design used to have

`game_concept.md` previously said a glancing hit shoves and a solid hit tumbles.
That is gone: **every ball that connects tumbles you.** One outcome instead of
two, which removes a threshold nobody would be able to see coming, and makes the
dash-deflect the only way to take a ball without consequence — so the interesting
choice is *do I commit to a dash*, not *was that hit hard enough*.

## Replication

**[open]**, and the roadmap already flags it: do balls need full authoritative
replication, or can clients simulate them from a shared seed?

The cheap answer is attractive and the risk is specific — a ball is exactly the
thing whose trajectory has to agree, because it does damage, and two machines
disagreeing about where a ball is means two machines disagreeing about who got
hit. Lean authoritative and **measure the bandwidth before optimising it**; a
ball is a position and a velocity, and there are not many in flight at once.

Whatever is chosen, the hit itself is resolved by the host, like every other
momentum transfer in this game.
