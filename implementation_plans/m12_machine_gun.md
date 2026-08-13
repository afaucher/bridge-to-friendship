# M12 — The machine gun, and the special slot it arrives in

Asked for in playtest as "machine gun", scoped against the specials design that
already existed. This is **the first special**, not a new system: the category,
the one-slot rule, the input bit and the HUD box were all designed before this
document and are cited rather than re-decided.

Sources this obeys: `game_concept.md` §Special, `hazards.md` §The specials
revised, `implementation_plans/roadmap.md` M12, `m9_hud.md` §What it draws.

---

## What the docs already settled, and what this changes

| already decided | where |
|---|---|
| a special is a pickup with **fixed uses**, dropped when spent | `game_concept.md` §Special |
| **one slot** — carrying one special is not carrying any other | same |
| picking up a new one **drops the spent one where you stand** | same |
| **a special is never the only answer** — every obstacle stays solvable without one | stated three times; `hazards.md` §The principle underneath it |
| weapons **kill what is destructible**; that is what earns the category its slot | `hazards.md` |
| `ACTION_SPECIAL` exists and is edge-triggered | `sim_config.gd`, roadmap M12 |
| the HUD reserves a special slot, drawn empty | `m9_hud.md`, `hud_model.gd` |
| the carried-item channel exists | M8.5 |

**What this document adds is one roster entry.** The published roster has a
shotgun (ranged shove, several uses, kills destructibles) and a rifle (precise at
30 m). A machine gun sits between them and is defined by its *cadence* rather
than its reach: it is the special that applies **continuous** pressure, which is
the one thing neither of those does and the one thing the base verbs cannot do at
all — a shove is a single committed jab with a 0.35 s cooldown.

**And it deviates from the roadmap's build order, deliberately.** M12 says build
**legs** first, because legs decide the architecture: they modify ordinary
walking, so their charges must live in `PlayerBody.capture_state()` and every
reconciliation replay has to reproduce them. A gun is the opposite half — a
committed action the host resolves — so building it first delivers a playable
special *without* answering the legs question, and leaves that question exactly
as open as it is today. Nothing here forecloses it. See the state split below,
which is the roadmap's own finding applied.

---

## The rules

### Getting one

A special lies on the deck, authored with `*` — **a glyph that already exists**.
`GridConfig.Content.PICKUP` has been declared since the grid was written and has
never been built; this fills it.

Picked up by **radius, in its own pass after every body has stepped**, exactly as
hats are and for the reasons M8.5 states at length: the step order is a
topological sort over who is standing on whom, so resolving contests inside it
would let a carried player systematically win or lose races.

**One slot.** Walking over a second special while holding one **swaps** them: the
new one is held, the old one is dropped where you stand, with **whatever ammo it
had left**. That is what makes the slot a decision rather than an upgrade path —
a full gun you cannot carry is a full gun you are choosing to leave.

Refused in `TUMBLE`, `LEDGE_HANG`, `DOWNED` and the bus states, same as hats:
picking something up mid-tumble removes the cost of the tumble.

### Firing

Held, not tapped. **`ACTION_SPECIAL_HELD` is a new level-triggered bit**, and it
sits *beside* the edge-triggered `ACTION_SPECIAL` rather than replacing it.

The roadmap warns that `ACTION_SPECIAL` "must stay edge-triggered for exactly one
tick, or a reconciliation replay re-fires the jump and burns the charges". That
warning is about **legs**, which are predicted. A gun is not: firing is resolved
by the host and never replayed, so a level-triggered bit costs nothing here — and
keeping the two bits separate means legs inherit the invariant intact instead of
inheriting a bit a machine gun has already made level-triggered.

Rounds leave at `MG_FIRE_INTERVAL` while the bit is held and ammo remains. Each
round costs one. **At zero the gun is gone** — not an empty gun you keep
carrying, because a slot occupied by something that does nothing is the worst
version of a one-slot rule.

**Aimed with the existing free aim.** M8's aim already travels on the input wire
as an absolute angle for exactly this class of reason: it is resolved from a
mouse or a right stick that only the owning client has, so the host cannot
re-derive it. A gun is the second thing to need it and the first to need it to be
*accurate*.

### A round in flight — *revised after playtest*

This shipped as **hitscan**: a raycast resolved the tick it was fired, drawn as a
fading line. Playtest asked for physical balls, and was right. The argument for a
ray was *"ten rounds a second per player is up to 40 new objects a second in a
contact graph that already holds balls, stones, rushers and hats"* — and that
argument evaporated when the same playtest cut the rate to 2.5/sec. What was left
was a weapon whose rounds could not be seen, in a game read from 60 m away.

**A round is now a plain `Node3D` that moves itself, and the world sweeps a ray
along the segment it just covered.** That is a third option, and it beats both of
the obvious two:

- **Not a rigid body.** It would put those objects back in the contact graph, and
  a small fast one tunnels — the classic bullet-as-rigid-body bug.
- **Not a hitscan ray.** Exact, and invisible. The whole point of the note was
  that a round you cannot see is not a round.
- **The sweep is still exact.** A round cannot pass through anything at any
  speed, because the test is the segment and not the position.

**The plinko ball stays the counter-example that proves the rule** — it is a full
rigid body because its *arc* is the gameplay, and it bounces off pillars and off
other balls. A round only has to fly straight and stop.

**Speed and cadence are both deliberately slow**, and both came down twice on
playtest notes: 45 m/s → 22, and 10/sec → 4 → 2.5. A round now crosses the 30 m
range in about 1.4 s, which makes it a thing you watch arrive and, at distance, a
thing a moving target can be out from under.

**Clients are told where each round is, every tick**, in the same self-healing
snapshot the balls use — they simulate none of them. Direction for the tail is
derived from the step, so no velocity has to be on the wire.

### Spread — an ellipse, wide across and narrow up

**10° horizontal, 2° vertical**, rolled on the host only — the same licence
plinko's launch angle takes, and the only randomness in the whole weapon. Yaw and
pitch are rolled *separately*, which is what makes two numbers possible: a round
cone has one width by construction.

**Range costs accuracy with no falloff curve, no accuracy stat and no second
number to defend** — the geometry does all of it. At two metres the horizontal
cone is 0.35 m and a body-width target is a certainty; at four it is 0.7 m and
about half the rounds land; at thirty it is over five metres, which is
suppression rather than aiming.

**The two axes are not interchangeable, and that is why they differ by five to
one.** The bridge is a narrow strip and everything worth shooting stands on it, so
horizontal scatter reads as a weapon that sprays and vertical scatter reads as a
weapon that is broken. It was a round 10° cone first, which threw rounds two
metres over people's heads at range.

### It comes out of the barrel

Asked for in playtest, and not cosmetic. The weapon hangs off the player's
`Facing` pivot, which `player_body` already rotates to match `facing`, so the
barrel's global transform *is* the answer and nothing has to re-derive where
anyone is pointing.

**Which costs one thing, and it has to be paid.** A barrel held off the centreline
firing parallel to `facing` travels on an offset line forever — so somebody
standing dead in front of you is missed by a couple of hand-widths at *every*
range, which reads as the gun being broken. Rounds are therefore **converged on
the aim ray**, zeroed at `MG_RANGE`: exact at the far end, and off by less than
the muzzle offset everywhere nearer, which is well inside a 0.4 m body. The weapon
is also carried close to the centreline rather than out on the hip, because every
centimetre of that offset is error the convergence has to correct.

### What a round does

| target | outcome | why |
|---|---|---|
| a player | **1 damage and a knockback**, gated by `HIT_GRACE` | asked for in playtest |
| a rusher | **killed outright** | `hazards.md`: only being shot ends a destructible |
| a plinko ball | **shoved**, and the round stops | asked for in playtest. An *impulse*, not a set velocity like the dash's deflect: a dash decides where that ball goes, a round only argues with it. **The trade is that the plinko field is now partial cover** — which was the stated reason balls were originally left out of the mask, and is worth paying for being able to shoot a ball at somebody |
| a hat | nothing; rounds pass over them | knocking a friend's hat off with gunfire is a joke nobody asked for, and it would put the whole M8.5 reward curve at the mercy of a stray round |
| world, stones, a shooter | stops the round | cover is the answer to being shot at |

**The grace window is what makes this survivable, and it is not new.** At 10
rounds a second against `HIT_GRACE` of 0.75 s, at most ~1.3 rounds a second do
anything — a sustained burst downs a teammate in about four seconds rather than
half a second. That is the existing rule doing the job it was written for
(*"without it a single tumble through a pillar field drains the whole bar before
the player regains control"*), and the machine gun is the first thing to lean on
it this hard.

**The knockback is gated with the damage rather than applied per round.** Every
round tumbling you would mean a held trigger is a permanent tumble lock, which is
not a fight, it is a player being switched off.

### Losing it

- **Spent** — gone, at the moment the last round leaves.
- **Replaced** — dropped where you stand, with its remaining ammo.
- **Hanging or downed** — **dropped**, not destroyed *(added after playtest)*. You
  need both hands. Dropped rather than destroyed because a weapon lying beside a
  downed player is a reason for somebody to come, and because it is contestable
  while they are out of the game — which is the good version of this.
- **Falling out of the world** — destroyed, exactly like hats and for the same
  reason: it must not rescue the one failure the design does not rescue.
- **A tumble does NOT drop it**, and that line is exactly where hanging and downed
  sit on the other side. Hats pop on a tumble because hats *are* the bet — the
  whole M8.5 reward curve is "how long can you keep them". A special is a tool for
  the fight, and a tool that leaves your hand every time a plinko ball connects is
  a tool that is never in your hand during the only situation it is for. Hanging
  and downed are not being knocked about; they are being out of the game, and
  holding the only weapon on the bridge hostage while your friends come for you is
  the worst version of that. Different objects, different rules, and the
  difference is stated so the next special inherits the reason rather than the
  rule.

---

## The state split, which is the roadmap's finding applied

> *"The part that affects stepping goes in `capture_state()`. The part that does
> not is the M8.5 carried-item channel, reliable and unpredicted."*

For a machine gun, **nothing affects stepping**. Firing does not move you — there
is deliberately no recoil, because recoil is displacement, displacement is
predicted, and that would drag the whole weapon onto the reconciliation path to
buy a detail nobody asked for.

So:

- `capture_state()` is **untouched**. No ammo, no fire timer, no held-kind.
- Ammo lives **on the special body**, host-owned.
- Ownership travels **reliably** (who holds what); loose positions ride the
  **unreliable** snapshot. Same split M8.5 uses, same reasons.
- Ids are **host-assigned and monotonic**, never creation-order indices — a
  special can be created mid-run by a swap, so the stone list's "both machines
  loaded the same segments" trick does not apply.

---

## Tunables

Starting values with reasons, per house rules; every one expected to move.

| constant | value | why |
|---|---|---|
| `SPECIAL_PICKUP_RADIUS` | 0.9 m | a little wider than a hat's 0.7: you should not miss the only weapon on the bridge by 10 cm |
| `MG_AMMO` | 20 | eight seconds of held trigger — long enough to matter in one fight, short enough that it is not the answer to the next one. Cut from 60 as the rate came down, twice, so the magazine stays about the same length of *holding* |
| `MG_FIRE_INTERVAL` | 0.4 s | 2.5 rounds/sec. **Slowed twice on playtest**, from 0.1 and then 0.25. At the original rate the individual round did not exist — it was a beam, and "you can see a round coming" stopped being true with it. It has stopped being a machine gun in the literal sense, and that is fine: what was asked for was continuous pressure, and pressure at a rate you can read is the version that plays |
| `MG_SPREAD_DEG` | 10° | horizontal. **Widened from 4° on playtest**, which changed what the weapon is: at 4° everything inside eight metres was a guaranteed hit and the cone only mattered at range |
| `MG_SPREAD_VERTICAL_DEG` | 2° | five to one against the horizontal, because the two axes are not interchangeable on a narrow bridge |
| `MG_BALL_PUSH` | 10 N·s | about 5 m/s against a 2 kg ball — a third of `PLINKO_DEFLECT_SPEED`, so shooting a ball moves it and batting it away with your body still does more |
| `MG_BULLET_SPEED` | 22 m/s | **slowed from 45 on playtest.** Under four times a walking player: a round is something you watch cross the gap |
| `MG_BULLET_DROP` | 0.05 g | about a metre over the full range, 8 cm at the four metres where fights happen. It had to shrink when the speed did — drop goes with the *square* of flight time, and the fraction that gave 20 cm at 45 m/s gives five metres at 22 |
| `MG_RANGE` | 30 m | the rifle's number from `hazards.md`, deliberately: this is not the long-range special, so it does not out-reach the one that is |
| `MG_DAMAGE` | 1 | one round is one plinko ball; the cadence is the weapon, not the round |
| `MG_KNOCKBACK` | 8.0 m/s | below `SHOVE_TRANSFER_SPEED` (11). Being shot pushes you around; being dashed into still throws you further |
| `MG_KNOCKBACK_LIFT` | 2.0 m/s | just under the shove's 2.5, so a hit reads as a stagger rather than a launch |
| `SPECIAL_MAX_LOOSE` | 8 | a third of the hat cap: these are rarer by design |

---

## Tests

| test | what it pins |
|---|---|
| `test_special_pickup` | walking over one takes it; **one slot** — a second swaps, and the dropped one keeps its remaining ammo; a `TUMBLE` player takes none; going `DOWNED` **drops** it on the deck rather than destroying it; falling out of the world destroys it |
| `test_machine_gun` | the held bit fires at `MG_FIRE_INTERVAL` and not faster; ammo drains one per round; **at zero the gun is gone**; a round damages *and* moves a player; `HIT_GRACE` limits that to about one hit in two rounds; a rusher dies to a round; **a pillar stops the round** (cover works); a round is an **object in flight** that starts **at the barrel** and not inside the player; no two rounds leave on the same line, the cone stays inside its budget, and it is **wider across than up**; and a round **shoves a parked plinko ball** down-range without destroying it |

**The half that carries the design is "a rusher dies".** Everything else in the
list is also true of a gun that does nothing, or of a gun nobody can hold. A
weapon that cannot remove a destructible is a shove you can do from further away,
which is the exact critique `hazards.md` makes of a shotgun in a world with
nothing destructible in it.

---

## Explicitly not in this slice

- **Legs**, and therefore the `capture_state()` half of the special system. Still
  open, still the thing that decides the architecture, still deliberately not
  answered by a weapon.
- **The other five specials.** The pool, the slot, the drop rule and the HUD box
  are shared; a sword is a different resolve function.
- **Recoil, reload, spread, damage falloff, ammo pickups.** Each is a second
  number to defend and none of them is what "machine gun" asked for.
- **Making anything require a weapon.** `SegmentValidator` does not learn about
  specials, exactly as it does not learn about legs, and for the identical
  reason: a route that requires a contested pickup strands the players who did
  not get it.
