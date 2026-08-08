# M0 — Project skeleton

**Status: done (2026-08-08).**

The goal of M0 was to have a project that *builds, tests and connects* before
any game design exists, so that whatever M1 turns out to be starts on a green
gate rather than on a pile of scaffolding written under deadline.

## What M0 delivers

**Engine and build.** Godot 4.4.1, Forward+ 3D. `build.ps1` (Windows) and
`build.sh` (Linux, and cross-builds Windows) run the full test gate, abort on
failure, fetch export templates if absent, export, and package. Committed
`export_presets.cfg` with preset names the scripts depend on.

**Test harness.** `test_runner.ps1` / `test_runner.sh` run one headless test by
name with `--fixed-fps 60`, a 600s hang timeout, and per-test logs.
`import_check.ps1` / `.sh` repair a stale or absent `.godot/` cache before any
run. `scripts/test_support/test_case.gd` is the base class; a test is one file
under `scripts/tests/`, and the gate runs every one of them.

**Networking.** `NetworkManager` autoload owns sessions, peers and the
host/join/leave lifecycle over two interchangeable transports — Steam
(GodotSteam, for release) and ENet (for development and for every test).
`SteamManager` autoload owns lobbies and is the only file that touches the
Steamworks API. Host-authoritative topology; peer 1 is the host and is a player.

**Game content, deliberately minimal.** A ground plane, a capsule avatar with
walk/jump against real physics, a third-person camera, and a three-button menu.
This is a harness for the networking, not a design.

**Docs.** `CLAUDE.md` (how to work here, and the traps already paid for),
`README.md` (build/run/test), this directory and `design_ideas/`.

## Tests at the end of M0

| test | what it pins |
|---|---|
| `test_smoke` | autoloads exist, main scene is a Node3D with a ground and a Players container, player scene instantiates, nothing thinks it is networked at boot |
| `test_debug_settings` | every registered knob is well formed; set/get round-trips; out-of-range writes refused; the change signal fires once |
| `test_player_movement` | gravity, landing, walking a real distance, decay to rest, jumping — driven through the same input path the keyboard uses |
| `test_network_session` | `NetworkManager.host()` over ENet: signals, peer list, ids, double-host refused, `leave()` idempotent |
| `test_enet_loopback` | a real host and a real client in one process exchanging a real RPC over a real socket |

Two of these failed on their first run and found real bugs — an
`OfflineMultiplayerPeer` whose unique id is 1 being read as "I am the host", and
an RPC broadcast before the host had admitted the peer. Both are written up in
`CLAUDE.md` under Multiplayer.

## Explicitly NOT in M0

- Any game design. There is no goal, no verbs, no loop, no art.
- Player state replication beyond a position/yaw broadcast. No interpolation
  buffer, no reconciliation, no lag compensation.
- A lobby browser. **JOIN** joins the first lobby it finds, with a `TODO` on it.
- Steam features past lobbies + peer-to-peer: no achievements, no Rich Presence,
  no invites beyond the overlay's join-request hook, no cloud saves.
- Its own Steam appid. `steam_appid.txt` holds `480` (Valve's public "Spacewar"
  test appid), which is why `LOBBY_GAME_KEY` filters the lobby list — every
  other Spacewar project in the world is on that appid too.

## What M1 needed before it could start — answered 2026-08-08

The game design arrived (`design_ideas/game_concept.md`) and answered all four,
mostly in the direction that costs the most: **client-authoritative movement is
retired in M1.** Every core verb turned out to be an interaction between two
players' bodies — shove transfers momentum between them, rope ties them together
with a constraint — and two machines each owning one end of that cannot agree.
See `design_ideas/physics_and_authority.md`, and `implementation_plans/roadmap.md`
for the milestone set that follows.

The original four questions, for the record:

1. **How many players, and are they cooperative or adversarial?** This decides
   whether client-authoritative movement stays. It is fine for co-op and wrong
   for anything competitive, and the swap gets more expensive the more systems
   are built on top of it.
2. **What is replicated?** A handful of avatars is a different problem from a
   shared simulated world. If the world is authoritative and large, the
   host/client split has to be designed, not retrofitted.
3. **Does anyone join mid-session?** Late-join means every piece of world state
   needs a serialisable snapshot, which is a constraint on how state is stored
   from the first line — not a feature added later.
4. **Is the camera first- or third-person?** It decides whether the avatar needs
   a look-direction in the replicated state, and how much the input latency of
   client-authoritative movement matters.
