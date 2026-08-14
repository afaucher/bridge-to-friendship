# Netcode assessment — what a distant client actually gets

Written 2026-08-13, after a coast-to-coast playtest reported as "the client's
experience was pretty poor". This is an audit of what exists, not a plan. It
reads the code and measures the wire; every number below was produced by a rig
rather than estimated.

`physics_and_authority.md` owns the *model*. This document owns the gap between
that model and what is built.

Assume ~80 ms RTT, which is honest for coast-to-coast, and ~5 ticks each way at
60 Hz.

---

## The model is sound and mostly built

Host-authoritative, clients send input, the local avatar is predicted and
reconciled by rewind-and-replay. That is the right architecture for this game and
`physics_and_authority.md` argues it well. The reconciliation is real and
correct: `_reconcile` compares the predicted position for the acked tick against
the authoritative one, and on a miss re-applies the authoritative state and
replays every unacknowledged input through the same `step()` the host ran.

What follows is not "the model is wrong". It is five things the model assumes and
the code does not do.

---

## 1. The signature verb has a full round trip of dead air

**`SHOVE` is not predicted.** `_client_tick` predicts only in `WALK`; every other
state takes host state verbatim.

The stated reason is good and is quoted everywhere: *"there is no input to
mispredict, so the correction never fights the player"*. But it answers a
question about the **outcome** and is being applied to the **start**. Those are
different:

- **The entry is predictable.** The dash direction is chosen at the instant of
  the press, it is already on the wire (`aim` is an absolute angle, precisely
  because the host cannot re-derive it), and the first ticks are a straight line
  at a fixed speed. A client can reproduce that exactly.
- **The contact is not.** What the dash hits, and what that does to the other
  body, depends on positions this machine does not own.

Today a distant player presses dash and **nothing happens on their screen for a
full round trip**. Then they are already moving. For a game whose entire comedy
is built on a committed, unsteerable dash, that is the worst place in the build
to spend 80 ms.

The same applies to firing a special: `ACTION_SPECIAL_HELD` goes to the host, the
host spawns the round, and the round arrives in a snapshot ~1 RTT later.

`TUMBLE`, `LEDGE_HANG` and `DOWNED` genuinely have no input and are correctly
left unpredicted.

## 2. Nothing is interpolated, and the client does not know what time it is

Every remote body is written straight from the newest snapshot:

| body | how a client gets it |
|---|---|
| remote players | `apply_state(...)` — position assigned outright |
| balls | position and velocity assigned; simulation switched **off** |
| rushers, hats, specials, bullets | position assigned |

There is **no interpolation and no extrapolation anywhere in the codebase** — the
only two matches for "interpolat" are comments saying it is a later concern.

So on a link where snapshots arrive evenly, remote bodies move in clean 60 Hz
steps. On a real one they arrive in bursts, and every late or lost snapshot is a
frame where every remote body **freezes and then teleports**. Four players, two
dozen balls and a rusher all doing that together is exactly what "pretty poor"
describes.

**The wire already carries what a fix needs and nobody reads it.**
`_apply_snapshot(server_tick, ...)` takes the host's tick as its first parameter
and **the body never mentions it**. There is no clock sync, no RTT estimate, and
no snapshot buffer, so there is currently no way to say "render 100 ms in the
past" even though the information to do it is arriving 60 times a second.

## 3. A busy snapshot is two and a half ENet packets

Measured with `var_to_bytes` on real snapshot builders, on the playtest bridge:

| | quiet frame | busy frame |
|---|---|---|
| players (4) | 616 B | 616 B |
| balls | — | 1160 B (24) |
| hats | — | 820 B (16) |
| rushers | — | 392 B (8) |
| bullets | — | 264 B (8) |
| specials | — | 232 B (4) |
| **total** | **664 B** | **3492 B** |
| **per client** | **39 KB/s** | **205 KB/s (1.6 Mbit/s)** |
| vs ENet's 1392 MTU | 0.5 packets | **2.5 packets — fragments** |

Plus a 320 B stone layout every 30 ticks.

"Busy" here is not a worst case invented to look bad — it is the caps the config
already permits (`PLINKO_MAX_BALLS` 24, `HAT_MAX_LOOSE` 24, `RUSHER_MAX` 12).

Two consequences, and the second is the expensive one:

- **1.6 Mbit/s downstream per client** is a lot for a co-op game with four
  bodies in it, and it is sent to every client whether anything changed or not.
- **An unreliable packet larger than the MTU is fragmented, and losing any one
  fragment discards the whole packet.** At 3 fragments, a 1% link loss becomes
  ~3% snapshot loss; 3% becomes ~9%. Combined with §2 — no interpolation — every
  one of those is a visible freeze-and-jump for every remote body at once.

`unreliable_ordered` compounds it: the channel discards a packet that arrives
after a newer one, so ordinary internet reordering is additional loss on top.

## 4. The input queue can only grow

`_consume_remote_input` pops **exactly one** input per tick. `_submit_input`
appends **everything new** that arrives. There is no cap, no catch-up, and no
clock synchronisation between client and host — both free-run at 60 Hz on their
own clocks.

So the queue depth is a random walk with no restoring force. Any burst of
arrivals adds entries; nothing ever removes more than one per tick. **Every
entry sitting in that queue is one tick — 16.7 ms — of permanent added input
latency**, and coast-to-coast jitter guarantees the walk wanders upward over a
session.

The empty case is handled well and deliberately: the host repeats the last input
and does *not* advance the ack, which keeps the client's replay aligned. It is
only the full case that has no answer.

## 5. Everything, to everyone, every tick

`SNAPSHOT_INTERVAL_TICKS` is 1, with an honest comment calling it "correct and
wasteful". There is no delta encoding, no relevancy filtering and no
quantisation: the full state of every ball, hat, rusher, special and round goes
to every client 60 times a second, whether or not it moved.

## What the gate has never seen

`debug_inbound_delay_ticks` exists and `test_client_prediction` uses it, so
there *is* a latency harness — but it only delays snapshots **inbound to the
client**. It does not model jitter, loss, reordering, fragmentation, or delay on
the **input** path to the host. Every failure mode above is invisible to it.

That is why a build that passes 35 tests played badly across the country: the
gate exercises correctness under perfect network conditions, and nothing
exercises feel under bad ones.

---

## Ranked by feel-per-unit-of-work

1. **An interpolation buffer for remote bodies.** Read the `server_tick` already
   on the wire, keep the last few snapshots, render remote bodies ~100 ms behind
   and lerp between the two that straddle that time. No authority change, no
   prediction change, and it removes the freeze-and-jump that is most of what a
   distant client sees. This is the big one.
2. **Predict the start of a shove.** Enter `SHOVE` locally on the press and run
   the fixed-speed line; let the host stay authoritative for the contact and
   correct on arrival. Removes a full RTT of dead air from the game's signature
   verb. Predicting the entry is not the same as predicting the outcome — see §1.
3. **Bound the input queue.** A cap with drop-oldest, or consume two when the
   queue is deep. A few lines, and it removes a latency creep that gets worse the
   longer the session runs.
4. **Get the busy snapshot under one MTU.** Drop `velocity` from the blob for
   *remote* players (only the local one replays), skip the stone layout when
   nothing has moved, quantise positions. Ends fragmentation, which multiplies
   loss by three exactly when the screen is busiest.
5. **Measure RTT and show it.** Nothing in the codebase measures round-trip time.
   The next playtest report should come with a number rather than an adjective.

**And a harness that can fail.** Items 1–4 are unfalsifiable without one: a test
world that delays, jitters, drops and reorders both directions, and asserts what
a client SEES rather than what the host computes. On this project's own rules a
fix with no failing test is a fix nobody can check.
