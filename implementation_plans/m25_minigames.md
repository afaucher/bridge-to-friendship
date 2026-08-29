# M25 — the lobby as a staging area, and a round as a minigame

**Status: planning.** Nothing here is built. Decisions taken in conversation are
marked **decided**; everything else is open and says so.

The idea: a lobby is not punctuation between five sections of bridge, it is a
**staging area** you leave in a chosen direction. Each minigame takes the place of
a normal round — the party walks out of the lobby onto the checker, and the new
game takes over until they arrive at the next lobby, where they are the little
dude again.

Two examples are used throughout to keep this honest, because a seam justified by
one example is a seam shaped like that example:

- **Bus mode.** The same base game with a completely different level layout. At
  the start the party boards an **open-top** bus: one player drives, the rest
  stand with their heads and guns above the rail, with unlimited ammo. Make it
  through the course. **If the bus is destroyed you land where you were standing
  on it.**
- **Sidescroller spaceship shooter.** Player ships take the accessories and colour
  from the player. Possibly the same art as the base game — flying down a corridor
  with blocks up the walls and the game's own enemies standing on them.

---

## Why this is affordable: a round is already an abstract corridor

`round_machine.gd` says it in its own header:

> WHAT THE PARTY IS ALWAYS IN is a CORRIDOR between two boundaries: `rear_row`,
> the strip they came through, and `target_row`, the strip they are heading for.
> [...] which is why there is no separate notion of "which segment am I in"
> anywhere in here.

Every rule in that file — both walls, both predicates, the scoring, the spawn
rules — is expressed against two integers obtained from `grid.gate_after()`. The
machine has **no idea what is between them**. So the whole lobby → RUNNING →
CLOSING → SCORING → LOBBY flow works unchanged whether the corridor contains a
bridge, a bus route, or a starfield.

`rank_entries` already carries a note from the milestone that built it: *"each
future game type gets its own, and the difference between 'a scorer per mode' and
a growing if-chain is decided now, while there is one."* That hook is waiting.

**This is the finding that makes M25 a seam rather than a rewrite**, and it should
be re-checked before building: if any rule has quietly grown a dependency on
segments since M16, that is the thing to fix first.

## What the two examples disagree about

Derived by asking what each needs that the base game does not. The intersection is
the mode interface; everything else is shared and must stay shared.

| | base | bus | shooter |
|---|---|---|---|
| terrain | sections | a route | a corridor |
| what you drive | your own legs | **one shared vehicle** | **one vehicle each** |
| roles | none | **driver / passengers** | none |
| gravity | yes | yes | **not on the pilot** |
| camera | bridge 45° | bridge 45° | **sidescroller** |
| stragglers | 30 s window | **meaningless: the bus arrives as one** | works as-is |
| ammo | scarce | **unlimited for passengers** | open |
| wipe | checkpoint | *(no rule — see below)* | open |

Seven axes. Everything else — the corridor, the bands, the win condition, hats,
colour, accessories, the scoreboard — is common, and the design is only worth
having if it stays that way.

## Decided

**Everybody goes to the next minigame together.** One corridor, one mode, one
party. This is the decision that keeps the whole thing linear: `rear_row` /
`target_row`, the leash, `_trailing_edge_z`, the checkpoint and the wipe all
assume one party moving up one bridge, and splitting would have broken every one
of them. It also makes the chosen mode **one entry per round** rather than one per
player.

**Anyone can select the next minigame, from a control.** Not a vote, not a
consensus: any player sets it, the last write wins, and social pressure does the
work a tie-break would. In a four-player co-op that is the right failure mode —
a vote can deadlock, and losing one means being dragged somewhere you did not
choose.

*(Superseded: an earlier proposal had each door opened by everyone standing at it,
reusing the gate band's own "all at or past" predicate. Recorded because it is
still the fallback if last-write-wins turns out to be abused in play.)*

## The transition, in three moments

### 1. Choosing — and the one thing that genuinely breaks

**The bridge is a pure function of `(seed, count)`.** `_extend_run_to.rpc(seed,
wanted)` is two integers and a joining client rebuilds the world from them. That
is the drop-in contract and most of the netcode rests on it.

**A player's choice is not a function of a seed.** So the plan becomes
`(seed, count, modes[])`, and that array must ride the same message — a client
that learns the count before the mode would build a corridor before knowing what
fills it.

The array is short (one entry per round) and changes rarely, so the cost is small.
But it is a real widening of the contract and should be built as one: the message,
the late-joiner path and the test all move together.

**The lookahead has to change.** `_extend_run` builds `RUN_LOOKAHEAD_SEGMENTS`
ahead of the party. With a mutable choice there is nothing to build ahead *of* —
the corridor past the lobby does not exist until somebody picks.

The answer is **speculative generation, invalidated on change**: build the
corridor when a mode is selected, throw it away and rebuild if the selection
changes. The party is standing in the lobby by definition while that happens, so
the rebuild is never seen.

It has a free bonus worth designing toward: **changing the selection visibly
changes what is down the bridge.** The front wall stands at the lobby's far band
during LOBBY, so how much can actually be seen past it is worth checking — if the
answer is "quite a lot", the selector needs no preview art at all.

### 2. Swapping — at the crossing, and NOT by swapping bodies

`_cross()` is already the single place LOBBY → RUNNING happens, and it is already
broadcast reliably on `_round_sync`. That is the seam, free.

The hazard is what you swap *to*. `capture_state()` is 21 PlayerBody fields and
the snapshot's player section is that shape; a ship is not.

**Recommendation: the avatar never changes.** Every minigame is *the little dude,
possibly attached to something that moves differently.*

- **Bus** — the party rides one vehicle.
- **Shooter** — each player rides their own.

Riding already exists: `platform_floor_layers`, the elevator, and the carrier
rules in CLAUDE.md. A vehicle becomes a new replicated object kind beside gunners
and deployables; the body is pinned to it and input is routed to the vehicle
rather than to the legs. Gravity stops mattering for a pinned rider because it is
not simulating itself.

This keeps `players`, `capture_state`, the snapshot and the round machine all
unchanged — and it is what the phrase *"you transition back to the little dude"*
implies: the dude is always underneath.

**THE OPEN-TOP BUS SETTLES THIS, and it is worth reading twice.** The passengers
are not seated in an abstraction, they are *standing on a moving platform with
their guns out* — which is a rider in the sense the engine already has, the sense
the elevator already uses. Three things fall out of it at once and none of them
needs building:

- **A passenger is just a player.** Standing, aiming, shooting, shoved by a
  contact. There is no passenger verb, no seat state, no second control scheme.
  "Unlimited ammo" is the only override in the whole mode.
- **There is no bus wipe rule.** The bus is destroyed, the thing you were standing
  on stops existing, and you fall from where you were standing. Falling, the ledge
  catch, `DOWNED`, the drone and the checkpoint all take over unchanged. *An open
  question that deletes itself is the best kind of answer to one.*
- **The bus is a moving platform with a driver**, not a vehicle system. The
  elevator is the same object, smaller and on one axis.

**AND IT NAMES THE MILESTONE'S REAL TECHNICAL RISK.** CLAUDE.md, on riding:

> Godot transports a rider on a moving body, one tick LATE. [...] we currently use
> the built-in (`platform_floor_layers`), with the caveat that it is
> engine-internal state `capture_state()` cannot restore — so watch
> `GameWorld.corrections` if riding ever happens during networked play.

Bus mode makes riding **the entire round, for the whole party, in multiplayer** —
precisely the case that note says has never been tested. Client prediction
rewinds by `apply_state()`, and the one piece of state that decides where a rider
ends up is not in the blob. If this breaks, it breaks as rubber-banding for every
passenger for the whole minigame.

It should be measured **before** phase 3 is designed, not during it: put a player
on the elevator over ENet, hold a direction, and watch `corrections`. That is an
afternoon, it needs nothing from this milestone, and the answer decides whether a
bus carries riders or carries *seated* bodies it positions itself.

The same note also warns that a carrier cannot walk while a body rests on it —
already solved for the elevator by dropping the players bit from the carrier's
mask for the duration of its own step, and `add_collision_exception_with` is
explicitly the wrong tool because it is mutual. A bus is that at four times the
size.

**The alternative is a real ship class**, which is what this project's own rule
would suggest (`gunner_body.gd`: *"when the second kind starts needing state the
first has no use for, it stopped being a configuration"*). Held in reserve: it
costs the wire format, and nothing has yet shown that a ship needs state a
seated body cannot carry.

### 3. Restoring — at the far band

Unseat, park in the lobby, be the little dude. The machinery that assumes walking
bodies is what needs auditing here: `_lobby_point`, `entry_spawn_cell`, the leash,
`_restart_at_checkpoint`.

**`CLOSING` is per-mode.** Thirty seconds for stragglers is nonsense with a shared
bus — one vehicle arrives, everyone arrives. So a mode answers "how does this
round end for the people who are not first".

## Managing the overlap

Everything above is about ONE minigame taking the place of a round. This section
is about the second, third and fourth — the difference between a mode system and
four copies of the game. It is ordered by *cheap now, brutal later*, which is the
only ordering that matters while there is still one mode.

### 1. A mode DECLARES its overrides; it must not write them

The most valuable rule to fix while it is free. If bus mode *writes* unlimited
ammo somewhere and the round ends without restoring it, the next round has
unlimited ammo.

**This project already has that hazard at test scale and keeps tripping on it.**
`test_gunners` must restore `turret_arc_deg`; `mg_spread_deg` had to be restored
in two separate files on 2026-08-22. Those are caught because a gate runs them
back to back and somebody reads the diff. A mode leaks *during play*, on one
machine, and nobody is watching.

So a mode declares `{ammo: unlimited, gravity: off}` and the world composes that
over the defaults. Leaving a mode is DROPPING the declaration, which cannot leak
because there is nothing to remember to undo. With one mode the two designs are
indistinguishable; with four, one is a migration.

**Where the composition lives is open.** `SimConfig` is a constants file and must
stay one — a mode that edits it is a mode that edits the next one.

### 2. Every subsystem x every mode is a grid, and the failure mode is SILENCE

Roughly twenty pools tick every frame: rushers, gunners, zombies, plinko, hats,
specials, deployables, stones, elevators, mounds, graves, merchants, the leash,
the checkpoint, the rescue drone.

In a spaceship shooter, what does the **rescue drone** do? What does a **hat** do?
What does the **merchant** do?

The dangerous answer is not "it errors". It is *"it quietly runs"* — hats posing
onto ships, a drone flying out to rescue a spaceship, a merchant standing in a
starfield waiting to be dashed into.

So **each mode owes every pool one of: runs / does not run / runs differently**,
and that list has to be explicit rather than implied by what happens to be wired
up. The test is what happens when somebody adds pool twenty-one: it should fail
loudly for every existing mode rather than silently joining them all.

This is CLAUDE.md's own lesson turned on the system: *adding a new kind of thing
re-aims every measurement that did not know there was more than one kind.* With
modes it runs both ways — a new mode must consider every subsystem, and a new
subsystem must consider every mode.

### 3. The base game is MODE ZERO, not the default

If "base" is the ABSENCE of a mode, every subsystem grows an implicit `if no mode,
do the old thing`, and modes become exceptions to a normal nobody wrote down.
Exceptions to an unwritten normal is how a system acquires four incompatible
special cases and no way to test any of them.

If base is a mode like any other, then **the mode machinery is exercised by the
thing that runs every day**, in every playtest and every gate. That is the only
version that stays working, and it is why phase 1 below is a mode that must look
like nothing happened.

Corollary, already decided: **the lobby is always base.** A broken mode can then
never strand the party somewhere they cannot choose again.

### 4. The traversal model is per-mode, and this one has teeth

`SegmentValidator._can_step` models a WALKING player: no step-up, a slope budget
on ramps, ladders behind a capability flag. A ship corridor validated by "can a
player walk this?" is nonsense.

**And it fails in the worst available way.** CLAUDE.md: *a rejection oracle
converts "wrong" into "absent"*. `SegmentGen.section()` rerolls up to 24 times and
falls back to flat, so a corridor the walking validator dislikes produces
**nothing, silently, forever** — and every assertion about that corridor passes
over an empty set. This project has already lost a day to exactly that shape on
split plateaus, and the tell was a PRESENCE counter, not a correctness one.

So any mode with a different body has to bring its own answer to "can this be
crossed", and the assertion that catches it is *"a corridor of this mode exists at
all"*.

### 5. Every test must name its mode

Every existing test builds a `GameWorld` and assumes base rules. The moment modes
exist they are all implicitly base-mode and none of them says so — and the day a
mode changes a default, they break *talking about something else*.

That is not hypothetical: when `MG_BULLET_SPEED` moved on 2026-08-22, three tests
failed with messages about hats and shields. A mode changing gravity or ammo would
do the same across twenty files at once.

One line in the harness now. Unrecoverable once there are a hundred tests and four
modes.

### 6. Stats and scoring need a per-mode home

`rank_entries` is already hooked and says so. The gap is a layer down:
`StatRegistry.STATS` is a flat dictionary and `superlatives` is computed across all
of it. "Most hats" is a base-game concept; bus mode's interesting number might be
"damage the bus took", and the shooter's might not involve hats at all.

Worth deciding before four modes have opinions: does a mode CONTRIBUTE stats to a
shared registry, or PICK from it? The badge limit and the superlative pass both
assume one population.

### What this changes about the phasing

Items 1, 3 and 5 belong in **phase 1**, even though phase 1 has nothing to look
at. They are each a small amount of structure now and a migration later, and phase
1 is the only moment when there is exactly one mode to convert.

Items 2 and 4 can wait for the second mode, PROVIDED the seam exists — a pool that
cannot be told "not in this mode" is a pool that will be rewritten. Item 6 can wait
for a mode with a genuinely different notion of winning.

## Phases

**Phase 1 — the seam, with nothing new to look at.** *(BUILT 2026-08-25.)*

`scripts/sim/game_mode.gd` is the registry; base is `MODES[0]`. `GameWorld` gained
`run_modes` (one entry per round), `current_mode()`, `tuned()` as the single
composition point, and `selected_mode` / `next_mode` polled only in a lobby.

**There is no control in phase 1, and the settings registry is why.** A debug knob
was written first — the shape `force_piece` has, as the plan suggested — and
`test_debug_settings` refused it: *every choice knob must offer at least two
options*. With one mode there is nothing to choose between, and the rule is right:
a control that cannot change anything cannot be tested either. So the selector is
a field the phase 2 control will write, and the lock/guard behaviour around it is
tested by driving that field directly. The wire
went from `(seed, count)` to `(seed, count, modes)` — same message, tolerant of a
caller that omits it, and the late-joiner path sends it too. `test_case.gd` gained
`test_mode` / `world_under_test()`, which is obligation 5 paid at one line.

**What was deliberately NOT built: discarding already-generated geometry when a
selection changes.** It cannot be exercised — there is one mode, so no choice can
ever differ from what the corridor was built for — and a teardown written now
would be an unreachable path that merely *looks* implemented: fifteen pools to
unwind (stones, shooters, hearts, mounds, graves, ladders, cover, elevators, the
height accumulator) with nothing able to prove any of it. `_rebuild_corridor_ahead`
re-plans the array, which is real and tested, and **refuses loudly** if a choice
ever lands on ground already built. **That is phase 2's first job**, and phase 2 is
the first moment a second mode exists to prove it.

Obligations 2 (subsystem × mode) and 4 (per-mode traversal) remain deferred to the
second mode as the plan says, and the seam they need — a pool that can be told
"not in this mode" — is `GameMode.policy()`, which exists and is asserted
exhaustively.

 A mode that is *exactly the
current game*, selected by a debug knob (the shape `force_piece` already has). It
must prove: choose → lock → generate → cross → restore, plus the widened drop-in
message and a late joiner arriving mid-mode. **If phase 1 shows any difference on
screen, it has failed.**

It also carries the three structural obligations from "managing the overlap",
because this is the only moment when there is exactly one mode to convert:
declarative overrides, base-as-mode-zero, and every test naming its mode. None of
them is visible; all of them are migrations if deferred.

**Phase 1b — the blank zone, and what it unblocks.** *(BUILT 2026-08-25.)* A
second mode, chosen because what the bus and the shooter both need is not a rule
about hazards but that **a mode generates its own ground** — a bus wants a route,
a shooter wants a corridor, and neither is `section()` with knobs on. A flat empty
zone is the smallest honest instance of that seam.

`GameMode` entries now declare `terrain`, and `BridgeGrid` calls the generator
they name. Eleven pools are declared `off`, which is the first time the
subsystem × mode grid has had two rows and therefore the first time it could be
wrong — with one row every entry agreed with every other by construction.

**Two things the A/B found that the first draft had wrong:**

- **The terrain claim was testing the generator, not the caller.** With
  `GameMode.terrain()` hardwired to the ordinary bridge the file still passed,
  because every assertion called `SegmentGen.blank_zone()` by hand. The seam is
  the *caller*. Fixed by building a real two-round run and asserting round 1 is
  blank while round 0 is not — so the builder is switching rather than configured.
- **A mode did not own its authored slots.** `plan()` fills some slots with pool
  FILES, which went straight to `load_segment_file` without asking the mode — so a
  blank round came out 3 sections of 5, with two authored maps full of hazards in
  the middle of a zone defined by having nothing in it. That would have read as the
  mode intermittently failing. A mode with its own terrain now owns every non-lobby
  slot. The general shape is the recorded one: adding a kind re-aims every rule
  that did not know there was more than one kind, and here the older kind is *"a
  slot can be a file"*, which predates modes entirely.

**Now unblocked:** the corridor teardown (a choice can finally differ from what
was built) and phase 2's control (a choice now has two options). Still waiting on
a mode with a different BODY: per-mode traversal (obligation 4) and per-mode stats
(obligation 6).

**Phase 2 — the control.** *(BUILT 2026-08-25, with the teardown.)* The in-world
selector. `merchant_body.gd` was the precedent and most of the answer, exactly as
predicted: a grid-resident thing you walk up to and dash into.

`scripts/sim/mode_post.gd` is a static body on layer 11, built in code, carrying a
banner whose colour is the chosen mode. `resolve_shove_contact` dispatches on
`has_method("can_select")` the same way it does on `can_trade`. One per lobby and
none in a section — being in a lobby is what makes it safe to be dashable at all,
since the corridor past it is speculative and nobody is standing on the ground a
change re-cuts. Last write wins, no vote, as decided.

**The teardown that phase 1 deferred is built with it**, because a control without
one is a control that lies. `BridgeGrid.truncate_run` sweeps rather than
enumerates: nodes are freed **by position** (every prop kind has its own root) and
cell keys **by reflection** over the grid's own properties — so a container added
next month is swept next month. Roughly thirty containers accumulate per segment
and a hand-written removal that missed one would leave a key pointing at a freed
node, which fails minutes later somewhere else.

**And the line the teardown draws is not "everything in the world".** It is
between what belongs to the LEVEL — rushers, gunners, zombies, balls, put there by
the ground they stand on — and what belongs to the PARTY: players, hats, specials.
A hat is the score of this game and there is no undo for one, so a mode change
that ate a hat lying past the cut would be unrecoverable and would read as a bug
rather than a rule. Both halves are asserted.

**Three bugs the tests found, all off-by-a-round or off-by-a-layer:**

- **The cut was a whole round wide.** `round_index` increments on *entering* a
  lobby, so a party in a lobby is in round N choosing round N's own sections. The
  first version kept "through round N", which kept the very ground the choice was
  about — the choice appeared to be taken up and changed nothing.
- **A mode did not own its authored slots** (see phase 1b).
- **A dash test that could not fail.** It called `begin_shove`, which does not
  exist; the raise aborted the phase and every assertion below it silently never
  ran while the file reported PASS. Driven through `ACTION_SHOVE` now.

**Phase 3 — the bus.** A large moving platform, one player's input steering it,
an ammo override, and a per-mode straggler rule. Much smaller than it first looked
— see the open-top note above, which retires seats, roles-as-state and the wipe
rule all at once.

**Its prerequisite is a measurement, not a feature:** does a predicted client
riding a moving platform over ENet stay put? Do that first and alone.

**Phase 4 — the shooter.** A mode-owned camera, which the camera being view-only
should make cheap.

## Open

- **Does prediction survive riding?** The milestone's biggest technical unknown,
  and the only one that could change the shape of the bus. Measurable today
  against the elevator — see phase 3.
- **Where a declared override is composed.** `SimConfig` is a constants file and
  has to stay one, so "unlimited ammo for this round" needs somewhere to live that
  is neither a constant nor a global write. See overlap item 1.
- **Whether a mode contributes stats or picks them.** See overlap item 6.
- **`SegmentPool.is_lobby_slot(i)` is `i % 6 == 0`,** a fixed cycle. The moment a
  mode declares its own length that arithmetic is wrong, and every caller needs
  finding. Small, load-bearing, easy to miss.
- **Does a mode get to change the width?** The canvas is 21 and M22's whole
  profile system assumes a bridge. A corridor for ships may want something else,
  and `_check_gates` and the join contract are expressed in those terms.
