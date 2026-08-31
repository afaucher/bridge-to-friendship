# The merchant

Proposed 2026-08-18. The first NPC in this game that is not trying to kill you,
and the first place one kind of value turns into another.

## One line

A rare figure standing on the bridge who takes one hat off your tower and gives
you a hat three and a half times taller — the only source of such a hat in the
game.

## Why this is not just a pickup

Hats are the one thing in the game you carry on purpose. They are score
(`stat_registry.gd` ranks a round by the tower you finish with), they are a bet
(the whole stack pops on a tumble), and they are deliberately inert — M8.5 is
explicit that "the moment a hat is worth wearing for a reason other than points,
it stops being a bet and starts being equipment."

The merchant does not break that rule, and it is worth being precise about why,
because the obvious version of this idea does. **He does not sell power. He sells
a bigger version of the bet.** A tall hat is still worth nothing but points and
still pops on the first tumble; what it changes is how much of you is sticking
up. That keeps the item entirely inside the system hats already have, and it is
the reason this is a content feature rather than a balance problem.

**THE TALL HAT IS ALSO A TALLER TARGET, AND THAT IS THE ENTIRE BALANCE LEVER.**
2026-08-16 made a worn hat a hit column: a round travels flat at the height of
the muzzle that fired it, so a shooter above you meets your tower before it meets
you. A hat 3.5x tall adds 0.88 m of silhouette in one slot. Nothing has to be
tuned for this — the risk curve and the reward curve are already the same curve,
which is the property M8.5 wanted from hats and never quite got, because seven
ordinary hats cost the same to acquire as they do to lose.

So the sentence the feature exists to produce is **"who gave HIM the big hat"**,
followed shortly by watching it come off.

## The three decisions

Settled 2026-08-18 with the user, recorded here with what each one costs.

### What he gives: a hat 3–4x taller, and this is its only source

Not a special, not a trinket, not a stat. A hat, of a size the ordinary catalogue
cannot roll.

The merchant's hat is sized against the **slot**, not against the tallest
ordinary hat — because a hat that does not change its slot intersects the one
above it, and the catalogue already does this. `HatStyle.HEIGHT_MAX` is 0.55
against a `HAT_HEIGHT` slot of 0.35, so the tallest ordinary hat is already 1.6
slots and its crown passes clean through its neighbour. That is a cosmetic quirk
nobody has noticed at 0.2 m of overlap. At 3.5x it would be most of the tower,
which is what forces the per-hat slot below rather than a bigger mesh.

**Scarcity is the point and has to be enforced in code, not by convention.** "The
only way to acquire such a hat" means the random roll must never produce one; see
the reserved-band note below, which is how that becomes a property rather than a
promise.

### How you buy: you stand at him and press E

**This section used to say "you dash into him", and the reasoning it gave was
sound and still lost to a playtest.** It is kept below rather than deleted,
because what was right about it is why the replacement works.

The original argument was that the game had no interact verb — two action bits,
`ACTION_SHOVE` and `ACTION_SPECIAL_HELD` — and that the dash was the *right*
verb rather than merely the available one: a committed action aimed at a thing,
unmistakably deliberate, and impossible to trigger by pathing past. A radius test
of the kind `_process_hearts` uses would spend a hat with no decision attached,
which is the one outcome this must not have.

**Every one of those claims was true. The verb was still wrong.** Reported
2026-08-29: *"it is really easy to miss them and dash off a cliff."* A dash is
56 m/s and covers 5.6 m, and the shopkeeper is often near an edge — so the price
of a near miss was the run. The trade was fine; the *approach* was the hazard.

The premise had also expired. `ACTION_USE` exists: it was added for boarding a
bus and is what the self-revive gamble reads. So the interact verb the original
note said the game had never needed had been on the wire for two milestones.

**And the property being protected was never about speed.** "Unmistakably
deliberate" is a property of the CONTROL: `E` is edge-triggered, so nobody sells
a hat by walking past it either. What the dash added on top of that was not
deliberateness, it was *risk* — and risk paid at the moment of a purchase, in a
co-op game about getting hats to the far end, is a tax rather than a decision.

So: stand within `SimConfig.USE_REACH` and press E. He is still a solid body you
cannot walk through, and dashing into him is still how you get there in a hurry
— it just is not the sale any more. `GameWorld._use` owns the press and states
the order it resolves in; `_use_nearby` picks the nearest thing worth using and
still dispatches on `has_method`, so a fourth kind of post is a new method rather
than a branch anybody has to remember.

### What it costs: one hat, flat

The top of your stack. Not the whole tower, and the offer does not improve with a
taller one.

The scaling version was considered and dropped: it makes the merchant a reason to
have been playing well already, and this should be a thing the player who is
*losing* the hat game can still use. One hat in, one tall hat out, same deal for
everybody.

**ONE SALE PER MERCHANT.** He is spent afterwards, like a mound or a heart. Four
players and an unlimited shopkeeper is four dumped hats and four tall ones, which
is neither rare nor a decision. Spent-once also makes him **contested**, which is
the idiom the game already runs on — hearts are first-come-first-served precisely
so they are a thing to communicate about.

**HE WILL NOT TAKE A TALL HAT** (decided 2026-08-18). If the top of your stack is
tall, there is no trade and you lose nothing. You cannot launder one tall hat into
another, and you can never trade *down*.

Note what this rule does and does not say, because they are two different rules
and only one of them was asked for. It governs the **payment**, not the wardrobe:
a player who trades, then picks up an ordinary hat, has an ordinary hat on top
again and may trade with the next merchant. **Two tall hats are therefore
reachable, and that is left allowed** — each one still costs a fresh ordinary hat,
merchants are one in six segments, and 2.45 m of silhouette in two slots is the
game's own argument that carrying more should be louder. A separate
one-per-head cap can be added later if playtest disagrees; it is not implied by
the refusal.

## What it actually costs to build

Four findings from reading the code, each of which is a bug if it is discovered
later instead of now.

### 1. THE SLOT IS THE THING THAT HAS TO CHANGE, AND IT IS HARD-CODED IN FIVE PLACES

This is the whole engineering content of the feature and everything else is
plumbing.

`SimConfig.HAT_HEIGHT` is not "how tall a hat is" — hats are 0.10 to 0.55 and
always have been. It is **how tall a SLOT is**, and it appears as a bare constant
at five sites:

| site | what it decides |
|---|---|
| `hat_pool.gd:115` | where a worn hat is drawn within its slot |
| `hat_pool.gd:116` | how far up the next slot starts |
| `hat_body.gd:265` | the worn hit column's height |
| `scenes/hat.tscn:33` | the shape asset, with a comment saying this is a constraint |
| `test_hat_pickup.gd:120`, `test_hat_lean.gd:116` | assert the spacing IS `HAT_HEIGHT` |

A per-hat slot means `HatBody.slot_height()`, read at every one of those. **Get
the spacing and miss the hit column and you have rebuilt the 2026-08-16 gappy
tower on purpose** — a 1.2 m hat drawn in a 1.2 m gap with a 0.35 m collider is
0.86 m of hat a bullet passes straight through, and the report will be "I shot
him in the big hat and nothing happened."

CLAUDE.md already states the rule this generalises: *where things tile, the hit
shape is a property of the slot, not of the thing in it.* The amendment is that
the slot is now a property of the hat's **class**, and the tiling still has to be
seamless — `base += up * hat.slot_height()` and a column of exactly
`hat.slot_height()` centred on the origin, or the two disagree.

### 2. "TALL" MUST BE A PURE FUNCTION OF `style_id`, WHICH MEANS A RESERVED BAND

`hat_style.gd` opens with the constraint the whole hat system hangs on: the shape
is derived from `style_id` and never rolled at spawn, because the id is what
travels on the wire and what makes a stolen hat stay the hat it was.

A `tall` boolean on `HatBody` would be a second field to replicate, to persist,
and to get wrong on a late joiner. **A reserved band of style ids costs nothing
and inherits every one of those properties for free:** the wire already carries
it, `HatConfig` already saves it, `_worn_hat_dump` already sends it to a joiner,
and `HatStyle.knobs()` gains one branch at the top.

**Reserve the LOW band (`0 <= style_id < TALL_STYLE_COUNT`), not negatives.**
`hat_pool.spawn_loose` rolls a raw `randi()`, which is negative half the time —
so "negative means tall" would turn half of every hat already saved on every dev
machine into a stovepipe overnight. A saved id landing in 0..7 is one chance in
2^28. This is a migration hazard that only exists in one of the two obvious
encodings, and it is invisible until somebody launches the game.

The roll in `spawn_loose` still needs a guard so the ordinary catalogue cannot
land in the band. That guard is the code that makes "only from the merchant" true.

### 3. A LAYER NOTHING MASKS IS A COLLIDER MADE OF NOTHING

The player's mask is `151` = world | players | stones | rushers | barrier. A
merchant on any other layer is created, positioned, replicated, drawn, and walked
straight through — and a test asserting he exists passes the whole time.

This is the **sixth** time this project would have paid for that bit; CLAUDE.md
carries five. Give him a named `layer_10 = "merchant"` in `project.godot` and put
that bit in the player mask (151 -> 663). Named because a named bit is one you
can read back, and asserted directly (`merchant.collision_layer &
body.collision_mask != 0`) because a position assertion that fails for this
reason takes an hour to explain.

Do not park him on the stones layer to save the step. It works, and it means
every future rule written about stones silently acquires an opinion about the
shopkeeper.

### 4. HE IS GRID CONTENT, SO ONLY HIS SPENT-NESS IS REPLICATED

Same shape as a mound, a shooter and a heart, and for the same reason: the bridge
is a pure function of its seed, so every machine builds the merchant from the
segment and needs telling only that he is used up. `bridge_grid.gd` already has
the pattern three times over — `_spent_mounds` / `spent_mound_layout()` /
`apply_spent_mounds()`. Copy it; do not invent a fourth shape.

The trade itself is one reliable event: a hat destroyed and a hat spawned worn,
both of which the pool already has RPCs for.

### 5. "DOES NOT PERSIST" IS A CHANGE TO WHICH HAT IS SAVED, NOT A GUARD ON SAVING

A tall hat does not survive a launch (decided 2026-08-18). It is yours for the
run and the next session starts you without it.

The obvious implementation is wrong, and wrong in the direction that makes the
merchant free. `_remember_hat` is the single choke point — `_wear_hat` calls it
with the hat just picked up (`game_world.gd:1819`) and `_forget_hat_if_bare`
calls it with `worn[worn.size() - 1]` (`:1877`). **That index is the TOP of the
stack**, because `HatPool.worn_by` sorts by `stack_index` ascending, and a hat
arrives on top — so both paths hand it the tall hat the moment you own one.
(`m8_5_hats.md` says the saved hat is the "bottom of your stack"; the code says
top. The code is what ships.)

Guarding `_remember_hat` with an early `return` on a tall style leaves whatever
was on disk before. Walk that through: you own one ordinary hat, saved. You trade
it for a tall one. The trade consumed it, the tall hat is refused by the guard,
and the disk still names the hat you just spent — **so next launch hands you back
the hat you paid with.** The merchant becomes free across sessions, and the symptom
is invisible until somebody restarts the game.

Saving `NONE` whenever the top is tall is wrong in the other direction: a stack of
`[ordinary, tall]` would discard an ordinary hat you still own and are still
wearing.

**The correct rule is one line and it is about SELECTION: save the topmost hat
that is not tall, and `NONE` if there is no such hat.** Every case then falls out
right — `[tall]` saves nothing (you spent your hat and got something that does not
keep), `[ordinary, tall]` saves the ordinary one, and trading up from a bare-but-
for-one head really does cost you your saved hat. Both call sites go through the
same helper, which also makes `_wear_hat` stop assuming the hat it was handed is
the top one.

#### REVERSED 2026-08-23 — the whole stack is saved, tall hats included

*"I am fine with the tradeoff — it is more fun to keep your big hat."* So the
selection is no longer a selection: `_persistable_stack` returns every worn style
in order and the config holds an array.

**Name what it costs, because that is the only thing that makes a reversal worth
anything.** The trade is a *purchase* now rather than a bet, and a fall is the
only thing left that can take a trophy off you. That was the argument for the old
rule and it was a good one; it lost to the game being more fun.

**The load-bearing half of this finding is untouched, and it is worth saying so
explicitly.** Everything above about SELECTION VERSUS A GUARD still holds — the
save is rebuilt from what you are wearing every time, so a hat you spent is gone
from the file the moment it leaves your head. A guard with an early return would
still leave the disk naming the hat you paid with and still make the merchant
free across sessions. `test_merchant_save` still asserts exactly that, and it is
the assertion that did not change when the rule around it did.

## Where he stands

`hazard_dressing.gd` places content by rule against a per-theme budget, and a
merchant is the first entry whose budget wants to be *fractional*. The pass is
deterministic in `(run_seed, index)`, so rarity is `_mix(salt) % N == 0` rather
than a float — same mixer, no global RNG, and a given seed puts him in the same
place on every machine.

His placement rules, in the language `_wants` already speaks:

- **Open ground, with clearance.** `_open_run` plus `not _near_content`. A
  shopkeeper behind a tree is a shopkeeper nobody finds.
- **Never near a lift**, which the `DANGEROUS_KINDS` check already enforces for
  hazards — and here for the opposite reason. A rider carried past him is a hat
  spent by the terrain.
- **NOTHING DANGEROUS BESIDE HIM, and this is the rule that needs adding rather
  than reusing.** Every other kind asks "where do I want to be"; the merchant is
  the first that needs the hazards to ask about *him*. He must be placed first
  and then excluded, or `_near_content` extended.

That last one is a bug being written down before it happens. **A dash is also how
you fight.** A merchant three cells from a rusher means a player dashing at the
rusher clips the shopkeeper and loses a hat to a trade they never made — and the
report will say *the rusher took my hat*, because that is the only attribution
available from inside the game. CLAUDE.md's 2026-08-16 entry is this exact shape:
a spike block two cells from a lift, reported for three rounds as "the elevator
hurts you."

## What the tests have to pin

Written before the code, because most of these are claims a test can hold while
being false.

| test | what it pins |
|---|---|
| `test_merchant_trade` | a press at him takes the TOP hat and returns a tall one; **a second press does nothing** (spent); a player with no hats gets nothing and loses nothing; **and a dash with no press behind it is not a trade** — the control that makes the verb change real, since every other phase still arrives at speed |
| the refusal | a player whose top hat is tall dashes in, keeps every hat, and gets nothing — **and the merchant is still unspent afterwards**, because a refused trade that burns the sale is a merchant the next player finds empty for no reason |
| the save rule | *(reversed 2026-08-23)* `[tall]` saves the tall one; `[ordinary, tall]` saves both, bottom-first; **trading your only hat leaves the disk naming the trophy and NOT the hat you spent** — that last clause is the one the naive guard fails and is still the whole point of finding 5 |
| `test_merchant_reach` | the mask bit is set AND a body dashed at him under power actually stops — a blocker that exists is not a blocker that blocks |
| the tall slot | a stack of `[normal, tall, normal]` is spaced by each hat's own slot, **and the hit columns tile with no gap** — sample a ray at several heights up the tall hat, not once at its centre |
| the reserved band | 10k rolls of `spawn_loose` produce no hat in the band; the band's hats are 3–4x a slot |
| `test_merchant_placement` | over many seeds, no dangerous content within N cells of a merchant — **and A/B it with the rule deleted**, per the 2026-08-16 note about a test run on the wrong object passing at 250 seeds |

The last one is the one most likely to be green and worthless. `BridgeGrid`
places hazards at load; `SegmentGen.section()` output has none in it.

## Open questions

1. **Does he say anything?** There is no dialogue system and this does not want
   one. **[proposal]** the trade is legible entirely from the geometry: he is
   holding the tall hat, visibly, and after a sale he is not.
2. **What happens to a spent merchant when the party wipes?** A merchant inside a
   section the party has to replay should probably come back. Follows whatever
   `_settle_round_transition` does to spent mounds; not decided here.
3. **Should a tall hat be worth more at the round end?** It is currently worth
   exactly one hat to `stat_registry`, which ranks by tower height. Given it
   *cost* a hat, a trade is score-neutral and buys only the silhouette and the
   joke. That may be the right answer — the item sells itself on being visible,
   not on being points — but it is the number to look at first if the merchant
   reads as pointless in playtest.

**Answered 2026-08-18:** he will not accept a tall hat as payment (see The three
decisions), and a tall hat persists across launches like any other (reversed
2026-08-23 — see finding 5, which is where the non-obvious half of that lives and
where what the reversal costs is written down).

## Tunables

Starting values with reasons, per house rules — every one expected to move.

| constant | value | why |
|---|---|---|
| `TALL_HAT_SLOTS` | 3.5 | 1.225 m in one slot. Three is barely a statement; four plus one lean of 5° starts swinging further than the head it is on |
| `TALL_STYLE_COUNT` | 8 | a handful of distinct trophies rather than one, so two players with tall hats do not have the same hat. Matches `PALETTE.size()` |
| `MERCHANT_RARITY` | 1 in 6 segments | rare enough to be an event, common enough that a session sees two |
| `MERCHANT_CLEARANCE` | 3 cells | the radius nothing dangerous may be placed inside. Bigger than a rusher's reaction distance, which is what the accidental-trade case is really about |

## Explicitly not in this

- **Anything he sells that is not a hat.** The moment he sells a rocket he is a
  balance surface and every segment he appears in is a segment with a free
  special in it.
- **Buying back.** One direction only; a shop you can sell into is an economy.
- **A currency.** The hat *is* the payment. Nothing counts, nothing accumulates.
- **More than one item on offer.** A choice needs a UI, and the whole reason the
  dash works as the verb is that there is nothing to choose.
