extends RefCounted

# Send only what changed. See implementation_plans/m13_netcode.md item 6, which
# measured this before it was built: of everything in a snapshot, hats, rushers
# and specials are 0.2% changed tick to tick and four players are 4.2%. Only
# plinko balls genuinely move, because a ball on a 4-degree deck rolls until its
# lifetime culls it.
#
# THE FORMAT, per section:
#
#   [ PackedInt32Array ids,   every id present this tick
#     Array changed ]         only entries differing from what was last sent
#
# THE MANIFEST IS THE WHOLE DESIGN, and without it this is a data-loss bug rather
# than an optimisation. Every applier in this project is self-healing by
# construction: it builds a seen-set from the entries it receives and DESTROYS
# anything not mentioned. Omit unchanged entries naively and every one of them
# deletes every body that did not move. The id list keeps the destroy semantics
# exactly as they are while letting the payload shrink -- the seen-set comes from
# `ids` instead of from `entries`, and nothing else about an applier changes.
#
# WHAT MAKES IT ROBUST AS THE GAME GROWS: a new body type is a new section and one
# more encode() call; a new field needs nothing, because the comparison is
# whole-entry; a field that changes every tick needs nothing, because it is simply
# always sent. Getting it wrong sends too MUCH, which is the correct direction for
# a mistake to fail in.
#
# The contract is three rules:
#   1. Element zero of an entry is its id. Already true of all six sections.
#   2. Entries are built deterministically -- see the quantised comparison below.
#   3. A keyframe every KEYFRAME_TICKS, so a lost packet costs staleness rather
#      than permanent divergence.

# How often the host sends everything regardless. Half a second bounds how long a
# single dropped packet can leave one entry stale.
#
# THIS IS WHAT AVOIDS THE EXPENSIVE VERSION. Classic delta encoding needs
# per-client ACKED BASELINES, because a delta against a snapshot the client never
# received decodes into silent, permanent corruption -- which would mean acks on a
# channel that has none, per-client state on the host, and per-client packet
# construction instead of one broadcast. A keyframe buys the same safety with a
# counter.
const KEYFRAME_TICKS := 30

# The resolution the comparison is made at. Anything that moved less than a
# centimetre since the last send is "unchanged" as far as this is concerned.
const QUANTUM := 0.01

# COMPARED QUANTISED, SENT EXACT, and the split matters in both directions.
#
# Compared quantised, because a resting RigidBody3D jitters in the low bits of a
# float and an exact comparison would report every settled hat as changed on every
# tick -- which is the whole saving, gone.
#
# Sent exact, because the LOCAL player's blob is what _reconcile rewinds to. A
# position rounded to a centimetre before transmission would put a centimetre of
# error into the start of every replay, on the one body where precision is the
# point. Quantisation as a WIRE format belongs with the packing work, where the
# player blob gets a display-only variant; here it is only a comparison key.
static func encode(entries: Array, last: Dictionary, keyframe: bool) -> Array:
	var ids := PackedInt32Array()
	var changed: Array = []
	var seen: Dictionary = {}

	for entry in entries:
		var id: int = int(entry[0])
		ids.append(id)
		seen[id] = true
		var key: Array = _quantise(entry)
		if keyframe or last.get(id, null) != key:
			changed.append(entry)
			last[id] = key

	# Anything that has gone stops being remembered, or `last` is a slow leak
	# keyed by id -- and worse, a recycled id would compare against a dead entry.
	if last.size() > seen.size():
		for id in last.keys():
			if not seen.has(id):
				last.erase(id)

	return [ids, changed]

# The id list, for the seen-set. Split out so an applier reads what it means
# rather than indexing into a pair.
static func ids_of(section: Array) -> PackedInt32Array:
	return section[0] as PackedInt32Array

static func changed_of(section: Array) -> Array:
	return section[1] as Array

# An empty section, for a world with nothing in it yet.
static func empty() -> Array:
	return [PackedInt32Array(), []]

static func _quantise(value: Variant) -> Array:
	var out: Array = []
	for v in (value as Array):
		match typeof(v):
			TYPE_VECTOR3:
				out.append(Vector3(snappedf(v.x, QUANTUM), snappedf(v.y, QUANTUM),
					snappedf(v.z, QUANTUM)))
			TYPE_FLOAT:
				out.append(snappedf(v, QUANTUM))
			TYPE_ARRAY:
				out.append(_quantise(v))
			_:
				out.append(v)
	return out
