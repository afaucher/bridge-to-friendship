# M26 — The Race Track

A mode where the goal is a lap time rather than the other end of the bridge.

Players drive a bus around a closed circuit. Crossing the start line begins a
lap; every checkpoint must be touched in sequence; crossing the start line again
completes the lap and prints a time. The exit is where it always is, so a party
can leave whenever they like — or keep going round to beat their own time.

---

## The constraint, and how it turned out to be half wrong

**A loop cannot stream.** Every other mode in this game is a corridor: segments
stack along −Z, the run is extended ahead of the party and truncated behind
them, and a "level" is a window that moves. A circuit is the opposite shape — it
is bounded, it comes back on itself, and the ground behind you is the ground you
are about to drive over again.

The first version of this plan concluded that the race track must therefore be
**one section the run does not advance through**, and that `_extend_run`, the
leash and the round machine all had to learn that a run can be closed. Two of
those three turned out to be wrong, and it is worth writing down which.

**What was right: one circuit per round.** A party lapping one of five stacked
circuits is not racing a track, it is driving through five of them. But the fix
is not a shorter round — `SECTIONS_PER_ROUND` is a constant in 49 places where
it means BOTH "the run's cycle" and "how long a round is", and those are exactly
the two meanings that come apart the day they differ. The circuit **spans the
round's slots instead**: five consecutive slices of one computation laid into
five consecutive slots. Segments already stack into one continuous strip of
ground, so that is one circuit, and the seams are free because a slice boundary
is an ordinary row of the same grid.

**What was wrong: the run should still advance.** The brief that followed was
explicit — *players can exit the normal way but may want to continue to go
around the track to get better lap times*. So the circuit's far cap IS the exit,
driving through it ends the round like any other, and a party that wants a
better time simply does not take it. Nothing in the simulation special-cases
RACE, and nothing should: the forward exit is a feature, and the lap is the
reason to ignore it.

The leash and the trailing edge are unexamined rather than known-good. Both are
built on "the party's furthest progress up-bridge", which on a circuit means
something different from what it means on a bridge, and nobody has driven a full
party round one yet to find out how it feels.

---

## The track

**As wide as the canvas allows.** The grid canvas is 21 cells (42 m) and the
race track uses all of it, edge to edge — no setback, no rail. Widening the
canvas itself is a separate change with a long tail (CLAUDE.md records what the
15 → 21 bump cost), so "as wide as possible" means *all of what there is* rather
than *more than there is*.

**Built by the same generator pattern as the serpentine**: rolled bands, a
character per band, and a shape that is stated rather than discovered. Where
`bus_track` rolls lanes and links, `race_loop` rolls the four sides of a ring
and the width of each — so no two circuits have the same corners, and the
variety is a property of the roll rather than of noise.

The infield is **void, not deck**. That is the whole reason it reads as a
circuit rather than as a field with markings on it: there is an inside you can
fall into, the corners have consequences, and the ring is a route rather than a
suggestion.

### The oracle for a loop

`SegmentValidator` models a walking player crossing from entry to exit. That is
the right question for a corridor and the wrong one for a circuit — a loop is
"crossable" through either half of the ring and would validate while being a
perfectly broken racetrack.

The claim that actually matters is **the road encloses the infield**: a flood
fill from outside the canvas cannot reach the middle without crossing road. That
is an arithmetic fact rather than a tuned threshold, it fails loudly if a corner
is cut through, and it is the per-mode traversal oracle M25 said each mode would
eventually need.

---

## Laps

**Checkpoints are a sequence, not a set.** Crossing the start line arms the lap;
each subsequent checkpoint only counts if it is the next one; the start line
completes it. Out-of-order touches are ignored rather than penalised — the rule
exists so nobody can shortcut across the infield and call it a lap, and that is
all it needs to do.

Per player, not per bus. Four people in one bus post the same time, which is
fine and true; a passenger who steps off and boards another keeps their own.

The HUD shows the running lap, the last lap and the best.

---

## Buses

**A race track has to be able to give you another one.** On a corridor, losing
the bus is a setback you walk off. On a circuit it is the end of the mode: there
is nothing else to do there, and the party is standing in a ring.

Answered by a **bus post** — a post you dash, at the middle of every level with
buses in it, halfway being the furthest you can ever be from one. Nothing
replaces a bus automatically, and two versions that did were written and taken
out: a vehicle that reappears on its own has no cost, so driving into the void
stops being a mistake. A party that loses every bus at once walks to the post
together, which is the answer to the question this section used to end on.

## Phases

1. **The circuit.** `race_loop()` and the enclosure oracle. — *done*
2. **The mode.** A `RACE` entry, its pool table, and one circuit per round via
   slicing. — *done*
3. **Laps.** Checkpoint sequencing, per-player timing, the live clock and the
   best-lap display, and lap time as the first ranking key. — *done*
4. **The pit.** Bus supply. — *done*, as the bus post.

### What is left

Nothing structural, and one thing that needs a playtest rather than a plan:

- **The leash and the trailing edge on a circuit.** Both are built on furthest
  progress up-bridge. On a ring the party can be spread right around it while
  barely differing in Z, and nobody has driven a full party round one to see
  whether that reads as freedom or as a rubber band.
- **Whether a lap is worth driving.** The circuit is 44–56 rows, so a lap is
  roughly 25–30 seconds at speed. Fewer, longer laps or more, shorter ones is a
  feel question, and the generator's row range is the one dial.
