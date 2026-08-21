# Character customization

Proposed 2026-08-20. Four cosmetic slots — **eyes**, **nose**, **one accessory**
(horns / antlers / tail), and a **personal colour** — chosen on a character
screen reached from the main menu, previewed as a full-body model, and saved
across sessions.

## One line

The first thing in this game that is yours, that nobody can take, and that does
nothing.

## Status

Built so far (2026-08-20), in the order it landed:

| piece | state |
|---|---|
| **nose — the beak** | shipped. A triangular prism replacing the box; a straight replacement of the facing marker, not a slot you choose from |
| **the character screen** | shipped. Opened from the menu, with a full-body turntable preview built from the real player scene |
| **the derived nose colour** | shipped — `character_style.gd` |
| **personal colour** | shipped end to end: chosen on the screen, saved to `user://player.cfg`, worn by the body, and replicated to everyone |
| **eyes** | shipped, and **not as a slot** — see below |
| **one accessory slot** | shipped — horns, antlers, a tail, or none |
| **colour in the HUD and score screen** | not built — the value is on the body only |

The nose was deliberately narrowed to one shape. The original ask was a *better
nose*, and the six-variant catalogue below over-built it into a menu; shipping
one costs nothing a slot would later need, because the catalogue is written down,
the budget governing it is measured, and `test_nose_shape.gd` already asserts the
contract any future variant must meet.

That is a deliberate narrowing and it is worth saying why it is safe. The nose
was never going to be a *choice* in the first pass: the original ask was a
better nose, and the six-variant catalogue in this document over-built it into a
menu. Shipping one shape costs nothing that a slot would later need — the
catalogue is written down, the budget that governs it is measured, and
`test_nose_shape.gd` already asserts the contract any future variant has to meet.

**And the beak is the most conservative possible version of the change:** it
occupies exactly the box the old wedge did, so the one measured property of the
marker — 0.35 m of protrusion past the body — is untouched. Only the plan-view
outline moved, from a square tab to an arrow.

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

**THE COLOUR TAKES THE WHOLE BODY** (decided 2026-08-20), replacing the hardcoded
blue rather than sitting on a band or a sash. This answers `art_direction.md`'s
open question 1, open since 2026-08-15, and it answers it in the expensive
direction: **every art style in the bake-off must now survive an arbitrary body
colour.** `SITE`'s hi-vis worker and `GOUACHE`'s painted cloak both assumed a
neutral body with colour on an accessory, and neither assumption holds any more.
That is a real constraint on a decision that has not been made yet, and it should
be carried back into the bake-off rubric rather than discovered when a style
comes back beautiful and monochrome.

**And it lets a player dress as a threat.** `hat_style.gd:28-32` keeps blues and
red-oranges out of the hat palette precisely so a hat reads as "not scenery, not
a player, not a threat"; the shield comment in `player.tscn:84-85` says the
palette's rule is that warm things hurt you. A whole-body free picker means
somebody will choose rusher-red, and at 30 m a red thing on the bridge currently
means *charging at you*.

This is a different problem from the one the free-picker decision accepted. "Two
players look alike" was chosen knowingly; "a player looks like an enemy" is a
consequence of pairing that choice with whole-body, and it was not. **The
existing answer is contract rule 1 — silhouette carries identity, colour carries
team** — and it holds here: a rusher is a cone, a player is a cylinder that never
tips, and the two are different shapes at any distance. So this is logged as a
known cost with a standing defence rather than as a blocker. It is the second
thing to look at if playtest reports mistaking players for hazards, the first
being whether the shapes are as distinct in motion as they are at rest.

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

## The catalogue

### Two budgets, pointing opposite ways

Measured off `player.tscn`. The body is a cylinder of **radius 0.4**, height 1.8,
origin at its centre. The nose is a `BoxMesh` of `(0.3, 0.3, 0.5)` at
`(0, 0.35, −0.5)`, so its front face is at z = −0.75.

**THE NUMBER THAT MATTERS IS NOT THE NOSE'S SIZE. IT IS HOW FAR IT STICKS OUT
PAST THE CYLINDER.** From a camera looking down at 60 m of bridge, the body is a
circle, and the only part of the nose that contributes anything to the facing
read is the part outside that circle. The current nose runs from the silhouette
edge at z = −0.4 out to z = −0.75:

> **Protrusion budget: 0.35 m.** That is the entire top-down facing marker.

A variant can be twice the volume and read as *nothing* if it hugs the body — and
this is the trap the whole slot has, because a bigger nose looks more legible in
the character preview, where the camera is at eye level, and the preview is where
every one of these will be judged. **The preview is the one view that cannot see
the property the nose exists for.**

Accessories have the mirrored constraint. Contract rule 1 says silhouette carries
identity, and the identity being carried is "that is a player, not a hazard" — so
lateral spread has a **ceiling** where nose protrusion has a **floor**:

> **Spread budget: an accessory may not make the top-down silhouette
> unrecognisable as a cylinder.** Antlers are the variant that tests this.

Two opposite rules, one reason: the top-down outline is the whole communication
channel, and the nose is trying to break the circle while the accessory is trying
not to.

### Noses

Every one is asymmetric about −Z, brighter than the body by the derived contrast
rule, and hangs off the `Facing` pivot.

**Only `BEAK` is built.** The other five are recorded as a catalogue to draw from
if the nose ever becomes a slot; none of them is implemented.

| variant | shape | from directly above | protrusion | note |
|---|---|---|---|---|
| **WEDGE** | a box, blunt | a square tab | 0.35 | The shape the game shipped until 2026-08-20, and the control every other row is measured against |
| **BEAK** | tapers to a point | a triangle | 0.35 | **SHIPPED.** A `PrismMesh` in exactly the wedge's bounding box, so the protrusion is unchanged and only the outline moved. A prism and not a cone: pointy in plan view, full height from the side, where a cone would have thrown the mass away |
| **SNOUT** | rounded, wider, slight droop | a broad tongue | 0.28 | Widest and shortest. Sits at the **floor** of the budget, so it is the first thing to re-measure if anyone reports a bad facing read |
| **FORK** | two forward-swept prongs | a V | 0.35 | The gap is the character. Keep it ≥ one prong's width, or at range the prongs merge and it is a wedge that cost twice as much |
| **PROW** | a tall thin vertical blade | **a line** | 0.40 | **The risky one.** A line has no width to catch the eye from above — it is the least readable variant in the set and needs a width floor or it should be cut |
| **VISOR** | a shallow arc wrapping the front, pointed at centre | a forward-biased crescent | 0.30 at centre | Most of the arc hugs the body and contributes nothing. The centre point does all the work and must clear the budget alone |

### Eyes — NOT A SLOT (decided 2026-08-20, shipped)

**Everybody gets eyes and nobody chooses them.** They are not something you
equip; they are what a face is. What varies is a little shape, and a chance the
two do not match.

The six-variant menu this section used to propose is deleted rather than
deferred. It was the same over-build as the nose catalogue — turning "characters
should have faces" into a thing to shop for — and here the cost is worse, because
an eye style you pick is an eye style you can pick badly, and the art direction
already says eyes must *lose* at gameplay range rather than compete with the nose
for the facing channel.

**Derived from a saved seed, never rolled at spawn.** This is `hat_style.gd`'s
opening constraint and it applies with full force:

- a `randf()` at spawn gives you a different face every launch, which is the
  precise opposite of what this feature is for;
- and a different face on every *machine* at once, so the wonky eye your friend
  is laughing at is not the one you can see;
- and it is untestable, because a draw from the entropy-seeded global RNG has no
  correct answer to assert.

So the seed is rolled **once**, on a first launch, saved beside the colour, and
replicated beside it. Everything about a face is a pure function of it.

Note this makes the seed the second thing in `player.cfg` that is *dealt* rather
than *chosen* — the hat being the first — and it is dealt for the same reason: a
default nobody rolled would give every player on earth the same face.

| knob | range | note |
|---|---|---|
| size | 0.038–0.055 | small enough to be lost at bridge range, deliberately |
| spread | 0.10–0.145 | lateral, either side of the centreline |
| height | 0.50–0.60 | above the nose, below the top of the head |
| asymmetry | **35% of faces** | a minority: if everyone is odd then nobody is |

Asymmetry picks *which* eye and *in what way* from separate draws — size, height,
or a bit of both — because one draw would make every odd face odd in the same
direction, which reads as a broken model rather than as a face.

**Eye colour is a constant where nose colour is derived, and that asymmetry in
the design is deliberate.** A pale sclera with a dark pupil carries its own
contrast: on a dark body the white ring reads, on a pale one the pupil does.
There is no body colour that hides both, so there is nothing to derive.

### Accessories

One at a time. Mesh only — no `CollisionShape3D`, no layer, no mask. All hang off
`Facing` so they turn with the aim, and none of them raise `mount_y`.

**Three are built; `EARS` and `SPIKES` are catalogued and not implemented.**

| variant | shape | measured spread | note |
|---|---|---|---|
| **HORNS** | two short thick cones, curving out and up from the sides | 0.37 | **SHIPPED.** The safest: short, close to the head, unmistakable. Splayed outward so the vertical column stays the hats' |
| **ANTLERS** | a beam and two tines a side | 0.42 | **SHIPPED**, and the variant that tests the ceiling. Visible from above precisely *because* it splays — the point and the risk in one property |
| **TAIL** | one tapered cone, trailing low behind on the aim axis | 0.09 | **SHIPPED.** A **rear-pointing facing cue**, reaching 0.26 back against the nose's 0.35 forward — asserted, so it can never out-shout the marker |
| **EARS** | two rounded flaps, drooping outward | low | catalogued only. Mostly a close-range read, like eyes |
| **SPIKES** | a lateral row of small spines along the sides | minimal | catalogued only. Reads as texture on the outline rather than as protrusion |

**Stored and replicated by NAME, never by index.** An integer index into the
list is a value that silently remaps the day anybody reorders it — every saved
character would quietly grow different antlers. The cost is that a config file or
a packet can name something this build has never heard of, so an unknown name
wears nothing rather than raising, and the host **validates the name off the
wire** before it reaches anybody else's roster.

**Cut: `CREST`** — a fore-aft ridge along the top of the head. Disqualified twice
over, which is why it is worth recording rather than quietly omitting. It sits in
the **hat column**, which is the one thing an accessory may not do; and from
above it is a fore-aft line through the body's centre, which is *a facing cue* —
a second one, in a different place, competing with the nose. Either fault alone
would be enough.

### The default character

**WEDGE nose, DOTS eyes, no accessory, and the current blue** —
`Color(0.25, 0.6, 0.85)`.

That is not a placeholder, and choosing it is the point. A first-launch character
is what most players are seen as for their first session, so it has to be a
deliberate design rather than the absence of one. The deliberate design available
here is **the player the game already ships**: the only nose with a proven facing
read, and the one body colour the entire art direction was built around —
`player.tscn:25-26` picked it to be "obviously not scenery", and `hat_style.gd`
excludes blue from the hat palette to keep it unambiguous.

So an unconfigured player looks exactly like a player looks today. Everything in
this feature is something you opt into, and the baseline is the one configuration
with a track record.

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

**BUILT 2026-08-20, AND NOT THE WAY THIS SECTION ORIGINALLY SPECIFIED.** The
first draft said to copy the worn-hat channel. That was the wrong pick, and the
reasoning is worth keeping because it is a choice this codebase offers more than
once.

The hat channel is a **per-object** RPC: `_wear_hat` names a hat and a body, and
opens with `if hat == null or body == null: return`. So it carries an ordering
trap — anything sent before the newcomer has been told who exists is dropped in
silence. `host_add_peer:4463-4477` is a long comment about that exact bug, which
shipped and was reported as "hats do not appear on other players when joining."

But **a colour is not per-object state. It is per-peer metadata, exactly like a
display name** — and the names channel has no ordering trap at all, because
`_set_names` stores a dictionary and lets whoever needs it read it later.

So the built version rides the names channel:

| names | characters |
|---|---|
| `player_names` dictionary | `player_colours` dictionary |
| `_announce_name()` at `start()` | `_announce_character()` beside it |
| `_submit_name` — `@rpc("any_peer", ...)` | `_submit_character`, same |
| `_set_names` — `@rpc("authority", ...)` | `_set_characters`, same |
| `_broadcast_names()` in `host_add_peer` | `_broadcast_characters()` beside it |

**And it applies from BOTH ends**: `_spawn_player` paints from the dictionary,
and `_set_characters` paints everyone already present. Whichever arrives second
does the work, so **there is no order in which a player ends up the wrong
colour** — the property the hat channel had to be taught with a comment is
structural here instead.

One consequence worth stating: a peer with no entry is not an error, it is the
default. That is what makes practice partners, late joiners, and a client whose
announcement is still in flight all *correct* rather than merely tolerated.

The general lesson: **ask whether the thing you are replicating belongs to an
object or to a peer, and pick the channel that matches.** Copying the nearest
existing RPC inherits its constraints along with its shape.

**Can a character change mid-session?** No, and today that is free rather than
enforced: the button that opens the screen is on the menu, and the menu is hidden
while a world runs. The colour is read at world construction. If the screen ever
becomes reachable mid-run, `_announce_character()` is already the whole
mechanism — it can simply be called again.

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
| the facing contract | **DONE — `test_nose_shape.gd`.** Asymmetric about −Z, and **protrusion past r = 0.4 within the budget** — a floor as well as a ceiling. A shape that clears the ceiling and misses the floor looks fine in the preview and says nothing from the camera, which ships as "the dash went the wrong way" |
| the taper | **DONE, and it is the only assertion there that a box fails.** An AABB cannot tell a prism from the box it was cut from, so the beak is asserted from its **vertices**: full width where it meets the body, narrowing to a point at the tip. See below — this is not a nicety, it is the assertion that caught the shipped bug |
| the spread budget | **DONE — `test_accessory.gd`.** Measured off the BUILT meshes, not the declared numbers |
| accessories do not collide | **DONE, and A/B'd.** Asserted over the whole subtree, not just the root — the failure would be one part with a shape on it. Giving every part a `CollisionShape3D` failed all three kinds |
| the hat tower is unmoved | **DONE.** A real three-hat stack posed with antlers and without, compared height by height — plus an assertion that the hats really are stacked, because three equal numbers prove nothing if the tower had no height |
| **they splay outward** | **DONE — and its first version was worthless.** It checked that the widest point exceeded 0.3, and **passed with the horn tilt reversed**, because a horn attached at x = 0.26 with radius 0.075 already reaches 0.335 untilted. The number was satisfied by the mounting point. A direction claim has to be measured as one: each piece's tip against its own base. Only the A/B found this |
| horns vs. the hat column | a stack of three hats is spaced identically with horns and without — **and assert the comparison can fail**, or it is a pair of numbers nobody checked |
| accessories do not collide | no `CollisionShape3D`, and the accessory's layer is masked by nothing. Six bugs in this project have been one wrong bit here |
| persistence | **DONE — `test_character_config.gd`.** Round-trips; shares a file with the saved hat in both write orders; survives a corrupt value; `path_override` asserted to actually redirect, so the gate cannot eat a developer's character |
| the default | **DONE.** A first-ever launch produces the same character on every machine — no roll — and reading a default does not write a file |
| replication | **DONE — `test_character_replication.gd`, over a real socket.** Both directions, and the colour is asserted **on the material the renderer uses**, not in a dictionary. A/B'd twice: with the broadcast disabled, and with the body reusing the scene's shared material |
| **two players, two colours** | **DONE, and it is the assertion that earns the test.** Every other claim asks about one body at a time and would pass while the whole party shared one material. A/B confirmed it: both avatars came back the same green, in *both* worlds |
| eyes | **DONE — `test_eyes.gd`.** Deterministic and untouched by the global RNG; every seed including 0 gets two eyes, one either side; the asymmetry RATE is a minority rather than a stuck predicate; a face flagged symmetric really matches and one flagged asymmetric really differs; and the meshes are actually built, under `Facing`, without stacking a second pair on re-apply |
| **the flag agrees with the geometry** | **DONE, and A/B'd.** Suppressing the perturbation while still setting the flag failed *only* that assertion — the rate check stayed green. A test that measured the asymmetry rate alone would have passed while no face was ever actually asymmetric |
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
| `NOSE_PROTRUSION_MIN` | 0.28 | the floor, set by `SNOUT`, the shortest variant. Measured past r = 0.4, not from the origin |
| `NOSE_PROTRUSION_MAX` | 0.40 | the ceiling, set by `BEAK` and `PROW`. The current wedge's 0.35 sits between them by construction |
| `EYE_SCALE` | small | sized to be lost at bridge range on purpose, so it never competes with the nose for the facing channel |
| `ACCESSORY_SPREAD_MAX` | tbd | the top-down ceiling. Set it from `ANTLERS`, which is the only variant near it, and expect it to be the number that moves |
| `ACCESSORY_SPLAY` | outward | horns clear the hat column laterally. The number is whatever keeps `mount_y` untouched |
| `PREVIEW_SIZE` | explicit | never inherited — the headless viewport is 64×64 |

---

## Open questions

1. **Can the screen be opened mid-session?** Assumed no above. Yes is nicer and
   means re-checking the RPC ordering rule.
2. **Is the preview model reused on the score screen?** It should be — it is the
   other place a character is seen close — but that is a second consumer of the
   same viewport trick and it is not free.
3. **Does whole-body colour change the art bake-off's rubric?** It should. See
   the colour section: two of the six proposed styles assumed a neutral body.

---

## Explicitly not in this

- **Any gameplay effect whatsoever.** The moment an accessory changes a hitbox, a
  reach or a silhouette that something shoots at, it is equipment and it belongs
  in a different document.
- **Unlocks and progression.** Everything is free from the start (decided
  2026-08-20). Earned cosmetics are a second economy, and hats are the first.
- **Per-slot colour.** One colour, taking the whole body. Five independently
  coloured parts is a character nobody can pick out at range and a picker nobody
  finishes using — and the nose is already spoken for, since it is derived.
- **Conflict prevention on colour.** Decided 2026-08-20. No reservation, no
  auto-nudge; two players may look alike.
- **Multiple simultaneous accessories.** One slot (decided 2026-08-20).
- **Names, badges, titles, emotes.** Different feature, different document.
