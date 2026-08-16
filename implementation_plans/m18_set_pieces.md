# M18 — set-pieces: the layer that makes variety combinatorial

Layer 2 of the three-layer model in `design_ideas/world_generation.md`. It was
described there in full and then never scheduled: phases 0–9 of M17 build layer 1
(the skeleton) and layer 3 (the dressing pass), and the middle one fell out of the
list. This is that milestone.

**Phase 7 of M17 (buttons and doors) is deferred behind this**, at the same time
and for a reason that is not just ordering: a button-and-door IS a composition —
the door in front of you, the button on the far side of a drop — and building it
as a scatter of two new content types would produce the thing layer 2 exists to
prevent. It wants a set-piece format to be authored into. Phase 7 gets cheaper by
waiting; this does not get cheaper by waiting for it.

---

## Why now, by the parent doc's own test

The rule M17 established for ordering is **count what the multiplier would
multiply, rather than reasoning about plumbing**. When the dressing pass was
scheduled, the count was four hazard types and three layouts, and two of the four
wanted themes could not be expressed at all.

The count today, all of it shipped:

| | |
|---|---|
| terrain | deck, hole, water, ramp, height profile, narrowing, split lanes |
| ways up | ramp, ladder, elevator, teammate boost, legs |
| ground | crumble, timed block |
| hazards | skirmisher, turret, rusher mound, plinko shooter, spikes |
| cover | tree, half wall |
| objects | pillar, bouncer, heart, hat, six specials |
| structure | gate rows, spawn, lobby |

That is the largest number this project has ever had to multiply, and it is why
the answer to "the generated runs are correct and dull" is now available. The
parent doc predicted both halves of that sentence:

> The oracle proves crossable; nothing proves interesting. Expect the first
> generated runs to be correct and dull, and expect the fix to be **more and
> better set-pieces rather than better parameters.**

Tuning the generator's numbers is the trap this milestone exists to avoid. No
distribution over gap density produces "a shooter on a pillar behind a gap with
cover halfway across". That is a *relationship*, and a relationship has to be
authored once and then reused.

---

## It is ADDITIVE. Nothing that works today stops working

Worth stating first, because it bounds the risk of the whole milestone: this adds
a way to author, it does not replace one.

| stays exactly as it is | why it is safe |
|---|---|
| whole-segment `.seg` files | `playtest_bridge`, `run_gaps`, `run_pillars` and the test fixtures are unchanged; a run still opens on the authored bridge |
| `SegmentPool.POOL` | the existing list of authored sections and `@section` / `@lobby` markers is untouched |
| the profile loop's flat / ramp / lift / drop branches | a piece is a FIFTH thing it can decide to do, beside them |
| the dressing pass | unchanged, plus one keep-out band — the same shape as the lift clearance rule |
| the oracle and the reroll | unchanged; a stamped section is validated by exactly the check that already runs |
| `SegmentData` | gains two OPTIONAL header fields; a file without them parses precisely as today |

Nothing scans `segments/`. `SegmentPool` lists paths explicitly and says why in
its own comment — "a DirAccess scan of res:// behaves differently in an export
than in a dev run" — which is the same reasoning the piece library follows, and
it also means **a new `.seg` in that folder cannot leak into play by existing.**
Pieces are inert until the profile loop is taught to reach for them, so Phase 0
ships with zero effect on the game.

**The one real behaviour change**, and it is worth knowing before it surprises
somebody: a new branch in the profile loop consumes the mixer differently, so
**existing seeds stop producing the terrain they produce today.** Nothing breaks
— every run is still a pure function of `(seed, count)` and still validated —
but a seed noted down as "the good one" is not the same bridge afterwards. That is
true of every generator change and was equally true when lifts landed; it is
called out here because this is the last cheap moment to decide the seeds matter.

## What a set-piece is

**A `.seg` file with a `piece` tag, 4–8 rows long, stamped into a generated
section.** Not a new format and not a new parser: `SegmentData` already reads
width, length, heights, kinds and contents, and `segments/*.seg` is already in the
export `include_filter` — which is the one line standing between this working in
the editor and failing only in the shipped build.

Two header fields are added:

- `piece_exit` — the height the piece leaves you at, relative to the height it was
  entered at. `0` for a flat composition, `+2` for one that is also a climb.
- `piece_min_party` — optional; the smallest party that can cross it. Absent means
  one. **Recorded, not enforced here**: `validate_run` already reports per party
  size and 2a-ii says solo-crossable is a policy the assembler applies, not an
  invariant the oracle bakes in. A two-player piece is a legitimate thing to
  author on the day rounds have a lose condition.

### Full width only, in this milestone

The parent doc allows "a 4–8 row full-width slice, **or** a smaller patch with a
declared footprint". Only the first is built here.

A sub-width patch needs an answer to "what is beside it", and both answers are
bad without more thought: deck beside it means the party walks around the
composition and it is scenery, and holes beside it means every patch is also a
forced gap. Full width has no such question and inherits the join contract that
already exists. **Patches are Phase 4 and may never be needed** — a full-width
slice that is 4 rows long is already a small unit.

A piece whose width does not match the run's is SKIPPED, not stretched. Stretching
a composition is how you get a shooter that no longer covers the gap it was
authored to cover.

---

## How it is placed: reserve, then stamp

The generator's profile loop walks rows and decides, per row, to climb, drop or
stay flat. Placement hooks in there rather than after it.

**Reserving comes first and stamping second**, which is the whole of the design:
when the loop decides to spend `N` rows on a piece, those rows belong to the
piece — it writes their heights, kinds and contents entirely. The alternative,
building a skeleton and overwriting part of it afterwards, leaves every cell with
two authors and no rule about which wins, and the first bug from it is a ramp
whose top row was eaten by a piece that starts flat.

The piece is stamped at the current plateau height and the loop continues from
`height + piece_exit`. That is exactly the contract the join between two segments
already uses, one level down, and it means a piece is just another thing the
profile can decide to do — alongside a ramp and a lift.

**And then the existing oracle runs.** `SegmentGen.section()` already generates,
validates and rerolls up to 24 times before falling back to flat deck. A stamped
piece needs no new safety net: if it produced an uncrossable section, that attempt
is rejected like any other. What it does need is the **log** — a run that quietly
dropped every piece it tried and shipped bare terrain looks exactly like a run
that was never asked to place one. No silent caps.

---

## The library is an ORDERED LIST IN CODE, not a directory scan

`const LIBRARY: Array[String]` in a `set_pieces.gd`, listing paths in a fixed
order — the same shape as `SegmentPool.POOL`, which already exists and already
carries this exact argument in its own comment.

This is not tidiness. The bridge is a pure function of `(seed, count)` and a
joining client is told two numbers and builds the identical world. Selection is
`_mix(seed + index * prime) % LIBRARY.size()`, so **the index of a piece in that
list is part of the wire protocol in everything but name.** A `DirAccess` listing
is ordered by the filesystem, which is not guaranteed to agree between two
machines, let alone between Windows and Linux — and the failure would be two
players walking through different level geometry with no error anywhere.

Same reasoning the hat and stone pools already carry for their ids, and the same
reason `HazardDressing` has a local mixer rather than touching the global RNG.

---

## Dressing must keep out

`dress()` never overwrites existing content, so a piece's own hazards are safe.
That is not enough: the pass will happily put a turret in the empty cell in the
middle of a composition, and the empty cells of a composition are *part of it* —
the lane you are meant to cross, the cover you are meant to reach.

**A piece's rows are a keep-out band for layer 3.** Same shape as the lift
clearance rule built in M17 phase 9, and for the same reason: the dressing budget
is spent without knowing what the skeleton is asking of the player there.

A piece that WANTS dressing can say so with a tag later. Start closed — an
authored composition with one extra hazard in it is a composition somebody else
edited.

---

## Phases

**Phase 0 — the format, the library, and the piece oracle.**
`piece_exit` and `piece_min_party` in the parser; `set_pieces.gd` with `LIBRARY`;
a test that walks the library and requires each piece to be crossable on its own
from entry row to exit row by the weakest party. **Two pieces authored**, so the
oracle has something to pass and Phase 1 has something to slot — one flat, one
that climbs. Nothing in the game uses them yet.

*The test needs both halves:* a deliberately broken piece must be REJECTED by the
same check, or "every piece is crossable" is satisfied by a check that passes
everything. This project has shipped that exact hole twice.

**Phase 1 — reserve and stamp.**
The profile loop spends rows on a piece; the existing reject-and-reroll covers
correctness; a log line says what was placed and what was dropped. Tests: pieces
appear across a seed sweep, sections still validate, and the run is identical for
the same seed on two builds.

*Watch for:* a piece reserved so late that its rows run past the section's exit
row. M17 paid for this once already with ramps climbing into the exit row and
being stamped flat — "a climb must finish with room to spare". The same margin
applies, and the same symptom (a composition leading nowhere) will look like a
piece bug rather than an off-by-one.

**Phase 2 — dressing keep-out.**
Layer 3 skips piece rows. Test: no generated content lands inside a piece's
footprint, over a seed sweep — **and the test must dress the sections first**,
because the assertion that nearly shipped in M17 phase 9 inspected undressed
output and could not fail at any sample size.

**Phase 3 — the library.**
Six to ten pieces, and this is where the milestone's value actually arrives; the
three phases above are the machine that multiplies them. Deliberately spread
across what M17 built rather than clustered on what is easy: a lift under fire
with cover on the platform side, a crumbling causeway over a gap, a ladder shaft
with a turret covering the top, a spike corridor with a heart past it, a plinko
funnel with two lanes, a rusher pit you are meant to run rather than fight.

**Phase 4 — deferred, possibly forever.** Sub-width patches; pieces that declare
requirements ("needs a gap in front", "needs a 3-unit cliff") so the generator can
match them to terrain rather than only reserving flat rows.

---

## What this does not decide

- **Whether the pieces are good.** The oracle proves crossable; nothing proves
  interesting, and that is as true one layer down. The difference from the
  generator is that a bad set-piece is fixed by editing a text file, which is the
  entire argument for the layer.
- **Weighting or difficulty.** Selection is uniform over the library. The pool
  has a `difficulty` field nothing reads yet, and it can stay that way until
  there are enough pieces for the question to be real.
- **How many pieces a section should hold.** Start at one, because a section is
  16 rows and a piece is 4–8 of them.
- **Whether phase 7 changes shape once this exists.** It probably does, and that
  is the point of deferring it rather than a cost of it.
