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
- **A PEER ID IS NOT AN INDEX, and locally it looks exactly like one.** Observed
  2026-08-15: a straggler respawn passed `peer` to `entry_spawn_cell(index)`,
  whose lane maths is `width/2 - 3 + index*2` CLAMPED. Peers are 1 and 2 in a
  local game, so it produced lanes 1 and 2 and played perfectly; over the network
  Godot hands out large random ints, every straggler folded onto the outer
  column, and two of them onto the SAME CELL — coincident bodies, driven through
  the floor by the trap above, catching the deck lip on the way past. The report
  was "teleported to the lobby and left hanging off the outside of the bridge".
  **Any test with hand-picked peer ids of 1 and 2 cannot see this**, and every
  test in this repo used exactly those; `test_straggler_return` now uses ids of
  Godot's own shape. **And a CLAMP is the wrong response to an out-of-range
  index anywhere a body is placed** — it folds distinct callers onto one cell,
  which is not "somebody spawns oddly" but the through-the-floor trap. Wrap.
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
  **And where you CANNOT merge, OVERLAP -- a gap and a flush join are the same
  bug.** Observed 2026-08-16 on the elevator, whose slab cannot be merged into the
  deck because it moves. Inset by 4 cm "so it does not scrape", it stopped a body
  walking onto it DEAD at the boundary, with the platform level and a ray at chest
  height finding nothing: a flat-bottomed cylinder does not cross a 4 cm gap, it
  catches the far lip of one, and two boxes placed exactly face to face are that
  with the gap set to zero. Sizing the platform 3 cm PROUD on each side buries its
  vertical face inside the deck box, so a body crossing at deck height never meets
  an exposed edge. **Ray at FOOT height when a walk stops for no reason** -- the
  chest-height ray said "nothing there" and was the reason two rounds went
  looking for the wrong collider.
- **A CONVEX HULL AND A CYLINDER STOP AGREEING FAR FROM THE ORIGIN, and the
  disagreement is METRES wide.** Observed 2026-08-16 from a playtest report of
  "rubber-banding on ramps, even in solo". Ramp wedges were
  `ConvexPolygonShape3D` from `create_convex_shape()`, the player is a
  `CylinderShape3D`, and Godot solves that pair in WORLD space. At 160 m up the
  bridge the solver returned bogus manifolds -- normals anchored at the wedge's
  far vertices, reporting **4.47 m of penetration** against a 0.8 m-wide body --
  and `move_and_slide` dutifully depenetrated along them, throwing the body
  **3.86 m in ONE TICK** (a walking step is 0.108 m) and back again the next.
  **The tell that it is not movement code: `velocity` sat at a constant
  `(0,0,-6)` and `grounded` stayed true throughout**, so the displacement was 25x
  `velocity * delta`. When a body moves far further than its velocity allows it
  is being EJECTED, not driven -- read `get_slide_collision().get_depth()` before
  touching anything in `player_body.gd`. A 2x2x2 (origin/160 m x
  cylinder/capsule x convex/trimesh) put the fault in exactly one cell: only
  cylinder-vs-convex-far fails, and EITHER swap fixes it. Ramps now use
  `create_trimesh_shape()`, a static ramp having no need of a convex shape.
  Two further lessons came out of it. **It scales with distance, so solo's
  endless assembled run makes it worse the longer you play** -- which reads as
  degradation over time and is why the first report blamed the netcode; a
  near-origin fixture like `test_ascent.seg` shows the same bug as a harmless
  3 cm hitch. **So measure geometry FAR FROM THE ORIGIN**, at the distances the
  assembled run really reaches, or the fixture is the thing that is wrong. And
  `test_ramp_traversal` was green for the whole life of the bug because it
  asserts once at tick 220 -- the twin of the one-frame-sample note above.
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
- **A `Transform3D` IN A `.tscn` IS ROW-MAJOR, AND THE WRONG ONE HAS AN IDENTICAL
  BOUNDING BOX.** The fourth sign error, and the third from those nine numbers —
  observed 2026-08-20 turning the player's nose from a box into a beak. A
  `PrismMesh`'s apex is `+Y`, so it needs a quarter turn about X to aim down `-Z`;
  written column-major (the axis vectors, which is what the *constructor* takes)
  it turned the other way and the beak pointed **into the player**, full width at
  the front and tapering to a point where it met the body. **Every extent
  assertion passed** — the AABB is the same 0.3 x 0.3 x 0.5 at the same corner
  whichever way it spun, so protrusion, height, width and asymmetry were all
  correct about a marker that was backwards. Only a check on the VERTICES could
  see it: full width at the base, narrowing at the tip. **When a shape's identity
  is its taper, a bounding volume cannot test it** — an AABB cannot tell a prism
  from the box it was cut from, and neither can it tell which end is which. And
  the general form: after hand-writing a `Basis`, assert something that is not
  symmetric under the rotation you might have got wrong.
- **A LAYER NOTHING MASKS IS A COLLIDER MADE OF NOTHING, and it passes every
  test that asks whether it EXISTS.** Observed 2026-08-15 building M16's round
  barrier: the wall was put on layer 9 while the player mask is 7, so it was
  created, positioned, replicated and drawn, and players walked straight through
  it. `check(world._front_wall != null)` was green the whole time. **A test that a
  blocker exists is not a test that it blocks** -- walk a body into it under
  power, over several ticks, and assert the position. The mask itself is also
  worth asserting directly (`wall.collision_layer & body.collision_mask != 0`),
  because that names the fault instead of leaving a position assertion to be
  explained. This is the FIFTH bug in this project to be one wrong bit in a mask.
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
  **`tmp/` is the same trap and it fired 2026-08-15**, which is worse than
  `build/` in one specific way: the convention below sends every throwaway file
  there, so it is *by design* full of things that must never ship. Scratch COPIES
  OF TWO REAL SCRIPTS, made for an A/B and deleted ninety seconds later, were
  packed as `res://tmp/ab/*.gdc` — duplicate classes in the shipped game, from
  files that were not meant to survive the afternoon. Same fix as `build/`: the
  env scripts drop a `.gdignore` in, and `exclude_filter` carries `tmp/*` as the
  committed backstop. Caught by reading the `savepack:` list, which is the only
  thing that ever catches this.
- **AN OUT-OF-RANGE FALLBACK THAT PICKS "THE LAST ONE" IS A FEEDBACK LOOP WHEN
  SOMETHING KEEPS EXTENDING THE LIST.** Observed 2026-08-15 from two playtest
  reports that turned out to be one line. `segment_index_of_row` answered "the
  last segment" for any row it could not place, and a player standing BEHIND the
  start of the bridge is exactly that -- so a body off the back end reported as
  being at the very FRONT of everything built. `_extend_run` keeps segments ahead
  of the front, which moved the front, which built more: **199 segments and 4198
  rows -- 8.4 km of geometry -- within two seconds of walking backwards off the
  spawn.** The same wrong answer fed `_bank_checkpoint`, so a wipe returned the
  party thousands of rows up the bridge, past ground nobody had crossed. **A
  clamp is only ever correct at ONE end**; the two ends of a range are two
  different questions and want two different answers. And the second symptom is
  the tell for the general shape: **when a query about progress can be answered
  by something that is not making progress, anything that scales with progress
  becomes a loop.**
- **A BOUNDARY THAT IS A RANGE HAS TWO EDGES, AND `start + 1` IS INSIDE IT.**
  Observed 2026-08-16 from a solo playtest: "it says you lost, but you don't spawn
  in a lobby -- the lobby/non-lobby gets flipped." A gate band is TWO ROWS deep
  (widened 2026-08-15 so a party of four can stand on it), and `_lobby_point`
  returned `rear_row + 1` while calling it "the first row past the strip". It is
  the strip's SECOND ROW. Everything downstream asks `gate_after(row)`, which is
  strictly-greater, so a body one row into a two-row band reads as PAST it: the
  next boundary came back as the one five sections up-bridge, the machine sat in
  LOBBY with its front wall at the far end of the round, and the party played a
  whole section in the lobby state. **When a thing is a band, "just past it" is
  `band_end + 1`** -- and the tell is that the bug appeared the day the band
  stopped being one row, in code that was correct when it was written.
  **The second lesson is bigger: TWO CALLERS OF ONE PLACEMENT FUNCTION WANTED
  OPPOSITE DIRECTIONS.** A straggler at a round END is behind a party that just
  walked INTO a lobby and belongs forwards; a party that LOST is standing in the
  section that beat them and belongs backwards. The first fix walked backwards
  unconditionally, sent stragglers a whole round down the bridge, and the leash
  then dragged them back as ONE STACKED PILE -- the coincident-bodies trap again,
  reached by a route nobody would predict. **Before generalising a placement rule,
  enumerate its callers and ask which way each one means.**
  And note what the instrument said: `wipes` was 0 the whole time, because a solo
  death never reaches `_check_wipe` -- the round machine scores it first and
  `_settle_round_transition` erases `_returning` on the way. A counter that names
  the event is not the same as a counter the event increments.
- **A VALIDATOR THAT MODELS A MOVEMENT THE PLAYER DOES NOT HAVE CERTIFIES BROKEN
  LEVELS.** Observed 2026-08-16. `SegmentValidator` allowed a rise of
  `SOLO_RISE` (1 unit) between any two deck cells, so a one-unit step read as
  walkable. **There is no step-up in this game** -- `move_and_slide` does not
  mantle and nothing implements it -- so measured, a body at full stick into a
  one-unit step stops at y 1.45 against a step top of 1.76 and never gets up. Any
  segment whose only route crossed one VALIDATED AND WAS IMPASSABLE, which is the
  worst failure an oracle can have: it does not report a problem, it certifies a
  broken thing. A rise is now allowed only onto a RAMP (where the budget is a
  slope limit) or a real ascender. **Check what the BODY does before trusting
  what the model says it does** -- and the tell is that the fiction had been
  contradicted in writing for months: playtest_bridge's own header said the
  ladder "is not climbable yet, so today it is a 2 m wall" while the flood
  counted ladders as a way up. `LADDERS_CLIMBABLE` is now a flag rather than a
  comment somebody has to remember.
- **A PER-INSTANCE COLLIDER SIZED FROM COSMETIC DATA MAKES A ROW OF THINGS FULL
  OF HOLES.** Observed 2026-08-16 making worn hats shootable. `HatStyle` sizes
  every hat's collision shape from its style id {D} correct for how a hat SETTLES
  on the deck, and quietly wrong for a stack, because the stack spaces hats a
  fixed `HAT_HEIGHT` apart. Measured on one four-stack: collider heights of 0.233,
  0.101, 0.342 and 0.191, each starting at its own origin, leaving gaps a round
  goes straight through. The symptom is "I shot him in the hat and nothing
  happened", INTERMITTENTLY, depending on which hats the victim was wearing {D}
  and a test with one hat, or with fixed styles, never sees it. **Where things
  tile, the hit shape is a property of the SLOT, not of the thing in it.**
- **A RIGIDBODY3D THAT IS A CHILD OF ANOTHER PHYSICS BODY IS NOT RAYCASTABLE,
  and every property you can print about it looks correct.** Measured 2026-08-16
  making worn hats shootable. A worn hat is a `RigidBody3D` reparented under the
  player. With its shape enabled, its layer set, the query mask `0xFFFFFFFF`, and
  `PhysicsServer3D.body_get_state(TRANSFORM).origin` EQUAL to the node's
  `global_position`, a ray straight through it returned null -- six frames after
  enabling the shape, so not a deferred write either. The identical hat parented
  to the pool root is hit every time, frozen or not. **Do not hang a physics body
  off another physics body and expect queries to see it**; either keep it at the
  root and drive it by global transform, or test it analytically.
- **AND THE CONTROL HAS TO BE ABLE TO SUCCEED.** The first run of that probe
  "showed" a loose hat was unhittable too -- the hat was resting on the deck, the
  ray at its centre height also crossed the deck, and the DECK was returned. One
  more step and the conclusion would have been "hats cannot be shot at all",
  which is the opposite of the truth. **Lift the control clear of everything else
  before believing it**, the same rule as measuring on a fixture with nothing else
  moving in it.
- **A TEST RUN ON THE WRONG OBJECT CANNOT FAIL, HOWEVER MANY SEEDS IT SWEEPS.**
  Observed 2026-08-16 asserting that no hazard sits beside a lift. It passed with
  its own rule DELETED, at 40 seeds and again at 250 {D} because hazards are
  placed by `BridgeGrid` at LOAD, and the test was inspecting the raw output of
  `SegmentGen.section()`, which has no hazards in it at all. Widening the sweep
  made it slower and no more able to fail. **A/B a new assertion before believing
  it**, and when it survives its own rule being removed, suspect the OBJECT before
  the sample size.
  **REPEATED 2026-08-20, WITH THE WRONG OBJECT MIXED INTO THE RIGHT ONE.** A test
  that the generator now varies the bridge's width passed against the pre-M22
  code with the mutation verified applied -- because `SegmentGen.section()`
  returns a MAZE one time in five, and a maze is asymmetric and one cell wide by
  design. The variety it measured was real and had nothing to do with the change.
  Harder to spot than the lift case: the sample was not wholly wrong, it was
  DILUTED, so every number looked plausible. **When one function can return two
  kinds of thing, a claim about one of them has to say so** -- `seg.tags.has("maze")`
  was the whole fix, and the same applies to `piece_rows`, which are authored and
  carry their own silhouette.
- **A REVERT THAT LEAVES THE SMOOTHING IN IS NOT A REVERT.** Same change, same
  day, and it is why the A/B above took two rounds. The first mutation swapped the
  new per-row edge profile back to the old symmetric margin and left the
  `_cone()` call that follows it -- so the mutated profile was still smoothed, and
  the rate-cap assertion could not fail. **A feature that is generate-then-fix is
  TWO pieces of code, and reverting the generator while keeping the fixer measures
  neither.** The tell is an A/B where some assertions flip and one conspicuously
  does not: that one is downstream of something the mutation did not touch.
- **A CONSTANT THAT MEANT TWO THINGS AT ONCE SPLITS INTO TWO THE DAY THEY
  DIFFER, AND EVERY PLACE THAT PICKED THE WRONG ONE IS SILENT.** Observed
  2026-08-20 raising the grid canvas from 15 to 21 with a 15-wide baseline. For
  the whole life of the project `width` was simultaneously the coordinate frame,
  the bridge, the camera's framing, and "all of it" -- so `for x in seg.width`
  read correctly as any of the four. The moment they came apart, four separate
  rules were quietly wrong in four different ways: `_check_gates` demanded gate
  content on cells nobody can stand on, `test_set_pieces` demanded a piece be
  solid across ground the terrain does not have, the camera would have zoomed
  every player out 40% to frame six cells of air, and the entry/exit fixup wrote
  DECK over the profile that had just been carefully computed. **None of them
  errored** -- three failed as assertions about the wrong object and the fourth
  passed. **When a constant is about to stop meaning one thing, grep every use
  and ask which of the two each one meant**; the ones that read `seg.width`
  without thinking are exactly the ones that will be wrong.
  Its companion, and the reason the canvas bump was affordable at all: **a
  symmetric pad is a no-op you can PROVE.** `cell_centre` is
  `(x + 0.5 - width * 0.5) * CELL_SIZE`, so padding every file by 3 columns while
  the width grows by 6 leaves every existing cell at exactly the same world
  coordinate -- old column 0 and new column 3 are both x = -14. That turned "re-
  author thirteen levels" into a mechanical script, and the tests that broke were
  precisely the ones holding a hardcoded COLUMN INDEX rather than a position.
- **A GENERATE-THEN-REPAIR PIPELINE HAS TO BE READ BACKWARDS, because the LAST
  writer wins and it is usually the oldest line.** Same change. The edge profile
  was computed, coned, lift-corrected and re-coned with considerable care -- and
  then a four-line fixup from an earlier milestone stamped DECK across the full
  width of the entry and exit rows, overruling all of it. Measured: 120 open ends
  and 104 rate breaks, a six-cell flare at both ends of every generated section,
  none of it visible in the code that looked like it was in charge. **When a
  property you just computed is not in the output, find every later line that
  writes the same field** -- the culprit was correct when it was written and
  nobody touched it.
- **"SAME ARITHMETIC, ONE PLACE EACH" IS NOT A DESIGN, IT IS A COMMENT HOPING TO
  BE ONE -- AND A TIE IS WHERE THE TWO COPIES COME APART.** Observed 2026-08-21
  from a playtest of M23's watchpost: "it renders the ladder on the right side.
  Approaching it snaps you to the front side." The ladder's face was computed
  twice, once in `BridgeGrid._spawn_ladder` for the rungs and once in
  `PlayerBody._ladder_face` for the body, and the first one carried a comment
  warning that if either changed the other must change with it. **Neither ever
  changed and they disagreed anyway**, because they were never the same
  arithmetic: the art compared grid-LOCAL surface heights and the climb compared
  WORLD ones, on a bridge pitched 4 degrees.
  **IT TOOK A TIE TO SHOW, WHICH IS WHY IT SURVIVED THREE MILESTONES.** Every
  ladder before this sat on a cliff with one clearly-lowest neighbour, and both
  copies agreed however they measured. A free-standing post has THREE neighbours
  level with each other -- measured, east/south/west all at local height 0 -- so
  the tie-break becomes the entire answer, and local iteration order picked east
  while the pitch made south lower by 0.14 m. **When two implementations of one
  fact agree on every case you have, look for the case where the inputs TIE**;
  that is where their tie-breaks, which nobody wrote down, start deciding.
  The fix is the general one: the grid owns the heights, so the grid owns the
  answer, and both callers ask it. And it compares INTEGER heights -- the grid's
  own fact -- rather than a world Y, which is that fact plus presentation.
  **AND ITS TWIN, REPORTED MINUTES LATER: THE CONDITION THAT ENTERS A STATE MUST
  ASK WHAT THE STATE WILL DO.** With the face agreed, "you still snap to the
  ladder side when touching any edge of the block" -- because `_ladder_cell`
  tested only DISTANCE, in any of the eight cells around the body, while
  `_step_climb` pins the body to the ladder's FACE. Brush the far side of a
  free-standing post and you were moved the best part of three metres around it.
  The grab was omnidirectional and the hold was directional, and **the difference
  between an entry condition and the behaviour it enters is a distance the player
  gets teleported.** Same shape as the ladder-face bug one line up: a cliff
  ladder is unreachable from behind by the geometry, so nothing had ever entered
  that state from the wrong side. **When a state SNAPS a body somewhere, its
  entry test has to include "you are already roughly there".**
- **A ONE-DIRECTIONAL VERIFIER CANNOT SEE A DUPLICATE, AND THE SIZE IS THE ONLY
  THING THAT TELLS YOU.** Observed 2026-08-21: a release zip came out **75.9 MB
  where every build that day was 38.3**, with the exe unchanged. Inside were TWO
  copies of everything -- `BridgeToFriendship.exe` and
  `BridgeToFriendship.exe~RF29e46dfa.TMP`, 104 MB each. Windows writes
  `<name>~RF<hex>.TMP` when it replaces a file something else has open (an
  on-access antivirus scan of a 104 MB binary is enough), the export's directory
  wipe had silently failed on the locked exe, and `Compress-Archive` swept the
  backups in beside the real files.
  **The archive check added after the 2026-08-08 packaging bug did not fire, and
  could not.** It walked the build directory asking "is every file in the zip" --
  and the leftovers were real files on disk, so they counted as WANTED. An
  archive can be wrong by containing something nobody asked for, and only the
  other direction sees that. It now reports UNWANTED entries too, unit-checked
  against an archive built to carry one.
  The general form, and it is the third entry on this exact theme: **a check that
  only walks one side of a correspondence passes on every fault that lives on the
  other side.** The tell here was a number nobody was asserting on -- the file
  size -- which is why "a packaging step that reports its own success is not
  evidence; open the artifact" is worth doing even when the gate is green.
- **A CONSERVATIVE BOUND IS A FINE ANSWER TO "CAN IT FIT" AND THE WRONG ANSWER TO
  "WHERE DOES IT GO".** Observed 2026-08-21 from a playtest: "I don't see any
  towers in the middle of the field, all are to one side or the other". Patches
  were placed from `safe` -- the columns solid at EVERY profile the generator can
  produce -- which is exactly right for proving a patch can be placed at all, and
  is FIXED at the worst-case inset while the deck MOVES with the profile. At a 21
  canvas `safe` is columns 7 to 13 forever, so a section cut 6-and-0 has its deck
  at 6..20 and its tower pinned near 9: against the rail, on ground nowhere near
  the middle of anything. M22 had made 38% of rows asymmetric, so it was most of
  them. Fixed by deciding the column AFTER the profile exists, from the
  intersection of the real solid span over the patch's own rows -- placement went
  from three offsets to thirteen, and left/middle/right from [0, 98, 3] to
  [27, 45, 29]. **When a thing is placed against a frame, check that the frame is
  the one the player sees.**
  **AND TWO ROUNDS OF THEORY BOTH LOST TO PRINTING THE MAP.** The first diagnosis
  said towers were central and the report was about something else; the second
  said the fix had made them worse. Both were argued from the same numbers and
  disagreed. Dumping four real sections as ASCII settled it in one run and showed
  a tower flush against a rail that no metric had named. **When two explanations
  of the same measurement contradict each other, stop measuring and LOOK.**
  Its third lesson is about the fix rather than the bug: seeing that flush tower
  nearly bought a rule forcing a column of deck either side -- which would have
  NARROWED the placement range in answer to a report asking for more spread, and
  was redundant anyway because every patch already carries flat columns at its own
  edges. **Check whether the thing you are about to enforce is already paid for**,
  and be slow to correct toward the middle when what was asked for was variety.
- **ADDING A NEW KIND OF THING RE-AIMS EVERY MEASUREMENT THAT DID NOT KNOW THERE
  WAS MORE THAN ONE KIND, AND THE GATE TELLS YOU IN THE VOICE OF THE OLD
  FEATURE.** Observed 2026-08-20, four times in one milestone, which is why it
  gets its own entry rather than another line on the maze note. Introducing a
  PATCH -- a set-piece narrower than the bridge -- broke three unrelated tests,
  and not one of them said "there is a patch here":
  `_piece_at` assumed a piece starts at column 0 (true of every piece that had
  ever existed), so a patch at column 7 matched nothing and the section reported
  **18 cells of stray content** for a correctly stamped turret. A rule that "no
  ladders are generated" was scoped to the whole section when it was only ever
  about the profile LOOP, so an authored ladder inside a piece failed it -- and
  its stated reason ("there is no climb mechanic yet") had been false since the
  day `State.CLIMB` shipped. And the split-plateau sweep counted a three-unit
  tower as a three-unit SPLIT, because a patch is a plateau narrower than the
  bridge and that is exactly what the detector was looking for.
  Every number was true. None was about the feature being measured. **After
  adding a kind, grep the tests for the assumption that there was only one** --
  it reads as `x == 0`, `for x in width`, or any sweep that does not exclude the
  new thing, and it will fail talking about something else entirely.
- **WHERE A GENERATOR VALIDATES AND REROLLS, A BUG DOES NOT PRODUCE BROKEN
  OUTPUT -- IT PRODUCES NO OUTPUT, AND EVERY ASSERTION ABOUT THE OUTPUT PASSES.**
  Observed 2026-08-20 A/B-ing M23's split plateaus. The split's climb has to be
  on the HIGH side; put it on the low side and the high half is marooned deck.
  The expected failure was a counter of bad splits going up. What actually
  happened: `SegmentValidator` refused every such attempt, `section()` rerolled
  it up to 24 times, and the sweep came back with **zero splits in 63 sections**
  -- the feature had silently ceased to exist, and every rule asserted ABOUT
  splits (`ragged_ends`, `uncrossable`) was green over an empty set.
  Two things follow. **A rejection oracle converts "wrong" into "absent",** so
  the assertion that catches a generator bug is usually a COUNT OF THE THING
  HAPPENING AT ALL, not a count of it happening badly. And the corollary killed
  an assertion in the same file: `eq(unclimbable, 0)` could never move, because
  the case it named is filtered one layer down before anything here can see it.
  It is now a printed number, and the claim that bites is `with_split > 0`.
  **CONFIRMED AGAIN AND SHARPENED 2026-08-20 on M23 phase 3**, where three
  separate `eq(x, 0)` assertions turned out to be dead at once. `section()`
  returns only a segment `SegmentValidator` accepted or a flat fallback, so
  **every property the validator checks is true of everything a test of its
  output can ever see** -- "no island", "no marooned deck", "crossable" are all
  walls of green over a filter one layer down. The A/B is what showed it: giving
  a patch the row-owning `continue` leaves a five-wide island in a row of holes,
  and the island counter stayed at 0 while the PRESENCE counter fell to 0.
  **The rule for telling a live assertion from a dead one: does the VALIDATOR
  check this?** If it does, a bug gives an absence and the assertion cannot fire.
  If it does not, a bug gives a bad section and the assertion is worth having --
  which is why `ragged_ends` next door really does fire: a split running into the
  exit row is LEVELLED by the fixup rather than rejected, so the section stays
  crossable and comes out wrong.
- **WHEN A RULE GAINS A NEW AXIS, THE INSTRUMENT THAT WATCHES IT IS STILL ON THE
  OLD ONE.** Observed 2026-08-20 adding parapets along Z as well as across X. The
  test that diffs the old parapet rule against the new one over every authored
  file walked `[DIR_WEST, DIR_EAST]` -- so it was structurally incapable of
  seeing the direction that had just been added, and reported the change as
  clean. It was measuring the half of the rule that had not moved. Extended to
  all four directions it named a real bug in one run. **A report written for the
  old shape of a thing does not fail when the thing changes shape; it just stops
  covering it** -- so when you widen what a rule can DO, widen what the report
  ITERATES before believing the number.
  The bug it found is worth its own line, because the loose version looked
  perfectly reasonable: "is the void beyond this cell open to the side of the
  canvas" seems like a fine definition of an exterior edge, and **a chasm ACROSS
  the bridge satisfies it trivially, by SPANNING the bridge.** So the front lip of
  every full-width gap grew a railing -- 20 of them on `piece_timed_crossing`, 16
  on `piece_crumble_causeway`, the two pieces whose entire subject is a gap -- and
  a gap you may walk off the front of quietly became a corridor you are funnelled
  down. **A geometric predicate that is true for the case you meant is not
  evidence; find the case where it is true for the WRONG reason.**
- **A SOLVER THAT FINDS THE LARGEST PROFILE THAT FITS WILL ALWAYS PICK THE
  STEEPEST SLOPE, AND THAT IS NOT A BUG IN IT.** Observed 2026-08-20, asked to
  make the bridge's width change gradually. The generator rolled flat setback
  BANDS and let a two-pass minimum cone discover the taper between them -- so
  every transition in the game came out at exactly one column per row, the rate
  cap, because the largest profile that fits is the one that tapers as late and
  as hard as it is allowed to. Correct by every assertion and it read as the deck
  SNAPPING. **A cap is not a gradient**; the fix was to state the shape
  (waypoints joined by straight ramps, with a rolled rows-per-column stride)
  instead of deriving it. And the measurement that made it legible was not "is
  any slope illegal" -- none was -- but **what fraction of rows the edge is
  MOVING on**: 17% after, and effectively every transition row before.
- **A CONSTRAINT SATISFIED SOMEWHERE ELSE IS WORTH FINDING BEFORE YOU PAY FOR IT
  TWICE.** From the same change. Lift rows were forced to full canvas width so a
  rider always has ground to step onto -- which meant a rate-1 flare around every
  lift, in a third of all sections, fighting the gradient hardest at the one place
  the player is standing still looking at it. But `safe` already keeps every lift
  in the middle columns, and the deepest either edge can ever be cut still leaves
  those columns AND their neighbours solid: the property was guaranteed by
  construction, at every profile the generator can produce. **Two lines of
  arithmetic retired a special case that had been distorting the whole system** --
  and the tell was a rule phrased about a ROW when what it protected was a CELL.
- **A SOFT CONSTRAINT SOLVER WILL QUIETLY EAT A HARD ONE.** The third bug in that
  same profile. `_cone` takes a MINIMUM, so it can only ever widen the deck --
  which means a widening event two rows from the end reaches back and drags a
  PINNED end open with it, and forcing the end back afterwards leaves exactly the
  one-row cliff the cone existed to prevent. **A pin that runs before a smoother
  is not a pin, it is a suggestion.** Fixed by re-pinning after and clamping
  outward from the pins. And the diagnostic is the transferable part: printing
  WHERE the 19 surviving breaks were (`lift?false end?true`, every one) named the
  cause in a single run, after two rounds of plausible guesses about lifts.
- **AN ARITHMETIC IMPOSSIBILITY BEATS A TUNED THRESHOLD.** From the same test,
  and it is the reason the second A/B was decisive where a count would have been
  argued about. "At least five distinct widths" is a number somebody picked; **"the
  deck is sometimes an EVEN number of cells wide" is a proof**, because a single
  symmetric margin at an odd canvas can only ever produce `15 - 2m` and every one
  of those is odd. The reverted build printed `[9, 11, 13, 15]` -- exactly the four
  values predicted, and no other -- against `[11, 12, 13, 14, 15]` for the new one.
  **Where a change makes something newly POSSIBLE, look for a property the old
  code could not produce at all**, and assert that instead of a magnitude.
- **A HIT TEST THAT DISAGREES WITH THE ART IS A HAZARD PLAYERS LEARN BY DYING TO,
  and a test can lock the disagreement in.** Observed 2026-08-16. Spikes are drawn
  as nine cones standing straight up out of ONE cell; the hit test measured from
  that cell's four NEIGHBOURS, so the safe spot was the middle of the spikes and
  the danger was a ring from 0.7 m to 3.3 m out. It was deliberate, and
  `test_cover_and_spikes` asserted it in as many words — "standing ON the block
  never hurt: it is deck, and being BESIDE it is the hazard" — which is why it
  survived. It reached playtest twice: once as "the elevator hurts you" (a lift
  two cells away put the rider inside the invisible ring) and once as "visually
  that is not at all what we show". **When a hazard is reported in the wrong
  place, sample its damage as a MAP and compare it against the mesh**; and when a
  test states a rule the art contradicts, the test is the thing that is wrong.
- **"IS THIS CELL SOLID" IS A QUESTION ABOUT THE DECK, AND A PILLAR STANDING ON
  THAT DECK IS A DIFFERENT QUESTION.** Observed 2026-08-21 giving skirmishers a
  patrol. The grid is the right oracle for "is there floor that way" -- it is
  cheaper than a raycast and it is the same record the level was validated
  against -- but it answers about terrain, and a body steering at a solid cell
  with an obstacle standing on it is held there by `move_and_slide` forever: the
  walk never arrives, so no new destination is ever chosen. Measured: a gunner
  leaned on the pillar at (7,8) of `test_flat` for the whole rest of the phase.
  **Any "walk to a point" needs a way to give up**, and the first version of that
  was a TIME BUDGET -- "twice as long as the walk should take", which is twelve
  seconds at the edge of a patrol radius, correct by the formula and far too slack
  to look like anything but a broken enemy. A progress check (did the distance
  close at all in half a second) is the same fact noticed twenty times sooner.
- **A CANDIDATE LIST IS A SNAPSHOT, AND A RULE ABOUT ITS OWN KIND IS STALE THE
  MOMENT THE FIRST ONE LANDS.** Observed 2026-08-21 adding graves to the dressing
  pass. `_candidates` is computed once per kind and then walked, so every rule in
  `_wants` is answered against a grid with none of that kind on it. Harmless for
  everything built in the four milestones before it -- no hazard cared how far it
  was from another of itself, and the one-line "is this cell still empty" guard
  inside the loop covered the whole of what went stale. A grave cares: it is the
  only content that occupies its NEIGHBOURS, so two placed one cell apart is two
  packs rising into each other. **When you add the first thing that must not be
  adjacent to ITSELF, the precomputed list is no longer sufficient** -- re-ask at
  placement time, and re-ask for that kind alone rather than re-running the whole
  predicate, which would quietly retune every other kind's density inside a fix
  for this one.
- **A STRIDE THAT IS NOT COPRIME WITH THE LIST WALKS A SHORT CYCLE, and the
  symptom is a budget that is silently a ceiling.** Same day, same file, and it
  had been there since M17. `dress` spreads its picks by walking the candidate
  list at a seeded stride; where `gcd(stride, n) > 1` it visits `n/gcd` cells and
  revisits them. Measured over 320 generated sections: **68 of 117 budget
  shortfalls**, worst case 44 cells whose walk reached 2. The tell was a section
  reporting **115 candidate cells and placing zero**, which is not a shape a
  "the section was full" explanation can take. `theme_for` twenty lines above does
  the coprime walk correctly and says why in a comment; the loop below it was
  written as though a stride were just a number. **Any modular walk meant to cover
  a list needs gcd == 1, and the cheap tell is candidates >> placed.**
- **AND ASSERTING THE HELPER IS NOT ASSERTING THE PASS.** The first test for that
  stride fix checked `_coprime_stride` directly, reasoning that a placement count
  has a second explanation (the section might be genuinely full). A/B killed it:
  disconnecting the helper from the placement loop -- putting the bug back exactly
  -- left the test GREEN, because the function it asked was still there and still
  correct. The right move is to REMOVE the second explanation rather than stop
  asking the question: run on a roomy fixture, and only assert budgets for kinds
  with three times the candidates they need. Twin of the score-screen note below.
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
  **Repeated 2026-08-15 in the other direction, which is worth knowing about:** a
  test for Steam AVATARS asserted our own id was 0 and that every portrait was
  hidden. Both are true on CI and false beside a running Steam client, so it went
  GREEN in the gate and failed on the dev box. The fix is the same either way --
  assert a RELATIONSHIP, never a value. `own.steam_id == steam_id_of_self()` and
  `face.visible == (face.texture != null)` hold on every machine; "the id is 0"
  holds on half of them.
- **Headless builds the whole Control tree; it just does not draw it.** So a HUD
  or menu IS testable — node construction, `_ready`, `_process` and property
  writes all really run. That matters because GDScript resolves properties at
  runtime: `ProgressBar.tint_progress` is Godot 3 and raises on the first frame
  and nowhere earlier. If nothing in the gate ever instantiates a UI script, it
  ships having never been executed once (see `test_hud_view`).
- **`node.name = "X"` BEFORE `add_child` IS DISCARDED WHEN A SIBLING ALREADY HAS
  THAT NAME**, and what you get is not `X2` but a generated `@AudioStreamPlayer3D@342`.
  Observed 2026-08-22 spawning several gunshots in one frame: a test counting
  nodes by name found ONE of the two it had just made, and the tree was full of
  anonymous nodes. Set the name AFTER the add and the uniquifier does the
  sensible thing. Every self-spawning effect in `scripts/ui/` had this — the two
  new ones broke, `blast_effect` never did only because two blasts in one frame
  are rare, which is the shape of a bug that waits.
- **A WAV IMPORTS WITH LOOPING OFF, and `edit/loop_mode=1` in the `.import` does
  not necessarily reach the resource.** Observed 2026-08-22 wiring 50 s of hold
  music: set in the `.import`, cache cleared, re-imported, and `loop_mode` still
  read `LOOP_DISABLED` (the file is QOA-compressed, `compress/mode=2`). A track
  wired up perfectly then plays once and leaves the lobby silent — nothing in the
  code is wrong, the RESOURCE is. Set `loop_mode` in the script instead, so the
  fact lives where the thing depending on it can be read, and note that
  `loop_end` defaults to 0: `LOOP_FORWARD` over that is a loop of NOTHING rather
  than a loop of everything. **Assert the loop, not the wiring** — every
  behavioural claim about the music passed while it was set to play once.
- **A CONTROL PARENTED TO A CanvasLayer IS NOT LAID OUT BY ANYTHING, and its
  anchors are four correct numbers about a rect of zero.** Observed 2026-08-17,
  reported from play as "the score screen is top left". `PRESET_FULL_RECT` on a
  Control whose parent is a CanvasLayer leaves it 0x0 at the origin -- there is no
  parent CONTROL to take an area from -- so everything anchored inside it
  collapses too, and a `PanelContainer` with nothing to fill falls back to its
  content's minimum size in the corner. Size such a Control from
  `get_viewport_rect()` and reconnect on `size_changed`; anchors then work
  normally for everything nested INSIDE it.
  **And the reason it shipped is the general lesson: THE TEST ASSERTED THE
  ANCHORS, WHICH WERE RIGHT THE WHOLE TIME.** Asserting the input to a layout is
  not asserting the layout -- measure `size` and `position`, which is what the
  player is looking at. The same shape as the collision-mask notes: a property
  that is set correctly and has no effect.

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
- **A FRAME-GATED TEST WHOSE `finish()` SITS OUTSIDE ITS OWN GATE DOES NOT FAIL,
  IT PASSES EARLY -- and every assertion above it becomes dead code that nothing
  reports.** Observed 2026-08-22 in `test_shove_up_ramp`, the file written to be
  the POSITIVE half of the co-op gate. `finish()` and one assertion were indented
  one tab out of the `if frame == 240:` block that held the other four, so the
  test ended at frame 21 -- one frame after the shove was applied -- and four of
  its six assertion sites had NEVER RUN in the file's whole life. There is no
  error, no missing marker and no slow run to notice: it is a green test in 0.9 s
  that measured a body 0.3 s into a 4 s manoeuvre. Re-indented, it passes (4.84 m
  gained of the 1.41 m needed), so the VERB was right the whole time and only the
  gate on it was missing. Same day, same shape from the other direction:
  `test_blast_effect`'s stated central claim ("THE SIZE IS THE CLAIM") sat behind
  `if flash != null` on a frame chosen two frames after `queue_free()` takes the
  flash away, so a flash sized to anything at all passed. **An `if` around an
  assertion is a silent skip, and a chosen frame is a guess about somebody else's
  clock** -- sample every tick and assert the peak.
- **THE CHEAPEST WAY TO FIND ALL OF THAT: MAKE THE ASSERTION HELPERS LOG WHERE
  THEY WERE CALLED FROM.** `get_stack()` works in this engine build, so a
  four-line patch to `test_case.gd` (`print(st[2].source, st[2].line)` from
  `check`/`eq`/`near`), one whole-suite run, and a diff against every assertion
  call site parsed out of `scripts/tests/*.gd` answers "which assertions actually
  executed" as a fact about a RUN rather than a reading of the code. It found
  three real defects in one pass over 1,441 assertion sites, and it is worth
  re-running after any milestone that moves test code around. Restore the base
  class from a COPY afterwards, never with `git checkout --` (see below).
  The counting rule that keeps it honest: a `check(false, ...)` inside a failure
  branch is SUPPOSED never to run -- 30 of the 36 unexecuted sites were those.
  Count them separately or the signal drowns.

- **A TRANSPARENT MATERIAL DOES NOT WRITE DEPTH, so an object made of MANY PARTS
  paints over itself.** Observed 2026-08-28 building the death fragments. A
  corpse is 32 meshes assembled into the shape of the body that died; the
  material carries `TRANSPARENCY_ALPHA` because the pile fades at the end of its
  life, and at full opacity that is still the ALPHA PASS -- which sorts by each
  object's ORIGIN and does not write depth. So the pieces painted in origin
  order rather than depth order, and an intact corpse rendered **with a quarter
  of itself missing and the inside of its own far wall showing through**. The
  fragments were in exactly the right places the whole time.
  `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` lays depth down first and fixes it, at one
  extra pass. This is the THIRD bug in this project from that render pass -- see
  the status bar in `player.tscn`, which went solid black when its fill slid
  behind its own backing -- and the general form is: **a fade you have not
  started yet still costs you the pass**, so any multi-part object with a
  transparent material is mis-sorted from the moment it exists.
- **GODOT WINDS A FRONT FACE CLOCKWISE, so an outward normal is the NEGATION of
  the right-hand-rule cross product -- and a surface wound the wrong way INSIDE
  AN ASSEMBLED SOLID is invisible until something takes the solid apart.**
  Observed 2026-08-29 in hand-built fragment meshes: of the six face types on a
  fragment, the two radial end faces were wound the other way from the other
  four. Back-face culling removed them, so every piece was a HOLLOW SHELL you
  could see straight through -- and measured, each mesh enclosed **14% of the
  volume of the cell it was cut from**. It survived a whole round of screenshots
  because an intact corpse hides every inward-facing surface inside itself; it
  showed only once a pile was scattered and the insides came into view. **When
  you hand-author a mesh, the assembled shape is not evidence about the pieces.**
  Two method notes came out of the same fix, and they are the transferable part.
  **THE ENGINE WINDING CONVENTION IS CHEAPER TO MEASURE THAN TO REMEMBER:** the
  first version of the test assumed the right-hand rule, reported all 32 pieces
  of all four characters inside-out, and was WRONG -- the renders were lit
  correctly, which is not something an inside-out mesh does. Reading the
  convention off a `SphereMesh` (whose outward normal at a face is unambiguously
  its own centroid) settles it in ten lines, on this engine build, with nobody
  having to recall which way Godot goes. Flipping the sign until the test went
  green would have been tuning the instrument to the reading.
  And **THE DIVERGENCE THEOREM IS THE ASSERTION TO REACH FOR:** for a closed
  surface, `(1/3) * sum of area * (centroid . normal)` is the enclosed volume, so
  ONE number catches a missing face, an inconsistent winding and an inward
  winding at once. Computed from the STORED normals it is convention-free -- it
  measures the vectors the renderer actually consumes -- and compared against a
  volume derived from the SOURCE geometry it is not the mesh agreeing with
  itself. On a shape whose only inscription is angular it even has a closed form
  to hit: a regular n-gon is `(n / 2pi) * sin(2pi / n)` of its circle, which is
  0.99359 at 32 and is an arithmetic prediction rather than a picked threshold.
- **AND ITS COMPANION DEAD ASSERTION: NEVER CHECK generate_normals() AGAINST THE
  WINDING IT WAS COMPUTED FROM.** The same test carried "the stored normal agrees
  in sign with the face winding", which reported 0 failures throughout and could
  not have reported anything else -- the normals are DERIVED from the winding, so
  the sign is true by construction. Asking instead that they be PARALLEL (within
  0.01) makes it live: that is a claim about FLAT SHADING, and it would fail the
  day a smooth group stopped taking and corpses started rendering as balloons.
  **An assertion comparing two things one of which is computed from the other is
  asking whether arithmetic works.**
- **A POLYGON INSCRIBED IN A CIRCLE SITS INSIDE IT BY AN AMOUNT THAT DEPENDS ON
  ITS SEGMENT COUNT, so two pieces of one curved surface tessellated
  INDEPENDENTLY do not meet.** Same change, same day. Each fragment chose its
  angular segment count from its OWN arc length in metres -- reasonable in
  isolation, and it meant a wide piece and a narrow piece spanning the same
  surface inset their chords differently. The intact rusher came out with
  horizontal LEDGES stepping down its cone, and the pile stopped being the body
  it replaced. Fixed by sampling every piece on ONE GLOBAL angular grid, which
  works because every split is a midpoint and every boundary is therefore a
  multiple of TAU/2^k. **When you cut a curved surface into pieces, the
  tessellation is a property of the SURFACE, not of the piece** -- the same shape
  as the note above about a hit box belonging to the SLOT rather than to the
  thing in it. And note what could not see it: the tiling was exact and every
  assertion in `test_fragment_shape` passed, because the fault was entirely in
  how the exact cells were DRAWN. **A headless gate cannot see a rendering bug at
  all**, which is what the shot manifests are for.

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
- **"THE LAST FIELD" IS NOT "THE FIELD I MEAN", and a tolerant-tail test written
  relatively breaks the day somebody appends another one.** Observed 2026-08-23.
  Every new field on `capture_state()` comes with a test that truncates the blob
  and checks the old-blob path, and `test_call_for_help` wrote that as
  `old.resize(blob.size() - 1)` — correct while `call_timer` was last, and
  silently a test of the NEXT field the moment `self_revive_seed` was appended.
  It then failed claiming the tolerant read was broken, in a file that had
  nothing to do with the change. **Truncate to a NAMED length**, and note that
  the gate catching this is the system working: every tail-field test in the tree
  is one append away from the same mistake, so the fix is the convention rather
  than the one file.
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

- **A CEILING IS NOT A BUDGET, AND MEASURING ONE DOES NOT LICENSE A CONCLUSION
  ABOUT THE OTHER.** Observed 2026-08-15 answering "how far can you walk in five
  minutes": the probe correctly measured 5.88 m/s on clear deck, correctly
  reported that the demo level is ten seconds of walking, and then concluded that
  sections must be twenty-nine times longer or the target was wrong. A playtest
  said the same level takes five minutes to actually play. Both numbers were
  right, and reconciling them the first time produced a THIRD wrong answer,
  because "the demo level" is not a level: solo builds an ENDLESS assembled run
  and `playtest_bridge` is merely its first segment, so the five-minute report
  covered many segments and was never about the 60 m at all. **Check what the
  thing you are comparing against actually IS before doing arithmetic on it** —
  the units were fine, the object was wrong.
  **The measurement was also of an unobstructed straight line, and no metre of
  this game is one.** When a probe measures an idealised case, the honest report
  is the ratio it establishes, never a recommendation about the real one — and
  where a human has played the thing, THEIR number is the evidence and the probe
  is the proxy. Say which is which.
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
- **VERIFY THAT THE A/B MUTATION APPLIED, NOT JUST THAT THE TEST STILL PASSED.**
  Observed 2026-08-17 twice in one change. A `sed` anchored to `^			and
  dash_charges > 0:$` matched nothing, because a `\`-continuation had been written
  as one long line -- so the "reverted" build was the SHIPPED build, and the green
  run read as "the test does not catch this" when nothing had been reverted.
  **Print the mutation, or assert the string is gone, before believing the result.**
  The second one was real and worse: with the gate genuinely deleted the test STILL
  passed, because the dash covers 5.6 m and the fixture is 28 m, so the body ran
  off the end after three dashes and caught a ledge -- and three is also the charge
  limit. The right number for entirely the wrong reason. **Run both builds side by
  side and print the number**; identical output is the tell, and it is the only
  thing that separates "the rule works" from "the rig caps it anyway".

- **AN UNRELIABLE SNAPSHOT LARGER THAN THE MTU IS MOSTLY NOT DELIVERED, AND THE
  ONLY SYMPTOM IS THAT NOTHING ARRIVES.** Measured 2026-08-29 while writing
  `test_bus_replication`. With a real assembled grid the host's per-tick snapshot
  is ~1.0 KB on a quiet tick and **4.5 KB on a keyframe** -- and a client
  consumed **5 of 147** of them. The same test against `gym.tscn` (no grid)
  consumed 15 of 15. Nothing errors, `rpc()` returns success, and every counter
  on the SEND side reads perfectly: "attempted is not delivered", one layer
  lower than usual.
  **The consequence for design is the part worth keeping: EXISTENCE MUST NOT
  RIDE THE UNRELIABLE CHANNEL.** A delta carries an id list plus only the
  entries that CHANGED, so the one packet that first mentions a new object is
  the only chance to learn it exists -- miss it and the id list goes on naming
  something the client cannot build until the next keyframe, which is the packet
  least likely to arrive. A bullet survives this because it lives about as long
  as the gap; a bus does not, and the first version of bus replication left a
  client standing on nothing permanently. Hats and specials already had it
  right (`_hats_released`, `_special_dropped`, `_special_destroyed` are all
  reliable): **decisions go reliably, motion rides the snapshot.**
  And the fix that looked obvious is a FEEDBACK LOOP: having a client ask for a
  keyframe when it sees an id it cannot resolve makes the host send the 4.5 KB
  packet -- the one that does not arrive -- every few ticks, forever. It was
  written, measured, and removed.
- **A NET TEST THAT SAMPLES A CHOSEN FRAME IS A COIN FLIP ON THE ABOVE.** Same
  day, three separate assertions in one file. A six-tick window for "did the
  client correct" failed two runs in three against a correct build, because a
  correction can only be counted on a tick the client actually receives a
  snapshot for its own player. **Poll with a deadline** -- and the twin, from
  the same file: comparing two MOVING objects across a lossy link measures the
  link, not the agreement. Stop the thing first; a stopped bus has one right
  answer and both ends reach it (measured 0.00 m apart, against a 2 m tolerance
  that was still flaky while it was driving).
  A third in the same file was not about the network at all: `_reconcile` only
  counts a correction in a state the client PREDICTS, so a probe that shoves a
  body still falling from its spawn reports zero about a working build. **Wait
  for the state your instrument needs**, the same rule as isolating a stochastic
  mechanism before asserting on it.

- **A CLIENT THAT COUNTS ITS OWN TICKS DESYNCS EXACTLY THE THINGS THAT ARE PURE
  FUNCTIONS OF THE TICK, AND NOTHING ELSE.** Observed 2026-08-18 from a
  multiplayer playtest: "stuck elevator, one player saw elevator offset". `tick`
  started at zero on every machine and was never synced -- the host had been
  sending it on every snapshot since snapshots existed, in a parameter named
  `server_tick`, and the client discarded it. **It is invisible for almost
  everything, which is why it survived for milestones:** bodies, bullets, hats and
  specials are all TOLD where they are, so a wrong clock costs them nothing. It is
  fatal only where something is DERIVED from the tick to avoid replicating it --
  an elevator ("there is nothing to agree about beyond the tick itself") and the
  spike lift. Measured: the same platform at 2.92 m on one machine and 4.00 m on
  the other. **When you decide a thing is cheap to derive rather than send, the
  input to that derivation has become replicated state** -- and it is worth
  checking that it actually is.
  Its twin, from writing the test: the elevator cycle is 500 ticks, so a control
  that compares tick 0 against tick **5000** compares the same phase and passes
  while measuring nothing. A round number is the likeliest one to be a multiple of
  the period you are testing.

- **A LOOKUP TABLE WHOSE VALUES REPEAT, WALKED BY KEY AND WRITTEN THROUGH THE
  VALUE, IS DECIDED BY WHICHEVER KEY COMES LAST.** Observed 2026-08-18 adding
  three guns. `SHAPE_NODES` maps a special's kind to the mesh it shows, and
  `apply_kind_look` looped the kinds setting `node.visible = (shape_kind == kind)`
  -- correct for years while every kind had its own mesh, and silently wrong the
  moment four kinds shared `"Body"`: each pass wrote that node, so the LAST entry
  in the dictionary decided visibility for all four. Three of the four guns
  shipped as a floating barrel. **The tell in the report was the colour** -- "the
  machine gun comes out with a grey body" -- because grey is the HEAVY's gunmetal,
  and the heavy is last in the dictionary. Deduplicate on the value and ask "is
  this the mesh MY kind uses" rather than "am I the kind whose turn this is".
  And the reason it shipped: every test on those weapons asked what they DO --
  ammo, spread, damage, rate, glyph -- and none asked whether you can see them. **A
  weapon that is mechanically perfect and invisible passes a mechanics suite.**

- **A COUNTER ONLY EVER ASSERTED *ABSENT* IS A COUNTER NOBODY HAS CHECKED.**
  Observed 2026-08-17 from a playtest: "enemy damage and kills were both zero when
  they shouldn't have been". They were unreachable code. `_deliver` measured damage
  as health lost and **no enemy in this game has a `health` field** -- a rusher and
  a gunner are killed outright by a bullet, so `"health" in target` was false and
  an early return fired before either bump. `hits` worked only because it sits
  above that return. Every assertion in the test file about those two stats was
  that they equal ZERO -- zero for a friendly hit, zero for scenery -- so two
  counters that could never fire satisfied all of them, and the suite was green.
  **For every counter, assert one case where it MUST be non-zero**; a wall of
  `eq(x, 0)` is a wall of claims a dead variable passes. Its twin: measure a thing
  by the model it actually has (`is_spent()`) rather than by the one you assumed
  it had, and take the sample BEFORE the call that destroys it.

- **A VALUE THAT IS DESTROYED WHEN IT REACHES ITS TERMINAL STATE IS NEVER
  OBSERVED IN IT.** Observed 2026-08-16 measuring legs: a special is destroyed on
  the tick its ammo hits zero, so a test looping "until ammo == 0" never sees
  zero and runs to its frame cap, then reports the last count it did see (1)
  alongside four launches -- which reads as a launch that failed to bill. Watch
  for the OBJECT going away, not for the number bottoming out. Its twin, from the
  same run: a flag refreshed at the top of a world tick and invalidated further
  down it is STALE FOR ONE TICK, so an assertion fired on the tick of the change
  fails against correct code.
- **A TEST THAT HAND-BUILDS ITS OWN INPUT HAS NOT TESTED THE CALLER, AND THE
  CALLER IS USUALLY WHERE THE BUG IS.** Observed 2026-08-16 from a playtest report
  that the shield "doesn't block shots very well": it blocked none, ever, and
  `test_shield` was green the whole time because it constructed its own `Hit` with
  a source six metres away -- what a bullet OUGHT to look like. The real
  construction passed the round's IMPACT POINT as `hit.from`, which is the surface
  of the body it just hit, so every round arrived from 40 cm away: inside
  `SHIELD_MIN_BLOCK_DISTANCE`, unblockable, at every angle. The shield's own
  arithmetic was correct and correctly tested. **Where a field means "where did
  this come from", test it from something that really came from somewhere.**
- **TWO FIXES THAT A TEST CANNOT TELL APART ARE ONE FIX AND ONE GUESS.** Same day:
  the shield needed an honest origin AND the proximity rule scoped to blasts, and
  reverting EITHER left the new test green, because either alone saves a square-on
  shot. It took a case per half -- a grazing hit for the origin, a 0.9 m shot for
  the proximity rule -- before the A/B could fail twice. **A/B each half
  separately**; a pair reverted together only proves the pair.
- **A PLAYTEST REPORT NAMES WHAT THE PLAYER WAS DOING, NOT WHAT HIT THEM — and
  that is a correct report, not a vague one.** Observed 2026-08-16: "every time
  you stand on the elevator, it hurts you when it moves." The elevator never
  touched them. A SPIKE BLOCK two cells away was hurting anyone inside a 3.3 m
  ring it drew nothing to advertise, so the damage arrived exactly when the
  platform carried them into it, every time. Three probe rounds went into the
  platform before anything scanned what was AROUND it — and the first thing the
  scan found, a skirmisher, was a real bug and the wrong answer, which cost
  another round. **When a report blames a mechanism, ask what else is in range
  while that mechanism has the player, and keep asking after the first plausible
  culprit.** Be slow to reject the reporter: their correlation was perfect and
  their attribution was the only one available from inside the game. The general
  form: a hazard aimed at somebody who cannot answer it, or one whose reach is
  invisible, reads as the TERRAIN being the hazard.
- **AN A/B THAT GOES RED IS NOT AN A/B THAT COVERS, AND THE FAILURE LIST IS THE
  COVERAGE REPORT.** Observed 2026-08-28. `test_fragment_shape` asserts its
  central claim -- that every piece of a cut-up body is exactly the same size --
  for four characters, and reverting the equal-area split to the naive midpoint
  turned it red. Green after, red before: the A/B passed. But **only ONE of the
  four kinds actually failed.** At the shipped piece count a cylinder or a capsule
  never takes the radial axis at all (its radial thickness is the shortest of the
  three sides and the subdivision runs out of pieces before it becomes the
  longest), so three of the four were asserting an equality that no radial cut had
  contributed to. One tapered body was holding the entire line. Fixed by running
  each profile at a deeper count as well and ASSERTING THAT ALL THREE AXES WERE
  ACTUALLY CUT, rather than assuming it. **Read WHICH assertions the mutation
  broke, not just how many** -- an A/B that fails in one of the places it should
  fail in four is a test with a quarter of the coverage it appears to have.
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
- **"IT SHOOTS YOU" IS A COIN FLIP AT THIS GAME'S SPREAD, so isolate the spread
  before asserting damage.** Observed 2026-08-21. `MG_SPREAD_DEG` is 10, which at
  a skirmisher's own 12 m band is a cone **4.2 m wide against a body 0.8 m wide**:
  fewer than one shot in five lands, so "an awake gunner hurts you" measured over
  three shots is a 45% assertion. It failed first run, and the round that missed
  was **2 m wide of a stationary player** -- which reads as a gunner that never
  fired, and sent a round of diagnosis into the alertness code that had just been
  written. `DebugSettings.set_value("mg_spread_deg", 0.0)`, the same isolation as
  `turret_arc_deg` in `test_gunners`. The general form: **when a claim is "X
  happens", check whether the mechanism that delivers X is stochastic**, and take
  the randomness out rather than widening the window until it usually passes.
  **AND `test_gunners` HAD BEEN WINNING THAT COIN FLIP FOR MONTHS.** Two of its
  phases -- "out of cover it does hurt you" and "inside the arc it gets hit" --
  are the same claim over four shots, and both went red the day an unrelated edit
  in an EARLIER phase changed how many `randf()` calls came before them. The
  global seed makes a run repeatable; it does not make an assertion sound. **A
  seeded suite hides a probabilistic assertion until something upstream shifts the
  stream**, and what surfaces then looks like a regression in whatever you just
  touched.
- **AN ENEMY THAT STOPS ITSELF AT A PREFERRED DISTANCE CANNOT BE TESTED AGAINST
  ANYTHING FURTHER AWAY THAN THAT.** Observed 2026-08-21 writing "a skirmisher
  does not close across a hole". The fixture put the two 22 m apart down the
  length of `test_flat` with the chasm between them -- and a skirmisher closes
  only until it is inside its band, so it walks `start - 17` metres and parks,
  **5 m short of a hole 10 m away**. The phase passed with the rule reverted.
  Fixed by using the axis with room in it: the same fixture is 24 m long and 60 m
  WIDE. **Before writing a "walks into X" test, compute how far the body will
  actually walk** -- for anything with a standoff distance that is a subtraction,
  not the distance between the two markers you placed.
- **DOWNING THE SOLO PLAYER TO TAKE A TARGET AWAY HAS A FUSE ON IT.** Same day. A
  party entirely in `_returning` is a wipe, and `_restart_at_checkpoint` frees
  every gunner, rusher, ball, hat and special in the world -- so a phase that
  downs the player and then measures an enemy for fifteen seconds is measuring an
  enemy that gets deleted partway through, which presents as "the body under test
  fell off the bridge". Worse, `_returning` SURVIVES a phase's own cleanup, so the
  wipe can land on the FIRST tick of the next phase and delete something the
  previous phase never touched. Clear `world._returning` in the per-phase reset,
  and for a long quiet window remove the player from `world.players` instead --
  which has no fuse and also makes `_trailing_edge_z()` infinite, taking the leash
  out of the picture as well.
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
  `test_dash_prediction` 28784, `test_contact_prediction` 28785,
  `test_character_replication` 28786, `test_zombie_replication` 28787,
  `test_net_telemetry` 28788, `test_bus_replication` 28789. (28781 was held
  for M8.5's hat replication test and is now `test_run_session`.) Pick the next free one and add it
  here.
- **A sim or long-running harness needs an UNCONDITIONAL heartbeat,** or you
  cannot tell hung from slow. Print a plain `frame N / TOTAL` line on a path no
  game state can gate. *(inherited — diagnosing its absence cost hours.)*
- **A CONSTANT CAN BE SILENTLY GUARANTEEING A FIXTURE'S ASSUMPTION, and the test
  that depended on it never said so.** Observed 2026-08-23 making a worn hat's
  slot its own drawn height (it had been a flat `HAT_HEIGHT` while the meshes are
  drawn 0.10 to 0.55, so a stacked hat floated up to 0.226 m above the one below
  or sank 0.183 m into it -- reported from the character screen, which is the one
  place a stack is seen side-on). `test_tall_hat` sweeps a tower for gaps and
  **rebuilds the stack for every sample**, firing at offsets measured once on the
  first one. That is only sound if a rebuilt tower is geometrically identical, and
  it was -- for free, because the styles were ROLLED and the constant slot made
  the roll irrelevant. The moment a slot varied, every sample got a different
  tower, offsets from the first landed above the top of a later shorter one, and
  the test reported three GAPS in a tower whose own diagnostics showed it tiling
  with no seam at all. **The tell was the SHAPE of the failure: the misses were
  the top samples and they were NOT CONTIGUOUS.** A hole in a column is in one
  place; this moved. Fixed by pinning the styles, which is the assumption written
  down. And its twin, in two other files: a spacing assertion written as
  `near(gap, HAT_HEIGHT)` is a claim about the CATALOGUE, not about the stacking
  code it exists to watch -- `near(gap, worn[0].slot_height())` says the
  load-bearing thing and holds either side of the change.
