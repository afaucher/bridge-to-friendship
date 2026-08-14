# M14 — The debug console: a big config, shared by everyone

Asked for after the 2026-08-13 playtest:

> "A debugging menu that lets any player tweak parameters and have it reflected
> for all players. Assume a large config, not a small number of bespoke knobs.
> The first setting should be show hitboxes."

**This is the item most likely to pay for itself immediately.** Every other line
in that playtest report is a number somebody wants to try a different value for —
the plinko hit radius, the pillar width, the ramp slope, the machine gun's
spread. Today each of those is a `const` recompile-and-relaunch away, and the
person who noticed the problem is not the person who can try a fix.

---

## The foundation already exists, and it already predicted this

`scripts/debug_settings.gd` is a **registry**: a dictionary of options, each with
a label, choices, a default and a help string, plus environment overrides so a
headless run can flip one. Its own comment says the two things this milestone is
about:

> *"a debug menu can build itself from the registry without further wiring"*
>
> *"If a knob ever has to be CORRECT across a real multiplayer session, promote
> it out of here into replicated state; until then, ease of adding a toggle
> wins."*

That day has arrived. **Three things have to change and no more:** the registry
needs to describe numbers as well as enums, the values need to be replicated, and
something has to draw the menu.

---

## 1. The registry grows types

Today every option is an enum (`choices`, an index). Tuning gameplay needs
ranges:

| kind | example | why |
|---|---|---|
| `choice` | `net_log: off/on` | what exists today; unchanged |
| `bool` | `show_hitboxes` | a choice of two, but it deserves a checkbox |
| `float` | `plinko_hit_radius: 1.1, 0.4 … 3.0` | the playtest's actual asks |
| `int` | `mg_ammo: 20, 1 … 200` | |

Each entry keeps `label` and `help`, and gains `min`, `max` and `step` for the
numeric kinds. **Adding a knob stays one dictionary entry** — that is the
"large config, not bespoke knobs" requirement, and it is the property that has
to survive.

Group entries with a `section` field (`"Plinko"`, `"Ramps"`, `"Netcode"`) so a
config of fifty knobs is still navigable. The menu reads it; nothing else does.

## 2. How a knob reaches gameplay without making every constant a variable

`SimConfig` is `const` throughout, deliberately — it is where tuning lives and a
const is what makes it greppable and safe. **Do not turn it into a bag of
variables.** Instead the read site opts in:

```gdscript
# was:  SimConfig.PLINKO_HIT_RADIUS
DebugSettings.tuned("plinko_hit_radius", SimConfig.PLINKO_HIT_RADIUS)
```

`tuned()` returns the constant unless a knob is registered *and* has been moved
off its default, so the shipped game reads exactly what it reads today and the
cost is one dictionary lookup on a path that is not hot.

**Which numbers become tunable is decided one at a time, by somebody asking.**
Starting from the playtest: the plinko hit radius, the pillar radius, the machine
gun spread, and the ramp slope limit.

## 3. Replication: any player may ask, the host decides

The rule that keeps this consistent with everything else in the project:

- **The value lives on the host.** One owner, like every other piece of world
  state.
- **Any client may REQUEST a change** — `@rpc("any_peer", "reliable")` — which is
  what "any player can tweak it" means in a host-authoritative game.
- **The host applies it and broadcasts the whole config** —
  `@rpc("authority", "reliable")`. The config is small and changes by hand, so
  pushing all of it is cheaper than working out what changed. This is exactly how
  `player_names` already works, and copying that shape is the point.
- **A joiner gets the config in `host_add_peer`**, alongside the run seed, the
  spent mounds and the worn hats.

**Applied on a tick boundary, host-side, before the step loop.** A knob that
affects stepping is a sim rule; changing one mid-tick on one machine and not
another is a desync, and the whole reason this is replicated rather than local
is that the previous design said local knobs were fine *until* they had to be
correct across a session.

**Not shipped to players.** This is a dev surface: gate the menu behind the same
condition the practice-partner hotkeys use, and leave the RPCs registered but
unreachable in a release build.

## 4. Show hitboxes — the first real entry

Godot's own `debug_collisions_hint` is read when a shape enters the tree and does
nothing at runtime, so this has to be drawn:

- Walk the tree for `CollisionShape3D` and `CollisionPolygon3D`.
- `shape.get_debug_mesh()` gives the wireframe Godot itself uses.
- Parent a `MeshInstance3D` per shape with an unshaded, `no_depth_test` material
  so a box inside geometry is still visible — the same reason the status bar uses
  it.
- Toggling off frees them. Bodies created later (balls, rushers, bullets, hats)
  need it applied at spawn, so this hangs off the same place each pool creates
  its node rather than being a one-shot sweep.

**It answers two playtest items directly.** "Pillars catch you going around" and
"plinko balls hit you from a distance" are both claims about a collider that does
not match what is drawn — and the plinko one is already known to be a **2.0 m
test radius against 1.0 m of geometry**. Being able to see that in the running
game is worth more than the measurement in the report.

---

## Work breakdown

1. Registry gains `kind`, `min`/`max`/`step`, `section`. Existing entries keep
   working — they are `kind: "choice"` by omission.
2. `DebugSettings.tuned()`, and the four playtest knobs wired at their read sites.
3. Replication: request RPC, broadcast RPC, joiner sync, applied on a tick
   boundary.
4. The menu, built entirely by walking `OPTIONS` — a row per entry, a control per
   kind, grouped by section. **No per-knob UI code anywhere.**
5. `show_hitboxes`, and the debug-mesh layer it drives.

## Tests

| test | what it pins |
|---|---|
| `test_debug_settings` | extend the existing one: a float knob clamps to its range, an unknown key is refused, `tuned()` returns the constant when untouched and the override when set |
| `test_debug_replication` | over ENet (**port 28783**): a CLIENT requests a change, the host applies it, and **both machines read the new value**; a joiner arriving afterwards gets it too |

The second is the one carrying the design — "reflected for all players" is the
entire ask, and a local-only knob passes every other test in the file.

## Explicitly not in this milestone

- **Shipping it to players.** Dev surface.
- **Persisting the config.** It is a tuning session, not a settings screen. What
  survives is the value somebody writes into `sim_config.gd` afterwards.
- **Making every `SimConfig` constant tunable.** Opt-in per read site, one at a
  time, by request. A config with three hundred entries in it is a config nobody
  can find anything in.
- **Rebalancing anything.** This milestone builds the instrument. The numbers it
  finds are somebody else's commit.
