# Character customization

Proposed 2026-08-20. Four cosmetic slots — **eyes**, **nose**, **one accessory**
(horns / antlers / tail), and a **personal colour** — chosen on a character
screen reached from the main menu, previewed as a full-body model, and saved
across sessions.

## One line

The first thing in this game that is yours, that nobody can take, and that does
nothing.

## Why this is not a second hat system

Hats are already the game's cosmetic, and every rule about them is the *opposite*
of what this wants. `m8_5_hats.md` is explicit: "the moment a hat is worth
wearing for a reason other than points, it stops being a bet and starts being
equipment." A hat is stealable, poppable, scored by `stat_registry`, procedurally
rolled, and gone the moment you tumble. That is the whole design and it works.

A character is the other half of that sentence. **It is never on the table.** It
cannot be stolen, cannot be lost, is worth zero points, is not rolled, and
survives a wipe. The two systems share a head and nothing else.

This matters more than it sounds, because it decides every ambiguous case in
advance. Anything that would make a character droppable, scoreable, earnable or
enviable is out of scope by construction — not because it is a bad idea, but
because we already have a system for that and it is called a hat.

The sentence hats produce is *"that is MY hat on your head."* The sentence this
produces is **"that one's me."**

---

## The four slots

Settled 2026-08-20 with the user, with what each one costs.

### Colour: a free RGB picker, no conflict prevention

Any colour, always. Two players may turn up looking similar and that is
accepted.

**This is a deliberate trade against a written contract and it should be
recorded as one.** `art_direction.md`'s readability table lists the avatar's
first job as "*whose* it is (4-way colour read)", and rule 2 makes team colour
survive every proposed art style. A free picker spends that channel on
self-expression instead. The counter-argument is that the read never actually
existed — every player in the game today is the same blue — and that the nose,
the hats and the HUD row all still separate people. It is reversible: a curated
palette is a smaller change than a picker, so if playtest reports "I could not
tell who was who", the fix is available.

**But the colour has to travel as DATA, and that is a real break from the hat
system.** `hat_style.gd` opens with the constraint the entire hat feature hangs
on — the look is a pure function of an integer, never rolled at spawn, because
the integer is what travels on the wire and what makes a stolen hat stay the hat
it was. **A free picker has no id.** There is no integer to derive
`Color(0.31, 0.77, 0.42)` from, so the colour is three floats on the wire rather
than a seed.

That is fine, and the reason it is fine is worth writing down: **a character is
never stolen.** It only ever travels from its owner outward, so it needs no
identity that survives changing hands. The property the hat system paid for is
one this feature does not need. Do not copy the id-derivation trick here out of
symmetry — it would mean quantising the picker back into a palette, which is the
decision we just declined.

### Nose: a redesign of a load-bearing element, not a cosmetic

`player.tscn:67-73` says it outright, and it is the most important paragraph in
this document:

> Not cosmetic: the shove commits to one of four compass axes chosen from the
> movement input at the instant of the press, so a player about to dash needs to
> know which axis they are on BEFORE they commit. A featureless cylinder cannot
> tell them.

So "better nose shape" means **several shapes that all do that job**, not several
shapes. Every variant inherits the contract:

- **Asymmetric along −Z.** Local −Z is forward at rest (`player_body.gd:544-551`;
  `GridConfig.yaw_vector` returns `Vector3(-sin(yaw), 0, -cos(yaw))`). A
  symmetric nose is not a nose, it is a hat.
- **Readable from directly above**, which is contract rule 4 — the camera frames
  60 m of bridge and top-down silhouette does the work.
- **Brighter than the body**, per the existing material comment, and see the
  contrast rule below, which is now a computed thing rather than a constant.
- **Inside the collider's footprint or honestly overhanging.** The current nose
  already sticks out to z = −0.5 against a 0.4 radius. That overhang exists and
  nobody has reported it, so it is the budget: do not exceed it.

Within that, the shapes can differ a lot — a wedge, a beak, a snout, a blunt
prow, a pair of forward-swept fins. What they may not do is get smaller, get
dimmer, or become symmetric.

**A NOSE VARIANT IS THEREFORE THE ONE SLOT THAT CAN SHIP A GAMEPLAY BUG**, and it
will present as "the dash went the wrong way" rather than as an art problem.

### THE CONTRAST RULE, which the free picker forces into existence

The nose is `Color(0.95, 0.85, 0.25)` — a hardcoded bright yellow
(`player.tscn:35-37`). It reads because the body is always
`Color(0.25, 0.6, 0.85)`, a hardcoded blue. **Both halves of that were constants,
and the picker deletes one of them.**

A player who picks yellow gets a yellow nose on a yellow body: the facing marker,
which the design doc above calls load-bearing, becomes invisible. Not subtle —
gone. And it is worse than a uniformly bad outcome, because it is *one region of
the picker*: the feature works perfectly for every colour anybody tests with and
fails for the handful nobody thought to try.

**So the nose colour is DERIVED from the body colour, never stored.** Something
of the shape "rotate the hue far from the body's and force a luminance gap", with
the gap as a tunable. The test for this is not "is the nose yellow" — it is
**sweep the whole picker and assert a minimum perceptual distance at every
sample**, including the exact yellow that used to be the constant.

This is the same shape as CLAUDE.md's repeated lesson about asserting a
relationship rather than a value, arriving from a new direction: the moment one
side of a pair becomes user data, the other side stops being allowed to be a
literal.

### Eyes: honest about what they are for

**Eyes will not read at gameplay distance, and the art direction says so in as
many words.** Contract rule 4: "Top surfaces and top-down silhouettes do the
work. **Faces do not.**" A high camera over 60 m of bridge is looking at the top
of a cylinder; eyes are on its side.

That is not an argument against them. It is an argument about where they pay off,
and they pay off in three real places:

1. **The character screen itself**, which is the feature this document is mostly
   about, and where the model is close, framed and still.
2. **Downed and hanging players**, whom teammates approach and crouch over —
   the one moment the game reliably puts a camera near a face.
3. **The score screen**, if the preview model is reused there, which it should be.

What must not happen is eyes being *sized up* until they read from the bridge
camera, because the only shape that achieves that competes with the nose for the
facing channel — two bright marks on the front of a cylinder, one of which means
"this is where the dash goes" and one of which means nothing. **Eyes stay small
enough to lose at range, deliberately.**

### One accessory slot: horns, antlers, or a tail

One at a time, or none. Everything free from the start (decided 2026-08-20).

The single-slot decision is doing more work than it looks. A top-down camera
reads silhouette, the head already carries a tower of hats, and independent
toggles mean a player wearing horns *and* antlers *and* a tail is a shape nobody
designed. One slot keeps every possible player a shape somebody drew.

Two constraints, both of which are bugs if they are found later:

**HORNS MAY NOT RAISE THE HAT COLUMN.** `hat_pool.pose_stack` starts a tower at
`body.global_position + Vector3(0, mount_y, 0)` and walks up by each hat's own
`slot_height()` (`hat_pool.gd:106,121-123`), and `hat_body.gd` sizes the worn hit
column off that same function — the 2026-08-16 lesson that a slot spaced one way
and shot at another is a tower with holes in it. If horns push `mount_y` up, then
a cosmetic choice has changed how tall your hats sit, which changes your
silhouette, which changes what a shooter's flat-travelling round meets first.
**That is a gameplay effect, bought with a cosmetic**, and it is exactly the line
this feature exists on the other side of. Horns splay *outward*; the vertical
column above the head belongs to hats.

**NO ACCESSORY GETS A COLLISION SHAPE.** Contract rule 3 allows decorative
overhang only where nothing collides. A tail that catches a dash is a cosmetic
that changes a fight; a horn you can stand on is the "hat you can stand on is a
ladder" note from `player.tscn:150-152`, which is why worn hats have their shapes
disabled. Accessories are mesh and nothing else, and a test should assert that
rather than trusting it — this project has now paid for one wrong collision bit
six times.

The tail hangs off the `Facing` pivot so it trails the aim axis. Note that this
makes it a **second, rear-pointing facing cue**, which is a small bonus and a
small risk: it must never be brighter or larger than the nose, or the player has
two markers and the wrong one is louder.

---

## The character screen

### It is built in code, because everything here is

There is no menu scene to extend. `scenes/main.tscn:13-47` is a single
`VBoxContainer` with three buttons and a status label, and the entire menu "state
machine" is `world == null`, toggled with `menu.show()` / `menu.hide()`
(`main.gd:103,111,129`). `scenes/ui/` does not exist; `hud.gd`, `score_screen.gd`
and `debug_console.gd` are all built procedurally in `_ready()`, and `main.gd:41-45`
says that is the convention on purpose.

**`debug_console.gd` is the model to copy.** It is a `CanvasLayer` constructed
entirely in code, instantiated lazily on first open (`main.gd:167-176`), opened
from the menu with no world running (`main.gd:70-72`), and — the part that
matters — it **walks a declarative options table and builds one row per entry**
(`debug_console.gd:84,93,121-194`).

A character screen is that with four entries. The slots become a table, the table
becomes rows, and adding a fifth slot later is one dictionary entry rather than a
layout change.

### The preview, and the trick that makes it honest

A `SubViewport` containing a camera, a light, and a **standalone preview body** —
a bare `Node3D` with the same named children the real player scene has.

The pattern already exists and is already argued for. `HatStyle.apply_style(node,
style_id)` (`hat_style.gd:199-247`) writes meshes and materials onto any `Node3D`
carrying `Crown` / `Brim` children, with no live `HatBody` involved, and
`merchant_body.gd:106-131` uses exactly that to build the hat he holds up as
signage. The reason given there is the reason to do it here:

> built from this function rather than modelled by hand so that the thing on the
> counter is provably the thing you get — a lookalike would drift the first time
> the trophy's proportions were tuned.

So: **one static `CharacterStyle.apply_style(node, character)`**, called by the
real player body and by the preview both. A preview built any other way is a
promise that rots.

Four traps, three of them already in CLAUDE.md:

| trap | consequence | source |
|---|---|---|
| the headless viewport is 64×64 | never inherit the size; set the `SubViewport` explicitly | CLAUDE.md, cost a whole marker test |
| `--headless` disables rendering | the picture cannot be gated. Test the **style function**, never the image | `art_direction.md` Stage 0 |
| headless still builds the whole Control tree and runs `_ready`/`_process` | so the screen **is** testable for construction, and a UI script never instantiated in the gate ships having never run | CLAUDE.md, `test_hud_view` |
| a `SubViewport` has no light of its own | preview is a black silhouette; give it its own light rather than borrowing the world's | new |

And the one that is not about rendering: **a `Control` parented to a `CanvasLayer`
is laid out by nothing** (CLAUDE.md, 2026-08-17, reported from play as "the score
screen is top left"). Size the root from `get_viewport_rect()` and reconnect on
`size_changed`. Assert `size` and `position`, not the anchors — asserting the
input to a layout is not asserting the layout, and that is precisely how the
score screen shipped broken.

---

## Persistence

`hat_config.gd` is the precedent and it was written anticipating this:

> THE GAME'S FIRST PIECE OF STATE THAT OUTLIVES A SESSION, which is why the file
> is a plain ConfigFile with one named key rather than anything clever: **the next
> thing to persist (bindings, a chosen colour, a score) has to be able to land
> beside it without a migration.**

It names a chosen colour explicitly. So: more keys in `user://player.cfg`,
written through the same load-then-set-then-save shape that `save_style` already
uses (`hat_config.gd:53-58`) so neither file clobbers the other's keys.

**AND IT MUST HAVE ITS OWN `path_override`.** `hat_config.gd:30` exists because
without it "running the gate would read and rewrite the developer's own saved hat
— and a test that quietly mutates real user state is a test nobody can trust
twice." A character config without that line means the gate silently overwrites
the developer's character on every run.

Unlike the hat, a character has **no first-run roll**. A first launch gets a
documented default, identical on every machine, because a character is chosen
rather than dealt — and because a default that is random is a default no test can
assert.

---

## Replication

A character has to reach other players and, harder, **late joiners**. The hat
system already solved this and the solution has a known-bad ordering.

The shape to copy, all in `game_world.gd`:

| hat | character |
|---|---|
| `_wear_hat` — `@rpc("authority", "call_remote", "reliable")` (`:1811`) | `_set_character`, same annotation |
| `_worn_hat_dump()` (`:4055-4060`) | `_character_dump()` |
| `_sync_worn_hats(entries)` (`:4030-4036`) | `_sync_characters(entries)` |
| called in `host_add_peer` (`:4478`) | same place, same ordering |

**THE ORDERING IS THE WHOLE FINDING.** `host_add_peer` spawns every existing
player to the newcomer *first* (`:4458-4460`), and only then syncs worn items
(`:4478-4479`), with a comment at `:4463-4477` explaining why: `_wear_hat`
early-returns if the target body does not exist yet on the receiving client. That
is not a hypothetical — it is a fixed bug, reported as "hats do not appear on
other players when joining." **A character sync placed before the spawn loop
reproduces it exactly**, and the symptom is a joiner seeing a lobby full of
identical default-coloured players while everyone else sees the real thing.

Reliable, not the snapshot wire. `game_world.gd:3991-3997` draws the line: who is
wearing what travels reliably; a position that changes every tick belongs on the
unreliable per-tick wire. A character changes approximately never.

**Can a character change mid-session?** Simplest answer is no — it is read at
spawn and fixed for the session, which makes `_set_character` a spawn-time
announcement rather than a live channel. If the screen is reachable mid-run
later, the RPC already has the right shape; the ordering rule is what would need
re-checking.

---

## Colour in the HUD and the score screen

This is the half of "shared across HUD, accents, scoreboard" that is not free.

**There is no per-player colour anywhere in the UI today.** `hud.gd` and
`score_screen.gd` identify players by name (`hud.gd:337,445`), peer id
(`hud.gd:101,403`) and an optional Steam avatar (`hud.gd:169-174`), and every
`Color` constant in both files is a **semantic** one — `COLOR_ALERT`,
`COLOR_GRACE`, `COLOR_LEAD`, `COLOR_BADGE`. So a personal colour is new state
threaded to two new consumers, not a value being read from somewhere.

Two rules for spending it:

**Identity colour may not overwrite semantic colour.** The status bar over a
player's head means four specific things and one of them is silence
(`player.tscn:99-113`): green-over-red is injury, red-over-black is a clock
running out, blue-over-black is help arriving. A player whose personal colour is
red must not make their own bar mean something else. Personal colour goes on
**name text, a row chip, a border** — a designated zone, which is the same answer
`art_direction.md` reaches for its `SITE` and `GOUACHE` styles ("a jersey, a
flag, a painted panel"). It does not go on any element whose colour already
carries a rule.

**A chosen colour is safe to assert; a name is not.** CLAUDE.md's rule about
never asserting a display name exists because a persona name is read from the
environment and differs between a dev box with Steam running and the gate. A
personal colour is the opposite — it is data the player set, identical on every
machine — so `hud_row.colour == character.colour` is a legitimate assertion where
`name == "Player 1"` never was.

---

## What the tests have to pin

Written before the code, because most of these are claims a test can hold while
being false.

| test | what it pins |
|---|---|
| the contrast rule | **sweep the picker** and assert a minimum nose/body perceptual gap at every sample, including the exact yellow the constant used to be. One colour cannot see this bug — it is a region of the space, not a case |
| **A/B the contrast rule** | delete the derivation, and confirm the sweep goes red. Per CLAUDE.md 2026-08-17: print the mutation, and run both builds side by side |
| the facing contract | for **every** nose variant, the marker is asymmetric about −Z and its forward extent is within the current nose's. A variant that fails this ships "the dash went the wrong way" |
| horns vs. the hat column | a stack of three hats is spaced identically with horns and without — **and assert the comparison can fail**, or it is a pair of numbers nobody checked |
| accessories do not collide | no `CollisionShape3D`, and the accessory's layer is masked by nothing. Six bugs in this project have been one wrong bit here |
| persistence | a saved character round-trips; `path_override` points somewhere disposable, asserted, so the gate cannot eat a developer's character |
| the default | a first-ever launch produces the **same** character on every machine — no roll |
| late join | a joiner sees every existing player's real colour, not the default. **Assert against the host's value, not a literal**, and place the sync after the spawn loop or reproduce the 2026-08-16 hat bug |
| the screen constructs | instantiate it headless; it is a UI script, and one the gate never runs ships having never executed a line |
| the screen's layout | assert `size` and `position`, never the anchors — that distinction is why the score screen shipped in the corner |

The one most likely to be green and worthless is the horns/hat-column test, for
the reason CLAUDE.md gives about a wall of `eq(x, 0)`: two spacings that match
because neither code path ran look exactly like two spacings that match.

---

## Tunables

Starting values with reasons, per house rules — every one expected to move.

| constant | value | why |
|---|---|---|
| `NOSE_MIN_CONTRAST` | tbd | the perceptual gap the derived nose colour must clear against the body. Set it from the *current* blue/yellow pair, which is the one combination known to read at camera distance |
| `EYE_SCALE` | small | sized to be lost at bridge range on purpose, so it never competes with the nose for the facing channel |
| `ACCESSORY_SPLAY` | outward | horns clear the hat column laterally. The number is whatever keeps `mount_y` untouched |
| `PREVIEW_SIZE` | explicit | never inherited — the headless viewport is 64×64 |

---

## Open questions

1. **Does the personal colour take the whole body, or a zone?** This feature
   *forces* `art_direction.md`'s open question 1 ("does the style need to survive
   four team colours, or do we go one-avatar with colour only on an accessory?"),
   which has been open since 2026-08-15. Whole-body is the stronger read and the
   bigger constraint on every future art style; a zone is safer and quieter.
   **Worth answering deliberately rather than discovering.**
2. **Can the screen be opened mid-session?** Assumed no above. Yes is nicer and
   means re-checking the RPC ordering rule.
3. **Is the preview model reused on the score screen?** It should be — it is the
   other place a character is seen close — but that is a second consumer of the
   same viewport trick and it is not free.
4. **What does a player with no accessory and a default colour look like?** The
   default has to be a deliberate character rather than the absence of one,
   because it is what most players are seen as for their first session.

---

## Explicitly not in this

- **Any gameplay effect whatsoever.** The moment an accessory changes a hitbox, a
  reach or a silhouette that something shoots at, it is equipment and it belongs
  in a different document.
- **Unlocks and progression.** Everything is free from the start (decided
  2026-08-20). Earned cosmetics are a second economy, and hats are the first.
- **Per-slot colour.** One colour, on one designated zone. Five independently
  coloured parts is a character nobody can pick out at range and a picker nobody
  finishes using.
- **Conflict prevention on colour.** Decided 2026-08-20. No reservation, no
  auto-nudge; two players may look alike.
- **Multiple simultaneous accessories.** One slot (decided 2026-08-20).
- **Names, badges, titles, emotes.** Different feature, different document.
