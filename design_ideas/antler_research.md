# Antlers: the measured numbers, and the criteria that decide whether one reads

Research done 2026-08-21 after the moose accessory was rebuilt five times by eye
and rejected five times. Three parallel investigations: procedural-generation
literature, moose morphometrics, and visual identification. This is the synthesis.

**Its real subject is the METHOD**, not the moose. See
`design_ideas/character_customization.md` for the accessory system itself.

---

## The headline: there is no procedural-antler literature

Searched SIGGRAPH/EG proceedings, theses, Houdini/Blender/Unreal tools, GitHub.
**Nothing.** What exists is general branching-structure work you re-target, plus
real morphometric measurement. So every rule below is either a published result
about branching in general, or a measurement of real antlers converted to a
ratio. **Treat any antler tutorial you find as one person's taste with no
measurement behind it** -- and note that most cartoon-moose tutorials teach a
*dendritic* rack, which is the exact failure mode this document exists to avoid.

---

## THE TWO CUES THAT BREAK THE READ

Everything else is polish. Both of these were wrong in every version built by eye.

### 1. It is a PLATE, not a beam with branches

Every source names this first. ADFG's own anatomy diagram labels the parts *main
palm / brow palm / bay* -- there is no "beam with tines" vocabulary, because the
palm **is** the antler.

The cleanest numeric separator anyone offered:

> **filled silhouette area of one antler / area of its convex hull >= 0.6**
> A branchy cervid rack lands at 0.25-0.35.

Structurally, palmation is **fused tines with bone infill between them** -- bone
occupying space that in a pole-type antler would be empty. Not a membrane, not a
plate with spikes glued on. The tines remain visible only as the points around
the free border. For a primitive build this means: generate the tine directions
first, then FILL BETWEEN them; do not model a plate and decorate it.

### 2. It sits LOW and goes OUT -- not up from the crown

"Moose antlers grow out of the *sides* of the head, horizontally spread", against
elk which "grow backward over their bodies" from the top of the skull.

> **horizontal extent >= 2x vertical extent**
> **highest point < half a head-height above the top of the skull**
> **pedicle at or below ear level, LATERAL -- not on the crown**
> **outer edge tilted up no more than ~30 degrees from horizontal**

**Get palmation right but root the rack high and angle it upward and you have
built a FALLOW DEER** -- the other palmate cervid -- which reads as "deer", not
"moose". This was predicted by the research before it saw the model, and it is
exactly what had been built: a beam leaving the head at 47 degrees upward.

---

## The measured numbers

Child, Aitken & Rea (2010), *Alces* 46 -- **1,965 racks**, every dimension to the
nearest mm by one technician. The best single source that exists.

| | mature bull | average adult | yearling |
|---|---|---|---|
| maximum spread | 1142 +/- 154 mm | 815 +/- 174 | 569-667 |
| maximum height, one side | 771 +/- 123 | 481 +/- 175 | 287-324 |
| palm width, one side | 259 +/- 52 | 147 +/- 56 | 104-114 |
| shaft circumference | 180 +/- 18 | 142 +/- 24 | 110-125 |
| gap between inner brow points | 319 +/- 92 | 384 +/- 84 | 414-431 |

Anchored to head width (10 in / 254 mm, the field-judging convention):

| | ratio to head width |
|---|---|
| spread, mature | **4.50x** |
| palm long axis, one side | **3.03x** |
| palm width, one side | **1.02x** -- i.e. about one ear length |
| beam diameter | **0.226x** |
| pedicle separation | 0.70-0.80x (trade knowledge, not peer-reviewed) |

### The ratios that matter more than the absolute sizes

- **Palm aspect 1 : 2.5 to 1 : 3** (width to long axis). Two entirely independent
  datasets converge here. This is the single most important moose number.
- **Palm long axis runs FORE-AND-AFT and is ~62% of the total tip-to-tip spread.**
  The rack spans from mid-muzzle to the withers.
- **Beam diameter is ~5% of total spread.** Startlingly thin. This is the number
  most likely to be wrong in a hand-modelled antler -- people make it too thick.
- **Central void: the air gap between the two inner palm edges is ~0.6 of the
  spread**, each palm slab ~0.2. The silhouette is void-dominated in the middle
  and mass-dominated at the flanks, which is the OPPOSITE of a branchy rack.
- **The brow gap NARROWS with maturity** (0.47 -> 0.28 of spread). The brow palms
  grow toward each other across the face while everything else grows outward.

### Taper and branching, from the general literature

- **Da Vinci / pipe model / Murray's law:** `r^n = r1^n + r2^n`, n usually 2-3.
  Measured range across real trees 1.8-2.3. Antler taper is consistent with the
  same **n = 2**; there is no evidence antlers need a special exponent.
  Symmetric fork therefore gives child/parent = `2^(-1/2)` = **0.707**.
- Measured directly on red deer, which is better than deriving it: **a tine
  starts at ~0.43 of the beam's diameter at that point**, and **the beam loses
  ~12% of its diameter across each tine node**.
- **Tine length is 0.3-0.4 of the beam**; the beam continues at ~0.9. That wide
  r1/r2 gap is the signature of an antler. Tree L-systems use 0.6-0.9 for the
  branch ratio and produce a shrub.
- **Fork angle 45-70 degrees**, not the 20-35 that reads as "tree".
- **Divergence angle 0/180 degrees, NOT the golden 137.5.** Antler branching is
  planar bifurcation; the phyllotactic roll is what makes a structure read as a
  plant. Single biggest L-system change between "tree" and "antler".

### A hard constraint from developmental biology

Goss: **antlers with a species-specific tine count do not occur in miniature** --
"a decrease in antler size is always associated with reduced morphological
complexity". So **do not scale an antler mesh down for a smaller animal. Remove
tines.**

Lobo/Levin's linear-encoding model says an antler is stored as a **1-D sequence
of tine slots along the beam**, each with its own parameters -- not a recursive
grammar. For a game that is the better data structure anyway: an array of
`{position along beam, angle, length, type}` is authorable, seedable and
serialisable, which is exactly what `accessory_parts` already is.

---

## Stylisation: what to exaggerate, what to drop

From how illustrators, animators and emoji vendors actually solve it -- these are
solved instances of the same problem, and they converge.

The near-universal teaching device is **the hand**: palmate = "shaped like the
palm of a hand with outstretched fingers". The essential simplification is
**"connect the branches up top instead of connecting the lines all the way down
to the base"** -- draw the tines, then fill the web between them into one solid
mass, leaving only the tips separate. That is palmation, drawn.

**EXAGGERATE:** spread, well past the honest 1.67x ear span; plate solidity; the
convexity of the outer arc; the low horizontal set.

**DROP:** point count (9-19 real -> **3-5**); the bay (the "full palm" morph is
real, so this costs nothing in authenticity); palm cupping (flatten to one plane
-- and B&C says flat = big bull, so it is free authenticity); beam taper,
pearling, mass texture; asymmetry.

**NEVER DROP:** the outer-rim fringe. With zero tines the plate reads as a
butterfly wing, a leaf, or a hand -- not an antler.

Unicode's own moose-emoji proposal names three features as what makes a moose
immediately recognisable: **"the distinct *pan* antlers, large frame, and drooping
nose."** Note the word: *pan*, not branch.

---

## Documented failure modes

1. **Too branchy.** Building from lines and adding points. Most "easy cartoon
   moose" tutorials do exactly this. They get away with it because the bulbous
   muzzle and bell carry the read; a silhouette-only design cannot.
2. **Rooted on the crown.** Instant elk.
3. **Fan instead of slab.** No fore-aft depth; vanishes edge-on.
4. **Tines too long.** The rim reverts to branches and drifts toward elk.
5. **Symmetric radial fan.** Reads as a hand or a shell. Needs the fore-aft
   asymmetry: brow forward and low, main palm up and back.
6. **Over-cupped palm.** Narrows the spread; reads as a *small* bull.
7. **Notch in the OUTER edge.** The unbroken outer arc is the strongest single
   line in the silhouette. The bay belongs on the inner/front edge only.

---

## Reference views -- and the one that decides it

Boone & Crockett: *"A frontal view, with the animal's head down and antlers
nearly vertical, gives a much better chance for accurate evaluation."* Side views
make it "very difficult to estimate accurately at a distance". Emoji vendors
independently converged on forward-facing with the head lowered.

| priority | azimuth | elevation | tests |
|---|---|---|---|
| 1 | 0 | +30 | palm face, spread, central void, symmetry -- *the* moose image |
| 2 | 35 | +10 | spread AND depth AND brow at once; best "does it read" |
| 3 | 90 | 0 | true profile -- the only view that tests brow-to-muzzle and tips-to-hump |
| 4 | 0 | +90 | construction check: proves the 3:1 plate, which no other view can |

**And the warning that matters most here:** if the palms are built vertical so
they read in a front orthographic view, **they collapse edge-on in the game
camera**. `bridge_camera.gd` is a fixed 45-degree pitch, so a near-horizontal palm
presents its full face to it -- which is lucky, but it means the 45-degree view is
the one to tune against, never the front.

---

## Moose against elk -- they must not be confusable

| | moose | elk |
|---|---|---|
| structure | palmate plate, tines from the **edge** | dendritic, tines off a **beam** |
| roots at | **sides** of the head, ear level | **top** of the skull |
| dominant axis | **lateral** | **longitudinal**, up and back |
| beam | effectively none | everything |
| tines | short, outward from a rim | long, forward from the beam |
| front-view W:H | **> 2.5 : 1** (a wide bar) | **< 1.3 : 1** (a lyre) |
| hull fill, one antler | **>= 0.6** | **<= 0.35** |
| rear reach | tips ~ the shoulder hump | beams ~ the haunches |

---

## What nobody has measured

Stated plainly so nobody later mistakes a guess for a citation. These are design
decisions, not lookups:

1. **Palm thickness.** No peer-reviewed figure. The only numbers are from the
   antler-cutting trade: slabs run **0.5-1.0 inches** and thicken toward the base
   -- about **0.05-0.10 x head width**. B&C acknowledges thickness as desirable
   and folds it silently into the palm measurements rather than scoring it.
2. **Palm plane angle in degrees.** Never measured. Only "flat on trophies,
   cupped on small bulls".
3. **Beam angle off the skull in degrees.** Never measured.
4. **Point length and point spacing.** Never measured; only the B&C rule that a
   point must be >= 1 inch and longer than it is wide.
5. **Pedicle length / beam emergence height above the eye.** Never published.

---

## Sources

- Child, Aitken & Rea (2010), *Morphometry of Moose Antlers in Central British
  Columbia*, Alces 46:123-134 -- <https://alcesjournal.scholasticahq.com/article/156589-x.pdf>
- Bowyer et al. (2002), *Geographical Variation in Antler Morphology of Alaskan
  Moose*, Alces 38 -- <https://www.adfg.alaska.gov/static/home/library/pdfs/wildlife/research_pdfs/alces/511.pdf>
- Boone & Crockett, *Field Judging Moose* -- <https://www.boone-crockett.org/field-judging-moose>
- Boone & Crockett, *Field Judging American Elk* -- <https://www.boone-crockett.org/field-judging-american-elk>
- ADFG, *Moose Hunting in Antler Restricted Areas* (the antler-parts diagram) --
  <https://www.adfg.alaska.gov/static/hunting/moosehunting/pdfs/moose_hunting_antler_restricted_areas_brochure.pdf>
- Runions, Lane & Prusinkiewicz (2007), *Modeling Trees with a Space Colonization
  Algorithm* -- <https://algorithmicbotany.org/papers/colonization.egwnp2007.large.pdf>
- Runions et al. (2005), *Modeling and visualization of leaf venation patterns*
  (Murray's law, anastomosis) -- <https://algorithmicbotany.org/papers/venation.sig2005.pdf>
- Prusinkiewicz & Lindenmayer, *The Algorithmic Beauty of Plants*, ch. 2 --
  <http://algorithmicbotany.org/papers/abop/abop-ch2.pdf>
- *Variation of antlers in individual red deer stags*, Eur J Wildl Res (2023)
  69:27 -- the only per-tine angle and ratio statistics for any cervid
- Lobo, Solano, Bubenik & Levin (2014), *A linear-encoding model explains the
  variability of the target morphology in regeneration*, J R Soc Interface --
  <https://royalsocietypublishing.org/doi/10.1098/rsif.2013.0918>
- Goss, *Experimental Investigations of Morphogenesis in the Growing Antler* --
  <https://journals.biologists.com/dev/article/9/2/342/51456/>
- Unicode L2/21-197, *Proposal for Moose Emoji* -- <https://www.unicode.org/L2/L2021/21197-moose-emoji.pdf>
- Gasaway, ADF&G (1974), *Moose Antlers: How Fast Do They Grow?* --
  <https://www.adfg.alaska.gov/static/home/library/pdfs/wildlife/research_pdfs/moose_antlers.pdf>
