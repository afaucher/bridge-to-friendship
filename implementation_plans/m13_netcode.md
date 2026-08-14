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

**Read that table as a ceiling, not a typical frame.** Measured over 900 ticks of
a party walking the playtest bridge, the field carries **7.6 live balls on
average, not 24** — so a normal busy moment is nearer 1800 B / 105 KB/s. Still
1.3× the MTU, still fragmenting, but the 204 figure is the worst the config
permits rather than the steady state.

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

## If you only care about lag

Bandwidth and lag are different problems with different fixes, and the list is
shorter than it looks. **Three of the nine items below move perceived latency;
the rest are bandwidth and robustness.**

| item | lag? | why |
|---|---|---|
| **1. Interpolation** | **yes — the biggest** | the only fix for "everything stutters and teleports" |
| **2. Predict the dash** | **yes** | removes a full RTT of dead air from the signature verb |
| **8. Input queue / clock** | **yes** | removes latency that *accumulates over a session* |
| 3. Halve the cadence | no — costs a little | do it only after 1 |
| 4–6. Dead fields, packing, delta | **indirect only** | fewer bytes → under one MTU → fewer lost snapshots |
| 7. Idle emitters | no | fewer balls, and a gameplay change |
| 9. Measure RTT | no | tells you whether any of this worked |

**Delta encoding is not a lag fix, and it is worth being blunt about that.** Its
entire latency contribution is ending fragmentation: a busy snapshot is 2.5
packets today, an unreliable packet loses all of itself if any fragment is
dropped, and a dropped snapshot is a visible hitch. But the thing that makes a
dropped snapshot *visible* is the absence of interpolation — with item 1 in
place, one lost snapshot is invisible, and the fragmentation stops mattering.

**"Rate independence" is interpolation, not delta.** They sound similar and are
opposite ends of the problem: delta makes each snapshot smaller; interpolation
makes the client stop caring how often snapshots arrive. If the goal is to be
robust to a bad link rather than to a metered one, interpolation is the item that
buys it, and it is the one that makes lowering the send rate safe afterwards.

**Item 8 has a cheap version and a right version.** Capping the queue removes the
creep. The principled fix is a clock: the host tells the client whether its input
is arriving early or late and the client nudges its tick phase, so input lands
*just* before the host needs it. Start with the cap, measure, and only build the
clock if the cap is not enough.

**What is deliberately NOT on the lag list**, having been checked rather than
assumed:

- **Correction smoothing.** `_reconcile` snaps the body with `apply_state` and
  replays, so a mispredicted frame pops. Measured at 8 ticks of simulated delay:
  **1 correction in 240 ticks, worst displacement 0.10 m.** Rare and small, so
  smoothing is not worth the complexity yet. Re-measure on a busier rig — four
  players colliding is the case that would change this.
- **Lag compensation** (rewinding the world to when a client fired). This is co-op
  and nothing in it turns on a frame. Revisit only if the machine gun feels wrong
  once item 2 makes firing predictive.
- **Clock sync as its own item.** It is a prerequisite of item 1, not a separate
  piece of work — the host tick is already on the wire and unread.

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
1 cm resolution, over 600 ticks of steady state:

| type | entry-ticks | changed |
|---|---|---|
| hats | 12020 | **0.2 %** |
| rushers | 3360 | **0.2 %** |
| specials | 3005 | **0.2 %** |
| players | 2404 | 4.2 % |
| **balls** | 14281 | **90.9 %** |

**Almost nothing moves.** Balls are 99 % of the churn and are deliberately set
aside (item 7); everything else is within a rounding error of perfectly still.

#### The schema

Three candidates measured on the same real snapshots, balls excluded, 900 ticks:

| scheme | raw | + compression |
|---|---|---|
| A — full Variant (today) | 2091 B / 122.5 KB/s | 645 B / 37.8 KB/s |
| B — + quantised to 1 cm | 2090 B / 122.5 KB/s | 622 B / 36.5 KB/s |
| **C — + id manifest, changed only** | **907 B / 53.1 KB/s** | **256 B / 15.0 KB/s** |

**Scheme B is the surprise: quantisation on its own saves nothing.** A quantised
float is still an 8-byte Variant float. Its value is making a resting body
produce a *byte-identical entry* so the comparison in C is stable. Quantisation
is a prerequisite for the delta, not a saving in itself — the earlier draft filed
it under the wrong heading.

**Scheme C is the recommendation**, and it is deliberately the least clever thing
that works. Per section, send:

```
[ PackedInt32Array ids,      # every id present this tick
  Array changed ]            # only entries differing from what was last sent
```

#### The manifest is the whole design

Every applier in this codebase is **self-healing by construction**: it builds a
seen-set from the entries, creates unknown ids, applies, and **destroys anything
not mentioned**. There are seven, all identical in shape, with the id at element
zero.

That property is an asset and a trap. Omit unchanged entries naively and every
applier **deletes everything that did not move**. The manifest keeps the destroy
semantics exactly as they are while letting the payload shrink: the seen-set
comes from the id list instead of from the entries, and nothing else changes.

#### What it costs to implement

One helper host-side —

```gdscript
static func encode(entries: Array, last: Dictionary, keyframe: bool) -> Array:
    var ids := PackedInt32Array()
    var changed: Array = []
    for e in entries:
        var id: int = int(e[0])
        ids.append(id)
        if keyframe or last.get(id, null) != e:
            changed.append(e)
            last[id] = e
    return [ids, changed]
```

— and **two lines per applier**: take the seen-set from the manifest, iterate the
changed list instead of every entry. Seven appliers, all the same shape.

#### Why it stays robust as the game grows

- **A new body type** is a new section and one more encode() call. Water (M7), the
  bus (M11) and every remaining special land the same way.
- **A new field on an entry** needs nothing — the comparison is whole-entry.
- **A field that changes every tick** needs nothing; it is simply always sent.
- **Getting it wrong sends too much rather than too little**, which is the correct
  direction for a mistake to fail in.

Three rules are the entire contract: **element zero is the id** (already true
everywhere), **entries are built deterministically** (quantise floats), and **a
keyframe every 30 ticks**.

That keyframe is also what avoids the expensive version. Classic delta encoding
needs per-client acked baselines — a delta against a snapshot the client never
received decodes into silent, permanent corruption — meaning acks on a channel
that has none, per-client state on the host, and per-client packet construction
instead of one broadcast. **Keyframes buy the same safety with a counter** and
keep it a single broadcast packet, bounding the worst case at half a second of
staleness on one entry.

Applies to the **unreliable snapshot only**. Ownership already travels reliably
and must not be deltaed.

#### About compression — measured, not proposed

The compressed column is zstd on the payload, used as a **measure of how
redundant the encoding is**: 3.2× on scheme A, because Variant packs everything
into mostly-zero 8-byte fields.

**It is not a proposal, and it is probably not free money.** Godot's
ENetMultiplayerPeer appears to enable COMPRESS_RANGE_CODER by default, so some of
that redundancy may already be squeezed on the wire, and range coder is weaker
than zstd. **Verify what the link is actually doing before claiming any of it** —
one source found while researching this says exactly that: always profile before
claiming compression savings.

What the numbers do establish is that compression and the delta **compose**:
under the same compressor, scheme C is 256 B against scheme A's 645 B. The delta
win holds whether or not compression is already on, which is the reason to build
the schema rather than hope the transport saves you.

### 7. Idle the plinko emitters nobody is near

Suggested during the review, and it is the only item here that attacks the
**source** rather than the encoding — worth having because balls are 99 % of the
churn in the table above.

`_fire_shooters` walks every shooter cell the run has streamed in and fires each
one every `PLINKO_FIRE_INTERVAL`, forever, wherever the party is. Measured over
900 ticks with a party walking up the bridge: **60.9 % of shooter-ticks were more
than 40 m from any player.** Idling those is a straight ~60 % cut in balls
created, which is bandwidth, host physics and contact-graph pressure at once.

**But the radius cannot be guessed, and 40 m is the wrong number.** The same run
found that **no ball was ever within 20 m of a player**, 8.5 % were within 30 m
and 57 % within 40 m — because a ball's whole job is to be fired up-bridge and
*roll down* into the party. A shooter that only wakes when somebody is already
close produces balls that arrive after the moment they were for, and
`plinko.md`'s "balls come back down the bridge without anything aiming them" stops
being true.

So the gate is **asymmetric**: a shooter matters to players *below* it (its balls
roll to them) and to players approaching from below with enough lead time to
matter. Pick the up-bridge margin from how far a ball actually travels before it
first comes within threat distance of anybody — which is a measurement this rig
already knows how to take, not a constant to invent.

**And it is a gameplay change, not only an optimisation.** A field that spins up
as you approach is a different rhythm from one already in motion when you arrive,
and `plinko.md` argues the rhythm is the point. Worth a playtest on its own.

**Balls are NOT accumulating behind the party** — 0 % were past the trailing edge
where hats and specials get culled, so there is no missing-cull bug here. It was
worth checking; it was the obvious guess and it was wrong.

### 8. Bound the input queue

`_consume_remote_input` pops exactly one per tick; `_submit_input` appends
everything that arrives; there is no cap, no catch-up and no clock sync. Queue
depth is a random walk with no restoring force, and **every entry in it is a
permanent 16.7 ms of added input latency**.

Cap it, drop oldest, or consume two when deep. A few lines, and it removes a
latency creep that gets worse the longer a session runs.

### 9. Measure RTT and show it

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
