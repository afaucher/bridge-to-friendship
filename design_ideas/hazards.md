# Hazards

Written 2026-08-08. What threatens the party, sorted by **what it does to you**
rather than by what it looks like, plus the specials that answer each. Anything
marked **[open]** is unanswered; numbers are starting values with a stated
reason, per house rules.

`plinko.md` owns the plinko field in detail; this document is the roster around
it.

## The four things a hazard can do

The punishment vocabulary is deliberately tiny, and every hazard is one of these
four in a costume:

| verb | what it means | the design's view of it |
|---|---|---|
| **displacement** | TUMBLE — a pinwheel that keeps its momentum | **the real threat.** On a bridge full of holes, being moved is worse than being hurt |
| **damage** | hit points, and `DOWNED` at zero | a countdown, not a wall — see M5 |
| **denial** | you cannot be there | terrain's job, mostly |
| **impairment** | degraded, but still in control | water; the only one that leaves you playing |

A hazard that only does **damage** is a tax. The game's threat model is
displacement, so a new hazard should be checked against this table before it is
built: if the answer is "it costs a hit point", it is not yet interesting.

## Deflectable versus destructible — the split that justifies weapons

*(Decided 2026-08-08, and it is the most consequential line in this document.)*

Until now everything hostile was **deflectable**. A plinko ball is batted away by
a dash; a stone is pushed a cell; a player is launched. Nothing could be
*removed*. That made the ranged specials weak by construction: a shotgun was a
shove you could do from further away, and the player already has a shove for
free.

Threats now come in two kinds:

- **Deflectable** — balls, barrels, stones, angry rocks, other players. Shove
  moves them. They persist.
- **Destructible** — enemies. Shove *deflects* them, buying time. Only being
  **shot** ends them.

That single distinction is what earns the weapon-special category its slot. There
is now a threat the base verbs cannot resolve, only postpone.

### The principle underneath it

**A special is never the only answer.** It has shown up three times now and is
worth stating outright:

- Legs are a shortcut, never an ascender — a layer stays solo-passable by terrain
  (`game_concept.md` §Special, and E1b).
- A rusher can be deflected by a dash and outlived by its own timer, so a player
  with no weapon is inconvenienced, never stranded.
- Hearts and revives already exist, so a healing special adds a better option and
  not a required one.

The reason is drop-in: specials are contested, disposable and unevenly
distributed, so anything that *requires* one strands the players who did not get
it. Specials make an answer **cleaner**, never **possible**.

## The roster

Cost tiers reflect what machinery already exists.

| hazard | what it really is | verb | cost |
|---|---|---|---|
| holes, falls | the terminal failure | denial | **shipped** |
| edges, ledges | denial with a rescue window | denial | **shipped** |
| plinko balls | see `plinko.md` | displacement + 1 dmg | M6 |
| water flow | lateral push, wash-away | impairment | M7 |
| **barrels** | a plinko ball that starts at rest | displacement | **~free** |
| **angry rocks** | a stone that shoves on proximity | displacement | low |
| **spikes** | must tumble, not just hurt | displacement | low |
| **sand** | must deny the *dash*, not slow you | impairment | low |
| **saw-blades** | the first authored moving body | displacement | medium |
| **damaged ground** | the first *mutable* deck cell | denial, late | high |
| **rushers** | the first destructible enemy | displacement | medium |
| **spiders** | patrol, aggro, pathfinding | — | own milestone |

Three notes the table cannot carry:

**Barrels are the cheapest good hazard available.** The ball sim, the ricochet,
tumble-on-contact and the 4° pitch that rolls loose things back downhill all
exist for plinko. A barrel is a ball at rest. It gives the dash a fourth job and
it is the first hazard players aim at *each other*.

**Sand and spikes as originally sketched are both weaker versions of something
the game already has.** Sand-that-slows is a lesser water; spikes-that-hurt are a
tax. They become distinct hazards only as written above — sand is the one terrain
that takes a *verb* away, and spikes tumble.

**Damaged ground contradicts a written decision.** `bridge_grid.md` closes with
*"No destructible deck. Holes are authored, not created."* That is not a
preference: authored-static cells are what make a drop-in join cheap, so a
breakable cell means the snapshot grows a **deck diff** beside the stone list,
and the validator has to decide whether it floods the pre-break or post-break
bridge. Worth building — it is the only hazard that punishes standing still — but
it is a grid-model change scoped as one, not a hazard.

## Rushers

**Decided 2026-08-08.** The first enemy, and deliberately the *cheap* one:
spiders need pathfinding, patrol states and aggro. A rusher needs a direction.

**It rises, then it runs at you.** An authored cell holds a dormant mound
(glyph **`m`**, provisional). A player within `RUSHER_TRIGGER_RADIUS` wakes it;
it takes `RUSHER_RISE_SECONDS` to emerge, and *that emergence is the telegraph* —
the same fairness rule as plinko's slow balls. Then it picks the nearest player
and moves straight at them. No pathfinding: a straight line on the deck, which is
all "rushes right at you" requires and is the entire reason this is affordable.

**It is faster than a walk and vastly slower than a dash.** You cannot simply
stroll away from it — that is what makes it a decision rather than an annoyance —
but it is nowhere near a dash, so committing an axis still beats it.

**Three answers, in descending order of grace:**

1. **Shoot it.** It dies. Clean, and the reason to be carrying a weapon.
2. **Dash it.** Deflected and staggered, buying `RUSHER_STAGGER_SECONDS`. It gets
   back up. Scrappy, free, available to everyone.
3. **Outlive it.** It burrows back down after `RUSHER_LIFETIME`. Desperate, but
   it is the floor that stops a weaponless solo player from being ground down —
   the "never the only answer" rule above, made concrete.

**On contact it tumbles you and expends itself.** Displacement, per the table;
expending itself so a single rusher cannot chain-tumble someone who is already
out of control and has no way to respond.

### Starting values

| constant | value | why |
|---|---|---|
| `RUSHER_TRIGGER_RADIUS` | 6 m (3 cells) | close enough that the trigger reads as *your* mistake, far enough to give the rise time to matter |
| `RUSHER_RISE_SECONDS` | 1.0 | the telegraph. Long enough to back off or line up a shot, short enough not to be ignorable |
| `RUSHER_SPEED` | 8.0 m/s | above `WALK_SPEED` (6.0) so it cannot be outwalked; a rounding error against `SHOVE_SPEED` (56) |
| `RUSHER_STAGGER_SECONDS` | 2.0 | one dash buys a breath, not an escape |
| `RUSHER_LIFETIME` | 10.0 | long enough to be a real problem; short enough that a weaponless player has a floor |

### Engineering shape

A rusher is a **free sim body**, host-authoritative and **never predicted** —
same class as a plinko ball, not a player. Its target selection is host-decided;
clients are told the result and invent nothing.

Two events are discrete and therefore **reliable**: spawn, and death. Position
rides the per-tick snapshot in world-local coordinates like everything else. Ids
are **host-assigned and monotonic**, not creation-order indices — a rusher is
created mid-run by a trigger, so the stone list's "both machines loaded the same
segments" trick does not apply. This is the same trap written up for hats.

## The specials, revised

| special | answers | note |
|---|---|---|
| shotgun | rushers, crowds, close range | kills what is destructible |
| **rifle** | rushers and friends at distance | precision, not reach — the first tool that *helps* someone 30 m away without a rope, and equally the first that betrays them |
| sword | rushers, spiders, anything that comes to you | arcs, multi-target |
| thrown bomb | groups, delayed | |
| anchoring shield | water, knockback, holding a position | plant it; immovable **while planted and doing nothing else** |
| legs | spikes, sand, short gaps, one layer of height | traversal |
| **transfusion** *(name provisional)* | a teammate about to go `DOWNED` | gives them **your** hit points |

**Transfusion is a transfer, not a heal.** M5 already shipped proximity revive
and first-come-first-served hearts, so a third healing source would flatten the
rescue tension D2 exists to create. Giving away your *own* health is a different
act: it costs the giver, it can be overdone to the point of dropping yourself,
and — the actual reason it is in — **sacrifice is legible from across the
bridge** in a way that a heal is not.

**The knockback reducer was cut.** Two reasons. It is passive, so "fixed uses,
dropped when spent" does not apply and it breaks the one model every special
shares. And the entire game is displacement: an item that makes you harder to
displace makes you *less funny*. The version that survives is the anchoring
shield, which charges you a commitment for the same effect.

## The gap nobody has filled

**No hazard requires two players in two places at once.** The leash is a soft
rule; every hazard above is solvable by one competent player, and pillar 1 —
"the geometry is authored so that specific obstacles have no single-player
solution" — is currently carried entirely by the steep ramp.

A held gate, a pressure plate, something that must be weighed down while another
player crosses: an obstacle whose answer is **positional** rather than
**item-based**. That is the largest hole in the hazard design and the one that
most directly serves A1.

**[open]** It also sits awkwardly against E1b, which forbids a layer solvable
*only* by a cooperating pair, because drop-in means the party can be one player.
The resolution is probably that a co-op-only obstacle may gate a **reward or a
shortcut** but never the **route** — the same shape as legs. Confirm before
building one.

## Open questions

1. **[open]** Does a dash kill a rusher outright at full speed? Specified as no —
   deflect and stagger — so that the destructible/deflectable split stays clean.
   If playtest says a 56 m/s impact obviously ought to kill it, the split needs a
   different carrier and the weapons lose their exclusive job.
2. **[open]** Do rushers respawn from the same mound, or is a mound spent? Spent
   is simpler and keeps authored density meaningful.
3. **[open]** Naming. "Rusher" is descriptive placeholder; `m` for its mound is
   mnemonic but unclaimed glyphs are getting scarce.
4. **[open]** Does transfusion work on a `DOWNED` teammate, or only to prevent
   one going down? Prevention-only is the more interesting item and keeps the
   revive as the thing you have to physically reach.
