# Art direction: the style bake-off

Written 2026-08-15. Everything in the game is a Godot primitive with a flat
albedo, chosen for **feel** rather than for looks. That was correct — a cone that
reads as "this thing charges you" at 30 m taught us more than a modelled enemy
would have. This doc plans the swap: how to try several art styles cheaply, on
the elements that already exist, and how to pick one on evidence rather than on
whose mood board it is.

Nothing here changes gameplay, colliders, or the network protocol. **The art swap
is a view-layer change**: meshes and materials under the same nodes, the same
`CollisionShape3D`s untouched. If a style requires a collider change, it is not a
style, it is a redesign, and it goes back to the design docs.

---

## Part 1 — The readability contract

This is the part that gets lost when a style comes back beautiful and unplayable.
Every current primitive is carrying a **specific communicative load**, and most of
those loads are written down in the `.tscn` comments. A restyle inherits the load,
not the shape.

| element | current primitive | what it MUST still say |
|---|---|---|
| **player** | cylinder 0.8 ⌀ × 1.8, team-coloured, upright, flat-bottomed | *whose* it is (4-way colour read), which way it **points** (the nose wedge), that it is standable-on |
| **facing marker** | yellow box wedge, brighter than the body | the aim axis, at camera distance, from directly above |
| **shield** | 1.15 × 1.3 plate, **feet to head, resting on the deck** | cover with no daylight under it |
| **hat** | crown + brim, per-`style_id` palette, physical prop | it is **removable and stealable** — it must read as a separate object sitting on a player, never as part of them |
| **stone / pillar** | 1.6 ⌀ × 2.0 cylinder, tan | pushable one cell; stackable; the thing balls bounce off |
| **plinko ball** | 1.2 ⌀ sphere, near-black | slow, heavy, **incoming**; visible against deck and sky both |
| **rusher** | cone, red | charges, dies in one hit |
| **skirmisher** | capsule, magenta | keeps its distance and shoots |
| **turret** | base + ring + gun, dark | **bolted down**, ignores your dash |
| **shooter** | pillar-width cylinder + barrel | part of the pillar field, but the dangerous one |
| **bullet / rocket** | sphere+tail / capsule+flame | slow enough to watch cross the gap; direction of travel |
| **specials** | five distinct **silhouettes**, deliberately not five colours | which pickup it is, at 30 m, in one warm sun |
| **heart** | red sphere | first-come-first-served, worth shouting about |
| **mound** | brown dirt cone | a rusher is about to wake here |
| **deck / ramp / water / hole** | grey slabs, ramp wedges | *walkable / climbable / pushes you / kills you* — four states, four reads |
| **parapet** | derived wall | this edge will not drop you |

Five rules fall out of that table and bind every style below:

1. **Silhouette carries the identity; colour carries the team.** The specials
   sheet already proves this out — five shapes, one palette. A style that
   distinguishes its enemies by hue has spent the channel that player identity
   needs.
2. **Team colour must survive the style.** Four saturated player colours have to
   sit on the avatar without fighting the material. A style built on rusted metal
   or muted gouache needs a designated **tint zone** — a jersey, a flag, a painted
   panel — rather than tinting the whole body.
3. **The mesh may not lie about the collider.** `show_hitboxes` exists because a
   mesh that overhangs its shape produces "I swear that missed me". Decorative
   overhang is allowed only where nothing collides — brims, antennae, flags.
4. **Everything is read from a fixed high camera framing 60 m of bridge.** Top
   surfaces and top-down silhouettes do the work. Faces do not.
5. **The bridge is furniture and must stay furniture.** Detail on the deck
   competes with the things trying to kill you. Whatever style wins, the deck is
   its quietest surface.

---

## Part 2 — Six styles

Each is a *complete* proposal: a material logic, a palette rule, an edge
treatment, and a decision about where team colour lives. They are chosen to be
far apart from each other — the point of a bake-off is coverage, not a shortlist
of near-misses. Each has a **codename** used everywhere downstream (folder names,
prompt files, sheet titles).

### A. `TOYBOX` — injection-moulded playset

> Everything in the world is a piece from the same plastic toy set. Glossy ABS,
> visible mould seams, sprue nubs left on, sticker decals slightly misapplied.

- **Material logic:** one plastic. High spec, low roughness, zero metal, a soft
  rim of subsurface on thin parts. Wear is *scuffing and stress-whitening*, never
  rust.
- **Palette:** the six-colour toy-box set — red, blue, yellow, green, white,
  black — plus one grey for the "board". Nothing is between colours.
- **Edges:** hard chamfers, 2 mm bevel on everything, no sharp corners because
  moulds cannot make them.
- **Team colour:** the whole body. This is the one style where the avatar can be
  monochrome-tinted, because a toy is monochrome by manufacture.

| element | in this style |
|---|---|
| player | a chunky figure moulded in one team colour, arms fused to the body, a peg-hole in the top of the head that the hat *plugs into*. Nose wedge becomes a moulded visor. |
| hat | a separate sprue piece in a contrasting plastic; when stolen you see the peg. |
| stone | a moulded "rock" brick with a stud pattern on top so stacking looks designed. |
| ball | a heavy black marble, high gloss, one white highlight that tracks the sun. |
| rusher | a wind-up toy: a wedge on wheels with a visible key in its back, still turning. |
| skirmisher | an army-man figure moulded in dark green, permanently in a firing pose. |
| turret | a bolted-down base plate with four visible screws and a spring-loaded gun. |
| specials | boxed accessories — the shapes are as-is but in bright accessory plastic with a printed decal. |
| deck | a grey baseplate with a faint stud grid; water is translucent blue plastic with moulded ripples. |

**Risk:** cute reads as *low-stakes*. The tumble may stop feeling like a threat.

### B. `PLASTICINE` — stop-motion clay

> Aardman. Fingerprints in the surface, armature wobble, a world someone built on
> a table and lit with two lamps.

- **Material logic:** matte clay with a slight waxy sheen; visible thumb dents
  and tool marks; seams where two colours of clay were pressed together.
- **Palette:** warm and slightly dirty — clay never stays clean. Earth base with
  three or four saturated accents that read as "fresh clay".
- **Edges:** soft, hand-formed, asymmetric. **Nothing is straight.** The bridge
  sags a little.
- **Team colour:** a clay smock or a scarf pressed onto the body — a distinct
  slab of colour, not a tint of the whole figure.
- **Motion cue:** an optional 12 fps stepped animation mode on props (not on the
  player, whose responsiveness is load-bearing).

| element | in this style |
|---|---|
| player | a squat clay figure with a pinched-out **snout** as the facing marker — the nose wedge, literally. Wire armature visible at the ankles. |
| hat | a lump of contrasting clay pressed on; leaves a dent when taken. |
| stone | a hand-rolled boulder, thumbprints visible, no two identical. |
| ball | a dark grey clay ball that picks up bits of the deck as it rolls. |
| rusher | a shrieking clay wedge with two dots for eyes; splats flat when killed. |
| skirmisher | a lanky figure holding an obviously-cardboard rifle. |
| turret | a clay drum with a cardboard-tube barrel, taped down. |
| specials | props made of card and clay, glue visible. |
| deck | corrugated card under a skin of grey clay; water is a sheet of blue cellophane, crinkled, lit from below. |

**Risk:** expensive to author — the style's whole charm is that no two objects
match, which is the opposite of instancing.

### C. `SITE` — live construction site

> The bridge is genuinely being built, and you are on it without a permit.
> Hi-vis, hazard chevrons, scaffold clamps, concrete with form-tie holes.

- **Material logic:** real PBR — poured concrete, galvanised steel, painted steel
  with chipping, hi-vis polyester. Grime accumulates in corners.
- **Palette:** concrete grey and rust brown as the field; **safety yellow, orange
  and chevron black reserved exclusively for danger and for interaction.** This
  is the style's one big idea: the game's readability need and the real world's
  safety-colour convention are the same convention.
- **Edges:** honest hard edges, weld beads, bolt heads.
- **Team colour:** the hi-vis vest and hard hat.

| element | in this style |
|---|---|
| player | a worker in a hi-vis vest over grey overalls; hard hat in team colour; the facing marker is a **headlamp cone**. |
| hat | the hard hat itself — stealing one is stealing someone's PPE, which is exactly the right joke. |
| stone | a concrete kerb block on a pallet, chipped, with a stencilled load number. |
| ball | a wrecking-ball head — pitted steel, painted-over yellow, and unmistakably heavy. |
| rusher | a runaway wheelbarrow / cement mixer on a bad castor. |
| skirmisher | a rivet gunner behind a plywood shield. |
| turret | a bolted-down nail gun on a tripod, hazard-striped, with a compressor hose. |
| specials | tool-crate pickups; each silhouette is a real tool in a foam cut-out. |
| deck | poured deck sections with rebar stubs at the seams; parapets are Heras fencing panels; water is a burst main; holes are edged in chevron tape. |

**Risk:** grime is a texture budget, and hazard yellow everywhere becomes noise
if it is not disciplined.

### D. `BROADSHEET` — inked flat cel

> Ligne claire. Heavy ink outline, three flats per object, halftone dots instead
> of gradients. A comic panel that happens to be in 3D.

- **Material logic:** unlit or two-band toon; **no specular at all**. Shadow is a
  hatched pattern locked to screen space or to the object's UVs, never a soft
  gradient.
- **Palette:** limited and printed — a paper-white ground, one ink black, and
  6–8 flats that look like spot colours with slight misregistration.
- **Edges:** a real outline pass, **thickness by importance, not by distance**:
  thick on players and threats, thin on furniture. This is a style where the
  engine can encode priority directly.
- **Team colour:** the flat fill, with the ink line constant.

| element | in this style |
|---|---|
| player | a bold flat figure, thick outline, a single hatched shadow shape. Facing is a wedge of white in the ink. |
| hat | drawn with the same weight as the player, so a stolen hat is a visible line-art change. |
| stone | a flat tan shape with three hatch marks and a thick contour. |
| ball | pure black with a white rim light — the highest-contrast object in the game, deliberately. |
| rusher | ink-red with motion lines that are actual geometry. |
| skirmisher | outlined in the same weight as the player: an equal, not furniture. |
| turret | thin outline on the base, thick on the gun — the dangerous half is inked heavier. |
| specials | inventory-icon renderings, flat, with a dot-screen fill. |
| deck | near-white paper with thin ruled lines for cell seams; water is three flat blues with a ruled ripple; holes are solid black. |

**Risk:** flat shading kills depth cues on a bridge whose whole point is verticality
and holes. Needs a hard test on "can you see the hole".

### E. `GOUACHE` — storybook painterly

> Hand-painted textures, warm and slightly faded, like a 1970s children's book
> about a very long bridge.

- **Material logic:** painted albedo doing all the work; lighting kept soft and
  low-contrast so it does not fight the paint. Texel density deliberately low —
  brush strokes should be visible.
- **Palette:** dusty and warm — ochre, sage, brick, cream — with a cool sky to
  push the bridge forward. Saturation reserved for threats.
- **Edges:** slightly irregular, painted-in shadow at contact points.
- **Team colour:** a painted banner or cloak; the body stays painted-neutral.

| element | in this style |
|---|---|
| player | a stout painted figure in a cloak of team colour, hood pointing the aim direction. |
| hat | an illustrated hat with real character — the comedy prop of the style. |
| stone | a painted boulder with lichen; the pillar stacks look like a cairn. |
| ball | a mossy round rock — reads as *rolled down from somewhere*. |
| rusher | a bristling little creature, painted, all forward motion. |
| skirmisher | a hunched figure with a crossbow. |
| turret | a carved stone face that spits — the bolted-down thing, made architectural. |
| specials | painted objects on the deck with a soft drop shadow so they read as pickups. |
| deck | warm stone slabs with painted joint lines and moss in the corners; water is painted flow lines. |

**Risk:** the softest style here, and the one where a plinko ball is hardest to
spot. Threat contrast must be enforced by rule.

### F. `SIGNAL` — retro low-poly, vertex-lit

> A 1998 3D game remembered fondly. Chunky triangle counts, vertex colours,
> affine-ish textures at 64², dither fog swallowing the bridge ahead.

- **Material logic:** unlit or vertex-lit, tiny textures with visible pixels, no
  normal maps, a hard dither pattern for fog and for shadow.
- **Palette:** high-contrast and slightly wrong — cyan, magenta, amber, deep
  blue-black. Colour banding is a feature.
- **Edges:** low-poly facets left un-smoothed.
- **Team colour:** vertex colour on the body; it costs literally nothing, which
  suits the style's honesty.
- **Bonus:** the fog is a **design asset** — the bridge disappearing into dither
  ahead of the party supports "endlessly rising" for free.

| element | in this style |
|---|---|
| player | a ~150-triangle figure, texture at 64², a two-triangle visor for facing. |
| hat | a six-sided cone; the palette swap is a UV offset into a shared atlas. |
| stone | an 8-sided prism with a 32² rock texture, rotated per instance. |
| ball | a faceted sphere with a specular *sprite* stuck to it. |
| rusher | a spiky low-poly wedge that flickers its texture as it charges. |
| skirmisher | a boxy soldier with a muzzle-flash billboard. |
| turret | a hexagonal drum, a barrel, and one animated glowing texel. |
| specials | pickups that **spin and bob** — the era's convention, and a genuinely good legibility trick we should consider stealing regardless of which style wins. |
| deck | tiling 64² concrete with visible seams; water is two scrolling UV layers; holes are pure black with a dithered edge. |

**Risk:** nostalgia is not a style everyone shares, and low fidelity can read as
unfinished rather than as chosen.

---

## Part 3 — The pipeline

The goal is **six sheets that differ only in style**. If the shots differ in
framing, pose or content, the comparison is worthless — you end up picking the
style whose action shot happened to be more exciting. Consistency is therefore
enforced *upstream* of the image model, by generating from fixed control images.

### Stage 0 — Freeze the control geometry (in Godot, not in the image model)

The repo's advantage over a normal art bake-off: **the compositions already
exist in a running game.** We render them once, from the greybox, and every style
is generated on top of those exact renders.

Add a `--run-shots <manifest>` entry point beside `--run-test` / `--run-sim` in
`main.gd`, which:

1. loads a fixture segment, seeds the RNG, poses every body **explicitly** (set
   transforms; do not "play until it looks good" — that is not reproducible),
2. steps physics zero frames, places a `Camera3D` from the manifest,
3. captures `get_viewport().get_texture().get_image().save_png()` after
   `await RenderingServer.frame_post_draw`,
4. repeats for every shot in the manifest, writes to `tmp/shots/`, quits.

Two traps to design around, both already in `CLAUDE.md`:

- **`--headless` disables rendering entirely**, so this cannot run in the gate the
  way tests do. It is a windowed run on a dev box (or under a virtual framebuffer
  on Linux). Do not try to make it a test.
- **The headless viewport is 64×64.** Set the window size explicitly in the
  manifest (2048×1152 for shots, 1024² for roster cells); never inherit it.

Each shot is captured **three ways** — this is what makes the style transfer
controllable:

| pass | how | used for |
|---|---|---|
| **beauty** | as the game looks now | img2img base, and the honest "before" |
| **depth** | a depth-only view (`DEBUG_DRAW_..` or a depth shader override) | ControlNet depth — preserves the silhouette contract exactly |
| **colour-ID** | every element flat-shaded in a unique key colour | masks, and per-element recolouring/compositing later |

Store the manifest in the repo (`art/shots.json`) so anyone can regenerate the
identical set six months from now. That file, not the images, is the artefact.

### Stage 1 — One style anchor per style

For each codename, generate a **single hero image** and iterate on it alone until
it is unambiguously that style. This is the only stage with free-form prompting.
The anchor should contain a player, a stone, one enemy and a piece of deck — so
it establishes the material logic for the four surface families at once.

The anchor image *is* the style contract. Everything after this references it.

### Stage 2 — Lock the style, then vary only the subject

**Plan of record: a committed script against the Gemini image API.** Decided
2026-08-15. The alternatives were a Midjourney `--sref` workflow and a local
ComfyUI graph with depth ControlNet; both were rejected for the same reason, which
is that neither is a thing the repo can *hold*. A bake-off is only worth running if
it can be re-run — after a style edit, after a new enemy exists, six months from
now by someone else — and a sequence of clicks in a web UI is not re-runnable. A
script with the manifest and the prompt files committed beside it is.

ComfyUI remains the better answer on one axis: it is the only option that holds
geometry *exactly* (depth + canny ControlNet on the Stage-0 passes). If the sheets
come back with silhouettes drifting far enough to invalidate the comparison, that
is the fallback, and Stage 0's depth pass is already the input it needs. Do not
build it before then.

#### What holds the style, given there is no seed

**The API exposes no seed and no temperature.** Determinism therefore does not
come from sampler settings — it comes from holding the *inputs* fixed, which is
what Stage 0 exists for:

1. the **style anchor image**, passed in a style-reference slot, identical for
   every cell in a sheet;
2. the **Stage-0 control render** of that exact element or shot, passed as an
   object reference with an instruction to keep the composition and proportions;
3. a **frozen prompt scaffold** where only one slot moves.

Two runs will not be pixel-identical. They do not need to be — the comparison is
between styles, and every style is held by the same three mechanisms, so no style
gets an advantage from the way it was prompted.

#### Models and the cost split

| stage | model | why |
|---|---|---|
| anchors (Stage 1) | `gemini-3-pro-image` at `4K` | six images total, iterated. Quality matters more than cost here, and the anchor is the contract everything downstream inherits |
| roster + environment (Stage 3) | `gemini-3.1-flash-image` at `2K` | ~130 cells across six styles. Flash carries **3 style-reference slots**, which is what the anchor needs |
| action shots (Stage 3) | `gemini-3-pro-image` at `2K`, `16:9` | six per style, the most compositionally demanding, and the ones anyone will actually look at |

A Pro-made anchor referenced from a Flash call is fine — the anchor crosses as an
*image*, not as model state.

#### The call

`POST https://generativelanguage.googleapis.com/v1beta/interactions`

```json
{
  "model": "gemini-3.1-flash-image",
  "input": [
    {"type": "text",  "text": "<STYLE BLOCK><SUBJECT><FRAMING BLOCK>"},
    {"type": "image", "mime_type": "image/png", "data": "<anchor, base64>"},
    {"type": "image", "mime_type": "image/png", "data": "<control render, base64>"}
  ],
  "response_format": {
    "type": "image", "mime_type": "image/png",
    "aspect_ratio": "1:1", "image_size": "2K"
  }
}
```

Image data comes back base64 on `output_image.data`. Reference-slot budgets differ
per model (Flash Image: 10 object + 4 character + 3 style; Pro Image: 6 object +
5 character), which is well clear of the two or three we use — but the script
should assert it rather than discover it in a 400.

#### The prompt scaffold

```
<STYLE BLOCK — verbatim from the style's bible, never edited per-cell>
<SUBJECT — the only slot that changes>
<FRAMING BLOCK — "3/4 orthographic, neutral mid-grey ground, 1 m scale ticks">
<NEGATIVE>
```

Six text files, one per codename, with a single `{SUBJECT}` placeholder. **A prompt
that gets hand-tweaked per element is how a sheet ends up comparing prompts instead
of styles** — so the scaffold is loaded from the file and formatted, never
concatenated at the call site.

#### Repo layout

```
art/
  shots.json          # Stage-0 camera + pose manifest (committed)
  subjects.json       # the roster/environment/action cell lists (committed)
  prompts/<CODE>.txt  # one style scaffold per style (committed)
  anchors/<CODE>.jpg  # the style contract (GITIGNORED -- see below)
  rejected/<CODE>.txt # scaffolds for styles that were cut (committed)
  gen.py              # the generator (committed, stdlib only)
  out/                # full-resolution generations + sheets (gitignored)
  .gdignore           # keeps Godot's importer out of all of the above
```

**Generated images are not tracked; everything that produces them is.** Decided
2026-08-15. Anchors accumulate -- every re-roll and every new style adds another
-- and a game repo that grows by megabytes a round for binaries nobody can diff
is a repo nobody wants to clone. The generator, the prompt scaffolds, the two
manifests and the Godot shot rig are the reproducible part, and those are
committed.

**Know what that costs, because it is not nothing.** The API has no seed, so an
anchor CANNOT be regenerated identically -- re-running `gen.py anchors` gives a
different image in the same style. An untracked anchor is therefore irreplaceable
local state, and a fresh clone can rebuild the pipeline but not the exact style
contract the sheets were generated against. If a style is chosen and work starts
against it, its anchor needs a home that outlives one laptop -- an asset drive or
a release attachment -- before that happens.

`art/anchors/` is also kept at REFERENCE size rather than the 4K the API returns:
~1100 px and ~150 KB, which is all a style reference needs to be for the model or
for a human, and it makes every subsequent request cheaper to upload. The
full-resolution original stays in `art/out/<CODE>/_anchor.jpg`.

**`GEMINI_API_KEY` comes from the environment, never from a file in the repo.**
The script should refuse to run rather than prompt for it, and `art/out/` goes in
`.gitignore` beside `tmp/`.

**One runtime dependency, deliberately.** `gen.py` is Python 3 **stdlib only** —
`urllib.request`, `json`, `base64` — so there is no `pip install`, no venv and no
lockfile. It is a dev tool: `build.ps1`, `build.sh` and the test gate never invoke
it, and a machine without Python can still build and ship the game. That is the
same principle as the pinned engine, applied to a tool rather than to a dependency.

### Stage 3 — Sheets

**Assembly is an HTML page, not a composited image.** `gen.py` writes
`art/out/<CODE>/sheet.html` — a CSS grid of `<img>` tags with the cell name and
the prompt subject under each, plus the Stage-0 control render beside each
generated cell. That keeps the generator on stdlib (no Pillow), makes the
before/after comparison the default view rather than an extra step, and means a
sheet can be re-opened and re-judged without regenerating anything. A second page,
`art/out/compare.html`, puts one row per cell and one column per style — which is
the view the Stage-4 rubric is actually scored from.

Three sheets per style, same layout every time:

1. **Roster sheet** — 16 cells: player (×2 team colours), hat, stone, plinko
   ball, shooter, rusher, skirmisher, turret, bullet, rocket, grenade, mine,
   machine-gun pickup, heart, mound. Neutral ground, identical framing, a 1 m
   scale tick under each. This is the sheet that answers *can you tell the three
   enemies apart in a quarter second*.
2. **Environment sheet** — 6 cells: deck, ramp, hole edge with parapet, water,
   pillar field, and the wide establishing shot of the bridge climbing away.
3. **Action sheet** — 6 shots, listed below. Rendered from the Stage-0
   compositions, so all six styles show the *same six moments*.

**The six action shots** (each is a sentence of the design made visible):

| # | shot | what it is proving |
|---|---|---|
| 1 | one player dashing into another, three cells from a hole | the shove, and that intent is in the aim |
| 2 | a ball arriving through a pillar field at a group under pressure | the main obstacle, and ball-vs-deck contrast |
| 3 | a player hanging off a ledge while a teammate ropes them | the rescue, and the ledge read |
| 4 | mounds waking into a rusher wave on a narrow span | threat telegraph vs threat |
| 5 | turret and skirmisher crossfire across an open span | the two gunners, distinguishable at range |
| 6 | a downed player, a revive in progress, hats scattered on the deck | the comedy register, and prop clutter |

### Stage 4 — Judge on rules, not on taste

Score each sheet against the Part 1 contract before anyone says which is
prettiest. Suggested rubric, 0–2 each:

- three enemies distinguishable at a glance, at range
- ball readable against both deck and sky
- five special silhouettes still distinct
- team colour dominant on the avatar; four colours all viable
- facing readable from directly above
- hole vs deck unmistakable
- hat reads as a separable object
- the deck stays quiet

Then, and only then, taste. A style that wins on taste and loses on the rubric is
a style we would spend a milestone fixing.

### Stage 5 — Prove the winner in-engine before committing

**A proof sheet is not the game.** A concept image cannot tell you whether a style
survives at gameplay framing, in motion, at 60 Hz, with four players and a dozen
props on screen. So the first production step is a **one-element spike**: rebuild
only the player and the stone in the winning style, drop them into
`playtest_bridge.seg`, and look at it. If it survives that, commit; if not, the
bake-off cost sheets rather than a milestone.

Production then splits by element:

- **Shader/material pack first.** For `BROADSHEET`, `SIGNAL` and much of `TOYBOX`,
  most of the style is a shader (outline pass, toon ramp, vertex colour, dither
  fog) plus a palette resource — applied to the primitives we already have. This
  is by far the cheapest real art swap available and it is worth costing *before*
  anyone models anything.
- **Modelled props.** Stones, pickups, turret, shooter, mound — good candidates
  for image→3D (Trellis 2, Hunyuan3D, Meshy) from the roster-sheet cells, then
  retopo/decimate and hand-fix. Treat generated meshes as *blockouts with
  texture*, not as final.
- **Hand-modelled avatar.** The player is on screen constantly, is tinted four
  ways, wears a physical hat and must fit a cylinder that never tips. It is the
  one asset not to generate.

---

## Part 4 — What this obliges the code to do

Small, and worth doing regardless of which style wins:

1. **A view layer that can be swapped.** Each entity scene should reach its
   visuals through one child node (`Visual`) that a style pack can replace, rather
   than having meshes and `material_override`s scattered across the scene. Today
   they are scattered.
2. **A palette resource, not literals.** Team colours, threat colours and deck
   colours are `Color` literals in eight `.tscn` files. One `art_palette.tres`
   makes a style swap a data change and makes the "threat colours are reserved"
   rule enforceable.
3. **`art/gen.py`, and `art/out/` in `.gitignore`.** The generator, its manifests
   and its prompt files are committed; its output is not. `GEMINI_API_KEY` is read
   from the environment and the script refuses to run without it.
4. **`--run-shots` and `art/shots.json`.** Reusable for marketing screenshots,
   for Steam capsule art, and for spotting a visual regression by diffing two
   runs of the same manifest.
5. **Keep `show_hitboxes` honest.** After any restyle, run it. The whole point of
   the tool is catching a mesh that lies about its collider, and a restyle is the
   single most likely moment to introduce one.

## What rounds 1 and 2 actually taught us

Run 2026-08-15. Stage 1 cost six images and paid for itself immediately.

- **A style block that describes MATERIALS produces photography.** Three of the
  first six anchors came back as photographs of physical objects -- a real toy on
  a table, a clay model, a concrete still-life. The three that worked described a
  *rendering technique* instead. The bible was written for a human art director,
  who would have assumed "in a game" without being told. Every scaffold now opens
  with a `[RENDER]` block stating outright that the image is a screenshot of a
  running game, and `photograph, product photography` is in every negative.
- **The FRAMING line was half the cause.** The anchor framing said "arranged on a
  plain background, even lighting, three-quarter view", which is how you stage a
  product shot. It now describes the game's own camera. Worth remembering that a
  framing instruction can contradict a style instruction and win.
- **"Indie, not AAA" is worth saying explicitly.** Without it the temple style
  drifts toward photoreal blockbuster ruins, which is a target nobody here can
  build to.
- **A subject description leaks a shape you did not intend.** "A wedge on its
  front showing which way it FACES" produced a BIRD in all six styles
  independently -- front plus faces plus wedge is a beak. It now says compass
  needle, and says no face, no eyes, no beak.
- **The API returns JPEG only.** `response_format.mime_type: "image/png"` is a
  400, not a fallback.
- **The provenance label is a POST STEP** (`scripts/shots/stamp.gd`), never asked
  of the model: the prompts forbid rendered text, and a model that does render
  text renders it differently every time and in the style of the image -- which
  is exactly what a provenance label must not be.

**Styles after round 2:** `TEMPLE`, `MODERN`, `BROADSHEET`, `SITE`, `SIGNAL`,
`TOYBOX`, `PLASTICINE`. `GOUACHE` was cut for soft threat contrast and is kept in
`art/rejected/` as evidence.

**What the action shots showed that the anchors could not**, which is the whole
argument for generating them first and the roster later:

- `MODERN` holds our composition; `TEMPLE` rebuilds the scene into a nicer one.
  A style that restyles the level is worth more than a style that replaces it.
- `BROADSHEET` renders holes and the void behind the bridge in the SAME flat
  black. On a bridge whose failure state is falling through a hole, that fails
  contract rule 6 as generated.
- `SITE` keeps building a ROOM: the drop into open sky becomes a sunken pit with
  walls. "Construction site" implies enclosure, and enclosure removes the threat.
- In all four, pickups and hearts are coloured blobs at gameplay distance. The
  five distinct special silhouettes are under pressure at real framing
  *regardless of style*, which is a finding about the game, not about the art.

## Open questions

1. **Does the style need to survive four team colours, or do we go one-avatar
   with colour only on an accessory?** `SITE` and `GOUACHE` assume the latter,
   `TOYBOX` and `SIGNAL` the former. This is really a question about how strong
   the "who is that" read has to be, and it should be answered before Stage 1.
2. **Do we want stepped/12 fps prop animation?** `PLASTICINE` sells it hardest,
   but it interacts with interpolation of remote players — see the netcode notes
   before promising it.
3. **What is the tonal register?** `TOYBOX` and `PLASTICINE` say slapstick,
   `SITE` says competent-people-in-danger, `SIGNAL` says nostalgia. The game's
   comedy comes from committed actions, which works in all three — but the
   register decides how much a fall is *supposed* to sting.

## Sources

- [Midjourney style reference (`--sref`) guide](https://claudioautiero.substack.com/p/midjourney-style-reference-guide-sref)
- [Midjourney `--cref` for consistent characters](https://prompting.systems/blog/how-to-use-midjourney-cref-for-consistent-characters)
- [Nano Banana Pro reference-image setup and drift fixes](https://www.aifreeapi.com/en/posts/nano-banana-pro-reference-images)
- [Gemini image generation API docs](https://ai.google.dev/gemini-api/docs/image-generation)
- [ComfyUI depth ControlNet tutorial](https://docs.comfy.org/tutorials/controlnet/depth-controlnet)
- [ComfyUI for game asset pipelines, 2026](https://www.strayspark.studio/blog/comfyui-game-asset-pipeline-indie-2026)
- [Style transfer with ControlNet + IPAdapter](https://comfyui.org/en/image-style-transfer-controlnet-ipadapter-workflow)
- [AI 3D model generators compared, 2026](https://learn.rundiffusion.com/ai-3d-model-generators/)
- [Godot in-engine screenshots](https://shaggydev.com/2025/02/05/godot-screenshots/)
- [Godot proposal: off-screen rendering (why `--headless` cannot do this)](https://github.com/godotengine/godot-proposals/issues/5790)
