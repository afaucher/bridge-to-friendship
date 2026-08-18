# M20 — aiming at a point, and the A/B that decides whether it ships

Today the aim is a **yaw and nothing else**. `PlayerInput` carries one float, and
`_fire_round` builds its direction from `shooter.global_position +
yaw_vector(facing) * MG_RANGE` — a point at the shooter's own height, thirty
metres away. Every shot in the game therefore leaves level, and the only vertical
component any round gets is the 5% gravity in `MG_BULLET_DROP`.

That is fine on flat deck and wrong on a bridge that climbs in layers. A
skirmisher two units up is unshootable; a rusher in a pit below you is
unshootable; and the player's answer to both is to walk until the enemy is level,
which is the opposite of what a ranged weapon is for.

**This milestone does not replace that. It builds a second mode beside it and a
way to see both, so a playtest can decide.** Existing behaviour has to survive
untouched — not "mostly", but bit-for-bit when the knob is off, because an A/B
whose control has drifted proves nothing.

---

## What Alien Swarm actually does

Worth the search, because the design being asked for is theirs and they have
shipped it for fifteen years.

**Default is a level shot.** "By default you will shoot in a straight line, but
some aliens will be above or below you in elevation." Their base case is exactly
this game's current case — useful confirmation that level-by-default is not a bug
to be ashamed of.

**The cursor supplies the height.** "To shoot at a very sharp angle of height,
place your cursor directly over the target, or leave it to someone who has
Auto-Aim enabled." So the raycast-to-a-spot IS the mechanism, and the precision
cost is acknowledged rather than designed away.

**Auto-aim snaps to centre mass, and is the elevation answer.** "Any entity that
is in line of sight of where you are aiming will be aimed at, that makes aiming to
different level height enemies automatic. The auto aim snaps to the centre mass of
the enemy." Two things fall out of that phrasing and both are load-bearing here:
it triggers on *what the aim ray passes*, not on screen proximity, and it corrects
to the **middle of the body** rather than to the surface the ray touched.

**The gamepad has no cursor, so they invented one.** Right-stick aim is locked to
a circle around the character, with a cvar moving the virtual cursor in and out.
**Decided 2026-08-18: this project takes the same answer.** A pad holds a virtual
cursor at a fixed radius on the deck plane, and that cursor is raycast exactly as
the mouse one is — so `point` mode has one implementation and the pad is not a
special case downstream. `snap` then does the vertical work for a pad in practice,
which is what makes the radius forgiving enough to be playable.

From the wider aim-assist literature, three techniques are worth naming because
they are *not* all appropriate here:

| technique | what it does | verdict for this game |
|---|---|---|
| **snap / bubble** | aim jumps to centre mass inside a radius | **take it** — it is the elevation fix |
| **magnetism / friction** | slows the *turn rate* near a target | **reject** — `aim_source.gd` says the facing is absolute and never integrated; there is no turn rate to slow, and adding one reintroduces the pointer lag that file exists to prevent |
| **target priority / stickiness** | stops a second enemy crossing the line stealing your lock | **later** — real, but it only matters once snapping exists and is felt |

---

## The three knobs, and why they are three

This is one feature in conversation and **three independent switches** in the
build, because an A/B with one lever cannot tell you which half worked.

| knob | values | default |
|---|---|---|
| `aim_mode` | `level` / `point` | `level` — the shipped behaviour |
| `aim_assist` | `off` / `snap` | `off` |
| `laser_sight` | `off` / `on` | `off` |

`laser_sight` is deliberately **not** part of the A/B. It is the *instrument*, and
it has to work in `level` mode too — a line that only appeared in the new mode
would show you the new mode's aim with nothing to compare it against. Drawn from
the muzzle along the direction the shot will actually take, so it reports what the
gun is doing rather than what the cursor is doing. If those two disagree, that is
the bug it exists to find.

---

## Phase 0 — the wire carries a point

**The crux, and the only part that touches replicated state.**

`PlayerInput` is `[tick, move, actions, aim]` with `aim` a single yaw. A point
needs three floats, and the array is what a client sends, what the host replays,
and what prediction re-runs — so this is the change to get right first and alone.

Add a fifth element, `aim_point: Vector3`, defaulting to a sentinel
(`Vector3.INF`) meaning *no point supplied*. Everything downstream keeps reading
`aim` exactly as it does now; `aim_point` is consulted only in `point` mode.

**A POINT AND NOT A PITCH.** Two floats would be smaller, but the muzzle is not
the player: `_muzzle_of` returns the barrel tip, offset from the body, and
`_fire_round` already exists to correct for that by converging on a zero point.
Given a real world point that convergence becomes exact instead of approximate —
and "the round goes where the cursor is" is the entire feature. A direction
computed at the body and reused at the muzzle is off by the offset forever, which
is the bug `_fire_round`'s own comment describes having shipped once already.

**Resolved client-side, like the yaw already is.** `aim_source.gd` says it
plainly: the host cannot re-derive a cursor. The new point is the same kind of
fact.

*Ships with nothing reading it. `test_aim` and `test_client_prediction` must pass
untouched — that is the assertion that the control is intact.*

---

## Phase 1 — the laser sight

Before either aiming change, because it is how both are judged.

A thin line from `_muzzle_of` along the firing direction, ending at the first
thing it would hit. **Built from the same function the shot uses**, not from a
parallel copy — a sight that computes its own direction is a sight that can agree
with the cursor while the bullet disagrees with both, which is the shape of the
hat-collider bug already in CLAUDE.md.

View-only in the registry, so a client may apply it the instant it is clicked; it
changes nothing the simulation reads.

---

## Phase 2 — `point` mode

In `point` mode the aim direction is `(aim_point - muzzle).normalized()`, and the
`facing` yaw is derived from it so everything that reads `facing` — the mesh, the
dash, the shield arc — keeps working unchanged.

**Bullets already fall.** `MG_BULLET_DROP` is 0.05 — five per cent of gravity —
so a round aimed exactly at a point lands slightly under it, and further under the
further it goes. Three options, and the plan is to **start with (a) and measure**:

- **(a) ignore it.** At 22 m/s over 30 m the drop is small. Possibly invisible.
- (b) compensate: aim at a point raised by the computed drop.
- (c) set the drop to zero in `point` mode, making it hitscan-straight.

(b) is what a real sight does; (c) is what most twin-stick shooters do. The
measurement — actual miss distance at 10, 20 and 30 m — decides, and it is one
probe.

**The grenade is out of scope and the rocket is in.** A rocket travels straight at
`ROCKET_SPEED` and takes the same direction a bullet does. A grenade already
"solves an exact ballistic arc for the distance the player asked for", so pointing
it at a 3D point means re-solving that arc to a target *height* as well — a
different and harder problem that does not need to be inside the A/B.

---

## Phase 2b — the weapon points where it shoots

Raised from play: "when the player is aiming straight the weapon is slightly to
their side, so bullets do not go directly in front of you — worst with the rocket."

**Measured, and it is two separate things.** One is a real disagreement that
should just be fixed; the other is a design choice that `point` mode resolves for
free.

**The shot already converges, and the barrel does not know.** Both `_fire_round`
and `_step_rocket` aim at a zero point 30 m down the body's centreline, so the
round leaves the muzzle angled 0.42° inboard. But `_pose_held_special` sets
`weapon.rotation = Vector3.ZERO`, parenting the barrel to the `Facing` pivot — so
**the gun points along `facing` while the round does not.** Nobody chose that, and
it is not an A/B: it is a picture that disagrees with the simulation, which is the
hat-collider shape CLAUDE.md already records. The barrel gets rotated onto the
firing direction.

It also has to be fixed *before* the laser sight means anything. A line drawn out
of a barrel that points somewhere the round does not go is an instrument that
lies, and the whole milestone is judged through it.

**THE CONVERGENCE IS TUNED FOR A RANGE THE ROCKET IS NEVER USED AT.** Reported as
"the rocket does no convergence, the player has to compensate with aim". The code
says otherwise and the code is technically right, which is the least useful kind
of right: MEASURED, by firing one and tracking it,

| down-range | 1 m | 2 m | 3.5 m | 5 m | 6.5 m | ... | 30 m |
|---|---|---|---|---|---|---|---|
| off the player's line | 21.7 cm | 20.9 | 19.8 | 18.7 | 17.6 | | 0 |

Over the first six and a half metres the convergence buys **four centimetres out
of twenty-two**. A rocket is an area weapon used against slow things at close
range, so those are the only metres it ever flies -- and across them it is,
functionally, not converging at all. The report is correct about the game even
though it is wrong about the source.

A rusher is 0.5 m in radius, so 20 cm is inside a body -- which is why the machine
gun has never felt wrong, and why its 10-degree spread cone hides the same error
entirely. The rocket has no spread and is aimed at a PLACE rather than at a
target, so the same 20 cm is the difference between the blast landing where the
player clicked and 20 cm to the left of it.

**Point mode deletes it, and that is the strongest argument in this document.**
The zero becomes the aim point, so the error is zero at the range the shot is
actually taken rather than at thirty metres. The fix for the rocket arrives as a
consequence of the feature instead of as a separate change -- and if the A/B ends
with `point` mode rejected, this becomes its own small commit: converge on the
cursor's ground point rather than on a constant.

**Is any of this worth an A/B?** The maths is not — converging on the actual
target strictly dominates converging on a fixed range, and a barrel that points
where it shoots is not a preference. What might be: whether the barrel swivelling
independently of the torso *looks* right, or whether the body should turn with it.
That is a feel question, it is cheap to try both, and it is not on the critical
path — so it is noted rather than scheduled.

---

---

## Phase 3 — `snap` assist

Cast the aim ray. If it passes within `AIM_SNAP_RADIUS` of an enemy's centre,
replace the aim point with that centre.

**A TIGHT BUBBLE, BECAUSE POINTING AT THE GROUND IS A STRATEGY.** The ask is
explicit: point at an enemy and you hit it; point at the ground *near* it and the
round goes to the ground, because for the rocket that is the better play — an area
weapon against something slow is easier to land behind than on. A generous bubble
would eat that decision and quietly make the rocket worse. So the radius is about
a body width, not a screen-space cone, and it is tuned by playtest.

**Centre mass, not the surface.** Alien Swarm's phrasing, and it is what makes
pointing at an enemy's feet still hit them. **Confirmed 2026-08-18** — there are no
weak points to respect yet, so there is nothing for a more precise rule to be more
precise about.

**Weak points are not in this milestone** but the shape allows them: the snap
target is "a point on that body", and today it is the centre. If a head or a
glowing sac ever exists it becomes a different point from the same hook.

---

## What has to still be true when the knobs are off

The whole milestone rests on this, so it is stated as tests:

- `test_aim` unchanged and passing — the yaw path is untouched.
- `test_machine_gun`, `test_rocket`, `test_gunners` unchanged.
- `test_client_prediction` and `test_dash_prediction` unchanged. The input array
  grew, and the tolerant `s.size() >` reads `apply_state` already uses are the
  pattern to copy.
- A round fired in `level` mode with everything off lands where it lands today,
  measured rather than assumed.

---

## Open questions

1. **Does the laser sight ship, or stay debug-only?** It is a debug knob here, but
   a permanent thin sight is a legitimate design answer to "aiming at height
   requires precision", and might be what makes `point` mode viable at all.
2. **Does `snap` make `level` mode good enough?** A real possible outcome: the
   assist alone fixes elevation without the precision cost, and `point` mode never
   ships. The knobs are separate so that answer is available.
