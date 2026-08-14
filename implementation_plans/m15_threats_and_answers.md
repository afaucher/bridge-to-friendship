# M15 — Two enemies, three specials, and the model underneath them

Asked for 2026-08-14. The design is in `design_ideas/damage_model.md`; this is the
build order and what each piece owes.

**Three slices, and the order is forced.** The damage model is not a nice-to-have
refactor to do afterwards — all five new things are its clients, and building them
on today's hand-coded call sites means writing five more branches into a chain
that is already the wrong shape and then unpicking them.

---

## 15a — The damage model

`scripts/sim/hit.gd`: the value, its four kinds, and the helpers that build one.
`receive_hit()` on player, rusher, stone, ball, hat, special. The five existing
call sites stop deciding what they hit.

**The gate on this slice is that nothing changes.** `test_plinko`, `test_rusher`,
`test_machine_gun`, `test_shove` and `test_rescue` all pin current behaviour, and
if the matrix is right none of them notice. A refactor that needs its tests
edited is a refactor that changed something it did not mean to.

Then one new test for the matrix itself — the cells the examples turned on:
a bullet does nothing to a mound, a blast destroys it; a bullet does nothing to a
pillar, a blast moves it.

## 15b — The two enemies

Both fire the existing round, so **cover works against them on the day they
land** and nothing new has to be invented for that.

### The skirmisher
Holds a preferred distance and shoots. The first enemy with a *position* it wants
rather than a target it runs at, and that is the whole point: a rusher is answered
by moving, and this one is answered by closing.

- Approach when further than `SKIRMISHER_RANGE`, retreat when nearer, fire when
  roughly in band.
- **Line of sight gates firing, not just chasing.** The rusher already needs this
  and the reason is stronger here: a gun that fires through a pillar is a gun with
  no counter-play.
- **It must not retreat off the bridge.** A body that backs away from you until it
  falls is a comedy the player did not author. It stops at an edge — the same
  probe the carrier check already uses.

### The turret
Immobile, authored with its own glyph, fires the same round. **Its own type**
(`turret_body.gd`), not a flag on the skirmisher — see `hazards.md` for why the
firing arc is what forced that.

- **Its own numbers.** `TURRET_RANGE` 19 and a 2.0 s cadence against a
  skirmisher's 14 and 1.2 s: persistence rather than pressure, because it cannot
  reposition.
- **A mount facing and a firing arc.** `TURRET_ARC_DEG`, centred on the facing it
  was bolted at, shipped at 360 so nothing changed on the day it landed. Narrowing
  it makes flanking an answer the geometry gives free; it is a debug-console
  slider so the value gets found in a playtest.

- **Immune to `IMPACT`.** Dashing a bolted-down gun does nothing, or the free verb
  answers it and the weapon specials lose another customer.
- So it is the first hazard in the game that **requires** a special or cover to
  deal with — which makes it the one that has to be authored most carefully
  against `hazards.md`'s rule that a special is never the only answer. **The
  answer without a weapon is cover and distance**, and a validator rule should
  refuse a turret with no cover in front of it.

## 15c — The three specials

All three go in the slot M12 built. All three are `EXPLOSIVE` or a modifier, so
15a is what makes them small.

### Grenade — hold to adjust distance ✅ *built 2026-08-14*
Hold to charge, release to throw; the charge picks the distance. The first special
with an **analogue** commitment — everything else in this game is a binary press —
and the arc is the tell that lets everyone else read where it is going.

- **The charge is on the wire already**: `ACTION_SPECIAL_HELD` is level-triggered
  precisely because a machine gun needed it, and a grenade needs the same bit for
  a different reason. **The release edge is derived on the host** from that level
  bit rather than sent as its own action, so a throw never depends on one press
  packet arriving.
- Cooking it is deliberately **not** in scope: hold-to-aim and hold-to-cook are
  two different meanings for one input, and the second is a way to blow yourself
  up that nobody asked for.
- **The near throw is inside your own blast** (`GRENADE_MIN_RANGE` 3 against
  `BLAST_RADIUS` 4), and that is load-bearing: if a tap were safe, holding longer
  would be strictly better and there would be nothing to adjust.
- **Losing control cancels the charge and keeps the ammo.** A lost trigger must
  not read as a release, or being tumbled mid-charge throws a live grenade at
  whatever direction the tumble left you facing — a special spent by the game on
  the player's behalf.

**Two things this cost, both worth writing down.** The throw solved its speed with
the level-ground range formula while releasing from 1.2 m up, so every throw
overflew — a "3 m" tap landed at 5.5 m, *outside its own blast*, which silently
deleted the rule the whole verb rests on. And a grenade that rolled rolled 2.4 m
down the deck's 4° pitch during its own fuse, which moved every throw out of the
place the player picked. A grenade is **placed**, not bowled: locked rotation, full
friction, and zero linear damping so the solved arc stays true.

### Land mine — one second, then armed ✅ *built 2026-08-14*
Placed at your feet, harmless for `MINE_ARM_SECONDS`, then triggers on proximity.

- The arming delay is what stops it being a melee attack, and it is what makes
  placing one *in advance* the skill.
- **The owner is not exempt.** Standing on your own armed mine is fatal, so
  stepping away is part of the verb rather than a courtesy. The player is on top
  of a live mine for the whole arming second, which is the risk and the joke in
  one.
- **It triggers on anything on legs** — players, rushers, gunners — and
  deliberately not on plinko balls, which would spend it on nobody in an arena
  full of them. The proximity question is asked by the world, because "is anything
  standing here" is a question about pools; the deployable only decides what the
  answer *means*.
- **The button is edge-derived**, like the grenade's release: a level bit with no
  edge would lay a mine every tick and empty the pouch in three frames.
- Shares `deployable.gd` with the grenade — a considered position, not the default
  one, taken the same day the turret was split *out* of that shape. The test
  applied: does the second kind need state the first has no use for? It does not;
  both are a body with a countdown, disagreeing only about what starts it.
- **It is the shield's counter**, per the damage model: a blast beneath you is not
  in the arc.
- Triggered by enemies as well as players, or it is a trap that only ever catches
  friends.

### Shield — anchor and an arc
A modifier rather than a hit. Blocks damage **and** knockback arriving within an
arc of its facing; you cannot walk while it is planted; the facing is chosen when
it is planted and cannot be turned.

- Flanking is the counter-play, and a second player covering the other side is the
  co-op answer.
- It is the first special whose value is **positional** rather than aimed, which
  is a different shape of decision from everything in the slot so far.

---

## What each slice owes the tests

| slice | the claim that carries it |
|---|---|
| 15a | the five existing behaviour tests pass **unchanged**, and a bullet cannot kill a mound while a blast can |
| 15b | a skirmisher holds its band rather than closing; it does not back off an edge; a turret ignores a dash and dies to a round; a turret does not shoot outside its arc, and the same target inside it does get hit |
| 15c | a grenade's distance follows the charge; a mine does nothing for a second and then does; a shield blocks from the front and **not** from behind |

The shield's is the one carrying its design. A shield that blocked everything
would pass "it blocks", and the whole mechanic is the half it does not cover.

## Open, and deliberately not decided here

- **What a turret costs to author.** It is the first thing that can be authored
  into a spot with no answer; the validator rule needs a real map to be written
  against.
- **Whether the skirmisher should flee at low health.** Interesting, and a second
  behaviour to tune before the first one is proven.
- **Numbers.** All of them. The console shipped for exactly this.
