# Bridge to Friendship

A 3D multiplayer game in Godot (4.4.1, pinned in `godot.manifest`), shipping on
Steam.

Right now this is the skeleton: a 3D world with a ground plane, a capsule
avatar you can walk and jump, a networking layer with two interchangeable
transports (Steam for release, ENet for development and tests), a five-test
gate, and Windows/Linux build scripts. The game itself is not designed yet --
see `implementation_plans/m0_project_skeleton.md` for what M0 covers and what
M1 is waiting on.

## Requirements

PowerShell on Windows, bash on Linux. **Nothing else — no Godot install.**

The engine is a dependency of the repo, not of your machine. `godot.manifest`
pins the version, and the build scripts, the test runners and the editor
launcher all download exactly that build into `build/deps/` the first time they
need it:

```
build/deps/godot/4.4.1-stable/      the engine  (~120 MB)
build/deps/godot-data/              its data dir, incl. export templates
build/linux/  build/windows/        export output
```

All of `build/` is gitignored, and **nothing outside the repo is read or
written**. In particular a Godot on your `PATH` is never reused, and export
templates go into `build/deps` rather than your `~/.local/share/godot` (or
`%APPDATA%\Godot`) — so this project cannot pick up, or disturb, whatever Godot
setup you keep for your own work. That is the point: everyone building this game
builds it with the same engine regardless of what else is on their machine.

### Upgrading Godot

Edit the one line in `godot.manifest` and run a build; the new engine and its
export templates are fetched on the next run. Any
[godot-builds](https://github.com/godotengine/godot-builds/releases) tag works,
pre-releases included. To trial one without editing the file:

```bash
BTF_GODOT_VERSION=4.5-stable ./build.sh --target linux
```

Nothing accepts an engine that reports a different version than the pin — a
build made with the wrong engine is exactly the kind of failure that only shows
up in the shipped artifact.

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

Either script installs the pinned engine if this checkout does not have it yet,
runs the full test suite and aborts on any failure (`-Force` / `--force`
overrides; `-SkipTests` / `--skip-tests` skips the gate entirely and produces an
unverified build). It then fetches the export templates for the targets being
built — the upstream archive is ~1.2 GB and only the templates those targets
need are unpacked — and exports and packages:

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

## Opening the editor

```powershell
.\editor.ps1
```

```bash
./editor.sh
```

**Use these rather than double-clicking `project.godot`.** A `.godot` file opens
in whichever Godot the desktop has associated with it, which on a machine with
several installs is a coin flip — and opening this project in a newer editor is
not a harmless mistake: it silently rewrites `project.godot`, the scenes and the
import cache into its own format, and the pinned engine can no longer load what
it left behind. The launchers always open the version in `godot.manifest`,
installing it first if needed.

**SOLO / LOCAL** starts a single-player session with no networking. **HOST** and
**JOIN** use a Steam lobby and need a running Steam client. `steam_appid.txt`
currently holds `480` (Valve's public "Spacewar" test appid) — replace it, and
`SteamManager.APP_ID`, once the game has its own.

### Controls

Movement and aiming are **independent**: you walk one way while pointing another.

| | keyboard & mouse | gamepad |
|---|---|---|
| move | WASD / arrows | left stick |
| aim | mouse cursor | right stick |
| dash | Space | A, or right trigger |
| menu | F5 | Start |
| add a practice partner | F2 | — |
| hand control to the next player | F3 | — |
| quit | Esc | — |

The dash goes **where you are pointing**, at any angle, and cannot be steered
once it is running. With no aiming device it follows the direction you are
walking, and with nothing held at all it follows the way you were last facing —
it never refuses to fire.

Aim follows **whichever device you last moved**, so a pad player is not yanked
around by a resting mouse and a mouse player is not overridden by a drifting
stick. Facing is assigned instantly, with no turn rate: see
`design_ideas/game_concept.md`.

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
godot.manifest       the pinned engine version -- the only place it is written
godot_env.sh/.ps1    installs and verifies that engine into build/deps
editor.sh/.ps1       open the project in it
build.sh/.ps1        gate + export;  test_runner.sh/.ps1  one test by name
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
build/               ALL gitignored: deps/ (engine + templates), linux/,
                     windows/, and the packaged archives
tmp/                 throwaway output (gitignored)
```
