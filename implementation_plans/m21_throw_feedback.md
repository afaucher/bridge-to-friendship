# M21 — telling the player how far a throw will go

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
