# M13 — Netcode: make a distant client playable

From the coast-to-coast playtest of 2026-08-13. The findings are in
`design_ideas/netcode_assessment.md`; this is what to build.

**The authority model does not change.** Host-authoritative, clients send input,
local avatar predicted and reconciled — `physics_and_authority.md` argues that
well and it is right. Everything here is the layer that model assumed and nobody
built.

---

## Where the 200 KB/s goes

Measured with `var_to_bytes` on the real snapshot builders, playtest bridge, four
players, and every population at the cap the config already permits.

**Godot's Variant encoding is the story.** Inside an `Array`, *every* value costs
at least 8 bytes: an int is 8, a float is 8, **a bool is 8**, a `Vector3` is 16.

| type | bytes | entries | B/entry | KB/s | what is in it |
|---|---|---|---|---|---|
| balls | 1160 | 24 | 48 | **68.0** | id, position, **velocity** |
| hats | 820 | 16 | 51 | **48.0** | id, **style_id**, mode, position |
| players | 616 | 4 | 154 | 36.1 | the whole `capture_state()` blob |
| rushers | 392 | 8 | 49 | 23.0 | id, position, state, **target_peer** |
| bullets | 264 | 8 | 33 | 15.5 | id, position |
| specials | 232 | 4 | 58 | 13.6 | id, **kind**, mode, position, ammo |
| **total** | **3484** | | | **204.1** | **2.5 × the 1392 MTU** |

A quiet frame is 664 B / 39 KB/s. The cap case is what fragments.

### Why it is that big — three separate reasons, in order of size

**1. Cadence.** `SNAPSHOT_INTERVAL_TICKS = 1`. Everything, to everyone, sixty
times a second, whether it moved or not. Its own comment calls this "correct and
wasteful".

**2. Sending fields nobody reads.** Every bolded field above is dead weight:

- **Ball velocity** — a client calls `set_simulated(false)` and never integrates
  it. 16 B × 24 = 384 B/frame, **22.5 KB/s to send a number that is discarded.**
- **Hat `style_id`** — constant for the life of the hat, sent 60×/s forever.
  It only needs to arrive once, when a client first adopts the hat. **11 KB/s.**
- **Special `kind`** — same, constant. **`ammo`** changes at most 2.5 times a
  second and rides a 60 Hz channel.
- **Rusher `target_peer`** — host bookkeeping for choosing a chase target. No
  client reads it. **3.8 KB/s.**
- **The player blob is the wrong blob.** `capture_state()` exists for
  *rewind-and-replay* and therefore carries everything that affects stepping:
  `shove_cooldown`, `invulnerable`, `ledge_cooldown`, `state_timer`. **Only the
  local player replays.** A remote player needs position, state, facing, health
  and the two rescue fields the bar draws — and nothing else.

**3. The encoding.** After the above, the remaining fields still cost 8–16 bytes
each for values that are two bytes of information. Positions quantised to 1 cm as
three `int16` cover ±327 m — the whole bridge — and ids fit in a `uint16`.

Packed, the same busy frame is **736 bytes / 43 KB/s: 4.7× smaller, and half a
packet instead of two and a half.**

---

## The work, in the order it should land

Each item stands alone and each is separately playtestable. **1 and 2 are the two
a player would notice**; 3–6 are why the link can carry them, and they compound:
204 KB/s today, ~43 packed, ~16 packed-and-delta'd, ~8 at half cadence.

### 1. An interpolation buffer for remote bodies

Keep the last few snapshots with the `server_tick` **the wire already carries and
the client currently throws away** — `_apply_snapshot`'s first parameter is never
read. Render every remote body ~100 ms behind the newest snapshot, interpolating
between the two that straddle that time.

Applies to remote players, balls, rushers, hats, specials and rounds — every one
of which is a hard position write today, so a late or lost packet freezes all of
them at once and then teleports them.

**This is the single biggest visual win and it changes no authority.** It also
makes item 3 free: at 30 Hz *with* interpolation, motion is smoother than at
60 Hz without.

### 2. Predict the start of a `SHOVE`

Enter `SHOVE` locally on the press and run the fixed-speed line; the host stays
authoritative for the contact and corrects on arrival.

The existing rule — *"committed actions are not predicted"* — answers a question
about the **outcome** and is being applied to the **start**. The direction is
chosen locally, is already on the wire as an absolute angle, and the first six
ticks are a straight line. What is genuinely unpredictable is what it *hits*.

Today a distant player presses dash and sees nothing for a full round trip. For a
game whose comedy is built on a committed, unsteerable dash, that is the worst
80 ms in the build. Same treatment for firing a special.

**Reconciliation already handles being wrong:** a mispredicted shove is one
`apply_state` — the machinery is built and tested.

### 3. Halve the cadence

`SNAPSHOT_INTERVAL_TICKS = 2`. Straight 2× on everything, and after item 1 it
looks *better*, not worse. Do it after interpolation, never before.

### 4. Stop sending what nobody reads

In rough order of payoff: ball velocity (22.5 KB/s), hat `style_id` (11), a
display-only blob for remote players (~18), special `kind`/`ammo`, rusher
`target_peer` (3.8). **~60 KB/s, or 30%, with no encoding change at all** — this
is deletion, not engineering.

The local player keeps the full `capture_state()`; it is the only one that
replays.

### 5. Pack the wire

A `PackedByteArray` codec: `uint16` ids, 1 cm-quantised `int16` positions,
`uint8` states, a bitfield for the flags. Gets the busy frame to ~736 B and under
one MTU, which ends fragmentation — and fragmentation is what turns 1% link loss
into 3% snapshot loss exactly when the screen is busiest.

### 6. Delta against a keyframe

**Measured, because the first draft of this plan waved it away and the reason
given was weak.** "It fits in one packet with four players" is a statement about
sufficiency at today's caps, not a design argument, and it does not survive the
numbers.

Of everything in a snapshot, how much actually changed since the last one — at
the 1 cm resolution item 5 packs to, over 600 ticks of steady state:

| type | entry-ticks | changed |
|---|---|---|
| hats | 12020 | **0.2 %** |
| rushers | 3360 | **0.2 %** |
| specials | 3005 | **0.2 %** |
| players | 2404 | 4.2 % |
| **balls** | 14281 | **90.9 %** |
| total | 35070 | 37.4 % |

**Almost nothing moves.** Hats, rushers and specials are within a rounding error
of perfectly still, and even four players are 4 % — a walking body crosses 1 cm
in well under a tick, but three of the four were standing.

**Balls are the whole cost**: 99 % of every change in the table, because a plinko
ball is a `RigidBody3D` on a deck pitched 4° by design. It rolls downhill until
its 25 s lifetime culls it and never comes to rest. That is the plinko design
working, not a bug — but it means the bandwidth is dominated by one object type
whose entire purpose is to be in motion.

Even so: **~277 B/frame, 16.3 KB/s — 2.6× better than packing alone, and 12.5×
smaller than today's 204 KB/s.**

**The keyframe variant is what makes this cheap.** Classic delta encoding needs
per-client acked baselines, because a delta against a snapshot the client never
received decodes into silent, permanent corruption — the worst failure shape
there is. That would mean acks on a channel that has none, per-client state on
the host, and per-client packet construction instead of one broadcast.

None of that is necessary here. **Send a full snapshot every N ticks and, in
between, only the entries that have changed since that keyframe.** Then:

- it is still **one packet broadcast to everyone** — no per-client state;
- a lost packet costs staleness until the next keyframe rather than corruption,
  which is the **same self-healing-by-construction** property every snapshot
  applier in this codebase already relies on;
- and it composes with item 1, which is already rendering ~100 ms in the past.

A keyframe every 30 ticks bounds the worst case at half a second for an entry
that moved and was missed. Tune N against the harness.

### 7. Bound the input queue

`_consume_remote_input` pops exactly one per tick; `_submit_input` appends
everything that arrives; there is no cap, no catch-up and no clock sync. Queue
depth is a random walk with no restoring force, and **every entry in it is a
permanent 16.7 ms of added input latency**.

Cap it, drop oldest, or consume two when deep. A few lines, and it removes a
latency creep that gets worse the longer a session runs.

### 8. Measure RTT and show it

Nothing in the codebase measures round-trip time — the audit had to reason from
first principles about what an 80 ms link does. The next playtest report should
arrive with a number in it.

---

## The harness, which comes first

**Items 1–6 are unfalsifiable without it**, and on this project's rules a fix
with no failing test is a fix nobody can check. `debug_inbound_delay_ticks`
exists and `test_client_prediction` uses it, but it only delays snapshots
*inbound to a client* — no jitter, no loss, no reordering, nothing on the input
path to the host. Every failure mode in the assessment is invisible to it.

What it needs to grow, all on the existing two-worlds-in-one-process rig:

- **delay both directions**, independently
- **jitter** — a spread around the delay, not a fixed offset, since the freeze-
  and-jump is caused by variance and not by latency
- **loss**, including the **correlated** loss fragmentation produces
- **reordering**, which `unreliable_ordered` turns into extra loss

And then assertions about **what a client SEES**, not what the host computed: a
remote body's frame-to-frame motion stays smooth across a dropped snapshot; a
dash starts within N ms of the press; queue depth does not grow over a long run.

**Port 28781 is reserved** for M8.5's hat replication test and is still free; the
next one after that is 28783.

---

## Explicitly not in this milestone

- **Changing the authority model.** It is right. This is the layer on top.
- **Relevancy filtering.** Deciding *who* needs to hear about a body. The party
  is inside a 40 m leash on a bridge everybody can see, so there is nothing to
  filter — this is the answer to a problem this game does not have.
- **Acked per-client baselines.** See item 6: the keyframe variant gets the win
  without them, and they are what makes delta encoding expensive elsewhere.
- **Rollback for anything but the local avatar.** The party is co-op; nobody is
  competing over a frame.
- **A dedicated server.** Host-authoritative with the host playing is the
  topology `multiplayer_topology.md` chose, and none of the above needs it to
  change.
