# Multiplayer topology

**Decided 2026-08-08 (M0). Revisit when the game design lands — see the
"what would change this" section.**

## Host-authoritative, host is a player

Peer 1 hosts and also plays. There is no dedicated server build and no
matchmaking service: a session is a Steam lobby, and the lobby owner is the
host.

The alternative — a dedicated server — buys authority that cannot be tampered
with and a session that survives one player leaving, at the cost of hosting
infrastructure, a second export preset, and a lobby flow that has to find a
server instead of a player. For a small-group game shipping on Steam, the
listen-server model is the one the platform is built for: Steam's relay handles
NAT traversal, so peer-to-peer *works* without any of the usual pain.

## Two transports, one interface

`NetworkManager.Transport` is `STEAM` or `ENET`.

| | Steam | ENet |
|---|---|---|
| ships | yes | no |
| needs a Steam client | yes | no |
| works in the test gate | **no** | yes |
| two instances on one box | awkward | trivial |

They are interchangeable because everything above `NetworkManager` speaks in
peer ids and RPCs, which are transport-agnostic: the same `MultiplayerAPI`, the
same routing, the same semantics, a different socket underneath.

**This is the single most load-bearing decision in M0.** A CI box has no Steam
client, so a Steam-only networking layer has no automated test at all —
replication bugs would only ever be found by two humans launching two builds and
noticing. With ENet in the gate, `test_enet_loopback` runs a real host and a
real client through a real socket on every commit.

The rule that keeps this true: **gameplay code never calls `Steam.*`.** Anything
that reaches past `NetworkManager` becomes untestable the moment it is written.

## Client-authoritative movement — SUPERSEDED

> **Overtaken by the game design, 2026-08-08.** The section below is kept as the
> record of what M0 shipped and why. It is no longer the plan: every core verb
> turned out to be an interaction between two players' bodies, which client
> authority cannot resolve. Read `physics_and_authority.md` instead, and expect
> M1 to replace this. Everything else in *this* document still stands.

Each avatar's multiplayer authority is its own peer. A client simulates its own
body and broadcasts position and yaw; remote copies interpolate toward the last
state received.

This is the cheap, responsive option: no input latency on your own movement, no
reconciliation, no prediction. It is also trivially cheatable — a client asserts
where it is and everyone believes it.

That is an acceptable trade for a cooperative game and unacceptable for a
competitive one, so the decision is **deferred to the game design** rather than
settled here. The migration path is: clients send *input* to the host, the host
simulates every body and broadcasts state, clients predict locally and reconcile
against the host's authoritative frames. To keep that a local edit rather than a
rewrite, the authority split is confined to `player.gd`'s `_physics_process` —
nothing else in the codebase branches on who owns a body.

## Spawn handshake

One decision-maker: the host. `_spawn_player` is an
`@rpc("authority", "call_local")`, so the host executes the same function it
asks clients to execute; there is no host branch and client branch to drift
apart. When a peer joins, the host sends it every existing avatar first, then
announces the newcomer to everyone. That order matters the moment spawning
carries any state — the newcomer should know the world before the world knows
it.

## What would change this

- **A competitive game** → host-authoritative movement, and the prediction and
  reconciliation that come with it.
- **More than a handful of players, or a large simulated world** → the host
  becomes a bottleneck and interest management (only replicating what a peer can
  perceive) stops being optional.
- **Mid-session joining** → every piece of world state needs a serialisable
  snapshot, which constrains how state is stored from the first line.
- **Sessions that must outlive the host leaving** → host migration, or a
  dedicated server after all.
