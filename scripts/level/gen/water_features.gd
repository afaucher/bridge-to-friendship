extends RefCounted

# WATER IN A GENERATED SECTION (M27): a channel across the bridge, shaped as a
# pool or a zigzag, placed only where the section has plain deck to cut it from.
# Section-only.

const Hash = preload("res://scripts/core/hash.gd")
const GridConfig = preload("res://scripts/level/grid_config.gd")
const SimConfig = preload("res://scripts/sim/sim_config.gd")

# --- Water (M27) ---------------------------------------------------------------

# HOW OFTEN A SECTION GETS A CHANNEL lives in SimConfig as WATER_CHANNEL_IN,
# because a debug knob mirrors a SimConfig constant and a playtest has to be able
# to turn this one up to go looking for water on purpose.
const CHANNEL_ROWS := 2

# Deck to stand on either side of a one-sided channel's closed end, so the party
# always has a bank to be pushed against rather than a rail.
const CHANNEL_MARGIN := 3


# A CHANNEL CROSSES THE DECK AND FALLS OFF THE SIDE.
#
# LAST, AFTER THE PROFILE AND AFTER THE END-ROW FIXUP, and that ordering is the
# whole of why this is safe. The deck's real edges are the inset profile, which
# is computed above; the fixup then writes DECK across the baseline at both ends.
# A channel carved before either would be overwritten by the second -- which is
# the generate-then-repair trap this file has already paid for once, when the
# entry/exit fixup silently flared every section it was supposed to leave alone.
#
# ONLY PLAIN DECK ROWS. A ramp is a wedge and a lift is a shaft, and water in
# either is a hazard aimed at somebody with no verbs. Rows carrying a set piece
# are somebody else's composition. So the band has to be clean across its whole
# width before any of it becomes water.
#
# THE PARAPET IS SUPPRESSED WHERE THE WATER LEAVES, and only there. Otherwise the
# derived railing pens the channel in, there is no outlet, the flood finds no
# source, and the result is a decorative puddle -- which is exactly what
# playtest_bridge had for four milestones.
static func _place_channel(seg, salt: int) -> void:
	# THROUGH THE KNOB, so water can be found on purpose. Same caveat as every
	# other worldgen knob: it is an input to a generator whose output a client
	# rebuilds from a seed, so two machines that disagree about it build different
	# bridges. Solo and dev only.
	var every: int = maxi(1, int(DebugSettings.tuned(
		"channel_rarity", float(SimConfig.WATER_CHANNEL_IN))))
	if Hash.mix(salt + 5501) % every != 0:
		return
	var bands: Array = _channel_bands(seg)
	if bands.is_empty():
		return
	var z0: int = int(bands[Hash.mix(salt + 911) % bands.size()])
	# THREE SHAPES, ROLLED, EACH FALLING BACK TO THE NEXT. A straight channel is
	# one push across your path; a dog-leg turns a corner and its turn runs ALONG
	# the bridge, so crossing it means being shoved up or down the deck for a
	# moment; a pool with its exits in opposite corners has a DIAGONAL divide, so
	# the push is neither across nor along but somewhere between, and it changes
	# as you cross. Same water, three different things to cross.
	#
	# The fallbacks matter: a section that cannot fit a pool can usually fit a
	# dog-leg, and one that cannot fit either can almost always fit a straight
	# band. Rolling without them would turn "this shape does not fit" into "this
	# section has no water", which is the absence a reroll-and-validate generator
	# hides so well.
	match Hash.mix(salt + 4099) % 3:
		0:
			if _place_pool(seg, salt, z0):
				return
			if _place_zigzag(seg, salt, z0):
				return
		1:
			if _place_zigzag(seg, salt, z0):
				return

	# The deck's real span on these rows, which the profile decided.
	var left: int = _first_solid(seg, z0, 1)
	var right: int = _first_solid(seg, z0, -1)
	if left < 0 or right < 0 or right - left + 1 < CHANNEL_MARGIN + 2:
		return

	# TWO SHAPES, AND THEY PLAY DIFFERENTLY. Spanning the whole deck gives two
	# outlets and a WATERSHED down the middle -- calm in the centre, and which
	# rail it flings you at depends on where you entered. Stopping short of one
	# side gives a single outlet and one strong current the whole way across.
	var x0: int = left
	var x1: int = right
	if Hash.mix(salt + 1777) % 2 == 0:
		if Hash.mix(salt + 313) % 2 == 0:
			x0 = left + CHANNEL_MARGIN
		else:
			x1 = right - CHANNEL_MARGIN

	for z in range(z0, mini(z0 + CHANNEL_ROWS, seg.length)):
		for x in range(x0, x1 + 1):
			if seg.kinds[z][x] != GridConfig.Kind.DECK:
				continue
			seg.kinds[z][x] = GridConfig.Kind.WATER
		# The outlet: only the ends that actually reach the deck's edge.
		if x0 == left:
			seg.no_wall[z][left] = true
		if x1 == right:
			seg.no_wall[z][right] = true


# HOW DEEP A POOL IS, in rows. Deep enough that the diagonal divide across it is
# a shape you can be on the wrong side of, rather than a seam.
const POOL_ROWS := 3


# A POOL WITH ITS EXITS IN OPPOSITE CORNERS.
#
# The other two shapes have their outlets on one axis, so the current is across
# the bridge or along it. Open two DIAGONALLY OPPOSITE corners of a wide pool and
# the divide runs diagonally too: every cell goes to whichever corner is nearer,
# which is neither of those directions and changes under you as you cross.
#
# Nothing here computes that. The flood already answers "which outlet is nearest"
# for any arrangement of outlets -- this only decides where the holes in the
# railing are, and the field does the rest. That is the whole reason the flow was
# built as a distance field rather than as a direction somebody picks.
# SEARCHES, for the same reason the dog-leg does: four consecutive clean rows is
# a much stronger ask than two, so being handed one row and giving up meant this
# shape never happened at all.
static func _place_pool(seg, salt: int, _hint: int) -> bool:
	for z in range(2, seg.length - POOL_ROWS - 1):
		if _pool_at(seg, salt, z):
			return true
	return false


static func _pool_at(seg, salt: int, z_top: int) -> bool:
	if z_top + POOL_ROWS + 1 >= seg.length:
		return false
	for k in POOL_ROWS:
		if not _plain_deck_row(seg, z_top + k):
			return false
	for k in range(-1, POOL_ROWS + 1):
		if not _no_ramp_row(seg, z_top + k):
			return false

	var left: int = _first_solid(seg, z_top, 1)
	var right: int = _first_solid(seg, z_top, -1)
	if left < 0 or right - left < CHANNEL_MARGIN + 4:
		return false

	# INSET BY ONE COLUMN, AND THAT IS NOT A MARGIN -- IT IS THE FIX FOR FENCES.
	#
	# Reported: "water can wind up with fences." A parapet is derived on any solid
	# cell whose edge faces off the side of the bridge, and water is solid -- so a
	# pool spanning rail to rail with only two corners suppressed grew a RAILING
	# along the rest of both sides. A fence standing in a river.
	#
	# Suppressing every edge cell would have fixed the look and killed the shape:
	# the flood reads a suppressed rail as an outlet, so the pool would drain
	# everywhere and the exits-in-opposite-corners idea would be gone. Keeping the
	# water one column off the rail means it never meets an outer edge at all, so
	# there is nothing to fence -- and the two corners get a SPOUT out to the rail
	# instead, which is the only water that touches an edge and is suppressed.
	for k in POOL_ROWS:
		var a: int = _first_solid(seg, z_top + k, 1)
		var b: int = _first_solid(seg, z_top + k, -1)
		if a < 0 or b < 0 or b - a < 4:
			return false
		_wet_span(seg, z_top + k, a + 1, b - 1)

	# TWO CORNERS, DIAGONALLY OPPOSITE, and the flip is the other diagonal. Both
	# on the row's own edge rather than on a remembered one -- the deck's span can
	# differ row to row, so the near rail of the top row is not the near rail of
	# the bottom one.
	var flip: bool = Hash.mix(salt + 2203) % 2 == 0
	var top_row: int = z_top
	var bot_row: int = z_top + POOL_ROWS - 1
	var top_x: int = _first_solid(seg, top_row, 1 if flip else -1)
	var bot_x: int = _first_solid(seg, bot_row, -1 if flip else 1)
	if top_x < 0 or bot_x < 0:
		return false
	# THE SPOUTS. One cell of water reaching the rail at each chosen corner, and
	# the railing off it -- the only place this shape touches an edge, and the
	# only place it drains.
	seg.kinds[top_row][top_x] = GridConfig.Kind.WATER
	seg.kinds[bot_row][bot_x] = GridConfig.Kind.WATER
	seg.no_wall[top_row][top_x] = true
	seg.no_wall[bot_row][bot_x] = true
	return true


# HOW FAR THE DOG-LEG DROPS between its two runs, in rows. Far enough that the
# turn is a place rather than a kink, short enough to fit a section.
const ZIG_DROP_LOW := 3

const ZIG_DROP_HIGH := 6

const ZIG_WIDE := 2          # columns in the leg that runs along the bridge


# RIGHT, DOWN, RIGHT -- and the mirror of it.
#
# Runs from a closed end, turns down the bridge, and turns again to leave by a
# rail. ONE outlet by construction, so the whole path carries one current from
# the head to the fall, and the corner is where it stops pushing you across and
# starts pushing you along.
#
# THE CONNECTOR ONLY NEEDS ITS OWN COLUMNS CLEAN, not whole rows. Requiring
# nine clean rows would have made this almost never happen in a sixteen-row
# section; the leg is two columns wide, so two columns is what it has to ask
# about. The two horizontal runs still need clean rows, because they cross the
# whole deck.
# SEARCHES FOR ITS OWN PLACEMENT, and that is not a detail. The first version
# took the row the straight shape had picked and one rolled drop, and if that
# pair did not fit it gave up -- so it never fired ONCE in nine dumped sections
# while the test stayed green, because the straight fallback always works and
# "13 sections carry a channel" cannot tell you which shape they carry. A rolled
# shape that quietly never happens is the absence a reroll-and-validate generator
# hides best; the fix is to place it where it fits rather than where it was told.
static func _place_zigzag(seg, salt: int, _hint: int) -> bool:
	for tries in 12:
		var pick: int = Hash.mix(salt + 6151 + tries * 131)
		if _zigzag_at(seg, salt, pick, tries):
			return true
	return false


static func _zigzag_at(seg, salt: int, pick: int, tries: int) -> bool:
	var bands: Array = _channel_bands(seg)
	if bands.is_empty():
		return false
	var z_top: int = int(bands[pick % bands.size()])
	var drop: int = ZIG_DROP_LOW + (pick / 7) % (ZIG_DROP_HIGH - ZIG_DROP_LOW + 1)
	var z_bot: int = z_top + drop
	if z_bot + CHANNEL_ROWS + 1 >= seg.length:
		return false
	for k in CHANNEL_ROWS:
		if not _plain_deck_row(seg, z_bot + k):
			return false
	for k in range(-1, CHANNEL_ROWS + 1):
		if not _no_ramp_row(seg, z_bot + k):
			return false

	var left: int = _first_solid(seg, z_top, 1)
	var right: int = _first_solid(seg, z_top, -1)
	var bl: int = _first_solid(seg, z_bot, 1)
	var br: int = _first_solid(seg, z_bot, -1)
	if left < 0 or bl < 0 or right - left < CHANNEL_MARGIN + ZIG_WIDE + 2:
		return false

	# WHICH WAY IT LEAVES. `step` is +1 for right-down-right and -1 for its
	# mirror; everything below is written once and read either way.
	var step: int = 1 if (pick / 3) % 2 == 0 else -1
	var head: int = (left + CHANNEL_MARGIN) if step > 0 else (right - CHANNEL_MARGIN)
	var lip: int = br if step > 0 else bl
	# The corner, somewhere between the head and the far rail.
	var span: int = absi(lip - head)
	if span < ZIG_WIDE + 2:
		return false
	var corner: int = head + step * (1 + (pick / 11) % maxi(1, span - ZIG_WIDE - 1))

	# The columns the vertical leg occupies, kept inside the deck at every row it
	# passes through -- a connector that leaves the deck is a channel with a hole
	# in it, and the flood would read the hole as an outlet.
	var c0: int = mini(corner, corner + step * (ZIG_WIDE - 1))
	var c1: int = maxi(corner, corner + step * (ZIG_WIDE - 1))
	for z in range(z_top, z_bot + CHANNEL_ROWS):
		for x in range(c0, c1 + 1):
			if x < 0 or x >= seg.width:
				return false
			if seg.kinds[z][x] != GridConfig.Kind.DECK:
				return false
			if seg.contents[z][x] != GridConfig.Content.NONE:
				return false

	# --- carve: the run in, the turn, the run out --------------------------
	for k in CHANNEL_ROWS:
		_wet_span(seg, z_top + k, head, c1 if step > 0 else c0)
	for z in range(z_top, z_bot + CHANNEL_ROWS):
		_wet_span(seg, z, c0, c1)
	for k in CHANNEL_ROWS:
		_wet_span(seg, z_bot + k, c0 if step > 0 else c1, lip)
		# THE ONLY OUTLET, and the parapet has to come off it or the channel is
		# penned in and the whole path is a puddle.
		seg.no_wall[z_bot + k][lip] = true
	return true


# Water across a row between two columns, either order, deck only.
static func _wet_span(seg, z: int, a: int, b: int) -> void:
	for x in range(mini(a, b), maxi(a, b) + 1):
		if x < 0 or x >= seg.width:
			continue
		if seg.kinds[z][x] != GridConfig.Kind.DECK:
			continue
		seg.kinds[z][x] = GridConfig.Kind.WATER


# Rows where a band of CHANNEL_ROWS is plain deck all the way across.
static func _channel_bands(seg) -> Array:
	var out: Array = []
	for z in range(2, seg.length - CHANNEL_ROWS - 1):
		var ok := true
		# THE ROWS EITHER SIDE TOO, and only for ramps. A slope running into a
		# channel puts a body into the current at ramp speed with no say in where
		# it enters -- and where you enter is the whole decision a channel poses.
		# Caught by the test asserting it, on three cells out of sixty sections:
		# rare enough to have reached a playtest and been reported as the water
		# "grabbing" people.
		for k in range(-1, CHANNEL_ROWS + 1):
			if not _no_ramp_row(seg, z + k):
				ok = false
				break
		if not ok:
			continue
		for k in CHANNEL_ROWS:
			if not _plain_deck_row(seg, z + k):
				ok = false
				break
		if ok:
			out.append(z)
	return out


static func _no_ramp_row(seg, z: int) -> bool:
	if z < 0 or z >= seg.length:
		return true
	for x in seg.width:
		if seg.kinds[z][x] == GridConfig.Kind.RAMP:
			return false
	return true


static func _plain_deck_row(seg, z: int) -> bool:
	if seg.piece_rows.has(z):
		return false
	var solid := 0
	for x in seg.width:
		var kind: int = seg.kinds[z][x]
		if kind == GridConfig.Kind.HOLE:
			continue
		if kind != GridConfig.Kind.DECK:
			return false          # a ramp or water already; not ours to take
		if seg.contents[z][x] != GridConfig.Content.NONE:
			return false          # a lift shaft, a piece, anything placed
		solid += 1
	return solid >= CHANNEL_MARGIN + 3


# The first solid column scanning from one side; -1 if the row has none.
static func _first_solid(seg, z: int, step: int) -> int:
	var x: int = 0 if step > 0 else seg.width - 1
	while x >= 0 and x < seg.width:
		if seg.kinds[z][x] != GridConfig.Kind.HOLE:
			return x
		x += step
	return -1
