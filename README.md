# Bridge to Friendship

A 3D multiplayer game in Godot 4.4.1, shipping on Steam.

Right now this is the skeleton: a 3D world with a ground plane, a capsule
avatar you can walk and jump, a networking layer with two interchangeable
transports (Steam for release, ENet for development and tests), a five-test
gate, and Windows/Linux build scripts. The game itself is not designed yet --
see `implementation_plans/m0_project_skeleton.md` for what M0 covers and what
M1 is waiting on.

## Requirements

- **Windows:** PowerShell, plus `Godot_v4.4.1-stable_win64.exe` and
  `Godot_v4.4.1-stable_win64_console.exe` at the project root.
- **Linux:** bash, plus `Godot_v4.4.1-stable_linux.x86_64` at the project root.

The engine binaries are *not* committed (`.gitignore` excludes `*.exe` and
`Godot_v*_linux.x86_64` — they are ~130 MB each). Download 4.4.1-stable from
[godot-builds](https://github.com/godotengine/godot-builds/releases/tag/4.4.1-stable)
and drop them at the root:

```bash
curl -LO https://github.com/godotengine/godot-builds/releases/download/4.4.1-stable/Godot_v4.4.1-stable_linux.x86_64.zip
unzip Godot_v4.4.1-stable_linux.x86_64.zip && chmod +x Godot_v4.4.1-stable_linux.x86_64 && rm Godot_v4.4.1-stable_linux.x86_64.zip
```

Both platforms can build the game; Linux can additionally cross-build the
Windows release (no wine — Godot appends the project `.pck` to a prebuilt
Windows template, and GodotSteam ships binaries for every platform).

## Building

```powershell
.\build.ps1
```

```bash
./build.sh                  # both targets
./build.sh --target linux   # or: --target windows
```

Either script runs the full test suite first and aborts on any failure
(`-Force` / `--force` overrides; `-SkipTests` / `--skip-tests` skips the gate
entirely and produces an unverified build). It downloads the ~1.2 GB export
templates if they are missing, then exports and packages:

| target | binary | archive |
|---|---|---|
| Windows | `build/windows/BridgeToFriendship.exe` | `build/BridgeToFriendship_Windows_v<version>.zip` |
| Linux | `build/linux/BridgeToFriendship.x86_64` | `build/BridgeToFriendship_Linux_v<version>.tar.gz` |

The Linux build is a `.tar.gz` rather than a `.zip` because zip does not
preserve the executable bit — a zipped Linux build extracts non-executable and
will not launch.

`export_presets.cfg` is committed on purpose. The preset names
(`Windows Desktop`, `Linux`) are what the build scripts pass to
`--export-release`, so renaming them breaks the build. Its `include_filter` is
load-bearing: `export_filter="all_resources"` covers *resources*, so a plain
data file (`segments/*.seg`, `version.txt`) is skipped in silence unless the
filter names it.

### Build version

Both build scripts stamp a `yyyy-MM-dd.HHmmss` version into `version.txt` before
exporting, so it is packed into the game, and the running game prints it in the
**bottom-left corner**. Quote it in any playtest report — it is the only thing
that identifies which binary was played.

A run from the editor or from source shows `dev (...)` instead. `version.txt` is
written to the project root and never cleaned up, so an editor run finds the last
export's stamp sitting there; labelling it `dev` is what stops a stale number
being reported as the build under test. `version.txt` is gitignored — it is an
output, not source.

## Running the game

```powershell
.\build\windows\BridgeToFriendship.exe
```

```bash
./build/linux/BridgeToFriendship.x86_64
```

Or straight from source:

```powershell
.\Godot_v4.4.1-stable_win64.exe --path .
```

**SOLO / LOCAL** starts a single-player session with no networking. **HOST** and
**JOIN** use a Steam lobby and need a running Steam client. `steam_appid.txt`
currently holds `480` (Valve's public "Spacewar" test appid) — replace it, and
`SteamManager.APP_ID`, once the game has its own.

## Running tests

Tests are headless Godot runs, one process per test, living in
`scripts/tests/*.gd`. Logs go to `test_logs/<TestName>.log` and `.err.log`.

```powershell
.\test_runner.ps1 -TestName test_smoke
```

```bash
./test_runner.sh test_smoke
```

Run either with no argument to list the available tests. `CLAUDE.md` covers how
the harness works, what `--fixed-fps 60` is for, and the headless traps that
have already cost time here.

## Layout

```
scenes/              main.tscn (world + menu), player.tscn (avatar)
scripts/
  main.gd            game root: menu, spawning, headless entry points
  debug_settings.gd  DebugSettings autoload -- the dev-knob registry
  net/               SteamManager and NetworkManager autoloads
  player/            the player avatar
  tests/             one file per test; the gate runs every .gd in here
  test_support/      shared helpers -- NOT run as tests
design_ideas/        one short doc per design decision
implementation_plans/ one plan per milestone
tmp/                 throwaway output (gitignored)
```
