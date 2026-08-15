# Roadmap

Written 2026-08-08. The MVP is **M1–M10**; it is finished when every criterion
in `design_ideas/mvp_success_criteria.md` is met. Each milestone below says what
it *proves*, because a milestone that cannot fail has not been specified.

Ordering principle: **the riskiest unknown first.** The two unknowns that could
sink this project are (a) whether host-authoritative simulation of ropes and
momentum transfer is tractable, and (b) whether shove-plus-rope between two
players is actually fun. Both are answerable in a bare test room, before a
single metre of bridge exists — which is why content authoring is M10 and not
M1. Building levels for verbs that do not feel good yet is the expensive
mistake available here.

---

## M1 — Authoritative simulation core — **DONE (2026-08-08)**

**Proves:** two machines agree about a shared physics world.

Shipped: `scripts/sim/` (config, input, player body, game world),
`scripts/test_support/net_harness.gd`, the gym, and four new tests. Measured at
the end: **1 correction over 240 ticks under 133 ms of injected latency**, i.e.
prediction is right essentially always and B2's "no visible snap" holds with the
worst single-tick displacement at the budget's edge rather than over it.

Three things it cost that are now in `CLAUDE.md`: two perfectly coincident
bodies fall through the floor; `is_on_floor()` is derived state that survives a
rewind; and a readiness check that only runs in an event handler never runs
again.

Retires M0's client-authoritative movement, which
`design_ideas/physics_and_authority.md` establishes cannot survive this design.
Clients send input; the host simulates; clients predict their own walking and
reconcile. Introduces the custom integrator (explicit velocity, our own
collision response, `move_and_slide` for sweeping) and the player state machine
with `WALK` implemented and the rest stubbed.

Also delivers the **gym**: a flat test room with a few stones and two players.
Everything through M5 is developed and playtested there.

Exit: B1, B2.

## M2 — Bridge grid and segment loader — **DONE (2026-08-08)**

**Proves:** a text file becomes a bridge you can walk on.

Shipped: `scripts/grid/` (config, parser, validator, builder, runtime grid), the
`.seg` format, `segments/test_flat.seg` and `segments/test_ascent.seg`, and two
tests. Deck cells merge along X into runs (a 30x14 segment is 420 cells and far
fewer boxes). The validator runs the reachability flood twice — once with a solo
budget, once with an assisted one — so "no way up" and "a solo player is
stranded" are the same check with different numbers.

Two design corrections came out of building it, both now in `bridge_grid.md`:
**interior holes carry no parapet** (railing them made it impossible to ever
shove a stone through one, which the design calls out as the reward for
rearranging the bridge), and **the whole bridge is pitched 4 degrees** so loose
plinko balls roll back down at the players under their own weight rather than
needing a rule.

The cell model, heights, derived walls, holes, water and ramp geometry, pillar
stones as grid-resident data. The `.seg` ASCII format and its loader. The grid
is authoritative data; the scene is a view built from it.

Ships a handful of throwaway test segments — **not** designed content. Real
authoring is M10.

Exit: C1, C2, and the grid half of A4 (`max_walk_slope` is enforced).

## M3 — Bodies interacting: shove and riding — **DONE (2026-08-08)**

**Proves:** the signature verb feels good and resolves legibly, and bodies stack.

Shipped: the compass-locked dash with its momentum-transfer table, one-cell stone
pushing (including into a hole), dashing off the deck, and riding. Two tests.

Riding uses **Godot's built-in moving-platform transport**, not the explicit
`ride()` this milestone was scoped around — less code, at the cost of being one
tick stale and of living in engine state a reconciliation replay cannot restore.
`ride()` remains on the bodies, unused, so swapping back is a small edit. The
half Godot does *not* solve is a carrier being blocked by its own rider, which
the step loop handles by masking.

**Jump was removed here.** Space is the dash. A jump would quietly solve
obstacles that are meant to need a second player, which would undercut the
ascender grades the whole level design rests on.

Still open, deliberately: a rider cannot presently be shoved off its carrier, and
the fixed-yaw camera is not built (nothing renders yet).

Direction lock, dash, the momentum transfer table, stone pushing (exactly one
cell), leaving the deck. Fixed-yaw camera lands here, since the compass is
unusable without it.

Also **riding**: anything standing on another sim body is carried by it — stand
on a player and they carry you; an enemy landing on you gets carried by you. It
sits here rather than in M1 because it is a gameplay rule about bodies
interacting, which is what this milestone is. Godot does not provide it for
`CharacterBody3D` on `CharacterBody3D`; it needs an explicit carrier probe and a
carriers-before-riders step order. See `design_ideas/physics_and_authority.md`.

Exit: B3, B3b.

## BUILD ORDER: M5 BEFORE M4 (decided 2026-08-08)

The numbering stays as it is — the exit criteria reference it — but **M5 is
built first.**

The reason is the question "how does a yank get anyone up anything?". It does
not, on its own: a yank is a horizontal tug, and a player dragged into the side
of a 2 m step just slams into it. The rope only lifts someone because the
someone is **hanging from a ledge** and gets pulled up and over it — the vertical
component comes from the geometry of pulling toward a friend who is already up
there, not from the rope pulling upward.

So the ledge mechanic is the prerequisite, not the payoff. Building M4 first
would mean building a yank with nothing to yank anyone onto, then rebuilding it.

The cost is real and worth naming: the first genuinely playtestable co-op moment
moves later, and that moment is the roadmap's own stated riskiest unknown. M5's
practice-partner support (already shipped) is the mitigation — tumble, ledges and
the drone return can all be felt solo before the rope arrives.

## M5 — Damage, tumble, ledge grab and return — **DONE (2026-08-08)**

Shipped: health with a grace window, TUMBLE as a bouncing pinwheel, the automatic
ledge catch, DOWNED with proximity revive, the shared rescue countdown, the drone
return, and hearts as exclusive pickups. One test (`test_rescue`) walks the whole
failure-and-rescue loop.

**A shove now tumbles its target.** A dash arrives at 56 m/s, which is not a
nudge — so M3's shove is M5's first real damage-adjacent source, and the whole
loop is playable solo with practice partners: shove a partner into a gap, watch
them catch the lip, and mantle them out.

The `mantle()` primitive ships unused. Nothing can pull a hanging player yet;
that is precisely what M4 supplies, and it is the reason M5 went first.


**Proves:** failure is a setback with a rescue window, not a wall.

Hit points, the grace window, hearts as exclusive pickups, the ledge grab and its
bleed-out, the downed state, and the drone return.

**TUMBLE is a pinwheel, not a slide.** A hard hit throws a chaotic, bouncing body
that KEEPS its momentum — on a bridge full of holes the threat is displacement,
not damage, and a tumble that decelerates politely is not a threat at all.

**One rescue mechanism, two states.** `LEDGE_HANG` (caught a lip) and `DOWNED`
(out of health, decided 2026-08-08) are the same thing wearing different hats:
immobile, no verbs, a countdown, a teammate who can end it early, and the drone
if nobody does. Build the timer, the rescue hook and the drone hand-off once.
Two near-identical implementations would drift apart, and every rule that applies
to one applies to the other.

Revive is by **proximity**, not by rope — M5 ships first and there is no rope
yet, and a downed player whose only rescue needed a mechanic that does not exist
would be unrescuable. M4 later adds the better version: dragging a downed friend
somewhere it is actually safe to stand still.

The **ledge catch is automatic** (decided 2026-08-08): it fires most often while
the player is mid-tumble with no control, so a prompt they cannot answer would
read as the game cheating.

Ships the **ledge primitive** the rope depends on: a player near a lip catches
it and hangs; a hanging player cannot mantle unaided; a hanging player being
pulled can. M4 then supplies the pull and nothing else.

Exit: B5, B6, B7, B8.

## M4 — Rope — **DEFERRED (2026-08-08)**

**Deferred until there is a better solution for the rope**, by decision, not by
oversight. The design in `rope.md` settles what the rope *does* — soft simulated
shape, one authoritative force rule at the endpoints, and a yank that lifts
nobody by itself — but not yet how to build a particle chain that feels good
without being fragile. Building it half-convinced would be the expensive mistake.

What that costs, named plainly: **the co-op premise is still unproven.** A1 and
A3 — two strangers discovering the ramp solution, and the group laughing at an
outcome nobody chose — are the exit criteria most of the milestone set does not
address, and the rope is what was meant to address them. Everything downstream of
here is content and pressure on a loop whose central verb is missing.

The consolation is that M5 shipped the half that does not need it: a player can
be shoved into a gap, catch the lip, hang, and be mantled out. `mantle()` exists
and works; nothing calls it. M4 supplies the pull and nothing else.

**Proves (when built):** the game is cooperative rather than parallel.

A real soft simulated rope — a particle chain that drapes and swings — with grab
targeting, player-to-player tie, and the yank. Full design in
`design_ideas/rope.md`; the load-bearing idea is that **the rope's SHAPE is
cosmetic and simulated on every machine, while the rope's FORCE is one
authoritative rule at the endpoints.** That is what makes a simulated rope
affordable in a game with rewind-and-replay: the chain is never in
`capture_state()`, never in a snapshot, and never replayed.

There is no `SWING` state. A tumbling player on a taut rope swings because that
is what a body on a line does; it falls out of the constraint.

**This is the first playtestable moment of the whole co-op premise** — two
players, a ledge, a rope, and a friend hauling you back up. If A1 and A3 are
going to fail, they fail here. Playtest before starting M6.

Exit: B4, B4b, and the co-op half of A4.

## M6 — Plinko — **DONE (2026-08-08)**

**Proves:** there is a reason to keep moving.

Shipped: the shooter (a pillar with a barrel, scenery built by the grid), balls
simulated by the world, the launch cone, ricochet, the dash-deflect, and hit
resolution. `test_plinko` covers all four claims.

**Balls are fully authoritative and never predicted**, and the roadmap's open
question is answered that way on purpose: a ball is exactly the thing whose
trajectory must agree, because two machines disagreeing about where it is means
two machines disagreeing about who got hit. Clients rebuild their ball set from
the snapshot, so a dropped packet costs a frame of staleness rather than a ball
that exists forever on one machine.

**Health stopped being decorative here.** Plinko is the first real damage source,
so M5's bar, grace window, downed state and hearts all began doing something.


Full design in `design_ideas/plinko.md`. In short:

- **The shooter** is a cylinder pillar with a barrel on its business end, no
  wider than the pillar, authored with the `O` glyph (already parsed and
  collected). It sits up-bridge of the field it feeds.
- **Ejection varies the ANGLE and nothing else** — same speed every time, up to
  70 degrees off vertical. Fixed speed means every arc is the same size, so the
  field has a learnable rhythm; randomising speed too would make each shot
  individually unreadable, and an unreadable hazard is a tax rather than an
  obstacle.
- **Balls are slow and dodgeable on sight.** The bridge's 4-degree pitch is what
  brings them back down at the party; nothing has to aim them.
- **A dashing player bats a ball away** and takes nothing, and the dash keeps
  going — unlike a dash into a stone or a player, which ends on contact. It gives
  the shove a third job and turns the most committed action into a defensive one.
- **Any other contact is knockback, TUMBLE and one hit point.** This drops the
  old glancing-shoves / solid-tumbles split: one outcome, no invisible threshold.

Also the milestone where health stops being decorative — plinko is the first
real damage source in the game, so M5's bar, grace window, downed state and
hearts all start doing something.

Answers the open question of whether balls need full authoritative replication or
can be client-simulated from a seed. Lean authoritative: a ball is exactly the
thing whose trajectory must agree, because two machines disagreeing about where
it is means two machines disagreeing about who got hit.

Exit: C5.

## M7 — Water

**Proves:** terrain can threaten without an obstacle in it.

Lateral flow force, impaired movement, wash-away for a player who stops making
headway.

Exit: C4.

## M8 — Session: lobby, drop-in, checkpoints, leash — **MOSTLY DONE (2026-08-08)**

**Proves:** friends can actually get into a game together and stay there.

Shipped: the segment pool and its deterministic assembler, segment stacking,
lazy run extension, checkpoint banking, the wipe-and-restart, the soft leash, and
the drop-in handshake. `test_run_session` covers D2, D3 and D4.

**The load-bearing idea: the bridge is a pure function of (seed, segment
count).** A joining client is told two numbers and builds the identical bridge
locally; everything after that is a diff of what has moved. Sending the world
instead would put D2's five-second budget out of reach. Two consequences fell
straight out of it:

- **A client must not build eagerly.** It has no seed until told, `build_run`
  only ever appends, and segments built from the wrong seed would survive being
  told the right one. The bridges then differ for the rest of the session.
- **The assembler must not touch the global RNG**, which is seeded once per
  launch and consumed by everything else. A run planned from it would differ
  between two machines that had drawn a different number of randoms beforehand.

**Bandwidth.** Sending every stone every tick measured 4582 bytes on a
three-segment run — over ENet's 1392-byte MTU, which fragments an *unreliable*
packet on the channel that can least afford it. Now only moving stones go each
tick, and a compact cell-only layout resyncs twice a second; a settled stone's
position is derivable from its cell, so full state was sending the same fact
twice in an expensive format.

**Still open, and deliberately:**

- **D1 cannot be gate-tested** — two players over a Steam lobby needs a Steam
  client, which CI does not have. ENet proves the replication; Steam is the
  transport swap, and that is exactly why `NetworkManager` has two. It needs a
  manual two-machine check before this milestone is called finished.
- **The lobby browser is still "join the first lobby found"**, with the `TODO`
  it shipped with in M0.
- **Nothing unloads behind the party.** The run extends ahead lazily, which is
  the half that makes it endless; unloading is the half that makes it cheap, and
  it is riskier — a straggler unloaded out from under themselves is a fall out of
  the world. The leash is what makes it safe to attempt.

Exit: D2, D3, D4 met. D1 outstanding.

## M8.5 — Hats — **proposed, not agreed**

**Proves:** there is a reason to take a risk you did not have to take.

Stackable hats worn on the head, dislodged as a whole stack by a tumble, picked
up by walking over a loose one, and banked for points at each checkpoint. Loose
hats are authored content (a new `^` glyph).

The real deliverable is **the carried-item channel** — carried, contested,
droppable state that belongs to a player and is in neither `capture_state()` nor
the grid. Hearts and specials are its next two clients, so building it as
hats-only reopens this milestone twice.

Aimed squarely at A2 and A3, the two exit criteria the rest of the milestone set
addresses least directly.

**Scoring is deferred by decision** (2026-08-08) and severed from the rest of the
milestone: hats are complete and playable without it. `game_concept.md` records
the intent and leaves the answer open; all M8 owes it is a *shape* — an
extensible per-player bank record and a hook, not a distance integer.

That leaves `TUMBLE` (M5) as the only hard dependency, so this could run as early
as M5.5. It sits at M8.5 because it should precede M9, which is where the hat
count gets drawn.

Full scoping: `implementation_plans/m8_5_hats.md`.

## M9 — HUD — **DONE (2026-08-08)**

**Proves:** players can read their own and each other's state — and that *we* can
read it during a playtest.

Shipped: `hud_model.gd`, `hud.gd`, player names, and a simulation fix. Own health
as pips, the grace window as a flash on them, and three action slots top-left;
friends' name, health, state, bleed-out and rescue top-right. Four new tests.

**The split that makes a HUD gateable:** `hud_model.gd` is a pure function from
world state to a plain dictionary and holds every decision — which countdown
applies, how full each bar is, who is a friend, what order they come in.
`hud.gd` draws it and decides nothing. Same data/view split as the grid. It is
also the extension point: a rope slot, a hat count and a special are new fields,
not new layout.

**Scoping it found two things the code did not have.** `rescue_progress` was
host-only — missing from `capture_state()`, so the "a teammate is pulling you up"
bar existed on exactly one machine in the session and every client showed an
empty bar with no error. And there were no player names anywhere. Names became
**world state on the world's own multiplayer**, not `NetworkManager` RPCs: the
net harness roots each world at its own `SceneMultiplayer`, so an autoload RPC
would travel over the default peerless API and no test could ever reach it.

`test_hud_rescue_visible` was checked against the bug it exists for — reverting
the one-field fix makes it report `rescue bar at 0.00` against a host reading
0.333. It asserts the *transition* (empty while nobody helps, moving once someone
does) precisely so it cannot pass against a stubbed constant.

Two costs now in `CLAUDE.md`: never assert a display name (a dev box has Steam
and the gate does not), and headless builds the whole Control tree — so a UI
script nothing instantiates ships having never executed.

Full write-up: `implementation_plans/m9_hud.md`.

Exit: D5.

## M10 — Level design

**Proves:** the game has content, and making more of it is cheap.

Three distinct pieces of work, and the milestone is not done until all three
land:

1. **Tooling.** Whatever makes authoring fast: a validator that rejects a broken
   segment with a useful message, a way to load a single segment directly for
   iteration, and a live reload. E3 (a segment in under an hour) is the bar.
2. **The pool.** At least 12 segments covering every structural idea, more than
   one per idea so the assembler has real choices. Tagged and difficulty-rated.
3. **The curve.** How the assembler escalates with distance — segment
   difficulty, plinko density, heart scarcity — and where checkpoints fall.

Deliberately last, because a segment authored against verbs that later change is
a segment authored twice. It is also the milestone most likely to send work back
upstream: content is where a movement rule that seemed fine in the gym turns out
to be unusable on a real bridge, so expect M10 to reopen M3–M7.

Exit: A1, A2, A3, C3, C6, E1, E2, E3.

---

# Post-MVP

## MR — Rushers — **DONE (2026-08-08)**

Built out of order, ahead of M10 and M11, on request. Full design in
`design_ideas/hazards.md`; it was already settled there, so this was a build and
not a decision.

The first **destructible** hazard, which is the point of it. Everything hostile
before this was deflectable — a ball is batted away, a stone is pushed a cell, a
player is launched — so nothing could be *removed*, and that made the ranged
specials weak by construction: a shotgun was a shove you could do from further
away, and the shove is free. **M12 now has a threat the base verbs can only
postpone**, which is what earns that whole category its slot.

Shipped: mound glyph `m` and its validator rule, `rusher_body.gd` (RISE →
CHASE → STAGGER), proximity wake with a spent-once mound, line-of-sight gating,
contact tumble that expends the rusher, dash-deflect, the burrow timer, snapshot
replication with monotonic host-assigned ids, and eight mounds in the playtest
map. `test_rusher` covers all seven claims.

**Line of sight was added during the build** and is the one design change: a
straight-line chaser without it grinds into the near face of a pillar for its
whole lifetime. See the hazards doc for what it costs and what it buys.

**Still open, and both are playtest questions.** Whether a 56 m/s dash ought to
kill outright rather than stagger — specified as stagger, to keep the
destructible/deflectable split clean. And whether eight mounds on one map is too
many; the density is a guess and the cap (`RUSHER_MAX`) is a backstop, not a
tuning knob.

**Not built: any way to kill one.** That is M12's job, and until it exists the
only answers are the dash, the burrow timer, and walking one off a ledge.

## M11 — Bus mode

Rare and long: roughly one bus stretch every 8–12 foot segments, each running 8
or more segments, because the bus covers ground several times faster and a
short one is over before it registers as an act.

Needs the player state machine's `BUS_DRIVER` / `BUS_RIDER` states (reserved in
M1), road-surfaced segments (the grid already supports them), a vehicle in the
authoritative sim, and the seat-rotation `switch` that tells nobody it happened.

## M12 — Specials

**Partly shipped 2026-08-13: the MACHINE GUN, and the slot itself.** See
`implementation_plans/m12_machine_gun.md`. Asked for in playtest by name; it is a
new roster entry between the shotgun and the rifle, defined by cadence rather
than reach.

Shipped with it, and shared by everything that follows: `special_body.gd` /
`special_pool.gd` (the carried-item channel's second client), the one-slot rule
with swap-and-drop, the already-declared `*` glyph wired up at last with a
validator rule, `ACTION_SPECIAL_HELD`, M9's reserved HUD slot filled with kind and
ammo for self and friends, host-assigned monotonic ids, reliable ownership over an
unreliable position snapshot, and drop-in sync of who is holding what.
`test_special_pickup` and `test_machine_gun` cover nine claims between them; the
three load-bearing ones were each checked by reverting the fix.

**Two findings worth carrying forward.** `ACTION_SPECIAL_HELD` is a *separate*
level-triggered bit rather than a change to `ACTION_SPECIAL`, so the
edge-triggered invariant legs still need was not quietly spent on a weapon. And
`test_special_pickup`'s fall assertion passed without the fall rule until a second
player was stood safely on the deck — a solo player leaving the world is a wipe,
and a wipe clears every special anyway. Identical to the trap `test_hat_tumble`
hit; it is now two for two, so assume it for the third.

Still to build: shotguns, swords, thrown bombs, anchoring shields, **legs**.

**Build legs first of what remains**, even though it reads as the simplest,
because it is the one that decides the shape of the whole system. The machine gun
deliberately did not answer its question: nothing about a gun affects stepping, so
`capture_state()` is untouched and the legs decision is exactly as open as it was.

The other four are committed actions: press, and the host resolves what happened.
They need no prediction, for exactly the reason a shove needs none — the player
has no control over the outcome, so there is nothing to mispredict. Legs are the
opposite. They modify ordinary walking, the player keeps air control, and a jump
that arrives 80 ms late feels broken in a way an unsteerable dash never does. So
legs must be **client-predicted**, which drags the charge count onto the
reconciliation path: whether tick N produces a jump depends on how many charges
are left.

That splits a special's state in two, and the split is the finding:

- **The part that affects stepping** — charges remaining, mid-jump flags — goes
  in `PlayerBody.capture_state()`. Not an exception to the hats milestone's "keep
  items out of the blob" rule but the same rule read correctly: `CLAUDE.md` says
  anything affecting stepping must be in `capture_state()` or replays diverge,
  and hats were excluded because hats *do nothing*.
- **The part that does not** — which special you are holding, its style, who
  dropped it where — is the M8.5 carried-item channel, reliable and unpredicted.

Design consequences of legs are settled in `game_concept.md` §Special: 2 m of
rise (one layer, so a solo player can get themselves up); a shortcut and never an
ascender, so `SegmentValidator`'s two rise budgets are untouched; and the failure
mode to watch is legs being *common*, not legs being *strong*.

`ACTION_SPECIAL` must stay edge-triggered for exactly one tick, or a
reconciliation replay re-fires the jump and burns the charges — the trap
`player_input.gd` already documents for shove.

`sim_config.gd`'s "THERE IS NO JUMP" note asks that nobody restore a jump without
deciding what it does to the ascender grades. That decision is now made and
recorded; update the comment to point at it when this milestone lands.

## M13 — Netcode: make a distant client playable

**Added 2026-08-13** from the first coast-to-coast playtest, which was reported
as "the client's experience was pretty poor". Audit in
`design_ideas/netcode_assessment.md`, plan in `implementation_plans/m13_netcode.md`.

The authority model is right and does not change. What is missing is the layer it
assumed: **no interpolation anywhere**, the client never reads the host tick the
snapshot already carries, `SHOVE` is unpredicted so the signature verb has a full
round trip of dead air, a busy snapshot is **2.5× ENet's MTU at 60 Hz** (measured:
3484 B, 204 KB/s per client), and the host's input queue can only grow.

Ordered so the two a player would notice come first: an interpolation buffer,
then predicting the start of a shove, then the bandwidth work — halve the
cadence, stop sending fields nobody reads (~30% by deletion alone), pack the wire
(4.7× smaller, and under one MTU, which ends fragmentation).

**The harness comes first and is the real prerequisite.** Every item is
unfalsifiable without a rig that delays, jitters, drops and reorders *both*
directions and asserts what a client SEES.

## M14 — The debug console — **DONE (2026-08-14)**

**Added 2026-08-13**, asked for in the same playtest:
`implementation_plans/m14_debug_console.md`.

A big replicated config any player can tweak and everyone sees. `DebugSettings`
is already the right shape and its own comment predicted this — a registry a menu
can build itself from, with a note to promote it to replicated state the day a
knob has to be correct across a session. Three changes: numeric kinds in the
registry, host-owned replication (any peer requests, host decides, broadcast to
all), and a menu with **no per-knob UI code**. First entry is `show_hitboxes`.

Listed after M13 and built before it, for the reason given: every other line in
the playtest report is a number somebody wants to try.

**Shipped:** numeric kinds and sections in the registry; `tuned()` shadowing three
constants (`PLINKO_HIT_RADIUS` -- which had been an inline `BALL_RADIUS + 0.5` and
is the one already diagnosed as twice its geometry -- plus the MG's spread and
fire interval); host-owned replication where any peer requests and the host
decides, applied on a tick boundary; joiner sync; F1 opens a panel built entirely
by walking `OPTIONS`; and `show_hitboxes` drawing every collider as a wireframe.

**Two tests, both A/B'd.** `test_debug_settings` gained a **drift guard** -- a knob
that shadows a constant must default to it, read out of the script's own constant
map, because `tuned()` returns the registry value and a drifted default silently
changes the game to a number nobody chose. `test_debug_replication` (port 28783)
proves a CLIENT can change a setting and the host broadcasts it -- and it needed a
**counter at the line that applies the broadcast**, because host and client share
one autoload in a single process and every other assertion passed with the
broadcast disabled.

## M15 — Two enemies, three specials, and the model underneath them

**Added 2026-08-14.** Design in `design_ideas/damage_model.md`, plan in
`implementation_plans/m15_threats_and_answers.md`.

A skirmisher that holds a distance and shoots, an immobile turret, and grenades,
mines and a shield for the slot M12 built. **The damage model comes first and the
order is forced**: all five are its clients, and harm is currently dealt at five
call sites that each hand-code what they do to each target -- `_resolve_round_hit`
already type-sniffs three ways, and five new sources against three new targets
turns that into eight questions in five places.

The shape instead is one hit value and a `receive_hit` on each body, so the thing
dealing damage stops knowing what it hit. The gate on that slice is that **nothing
changes**: five existing behaviour tests pin what the game does today, and if the
matrix is right none of them notice.

Three cells carry design rather than bookkeeping. **A mound is immune to bullets
and destroyed by a blast**, which makes a grenade the way to pre-empt a hazard
before it wakes -- a new decision built entirely from parts that already exist. **A
turret ignores a dash**, so it is the first hazard that genuinely needs cover or a
special, and the first that has to be authored against the rule that a special is
never the only answer. And **a shield blocks from one direction only**, which is
what makes flanking the counter-play and a second player the co-op answer.

## M16 — Rounds and the lobby

**Added 2026-08-15.** Plan in `implementation_plans/m16_rounds_and_lobby.md`.

**Proves: the game has a shape.** Everything up to here is a bridge you walk
along until you fall off it. This gives the walk a beginning, an end, a score and
a place to stand between attempts: five-minute sections separated by lobbies,
with a black-and-white checker strip marking each boundary and a transparent
barrier enforcing that the party crosses together.

The structural claim is that **this is also the in-game menu.** A lobby where
players gather, pick a hat, see the last round's scores and later vote on the
next section is the only menu a co-op game of this kind needs — so the round
state is a replicated enum rather than anything derived from where bodies are
standing, and every future console, vote or selection screen is a field on it
rather than a new system.

It also RETIRES machinery. Checkpoints exist to answer "where does the party
restart" for an endless bridge; with rounds the answer is always the lobby you
came from, which is authored and obvious. `checkpoint_row`, `_bank_checkpoint`
and `_restart_at_checkpoint` all go — and with them the question that produced
the 2026-08-15 bug where a party that walked off the back of the bridge respawned
four thousand rows up it.

Eight steps, each separately gateable. **Five minutes is a TARGET, not a cap**
(decided 2026-08-15): the clock is measured, shown and put on the scoreboard, but
nothing in the state machine reads it, because a target nobody measures is a
target nobody hits and a clock that can end a round stops being a measurement of
the design and becomes part of it. The consequence is that reaching the next
strip is the only way forward, which promotes "does a round end when everyone is
out?" from an open question to a required transition.

## Later

Real Steam appid and store presence. Audio. More than four players. Progression
and unlocks, if any.
