# M26 — The Race Track

A mode where the goal is a lap time rather than the other end of the bridge.

Players drive a bus around a closed circuit. Crossing the start line begins a
lap; every checkpoint must be touched in sequence; crossing the start line again
completes the lap and prints a time. The exit is where it always is, so a party
can leave whenever they like — or keep going round to beat their own time.

---

## The constraint everything else follows from

**A loop cannot stream.** Every other mode in this game is a corridor: segments
stack along −Z, the run is extended ahead of the party and truncated behind
them, and a "level" is a window that moves. A circuit is the opposite shape —
it is bounded, it comes back on itself, and the ground behind you is the ground
you are about to drive over again.

So the race track is **one section that the run does not advance through**. Not
a sequence of sections that happens to bend; a single arena, generated once,
with the party inside it for as long as they want to be. That is also what the
brief means by *"the mode isn't a race to the next lobby"* — it is not a pacing
note, it is a statement about topology.

Three consequences, all of which are work:

- **The corridor must not extend.** `_extend_run` keeps segments ahead of the
  front; on a circuit the front goes round and comes back, and left alone the
  generator would build kilometres of bridge nobody is on. The mode has to
  declare that its run is closed.
- **The leash and the trailing edge mean something different.** Both are built
  on "the party's furthest progress up-bridge", which on a loop is not progress.
- **The round machine's win condition does not apply.** There is no gate to
  reach. Leaving is a choice the party makes, not an event the machine detects.

None of that is exotic, but none of it is free either, and it is why this is a
milestone rather than another lane flavour.

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

The blank zone's rule — one bus, rebuilt when none exists — is not enough on its
own, because it puts the replacement ahead of the party and the party is going
round in a circle. A race track wants a **pit**: a known place on the ring where
a bus is always available, so losing one costs a walk back rather than the mode.

---

## Phases

1. **The circuit.** `race_loop()` and the enclosure oracle. Nothing drives on it
   yet; the deliverable is a picture and a test.
2. **The mode.** A `RACE` entry, its pool table, and the run that does not
   advance. Drivable, no timing.
3. **Laps.** Checkpoint sequencing, per-player timing, and the HUD.
4. **The pit.** Bus supply, and what happens when everybody loses one at once.

Phase 1 is what this plan ships with. The rest are named here so the shape is
visible, not because they are decided.
