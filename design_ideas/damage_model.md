# The damage model

Written 2026-08-14, prompted by five new things that all want to hurt something:
two enemies that shoot, and grenades, mines and a shield. Every one of them is a
client of this, and building them on what exists today would mean rewriting them.

---

## What exists, and why it does not scale

Harm is dealt at five call sites, and **each one hand-codes what it does to each
kind of target**:

| where | what it does |
|---|---|
| `_resolve_ball_hits` | `take_damage` + `begin_tumble` on a player |
| `_resolve_rusher_contact` | the same, plus expend the rusher |
| `_resolve_round_hit` | **type-sniffs three ways** — ball, rusher, player |
| `resolve_shove_contact` | `receive_shove` on a player, `try_push` on a stone |
| `_process_rescue` | falling out of the world |

`_resolve_round_hit` is where the strain is visible. It asks
`has_method("deflect") and "ball_id" in target`, then
`has_method("begin_rise")`, then `"peer_id" in target` — a chain of "what are
you?" questions written by the thing doing the hurting.

That is N sources × M targets, and it is already wrong once: the machine gun had
to decide, in its own code, that hats are immune. **Five new sources and three new
targets turn a chain of three questions into a chain of eight, in five places.**

## The shape instead: the target decides

One value describes a hit. Every body implements one method that decides what the
hit does to *it*.

```gdscript
# The hit
{ kind, amount, from, push, lift, source }

# The target
func receive_hit(hit) -> bool     # true if it did anything
```

The thing dealing damage stops knowing what it hit. **A grenade does not need a
branch for mounds** — the mound knows it is destroyed by explosives, and that
knowledge lives in one place with the reason next to it.

### `from` is a POINT, not a direction

The single most load-bearing field, and it is a point because **that is what a
shield needs**: "harm coming from a certain direction" is a question about where
the hit *originated* relative to the body, and a direction of travel cannot
answer it for a blast.

Everything else derives from it. Knockback is `(target - from)` flattened and
normalised, which is correct for a round (the point where it struck), for a
contact (the other body), and for an explosion (its centre) without any of them
having to think about it.

### Four kinds, and each one earns its place

| kind | what it is | what makes it distinct |
|---|---|---|
| `IMPACT` | a body arrived — a dash, a rusher, a plinko ball | the only kind that **moves terrain** |
| `BULLET` | a round | the only kind that is **stopped by cover** |
| `EXPLOSIVE` | a grenade, a mine | the only kind that reaches **under and around** |
| `CRUSH` | *reserved* — a saw-blade, a falling thing | not built; named so the enum does not have to change later |

The distinction is not decoration — it is exactly the difference the examples
that prompted this document turn on. A mound is immune to bullets and destroyed
by a grenade. A pillar ignores a round and is moved by a dash or a blast.

---

## The matrix

**Rows are targets, columns are kinds.** This is the whole design; everything else
is plumbing.

| target | `IMPACT` | `BULLET` | `EXPLOSIVE` |
|---|---|---|---|
| **player** | damage + tumble | damage + tumble | damage + **bigger** tumble |
| **rusher** | deflect + stagger | **dies** | **dies** |
| **skirmisher** *(new)* | deflect + stagger | **dies** | **dies** |
| **turret** *(new)* | nothing — it is bolted down | **dies** (it is the thing you shoot) | **dies** |
| **plinko shooter** *(2026-08-14)* | nothing | **nothing** | **destroyed** |
| **mound** | nothing | **nothing** | **destroyed** |
| **pillar / stone** | moves one cell | nothing | moves one cell, away from the blast |
| **plinko ball** | deflected | shoved | shoved hard |
| **hat / special on the ground** | nothing | nothing | scattered |
| **held special** | nothing | nothing | nothing |
| **round in flight** | nothing | nothing | nothing |

Four entries carry design rather than bookkeeping:

**A mound is immune to bullets and killed by a blast.** It is dormant and flush
with the deck — there is nothing above ground to shoot. So a grenade becomes the
way to *pre-empt* a hazard: spend a charge to remove an enemy that has not woken
yet. That is a genuinely new decision (is this worth a grenade?) built entirely
out of parts that already exist, and it is the best thing in this document.

**A plinko shooter dies only to a blast**, exactly as a mound does, and that is
the same argument twice: a structure is not answered by gunfire. It matters more
here than for a mound, because it changes what the plinko arena IS. Until now the
balls were a permanent condition of that stretch of bridge and the only verb
against them was moving; a party carrying a grenade can now end the source. **The
arena stops being weather and becomes a problem with a solution** — and explosives
get a second thing nothing else can kill, which is exactly the niche this document
wants them to have.

It is deliberately NOT shootable. A machine gun that could clear the field from
the far side would delete the reason to walk into it, and the field exists to be
crossed.

**A turret is immune to IMPACT.** Dashing a bolted-down gun should do nothing —
otherwise the free verb answers the hazard and the specials category loses another
customer, which `hazards.md` already warns about twice.

**A pillar is moved by a blast, not damaged.** `bridge_grid.md` says no
destructible deck; a stone that could be *destroyed* is a hole created at runtime,
which is the grid-model change that document explicitly rules out. Moving one is
already a rule the game has.

**Loose hats scatter; held ones do not.** Gunfire deliberately cannot strip a
friend's hat stack — the machine gun already refuses that — but a blast throwing
loose debris around is free and looks right.

---

## Modifiers

A modifier answers "does this hit land at all", before the matrix runs.

### The grace window — exists

`HIT_GRACE` (0.75 s) after any landed hit. Already the thing that stops a tumble
through a pillar field emptying a health bar, and the machine gun already leans on
it harder than anything before it.

### The shield — new, and the reason `from` is a point

**Anchors you and blocks everything arriving within an arc.** Two halves, both
load-bearing:

- **It gates damage AND knockback**, not just damage. In a game whose threat model
  is displacement, a shield that let you be thrown while taking no damage would be
  protecting the wrong thing.
- **It anchors you.** You cannot walk while it is planted. That is what stops it
  being strictly better than not having it, and it is the same bargain
  `game_concept.md` already struck for the anchoring shield: *"immovable while
  planted and doing nothing else."*

The arc is centred on the shield's facing, which is chosen when it is planted and
cannot be turned. So being flanked is the counter-play, and a second player
covering the other side is the co-op answer.

**It does not block a blast under your feet.** An explosive whose centre is inside
the arc is blocked; one behind or beneath is not — which is exactly what a mine is
for, and stops the shield being a universal answer.

---

## What this makes cheap

Each of the five new things becomes one `receive_hit` implementation plus its own
behaviour, and **nothing already built changes**:

- **Skirmisher** — holds a preferred distance and fires. Its hits are `BULLET`s
  from the existing round, so cover already works against it on day one.
- **Turret** — the same, immobile, authored.
- **Grenade** — an `EXPLOSIVE` at a point, radius-resolved through the same matrix.
- **Mine** — the same hit, a different trigger.
- **Shield** — a modifier, not a hit at all.

## What it costs

An honest accounting, because a refactor that pretends to be free is one nobody
budgets for:

- Six existing bodies gain a `receive_hit`.
- Five call sites lose their hand-coded branches.
- `_resolve_round_hit`'s type-sniffing chain goes away entirely.
- **The tests that already pin the current behaviour must keep passing unchanged**
  — `test_plinko`, `test_rusher`, `test_machine_gun`, `test_shove`. That is the
  gate on the refactor: if the matrix is right, none of them notice.

## Explicitly not in this model

- **Damage over time, status effects, resistances.** The punishment vocabulary in
  `hazards.md` is four verbs wide on purpose.
- **Friendly fire toggles.** Everything in this game is aimed at friends as
  readily as at enemies; that is pillar 2.
- **Destructible terrain.** Ruled out in `bridge_grid.md`, and a blast moving a
  pillar is the version that fits.
- **Numbers.** Every value above is a matrix cell, not a tuning. The console
  exists now; the numbers are a playtest.
