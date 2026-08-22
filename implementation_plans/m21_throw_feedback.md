# M21 — telling the player how far a throw will go

> **UNPARKED AND PARTLY BUILT, 2026-08-22.** The park note below is kept because
> it is the reasoning that produced the answer, not because it is still current.
>
> What shipped: a **world-space marker at the aim point** and a **charge bar
> underneath it**. That is the "two holes which look like one" the note predicted,
> built as one object. `laser_sight` became a three-way knob — off / beam / dot —
> defaulting to **dot**; the beam is kept because it is still the better
> *instrument* for catching a sight and a round disagreeing, and is simply the
> wrong thing to ship. `game_world._update_laser_sight`, gated by
> `test_aim_readout`.
>
> The open question the note ends on — *why* the sight was going — was never
> answered in words and did not need to be: a dot is welcome under all three
> readings, since it marks a point rather than drawing a beam.
>
> **Still unbuilt: the arc preview**, which is the actual subject of the plan
> below. The bar says how long you have held; it does not say where the grenade
> will land. Everything from "The problem" down still applies to that.

The park note, kept because it is the reasoning that produced the answer:

> **PARKED 2026-08-21, and the plan below is out of date in one load-bearing
> way.** It waited on M20 deciding whether the laser sight would ship, because
> the best readout here was a range tick on that line. The sight shipped on by
> default with M23 phase 0 — and has since been called: **it is not staying.**
>
> So the preferred option in the table below is dead, and taking the sight away
> reopens something else. Point aim went to default partly BECAUSE the sight
> covered pads: a mouse player's cursor IS the aim readout, but a pad's is
> virtual (`AimSource.PAD_CURSOR_RANGE`, 6 m along facing, ground-probed) and
> invisible. Without a sight, a pad player cannot see where they are aiming
> vertically, which is worse than the level aim it replaced.
>
> That leaves two holes which look like one: *where am I aiming* (pads, always)
> and *where will this land* (this milestone). A world-space marker at the aim
> point answers both — in the player's gaze rather than in a HUD corner, showing
> the POINT rather than a beam, and moving out to the solved landing distance
> while a grenade charges. One object, both jobs.
>
> **Open before any of it is built:** whether the sight is going because it looks
> wrong, because it is clutter, or because a beam reads as hitscan when the
> rounds are projectiles. A marker is welcome under the first two and unwelcome
> under the third, which is the difference between building this and dropping it.
>
> The charge bar below is also weaker than it reads. A grenade never touches
> `fire_timer`, so the slot's bar draws zero for the one weapon with something to
> say and the wiring really is a few lines — but a player throwing a grenade is
> looking at the world, not at the corner of the screen. Its own row in the table
> says "changes nothing; pure information", which is a compliment about risk and
> a criticism of usefulness.

Queued behind M20 deliberately: both items here are about a *held charge* and
where it will land, and "where it will land" is the thing M20 is in the middle of
redefining. Building an arc preview against the current aim and then rebuilding it
against a cursor point would be doing it twice.

---

## The problem

A grenade is charged by holding the button and thrown on release, and the throw
"solves an exact ballistic arc for the distance the player asked for". That is a
good mechanic with **no readout at all**: nothing on screen says you are charging,
how far along the charge is, or where the thing is going to come down.

So the player learns it by throwing grenades away. Four of them, and then the slot
is empty and the lesson was "somewhere near there, probably".

This is the same class of fault as the dash charges before their HUD slot: a
resource or a commitment the player cannot see is one they discover by spending.

---

## Two questions, and they are not the same question

**1. Am I charging, and how far along?** A state readout. Cheap, and it is the
half that stops a player wondering whether the button registered.

**2. Where will it land?** A world readout. Far more useful and far more
committing: it turns the grenade from a feel weapon into an aimed one, which is a
design change rather than a UI addition.

They can ship separately and the first is nearly free. Worth being honest that
(2) is the one that changes how the weapon plays.

---

## Candidate readouts

| | what it shows | cost | what it changes |
|---|---|---|---|
| **charge bar on the slot** | percentage of full | trivial — the slot already draws a cooldown fill | nothing; pure information |
| **ring on the ground** | the landing circle, growing with charge | moderate | grenades become aimed |
| **full arc preview** | the whole trajectory | moderate; the solver already exists | grenades become aimed, and reads as a different game |
| **range tick on the laser sight** | a mark at the landing distance | small IF M20's sight ships | ties the two features together |

The last one is why this milestone waits. If M20's laser sight ships as a
permanent feature rather than a debug knob, the throw readout is a mark on a line
that already exists, and the two features share one instrument instead of adding
two.

---

## Chargeable mines

Same mechanic, applied to a weapon that does not have it: hold to throw a mine
further instead of dropping it at your feet.

**It is small and it changes the weapon's role.** A mine you can place at range is
a trap you can set ahead of the party rather than behind it, which is a different
tool — and it makes the same readout question apply to a second weapon, which is
another argument for solving the readout once.

Worth checking during the work: whether a thrown mine should arm on landing or
after a delay. A mine that lands live at a teammate's feet is friendly fire with
no counter, and `friendly_damage` is already on the scoreboard to catch it.

---

## Order

1. **The charge bar**, because it is nearly free and answers "did the button
   register".
2. **Whatever M20 decides about the sight**, which determines whether the landing
   readout is a new object or a mark on an existing one.
3. **The landing readout**, once there is somewhere to put it.
4. **Chargeable mines**, last, because they inherit all three.
