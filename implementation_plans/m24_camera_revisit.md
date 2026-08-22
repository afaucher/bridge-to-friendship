# M24 — revisiting the camera

Queued 2026-08-20, off the back of M22 (width) and M23 (height). Both of those
milestones ended by pointing at the same thing, from different directions, and
the camera has never been revisited since it was set.

**This is a plan to ASK the questions with measurements, not a plan to change the
camera.** Three of its properties are load-bearing and one of them has already
been re-justified once after its original reason expired — so the first job is to
work out which constraints are still real.

---

## What the camera is today

`scripts/ui/bridge_camera.gd`. Fixed yaw, fixed 45° pitch, pinned to the bridge's
centre line, following the local player in Z and Y only. Framing is derived
rather than eyeballed: `keep_aspect = KEEP_WIDTH` makes `fov` the HORIZONTAL
angle, so the distance falls out of the bridge's width —

```gdscript
var span: float = float(bridge_width_cells) * GridConfig.CELL_SIZE * width_margin
_distance = (span * 0.5) / tan(deg_to_rad(fov) * 0.5)
```

— and `bridge_width_cells` is set ONCE per run from `grid.width`
(`game_world.gd:376`).

Its three stated properties, each with a reason written into the file:

| property | why | still true? |
|---|---|---|
| fixed yaw | the mouse cursor is only a direction on the deck if the deck's orientation is stable | **yes, and stronger than ever** — see below |
| whole bridge across | co-op depends on seeing what your friends are doing | yes, but "the bridge" now varies |
| no sideways tracking | chasing X makes a 60 m bridge feel like a corridor, and slides the world under a player lining up a dash | **the open question** |

**Fixed yaw is not on the table.** Its original reason (compass-locked shoves)
expired in 2026-08-10 and it survived on a second, better one: free aim. M20
makes that stronger still — under point aim the cursor's world position IS the
shot, so a rotating camera would turn aiming into a moving-target problem. Any
proposal in this milestone that needs the yaw to move is the wrong proposal.

---

## The three questions

### 1. Should framing follow the LOCAL width instead of the run's canvas? (M22)

> **ANSWERED 2026-08-20, and the answer was neither.** Shipped with M22 phase C:
> the frame is a FIXED number of metres and the camera pans within the deck,
> clamped so the frustum never passes a parapet. Framing the canvas would have
> zoomed every player out 40% to show empty air; framing the local span would
> have turned every width change into a zoom, which is a drift under the cursor
> and worse under point aim. Panning-with-a-clamp has neither problem, and on
> any bridge at-or-narrower-than the frame it collapses to the old behaviour
> exactly. The reasoning below is kept because it is why the third option was
> the right one.

The file's own comment already states the intent — "a narrower bridge brings the
camera in rather than leaving it framed for one that is not there" — but
`bridge_width_cells` is set once per run and never varies. That comment was
written when width was a constant per run, so it describes an intention the code
has never had an opportunity to act on.

M22 changed the premise. A section now varies between roughly 11 and 15 usable
cells (measured: `[11, 12, 13, 14, 15]` over 43 generated sections), with 38% of
rows cut further on one side than the other. So there is now a real difference
between "the canvas" and "the bridge in front of you", and the camera only knows
the first.

**The catch, and it is why this is a question rather than a task:** framing to
the local span means the camera moves on an axis it has never moved on. Every
width change becomes a zoom. At one column per row (M22's `INSET_RATE`) that is
a slow, continuous drift rather than a snap — but a drift under a cursor is
exactly what the no-sideways-tracking rule exists to prevent, and under point
aim a zoom moves the cursor's world position without the player moving the
mouse.

**Measure first:** what is the actual framing delta between an 11-wide and a
15-wide section at the current `width_margin` of 1.55? If it is small, this is
free and worth doing. If it is large, the honest answer may be to leave framing
on the canvas and let a narrow section simply have more sky around it — which is
arguably correct anyway, since seeing the drop past the parapet is what makes a
narrow bridge read as narrow.

### 2. How tall can a tower be before it hides a teammate? (M23)

The one cap in M23 with no constant to read. Multi-level was cut from M17
explicitly on this: *"The camera problem was 'anything above a player hides
them'"* (roadmap, M17). A tower is a tall occluder at a fixed 45°, and the
occlusion scales with height.

This is the most concrete of the three and wants a straightforward soak: put a
tower of height H between the camera and a body, sweep H, and find where the body
stops being visible. The output is a number M23's generator can cap against,
which is better than either guessing or discovering it in a playtest.

**Worth measuring the pitch alongside it**, because 45° is the single variable
that trades occlusion against readability, and it has never been swept. Shallower
sees more of the players' height and occludes more; steeper sees the deck layout
and flattens everyone. The file says 45 is "enough to read the deck layout and
the gaps in it, shallow enough that players still have visible height" — a
sensible statement that predates split-level terrain, towers, and shooting at
things above you.

### 3. Does point aim change what the camera owes the player? (M20)

Under `level` aim, the camera only had to show you where you and your friends
are. Under `point` aim it also has to show you **where your cursor is and what is
under it** — the aim is a world position now, so anything the camera hides is
something you cannot aim at.

That is a genuinely new requirement, and it interacts with both questions above:
a tower tall enough to hide a teammate is also tall enough to hide the thing
shooting from behind it, and a zoom that moves under the cursor moves the shot.

---

## Ordering

Question 2 first — it is the most concrete, it has a clear measurement, and M23
is blocked on the answer. Question 1 next, since M22 has already shipped and the
current behaviour (frame the canvas) is a defensible default in the meantime.
Question 3 is a lens to apply to both rather than a separate task.

**Nothing here proposes a change yet, deliberately.** The camera has three
properties that are each holding up something else, and one of them has already
survived losing its original justification — which is a good reason to measure
before touching any of them.

---

## Open questions

- **Is the follow target still right?** The camera frames the LOCAL player, with
  a comment saying the party centroid is "a one-line change here, and is the
  better answer once the soft leash (M8) guarantees the party is close together".
  The leash exists now. Worth asking whether that one line should be taken —
  particularly given the offscreen-teammate markers built later, which are a
  mitigation for exactly the problem a centroid would reduce.
- **Does `width_margin` want to be a debug knob?** Sweeping pitch and margin by
  hand means an edit-and-rebuild per sample; both are `@export`s already, so
  exposing them through the `DebugSettings` registry (which is one entry each)
  would make the soak in question 2 something a playtest can also do live.
- **Do split-level plateaus (M23 Feature A) read at 45°?** A left/right height
  difference is a cliff face pointing across the screen rather than up it, which
  is the orientation the camera is least able to show. Worth including in the
  same soak as the tower sweep, since it is the same measurement with the
  occluder turned sideways.
