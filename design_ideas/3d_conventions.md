# 3D conventions

Small, boring decisions that are expensive to change once content exists.
Written 2026-08-08 (M0), when changing any of them costs nothing.

## Units and orientation

**1 unit = 1 metre.** Godot's default gravity (9.8) and the physics solver's
tolerances are tuned for this; picking centimetres means every default in the
engine is wrong by 100x and you find out via jitter rather than via an error.

**+Y is up. -Z is forward.** Godot's convention, and what `Camera3D` and
`Node3D.look_at` assume. `player.gd` maps `Input.get_vector(...)`'s +Y ("back")
onto +Z for exactly this reason — the sign flip lives in one line, commented,
rather than being scattered.

The reference avatar is a **1.8 m cylinder, 0.4 m radius**, resting with its
centre at y = 0.9 on ground whose top face is y = 0. `test_player_movement`
asserts that resting height, so a change to the collider is a change that a test
notices.

**A cylinder, not a capsule, and it never tips.** Players must be able to stand
on each other and on stones, and a capsule's domed cap slides a landing body
straight off. The flat bottom matters equally — it lets a body come to rest on a
stone instead of teetering on it. Upright is free rather than enforced:
`CharacterBody3D` is kinematic and does not rotate from physics. That is a
constraint on TUMBLE when it arrives — **tumble rolls the mesh and leaves the
collider upright**, or a rolling player stops being something anyone can stand on
halfway through the roll. Riding (being carried by whatever you stand on) is an
M3 deliverable; see `physics_and_authority.md`.

## Physics layers

Named in `project.godot` under `[layer_names]` so the collision-mask checkboxes
in the editor read as words rather than numbers:

| bit | name | who |
|---|---|---|
| 1 | `world` | static geometry, ground |
| 2 | `players` | player avatars |

Players collide with both (mask 3). Add a layer by naming it there in the same
commit as the first thing that uses it — an unnamed layer is a number someone
has to reverse-engineer from a mask.

**60 physics ticks per second**, pinned in `[physics]`. It is Godot's default,
but pinning it makes the value explicit: `--fixed-fps 60` in the test runner is
the same number, and a test that counts frames is counting this.

## Rendering

**Forward+.** The default renderer, and the one with the full feature set. Not
Mobile or Compatibility — neither is a constraint this project has, and moving
*down* later is easy while moving up is not.

MSAA 3D is on at 2x as a starting point. It is a knob, not a decision.

## Scenes

- `scenes/main.tscn` — the world root plus the menu. The world's contents live
  under a `World` node so that "everything the game built" can be cleared in one
  place; avatars live under `Players` for the same reason.
- `scenes/player.tscn` — one avatar. The camera hangs off a `CameraPivot` rather
  than off the body directly, so a look-direction can rotate independently of
  the body's facing without touching the body's transform.

**Only the local player's camera is `current`.** It is a per-viewport exclusive
flag, so leaving every avatar's camera enabled means the last one spawned wins —
which presents as "I am playing as someone else" rather than as a camera bug.
`player.gd` sets it from `has_control()` at `_ready`.
