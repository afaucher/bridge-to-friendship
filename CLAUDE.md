# CLAUDE.md

Operational guide for working on this repo with Claude Code. This is the
*how-to-work-here* companion to the design docs (`design_ideas/`) and the
milestone plans (`implementation_plans/`). See `README.md` for build/run.

Godot 4.7, GDScript, 3D, headless test workflow. Multiplayer is host-
authoritative over two interchangeable transports: Steam (GodotSteam) for
release, ENet for development and for every test.

**The engine is a dependency of the repo, not of the machine.** `godot.manifest`
pins the version; `godot_env.sh` / `godot_env.ps1` install exactly that build
into `build/deps/` and refuse anything that reports a different version. Nothing
outside the repo is read (a Godot on `PATH` is never reused) or written (export
templates go to `build/deps/godot-data`, reached by pointing `XDG_DATA_HOME` /
`APPDATA` at it, NOT to the developer's `~/.local/share/godot`). Several people
build this game on machines set up for other Godot work; that is the constraint
the whole build system is shaped by. Do not add a code path that falls back to a
machine-wide install — a build whose engine depends on what else is installed is
not a build anyone can reproduce.

**Provenance note.** The engine-level traps below marked *(inherited)* were paid
for in a sibling Godot project and are reproduced here because they are
properties of Godot and PowerShell, not of that game — they will bite here on
the day this project grows the same feature. Entries marked with a date were
observed *in this repo*. Do not silently promote an inherited note to a local
one; if you confirm one here, add the date and what you saw.

## Running tests

Tests live in `scripts/tests/*.gd`, one file per test, and are run by name:

```bash
# Via the runner (writes logs to test_logs/, prints a pass/fail line):
powershell -NoProfile -ExecutionPolicy Bypass -File ./test_runner.ps1 -TestName test_smoke

# Direct (simplest to capture output for grepping). The engine lives under
# build/deps -- it is a dependency of the REPO, not of the machine:
./build/deps/godot/4.7-stable/Godot_v4.7-stable_linux.x86_64 \
    --path . --headless --fixed-fps 60 --run-test test_smoke
```

- **Pass marker:** `>>> [TEST PASSED] <name> <<<`. Failures print
  `ASSERT FAILED` lines to stderr and `[TEST FAILED]`. The runner requires
  **both** exit code 0 and the marker — a test that crashes after printing its
  marker still exits non-zero, and a test that exits 0 without asserting never
  printed one.
- **Pass `--fixed-fps 60` on direct runs** (the runner already does). Without
  it, headless Godot runs the loop in REAL TIME — it *sleeps* to hold 60Hz — so
  a frame-counted test takes its simulated duration in wall clock. `--fixed-fps`
  uses the same 1/60 delta and identical frame counts (fully deterministic) but
  stops sleeping.
- **Reading output:** `test_runner.ps1` writes the real Godot output to
  `test_logs/<TestName>.log` and `.err.log` — read those. Piping the runner's
  stdout is lossy; the real message for a *parse* error appears only in the
  `.err.log` and never in the summary.
- **Writing a test:** subclass `res://scripts/test_support/test_case.gd`,
  implement `setup(main)`, assert with `check/eq/near`, call `finish()`. Use
  `_physics_process` for anything frame-based — the base class uses `_process`
  for its deadline, so overriding that disables the timeout.
- Anything under `scripts/test_support/` is a helper, not a test: the gate globs
  `scripts/tests/*.gd` only. Put shared rigs there so they do not run as tests.

`build.ps1` / `build.sh` run every test in parallel (capped) and abort the
export on any failure.

## Multiplayer

The whole networking surface is `scripts/net/`: `SteamManager` (lobbies, the
Steamworks API, nothing else) and `NetworkManager` (sessions, peers, the two
transports). **Gameplay code must never call `Steam.*` directly** — the gate has
no Steam client, so anything that reaches past NetworkManager becomes untestable
the moment it is written.

- **`get_unique_id() == 1` does NOT mean "I am the host."** Godot's
  MultiplayerAPI is never peerless: with no session it holds an
  `OfflineMultiplayerPeer` whose unique id is *also* 1. So a game that never
  connected to anything reports exactly what a host reports. Ask
  `NetworkManager.local_id()` (returns 0 when there is no session) or
  `NetworkManager.is_host`. Cost 2026-08-08: one wrong assertion in
  `test_network_session`, caught immediately because the test existed.
- **The two ends of a connection do not become ready in the same frame.**
  Observed 2026-08-08 in `test_enet_loopback`: the client's
  `connected_to_server` fires a frame or two BEFORE the host's `peer_connected`,
  because each MultiplayerAPI reports what its own poll has seen. An RPC
  broadcast on the client's signal alone goes to an *empty peer list* — the call
  succeeds, nothing receives it, and the symptom three seconds later is a
  silently lost packet rather than an error at the send. **Wait for both sides.**
  This generalizes past tests: any "on connect, immediately send X" is the same
  bug in gameplay code.
- **Two peers CAN share one process,** which is what makes the transport
  testable in the gate: a SceneTree holds several MultiplayerAPI instances, each
  rooted at a different node via `SceneTree.set_multiplayer()`. RPCs resolve by
  node path *relative to that root*, so `Pinger` under `NetHost` and `Pinger`
  under `NetClient` are the same address and the call crosses the socket. See
  `test_enet_loopback.gd`; copy that shape for any new replication test.
- **Test replication over ENet, not Steam.** Same MultiplayerAPI, same RPC
  routing, same peer-id semantics, different socket. A CI box has no Steam
  client, so a Steam-only mechanism has no gate at all.
- **`@rpc` mode is a security boundary, not a hint.** `"authority"` makes the
  API drop the packet unless it came from that node's authority peer;
  `"any_peer"` accepts it from anyone. Player state uses the former precisely so
  a client cannot move another client's avatar.

## Simulation traps (M1)

- **Two PERFECTLY coincident bodies fall through the floor.** Measured
  2026-08-08: two player cylinders at identical coordinates depenetrate into a
  degenerate normal that drives both DOWN through the ground (they settle at
  y = -1.9), while the same two bodies 1 m apart land correctly at y = 0.9. The
  symptom is every player free-falling from tick one, which reads as broken
  gravity — it is not; it is two things in the same place. Spawn points are a
  ring for this reason, and **any future code that places a body — the M5 drone
  return most of all — must not place it exactly on another one.**
- **`is_on_floor()` is derived state that survives `apply_state()`.** It lives
  inside the `CharacterBody3D` and rewinding cannot touch it, so a client that
  corrects to an airborne authoritative frame would replay its first tick still
  believing it was standing. `player_body.gd` keeps its own `grounded` flag,
  refreshed after every `move_and_slide` and carried in `capture_state()`. **Any
  state that affects stepping must be in `capture_state()` or replays diverge**,
  and the tell is `GameWorld.corrections` climbing every tick instead of sitting
  near zero.
- **A sim tick must equal a physics tick.** `move_and_slide()` takes its delta
  from the physics frame, so replaying N ticks inside one frame only reproduces N
  frames because the two are the same duration. `test_sim_determinism` is the
  tripwire; if `physics_ticks_per_second` ever changes, `SimConfig.TICK_DELTA`
  changes with it.
- **A readiness check that only runs in an event handler never runs again.** The
  net harness checked "is everyone spawned?" from `peer_connected` and
  `connected_to_server` — both of which fire *before* the host's spawn RPCs
  arrive — so it saw an incomplete roster once and never re-checked. The session
  was fine; the harness reported not-ready forever and every net test timed out.
  Poll readiness.
- **A body cannot walk while another body rests on it.** Two kinematic bodies
  block each other, and a rider is in permanent contact with its carrier, so the
  carrier's sweep collides with the thing standing on it. Measured 2026-08-08: a
  carrier held velocity 6 m/s and moved 0.2 mm, forever — which reads as "walking
  is broken", not "someone is standing on me". Fixed by dropping the players bit
  from the CARRIER's mask for the duration of its own step.
  **`add_collision_exception_with` is the wrong tool: it is MUTUAL in effect**, so
  the rider then falls through its carrier and the pair alternates
  grounded/not-grounded at half speed.
- **Godot transports a rider on a moving body, one tick LATE.** Doing it
  ourselves as well made riders move by `current delta + previous delta` and run
  off the front of their carrier. Pick one; we currently use the built-in
  (`platform_floor_layers`), with the caveat that it is engine-internal state
  `capture_state()` cannot restore — so watch `GameWorld.corrections` if riding
  ever happens during networked play.
- **A resting body flickers `is_on_floor()`.** `velocity.y == 0` does not
  reliably produce a floor collision in `move_and_slide`, and everything
  downstream flickers with it — the grounded flag, and therefore the carrier
  probe. `SimConfig.FLOOR_STICK` keeps a small downward push on while grounded.
- **`CharacterBody3D` is the wrong body for anything that rolls.** Observed
  2026-08-08 on plinko balls, and it took three wrong fixes to find. Its default
  GROUNDED motion mode brings a character's floor logic with it, including
  `floor_stop_on_slope`, whose entire job is to stop a CHARACTER sliding down a
  ramp — so balls landed on a 4-degree deck and sat there. `MOTION_MODE_FLOATING`
  removes that but not the deeper problem: a sphere micro-bounces on a shallow
  slope, so it is airborne on most ticks and `move_and_slide` never gets to
  convert gravity into roll. The symptom throughout was "the friction is far too
  high", and the friction was innocent every time. **A ball is a `RigidBody3D`** —
  it is the one object here whose behaviour is physics rather than a designed
  rule, and it is host-authoritative and never predicted, so the determinism
  objection to rigid bodies does not apply to it.
- **A resting body reports a collision EVERY tick, so "bounce on contact" scrubs
  velocity sixty times a second.** `velocity.dot(normal) < 0` is true by a hair
  once a body is settled, and multiplying the whole velocity by the restitution
  each tick is `0.5^60`. Decide a bounce from the velocity captured BEFORE
  `move_and_slide` (afterwards the into-surface component has already been
  removed, so it tells you nothing) and only above a real impact speed.
  **Deliberately NOT fixed for `TUMBLE`** — the per-tick scrub is what makes a
  tumble settle, and it was kept after playtest. See the note in `_step_tumble`.
- **ANY judgement about an impact must use the velocity from BEFORE
  `move_and_slide`.** It has now cost three separate bugs — the ball's bounce,
  the ramp launch, and the tumble bounce. `move_and_slide` removes the
  into-surface component, so reading `velocity` back afterwards says the body was
  barely moving toward the thing it just hit at 11 m/s, and every threshold
  keyed on it silently never fires. Capture `var approach := velocity` first.
- **Half a gate is not a gate.** `test_ramp_traversal` asserted a lone player
  *cannot* climb the steep ramp and nothing asserted a shoved one *can* — and a
  wall nobody can climb passes that just as well. The shove up a ramp was broken
  the whole time and fully green. **When a rule has two halves, test the half
  that says something is POSSIBLE**; that is the one carrying the design.
- **A COUNTER MUST OUTLAST THE STATE IT CREATES, or it is a counter that loses.**
  Observed 2026-08-13 from a playtest report of "winning the dash still tumbles
  you". A dash deflected a rusher into a 2 s stagger and the stagger stayed
  *dangerous*, while the dash itself lasted 0.1 s and its cooldown 0.35 s — so the
  player spent the answer, could not repeat it, and was tumbled by the very thing
  they had just beaten. **Compare the duration of a verb against the duration of
  the state it produces**; when the second is twenty times the first, the window
  in between belongs to the enemy. Two further lessons came out of the same fix.
  **One predicate cannot answer two questions:** `is_dangerous()` gated both "can
  it hurt you" and "can you bat it", so making it safe also made it unbattable and
  the player bulldozed it around with their body instead — it needed splitting
  into `is_in_play()` and `is_dangerous()`. And **a phase that samples ONE frame
  cannot see a bug seven frames later**: `test_rusher` checked the deflect at
  frame 30 and the tumble landed at 37, so it was green for the whole life of the
  bug. Where a claim is "X is safe FOR A DURATION", assert it on **every tick of
  that duration**, and read the duration off the object rather than counting
  frames — a re-deflect resets the clock, so the frame number was never knowable.
- **A rig that holds a movement input for two seconds walks the player off the
  map.** The same fix's first test failure was a hat stack dropped by a
  `LEDGE_HANG` sixteen metres away, with nothing to do with the hazard under test.
  Twin of the "measure on a fixture with nothing else moving in it" note below:
  **release the stick once the moment you are testing has passed.**
- **A TAPERED SHAPE IS PAPER-THIN WHERE IT TAPERS, and a walkable surface with
  nothing under it is a hole.** Observed 2026-08-13 from a playtest report of
  "falling through a gap near the bottom of a ramp". A ramp is a wedge, and
  `_build_deck` emits slabs for DECK and WATER only — so a ramp cell had no floor
  of its own and the first centimetres of every ramp in the game were a knife
  edge over a `DECK_THICKNESS`-deep void. Measured: 1.002 m of solid on the deck
  behind, **0.053 m five centimetres onto the ramp**, with its underside at the
  deck's *top*. Fixed with a skirt — the box the deck would have had.
  **`test_ramp_traversal` walked a body up that ramp on every run and passed the
  whole time:** a body at `WALK_SPEED` crosses two centimetres of paper in a third
  of a tick and never sinks into it. The bug needed a body that ARRIVES rather
  than crosses. **A gate can walk over a hole for months** — so when the symptom
  is "sometimes I fall through", measure the STRUCTURE, do not re-run the walk.
- **ISOLATE EVERY SAMPLE, NOT ONCE AT SETUP.** Observed 2026-08-14 sweeping the
  ramps: a probe cleared the rushers and balls in `setup()` and then ran 11
  attempts. The THIRD attempt failed every time -- at lateral offset 0.5 in one
  sweep and at 0.2 in another, which is the giveaway: it was the third ATTEMPT
  failing, not a position. Mounds keep waking while the run continues, and the
  rusher tumbled the probe. Both "anomalies" vanished when the clear moved into
  the per-attempt reset, and the ramps then measured clean everywhere. **A long
  sweep is a fixture that gets dirtier as it runs.** The tell is a failure that
  tracks the sample INDEX rather than the sample VALUE, so print both.
- **Measure on a fixture with nothing else moving in it.** The first pass of that
  investigation ran on `playtest_bridge.seg`, where live shooters and rushers were
  tumbling the probe body — and every one of those reads as "the ramp threw me
  off". Two rounds were spent on rig artefacts: that, and a flat-bottomed cylinder
  placed centre-on-surface, whose UPHILL RIM is `radius * tan(slope)` — 0.2 m on a
  26.6° ramp — buried in the slope, which the solver then ejects. **Before
  believing a rig, check what it does on a case that must be clean.**
- **A seam between two convex shapes catches a flat-bottomed body, and it
  presents as "sometimes".** Ramps were merged along Z but not across X, so a
  two-cell-wide ramp was two wedges with a vertical seam down the middle: walking
  up either half was fine, walking the middle stuck. Anything that depends on
  lateral position will pass a single-lane test forever. **Merge co-planar
  geometry into ONE shape**, and when a bug is intermittent, ask what varies
  between the times it happens.
- **A DISTANCE ASSERTION HAS NO OPINION ABOUT DIRECTION, and this project has now
  shipped three sign errors.** Observed 2026-08-14: the grenade throw built its
  own forward vector as `Vector3(sin(f), 0, cos(f))`, which is the exact NEGATION
  of `GridConfig.yaw_vector`, so every grenade was lobbed over the thrower's
  shoulder — and it reached a playtest. `test_grenade` had four claims about the
  throw and all four were about **how far**: a tap lands near, a full hold lands
  far, the near throw is inside your own blast. A magnitude is true whichever way
  the thing went. The same expression already existed in `SpecialPool.drop_offset`
  where it is correctly named `away`; copying it and calling it `forward` is the
  whole bug. **Build direction vectors through `GridConfig.yaw_vector`, never from
  sin/cos by hand**, and when a test measures how far, ask what measures which way.
  (The earlier two were both Godot's row-major `Basis` — a bullet tail and a muzzle
  offset, from the same nine numbers.)
- **Check the collision MASK before debugging the behaviour.** *(Now FOUR bugs,
  the latest 2026-08-14: grenades flew through pillars because their mask was
  world-only and a pillar is a STONE on layer 3.)* A dash passed
  straight through a pillar for two rounds of diagnosis: stones are on layer 4
  and the player's mask was 3. Nothing errors; the shove simply never contacts
  anything. **Three separate bugs have now been one wrong bit here** (that dash,
  a carrier unable to walk under a rider, and balls passing through each other),
  so the layers are NAMED in `project.godot` — a named bit can be read back.
  **When a body should collide with its own kind, its mask must include its own
  layer.** This is the one anybody omits, because every other entry in the mask
  is about something else and the self-bit does not look like it belongs.
- **A non-resource file is NOT exported unless `include_filter` names it.**
  `export_filter="all_resources"` means resources — a plain `.txt` or `.seg` in
  the project root is skipped in silence, so `FileAccess.file_exists()` is true
  in the editor and false in the shipped game. This is the worst shape a bug can
  have: it exists only in the artifact the gate cannot run. `version.txt` was
  packed only after being added to the filter; `segments/*.seg` is there for the
  same reason. **After adding any data file, read the `savepack:` list in the
  export output and find it.**
  It cuts the other way too: `all_resources` sweeps in ANY resource under
  `res://`, and the engine now lives under `build/deps/` — so its own
  `editor_settings-4.4.tres` was being packed into the shipped game until
  `exclude_filter="build/*"` was added (2026-08-10). Read that list for things
  that should NOT be there as well as things that should.
  **And it is not merely untidy — on 4.7 it ABORTS THE EXPORT.** Godot loads
  that stray EditorSettings while packing and then dies in `is_cmdline_mode`
  with `Parameter "singleton" is null`, *after* `savepack` has printed DONE, so
  the log looks like a completed pack followed by an unrelated crash. 4.4.1
  packed the same file and carried on: the identical tree exported fine on one
  engine and died on the next, which is what an engine upgrade is for finding.
  The build scripts now also drop a `.gdignore` into `build/` (godot_env.sh),
  and THAT is the real fix — it removes the directory from EditorFileSystem
  entirely, so nothing under it is scanned, imported or exported. The
  `exclude_filter` is the committed backstop. **Anything the build writes inside
  `res://` is a candidate for the shipped `.pck`.**
- **A one-of-something test cannot see a many-of-something bug.** Balls ghosted
  through each other for the whole life of the plinko feature while its tests all
  passed, because every one of them used a SINGLE ball — which is what you reach
  for when you want a deterministic assertion. If a feature's whole point is that
  several of a thing share a space, one of them must be tested together.
- **Enum values are script constants: `instance.Enum.VALUE` raises at runtime**
  and, per the GDScript trap below, ABORTS THE REST OF THE FUNCTION silently. A
  stone push read as "the shove missed". Read enums off a preloaded script
  (`StoneBody.Mode.SETTLED`), never off an instance.
- **Two worlds in one process share ONE physics space.** The test harness offsets
  each world by 1 km for exactly this reason. It is also why the snapshot wire
  format carries **world-local** coordinates: a protocol with absolute positions
  would teleport a client's player into the host's copy of the world.

## Headless gotchas

- **A fresh clone or `git worktree` is NOT a runnable checkout — import first.**
  *(inherited)* `.godot/` is not tracked, so a new checkout has no import cache
  and no global class cache; every run dies in a parse-error cascade *before
  reaching the test*, and the process can stay resident afterwards so a task
  list shows a healthy Godot. `import_check.ps1`/`.sh` now handle this
  automatically (they run `--headless --import` when `.godot/` is absent), but
  recognise the symptom: **several logs of exactly the same size are several
  runs that produced no run-specific output.**
- **Do NOT trust `--headless --check-only --script <path>` for validation.**
  *(inherited)* It reports *false* parse errors on autoload identifiers —
  `DebugSettings`, `NetworkManager`, `SteamManager` are used all over this
  codebase, so a syntax gate built on it fails on correct code. Both build
  scripts deliberately omit that step; scripts are validated by the tests that
  load them, and `test_smoke` is the one that fails first and cheapest.
- **Godot 3D physics is not bit-deterministic run to run** *(inherited)*
  (contact-solver / float ordering), even with a fixed delta and a seeded RNG.
  Assert *robustly* — margins and tolerances, as `test_player_movement` does
  with `near()` — never on an exact position or an exact frame.
- **But a margin-shaped failure is NOT automatically jitter.** *(inherited)*
  Re-run the one test solo and compare the NUMBER. Identical → deterministic,
  debug it. Different → then it is jitter. That is one cheap run, versus tuning
  a budget that was never the cause.
- **A DEV BOX HAS STEAM AND THE GATE DOES NOT, so never assert a display name.**
  Observed 2026-08-08 writing the M9 HUD tests: `SteamManager` initialises fine
  on a developer machine (`[Steam] ready: duckbob`), so `_local_display_name()`
  returns the persona there and the `"Player 1"` fallback on CI. A test asserting
  the literal passes in one place and fails in the other for a reason the code
  does not control. **Assert the rule** — `default_player_name(1)`, or that a
  name was announced *at all* — never the value. Generalises past names: anything
  read out of the environment (persona, locale, machine name, wall clock) is not
  a property of the code and does not belong in an assertion.
- **Headless builds the whole Control tree; it just does not draw it.** So a HUD
  or menu IS testable — node construction, `_ready`, `_process` and property
  writes all really run. That matters because GDScript resolves properties at
  runtime: `ProgressBar.tint_progress` is Godot 3 and raises on the first frame
  and nowhere earlier. If nothing in the gate ever instantiates a UI script, it
  ships having never been executed once (see `test_hud_view`).
- **THE HEADLESS VIEWPORT IS 64x64, so screen-space UI cannot be tested through a
  camera.** Measured 2026-08-14 building the offscreen teammate marker: a point
  dead ahead of a `Camera3D` unprojects to (32, 32) -- correct, and also within
  48 px of all four edges at once, so every teammate in the world read as "off
  screen" and the first version of the test failed four ways while the code was
  right. `unproject_position` and `is_position_behind` work fine; it is the SIZE
  that is nonsense. **Split the placement maths into a pure function that takes an
  explicit screen size**, assert that with a real 1280x720, and leave the
  projection itself to Godot -- it is their code, not ours, and only one of the two
  is worth a gate.
- **Tests seed the global RNG** (`seed()` in `main.gd`'s `_run_test`). `randf`/
  `randi` are otherwise entropy-seeded per launch, which makes any
  outcome-dependent test flaky run to run — and a flaky gate gets ignored, which
  costs the one real regression it exists to catch. Do not remove the seed.
- **GDScript's `%` has no `%g`, and an unsupported specifier does not raise — it
  returns THE FORMAT STRING.** *(inherited)* One line to stderr, then
  `"%g" % [1.5]` evaluates to the literal `"%g"`. Supported: `%s %d %f %x %c %%`
  with `-`/width/`.precision`/`*` modifiers. **A generator's exit code and file
  size prove nothing — grep its output for a value you can predict.**
- **`FileAccess.store_line` buffers** *(inherited)* — a file being written may
  read back as 0 lines until it is flushed or closed.
- **Kill stragglers** if a run hangs: `pkill -f Godot_v` (Linux) or
  `taskkill //F //IM Godot_v4.7-stable_win64.exe` (Windows).
- **PowerShell's `-Encoding utf8` writes a BOM, and a BOM breaks Godot's text
  formats.** Observed 2026-08-08 rewriting a `.tscn` with `Set-Content -Encoding
  utf8`: every load failed with `Parse Error: Expected '['` at **line 1**, and
  the file looked perfectly correct in every editor. The cascade then blamed
  eight unrelated scripts that merely preload the scene. Use the Write tool, or
  `[System.IO.File]::WriteAllText`, for any file Godot parses. A line-1 parse
  error on a file that reads fine is a BOM until proven otherwise.
- **A test script that fails to compile used to HANG the runner rather than fail
  it.** `load()` returns null on a parse error; setting a null script leaves a
  bare Node with no `setup()`, which runs nothing and never quits — so a typo
  presented as a 600 s timeout while the real `Parse Error` sat in the
  `.err.log`. `main.gd` now checks for this and exits 1 with a pointed message.
  The general lesson stands: **a hang is very often a compile failure.**
- **`Compress-Archive` SILENTLY SKIPS a file it cannot open.** Observed
  2026-08-08: the release zip came out 1.5 MB instead of 33 MB because the 97 MB
  `.exe`, written seconds earlier and still being scanned by the on-access
  antivirus, was locked at the moment it was read. No error, no warning, exit
  code 0, and the script printed "Build Complete!" over an archive containing the
  `.pck` and the DLLs and **no game**. Intermittent, which is worse — the same
  command a minute later produced a correct archive. `build.ps1` now verifies the
  archive entry-by-entry against the directory (presence *and* length) and
  retries before failing. **A packaging step that reports its own success is not
  evidence; open the artifact.** Generalises: this is the shipped-artifact twin
  of the `include_filter` trap above — both produce a broken build that no test
  run can see.
- **PowerShell capture traps, both of which silently corrupt a long run.**
  *(inherited)* `Select-Object -First N` TERMINATES the upstream pipeline, which
  kills the Godot process mid-run — a truncated run then looks like a crash or a
  clean finish depending on where it stopped. And `Select-String` is
  case-insensitive by default, so a pattern like `RETURNED` matches
  `returned_empty=0` in every routine status line. Separately, `*>` does NOT
  capture a native executable's stdout the way it captures a `.ps1`'s streams:
  the file is created and stays empty. Pipe to `Select-String` (no `-First`, add
  `-CaseSensitive`) rather than redirecting.
- Long-running commands get auto-backgrounded by the harness; wait for the
  completion notification, then read the log file.
- **A DURABLE log is guilty until proven fresh — check its mtime before reading
  it as this run's result.** *(inherited)* Files under `test_logs/` persist
  between runs. Reading a stale one produced a wrong "the gate is red" call and
  a whole A/B chasing a failure that did not exist. **Identical timings across
  two runs means you are reading one run twice.** Prefer the invocation's own
  captured stdout.

## GDScript traps

- **`:=` cannot infer a type from a Variant expression.** Observed 2026-08-08 in
  `debug_settings.gd`: `var env_name := "BTF_" + key.to_upper()`, where `key`
  came from iterating a Dictionary, is a *parse* error — "Cannot infer the type
  of ... because the value doesn't have a set type". Write the type out:
  `var env_name: String = "BTF_" + str(key).to_upper()`. Same for
  `var x := arr.filter(...)` → `var x: Array = arr.filter(...)`.
- **A parse error in one script fails EVERY script that depends on it,** and the
  suite then reports damage nowhere near the cause. The above broke
  `test_smoke` and `test_debug_settings`, which name-drop `DebugSettings` and
  otherwise had nothing to do with it. **After any multi-site or mechanical
  edit, run ONE affected test directly and read its `.err.log`** before spending
  ten minutes on a full gate — a compile failure surfaces there in seconds.
- **A missing `Dictionary[key]` access aborts the rest of that function for the
  frame** *(inherited)* — it raises a runtime error rather than halting the
  engine. In a hot path like `_physics_process`, one missing field silently
  kills the whole per-frame update with no crash. Use `d.get("field", default)`
  for anything not guaranteed to be present.
- **The same is true of a missing PROPERTY, and it can turn the gate green over a
  test that stopped testing.** Observed 2026-08-10 renaming `shove_dir` to
  `shove_yaw`: `test_shove` still read the old name, the read raised, the raise
  aborted the rest of that phase — so the assertion never ran and the suite
  reported PASS with `SCRIPT ERROR: Invalid access to property` sitting in
  stderr. **The runner checks the exit code and the marker; a GDScript runtime
  error changes neither.** After renaming ANY field the tests touch, grep the
  tests for the old name — the gate will not tell you. Same shape as the
  `test_ramp_traversal` half-a-gate note above: a test that cannot fail is not a
  test.
- **Assigning a freed object to a typed `var x: Node` raises BEFORE
  `is_instance_valid(x)` can say no.** So the usual guard does not guard: the
  raise aborts the frame, and if that frame was advancing a state machine the
  symptom is a TIMEOUT with no failing assertion. Cost 2026-08-08 in
  `test_rusher`, twice, on a body whose whole job is to die on contact. Hold an
  **id** and look the node up, or keep the variable untyped.
- **Adding a `preload` const can create a CLASS CYCLE that HANGS the run, not
  fails it.** *(inherited)* A bare `class_name` reference resolves lazily; a
  `const X = preload(...)` forces the script to resolve earlier and can close a
  loop. The errors read `Parse Error: Could not resolve class "..."` and the run
  wedges rather than reporting a failure. **If a test that passed a minute ago
  now hangs, suspect a newly-added preload before suspecting the game.** The fix
  is usually structural — move the logic onto the class that already imports the
  other — rather than a forward-declare dodge.
- **A reject-sampling `while` is an infinite loop waiting for a degenerate
  input.** *(inherited)* `while j == i: j = randi() % n` never terminates when
  `n == 1`, and it burns CPU *inside a single physics frame*, so the game stops
  advancing while the process looks perfectly busy. Prefer an offset pick
  (`j = (i + 1 + randi() % (n - 1)) % n`) and guard `n < 2` explicitly.

## Architecture orientation (pointers, not a re-doc)

- **`scripts/main.gd` is the root of everything running.** It owns the menu, the
  spawned avatars, and the two headless entry points (`--run-test`,
  `--run-sim`). The headless check is the FIRST thing `_ready()` does, before
  any menu or network wiring — a test run must not touch Steam.
- **Spawning is host-decided, one code path.** `_spawn_player` is an
  `@rpc("authority", "call_local")`, so the host runs the same function it tells
  clients to run rather than having a host branch and a client branch that can
  disagree. A newcomer is caught up on existing avatars *before* being announced
  to everyone.
- **Player movement is client-authoritative** (each avatar's authority is its
  own peer; remote copies interpolate toward a broadcast state). Fine for co-op,
  wrong for competitive. The swap — clients send input, host simulates all
  bodies — is deliberately confined to `player.gd`'s `_physics_process`.
- **Debug knobs live in the `DebugSettings` autoload** as a registry (`OPTIONS`
  dict). Read with `DebugSettings.get_choice("key")` / `is_on("key")`; add one
  by appending a single `OPTIONS` entry. Every knob is also settable from the
  environment as `BTF_<KEY>=<index or name>`, so a headless run can flip one
  without any UI.

## Measuring a change

These are the expensive lessons from a sibling project, kept because they are
about *method*, not about that game.

- **MEASURE THE STAGE YOU CHANGED, not the end of the funnel.** A change built
  to raise stage-2 throughput, judged on the stage-5 outcome, reads as null: a
  funnel's end sums every failure mode, so a real gain at one stage is invisible
  while a later stage still fails. Corollary: with an event that occurs 0–2
  times per run, three samples cannot distinguish anything.
- **"Attempted" is not "delivered," including in instrumentation you just
  wrote.** A send function that returns a sequence number whether or not anyone
  was listening produced a "12/12 landed" counter that was measuring sends. The
  honest count has to be incremented on the RECEIVING side, at the line that
  consumes the message. (This is exactly the shape of the empty-peer-list RPC
  bug above.)
- **A LATENCY INSTRUMENT READ ON A STATIONARY BODY REPORTS ZERO, WHICH LOOKS
  EXACTLY LIKE A BROKEN INJECTION.** Observed 2026-08-14 measuring the contact
  prediction baseline: the client-versus-host disagreement about a remote player
  was 0.000 m at 4 ticks of injected delay AND at 40, which reads as "the delay
  does nothing" and would have condemned a working rig. It was zero because the
  reading was taken at the END of the run, when both players were pressed together
  and STILL — and a still body looks identical in every view however stale. Sampled
  every tick it scaled properly (0.40 m at 4 ticks, 2.65 m at 40). **Staleness is
  only observable on something that is MOVING**, so sample it across the run and
  keep the worst, never once at the end.
- **VALIDATE AN INSTRUMENT AGAINST A CASE WHERE IT MUST REPORT FAILURE before
  trusting its output.** Probes that could only ever return 0, and probes that
  sampled state after it had already been released, both produced confident
  *wrong* eliminations. Knowing this rule does not prevent repeating it — the
  check has to be mechanical: feed the instrument a known-bad case and confirm
  it says so.
- **The absence of a gated log is NOT the absence of the event.** A `grep -c`
  returning 0 usually means the print sits behind a `DebugSettings` toggle that
  is off. Cross-subsystem disagreement is the reliable signal; a silent log is
  not evidence.
- **Build the smallest rig that reproduces the mechanism before instrumenting
  the whole game.** A two-body question chased through full-scale runs for six
  turns was answered in 1.5 seconds by a purpose-built two-body harness. The
  full game is where RATES are measured; it is a terrible place to debug a
  MECHANISM.
- **A max/peak answers "did it ever," never "does it usually." When the question
  is whether a behaviour is RUNNING, measure DUTY CYCLE.** One transient frame
  sets a max, which once produced a confident conclusion that was the exact
  opposite of the truth. And two maxima are only comparable if they were sampled
  over the same frames — state the window when you record one.
- **`git log --grep` BEFORE proposing a change to load-bearing behaviour.**
  Behaviour that looks wrong in one context is often deliberate in another, and
  the commit message is where that reasoning lives.
- **Prefer a DIRECT COUNT at the line that does the thing.** Counting where the
  event happens cannot be argued with; eliminating candidates by reading can be,
  and often wrongly.

## Conventions

- Commit messages use a `feat:`/`fix:` prefix.
- Design decisions get a short doc in `design_ideas/`; milestones get a plan in
  `implementation_plans/`. Prefer adding to those over inline essays.
- **AUTHORING SOMETHING INTO THE PLAYTEST MAP CAN BREAK A TEST THAT MEASURES ON
  IT.** `playtest_bridge.seg` says in its own header that it is not a fixture and
  that tests keep their own segments -- but `test_plinko` and `test_rescue` use it
  anyway, because it is the only map with shooters and authored gaps. Observed
  2026-08-14: adding one skirmisher failed three assertions in `test_plinko`, and
  not one of them named it ("the dash is running -- expected 1, got 2" was a
  player being shot mid-dash). **Anything added to that map for feel has to be
  cleared by the tests that borrow it** -- `_isolate()` already existed for
  exactly this and just needed the new pool.
- **A TEST WHOSE WINDOW STARTS AFTER THE EVENT CANNOT SEE IT.** Observed
  2026-08-14 on `test_dash_prediction`: the stall being asserted about happens
  between tick +0 and +1, and the sampling window began at +1 -- so the assertion
  was dead code and passed against the broken build. Found by A/B, which is the
  only thing that finds it. **Sample from the tick the event happens ON.**
- **NEVER `git checkout --` A FILE THAT HAS UNCOMMITTED WORK IN IT.** Observed
  2026-08-14 while A/B-ing the debug console: a loop that disabled one function,
  ran the gate, then "restored" with `git checkout -- scripts/sim/game_world.gd`
  threw away an hour of uncommitted edits, because checkout restores from HEAD
  and HEAD did not have them. The next iteration then ran against code where the
  feature did not exist and reported a TIMEOUT, which reads as a hang rather than
  as a missing file. **Copy the file somewhere and copy it back** -- an A/B is a
  temporary edit, not a revert, and the two want different tools.
- **Temporary files go in `tmp/`** (gitignored). Any throwaway output — a dump,
  a scratch CSV, a debug capture, a one-off script's result — writes under
  `tmp/` (`res://tmp/...` from GDScript; call
  `DirAccess.make_dir_recursive_absolute("res://tmp")` first, it is idempotent)
  so a run never dirties the working tree. Do NOT write scratch files to the
  repo root. Test logs are the named exception and go to `test_logs/` (also
  gitignored).
- **Every test binds its own port.** The gate runs tests as PARALLEL processes
  on one machine, so two tests sharing a port is a race that fails whichever
  loses, intermittently, and reads as a networking bug. Allocated so far:
  `test_enet_loopback` 28777, `test_network_session` 28778,
  `test_authority_agreement` 28779, `test_client_prediction` 28780,
  `test_hud_rescue_visible` 28782, `test_debug_replication` 28783,
  `test_dash_prediction` 28784, `test_contact_prediction` 28785 (28781 is
  reserved for M8.5's hat replication test). Pick the next free one and add it
  here.
- **A sim or long-running harness needs an UNCONDITIONAL heartbeat,** or you
  cannot tell hung from slow. Print a plain `frame N / TOTAL` line on a path no
  game state can gate. *(inherited — diagnosing its absence cost hours.)*
