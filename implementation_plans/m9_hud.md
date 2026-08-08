# M9 — HUD

**Status: DONE (2026-08-08).** Twenty tests passing, four of them new.

Shipped: `scripts/ui/hud_model.gd` (the decisions, headless-testable),
`scripts/ui/hud.gd` (the Control tree, built in code), player names as world
state with a Steam-or-fallback source, and the `rescue_progress` replication fix.

**Both gaps this plan predicted were real.** `rescue_progress` was host-only, and
the test written for it was checked against the bug — reverting the one-field fix
makes `test_hud_rescue_visible` report `rescue bar at 0.00` while the host reads
0.333, which is the failure it exists to catch. There were no player names
anywhere, so they became world state announced over the world's own multiplayer
rather than `NetworkManager` RPCs — the net harness gives each world its own
`SceneMultiplayer`, so an RPC on the `/root` autoload would travel over the
default peerless API and could never be exercised by a test.

Two things it cost that are now in `CLAUDE.md`: a dev box has Steam and the gate
does not, so a display name is never a safe assertion; and headless builds the
whole Control tree, so a UI script that nothing instantiates ships having never
run once — which is what `test_hud_view` exists to prevent.

Still open, deliberately: the friend bearing is a compass point and a distance in
the row, not a screen-edge marker (the plan's `[open]`, resolved the cheap way);
and there is no art beyond flat colours.

---

## Original plan follows

**Proves:** players can read their own and each other's state — and, just as
much, that *we* can read it during a playtest.

Exit: D5.

---

## This is an instrument, and it should be built early

M5 shipped health, the grace window, `TUMBLE`, the ledge catch, `DOWNED`, the
bleed-out timers and the shared rescue countdown. **None of it is on screen.**
There is one `CanvasLayer` in `main.tscn` and it holds the menu.

That makes the HUD's real job the one `CLAUDE.md`'s "Measuring a change" section
is entirely about: it is the instrument you read every subsequent milestone
through. The next milestone after this one in build order is **M4, the rope** —
which the roadmap names as the project's riskiest unknown and its first genuinely
playtestable co-op moment. Running that playtest with invisible health, invisible
bleed-out timers and an invisible rescue countdown wastes the playtest, because
every question it is supposed to answer ("did the rescue feel earned?") is a
question about numbers nobody can see.

**Recommendation: build M9 before M4.** The numbering stays — the exit criteria
reference it — the same way the M5-before-M4 swap was handled. Nothing in the HUD
depends on the rope; the rope's slot is drawn empty, exactly as the special's is.

---

## Two things D5 assumes that do not exist

Found by reading the code, not by reading the spec. Both are small, and both are
invisible until someone tries to build the panel.

### 1. There are no player names

D5: *"each friend's **name**, health and special top-right."* Nothing in the
codebase has a player name. `NetworkManager` tracks peer **ids**; there is no
persona, no display name, no fallback.

So the HUD needs a name source, and it cannot be the obvious one:
**`CLAUDE.md` forbids gameplay code from touching `Steam.*` directly**, precisely
because the gate has no Steam client. Names must arrive as **session state owned
by `NetworkManager`** — collected from `SteamManager` on the Steam transport,
falling back to something deterministic (`"Player 2"`) on ENet, and replicated to
everyone at join.

That is a networking task hiding inside a UI milestone, and it is the item most
likely to be discovered late. It is also the piece that makes the friend panel
mean anything: a panel of peer ids is not a HUD.

### 2. `rescue_progress` never leaves the host

`player_body.gd:80` declares it; `game_world.gd:393` and `:406` increment it in
`_tick_haul` and `_tick_revive`. It is **not in `capture_state()`**
(`player_body.gd`, which carries `health`, `invulnerable`, `hang_dir` and not
this).

So the bar showing *"a teammate is hauling you up"* — the single most important
thing the HUD draws, during the tensest moment the game has — **exists only on
the host's machine.** Every client's HUD would show a frozen empty bar and no
error anywhere.

The fix is one field appended to `capture_state()`/`apply_state()`. It is safe:
`_reconcile` compares position only, so an extra field costs nothing there, and
`LEDGE_HANG`/`DOWNED` are not predicted, so a client simply takes the host's
value. **Do this first**, before any Control node exists, and verify it with a
networked test rather than by looking at a screen.

This is a clean instance of the rule in `CLAUDE.md`: *validate an instrument
against a case where it must report failure before trusting its output.* A
rescue bar that is always empty on a client looks exactly like a rescue that is
not happening.

---

## The split that makes a HUD testable headless

The gate is headless. Nothing renders, so nothing about a `Control` tree can be
asserted — and a HUD verified by eyeballing it is a HUD that silently rots the
first time a state enum changes.

**Separate the model from the view**, the same way the grid is authoritative data
and the scene is a view of it:

- **`scripts/ui/hud_model.gd`** — a pure function from world state to a plain
  data structure. Own health and max, own state, own countdown fraction, own
  slot list, and a friends array (name, health, state, countdown, distance,
  bearing) sorted stably. No node references, no rendering, no engine types
  beyond `Vector3`.
- **`scripts/ui/hud.gd` + `scenes/hud.tscn`** — Control nodes that draw whatever
  the model says. Thin by construction. Untested, and that is fine, because it
  contains no decisions.

Everything interesting — "is the bleed-out fraction right at 4 s of an 8 s hang?",
"does a dead peer disappear from the friends list?", "are friends ordered the same
on every machine?" — is then a headless assertion that runs in milliseconds.

**The model is also the thing M4, M8.5 and M12 extend.** A rope slot, a hat count
and a special slot are new fields on a dictionary, not new layout code.

---

## What it draws

Per `mvp_success_criteria.md` D5, and per the concept doc's note that this is
per-player screens rather than splitscreen — so one HUD per machine, showing the
local player prominently and everyone else compactly.

**Top-left — you.**
- Health, as `MAX_HEALTH` (5) discrete pips rather than a bar. Discrete because
  the number is small and "how many hits do I have left" is the actual question.
- The grace window (`HIT_GRACE`, 0.75 s) as a brief flash on the pips. It is the
  reason a tumble through a pillar field does not kill you, and it is currently
  unknowable.
- Three action slots: **push**, **rope**, **special**. Push is live (show
  `shove_cooldown`, 0.35 s, as a sweep). Rope is empty until M4. Special is empty
  until M12.
- **An empty slot must read as deliberately empty, not broken.** Outline and a
  dimmed icon, never a blank rectangle.

**Top-right — your friends**, one compact row each, up to three.
- Name, health pips, special.
- Their state when it is not `WALK` — and specifically **`LEDGE_HANG` and
  `DOWNED` must be loud**, with the countdown. This is the HUD's whole reason to
  exist: those two states are a request for help that the player currently has no
  way to make.

**Centre — nothing.** No crosshair, no damage vignette, no hit markers. The
camera is fixed-yaw and the game is read at bridge scale.

### One addition D5 does not specify

The camera is **fixed-yaw** looking along the bridge, and the soft leash lets the
party spread to ~40 m (D3). A teammate behind you, or 25 m across a 60 m
structure, is **off screen** — and the moment that matters most is exactly when
they are hanging off a ledge somewhere you are not looking.

So a friend's row needs **direction and distance**, not just name and health: an
arrow toward them and a metre count, or an edge-of-screen marker. Without it the
friend panel tells you someone needs rescuing and not where, which is half a
feature.

**[open]** Arrow-in-the-row versus a screen-edge marker. The row is simpler and
never occludes the world; the marker is faster to act on. Suggested: start with
the row, because it is testable as a bearing in the model and costs no layout.

---

## Work breakdown

| # | work | files |
|---|---|---|
| 1 | `rescue_progress` into `capture_state()`/`apply_state()`, and a networked test that a client sees it move | `scripts/sim/player_body.gd` |
| 2 | Player names as session state on `NetworkManager`: Steam persona where available, deterministic fallback on ENet, replicated at join | `scripts/net/network_manager.gd`, `steam_manager.gd` |
| 3 | `hud_model.gd` — world state to a plain structure, with slots and a sorted friends list | `scripts/ui/hud_model.gd` |
| 4 | `hud.tscn` + `hud.gd` — pips, slots, friend rows, countdowns | `scenes/hud.tscn`, `scripts/ui/hud.gd` |
| 5 | Wire into `main.gd` beside the existing menu `CanvasLayer`; show on session start, hide on menu | `scripts/main.gd`, `scenes/main.tscn` |
| 6 | Bearing and distance per friend | `hud_model.gd` |

Item 1 is a simulation fix that happens to have been found by scoping a UI
milestone. It should land whether or not the rest of M9 does.

## Tests

| test | what it pins |
|---|---|
| `test_hud_model` | health and countdown fractions at known ticks; a `LEDGE_HANG` player reports the right state and a falling fraction; slot list shape; friends sorted identically regardless of dictionary order |
| `test_hud_rescue_visible` | over ENet (**port 28782** — next free; add to `CLAUDE.md`'s list when it lands) a client's model shows a teammate's rescue progress advancing. **Assert it is zero before the helper arrives**, or the test cannot distinguish "replicated" from "always full" |
| `test_hud_roster` | a despawned peer leaves the friends list; a joining peer appears with a name; four players produce three friend rows |

The middle one is the milestone's point. Written the obvious way it passes
against a stubbed constant, which is precisely the failure mode `CLAUDE.md`
warns about — so it asserts the *transition*, not the end value.

## Explicitly NOT in M9

- **Art.** Placeholder shapes and the default theme. A HUD that has to look good
  before it can be read is a HUD that lands after the playtest it existed for.
- **Damage direction indicators, minimap, objective markers.**
- **Splitscreen or spectator views.** Per-player screens, per the concept doc.
- **Anything for slots that do not exist yet.** Rope, special and hat counts are
  fields on the model and empty boxes on screen until M4, M12 and M8.5 fill them.
