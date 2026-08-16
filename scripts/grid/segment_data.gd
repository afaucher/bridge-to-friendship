extends RefCounted

# A parsed .seg file: the authored source of truth for one chunk of bridge.
#
# Text, not a scene. A 30-wide grid is genuinely readable as characters, a change
# shows up as a legible diff, a test can assert properties of the map directly,
# and a generator can emit them. See design_ideas/bridge_grid.md.
#
# THE PARSER IS STRICT ON PURPOSE. Every failure it can catch here is a failure
# that would otherwise appear as geometry that is subtly wrong -- a row one cell
# short, a glyph that silently became a hole -- and be diagnosed by staring at a
# bridge in-game. Errors carry the layer, row and column.

const GridConfig = preload("res://scripts/grid/grid_config.gd")

var name: String = ""
var base_height: int = 0
var width: int = GridConfig.DEFAULT_WIDTH
var length: int = 0
var tags: Array[String] = []

# --- Set-pieces (M18) ---------------------------------------------------------
#
# Both OPTIONAL, and a file without them parses exactly as it did before: a
# set-piece is a `.seg` with a `piece` tag, not a second format. See
# implementation_plans/m18_set_pieces.md.

# The height a piece leaves you at, relative to the height it was entered at. 0
# for a flat composition, +2 for one that is also a climb. It is what lets the
# generator carry on from the right plateau — the same contract the join between
# two segments already uses, one level down.
#
# DECLARED RATHER THAN DERIVED, and the test checks the declaration against the
# geometry. Deriving it would make a piece that says one thing and does another
# impossible to catch; a mismatch is an authoring mistake worth being told about.
var piece_exit: int = 0

# The smallest party that can cross it. RECORDED, NOT ENFORCED: 2a-ii of the
# world-generation doc says solo-crossable is a policy the assembler applies, not
# an invariant the oracle bakes in, so a two-player piece is a legitimate thing to
# author on the day rounds have a lose condition.
var piece_min_party: int = 1

func is_piece() -> bool:
	return tags.has("piece")

# Row-major, indexed [z][x].
var kinds: Array = []      # GridConfig.Kind
var heights: Array = []    # int, in HEIGHT_UNITs above base_height
var contents: Array = []   # GridConfig.Content
var no_wall: Array = []    # bool -- true where the author suppressed a parapet

var errors: Array[String] = []

func is_valid() -> bool:
	return errors.is_empty()

# --- Access -------------------------------------------------------------------

func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < width and z >= 0 and z < length

func kind_at(x: int, z: int) -> int:
	if not in_bounds(x, z):
		# Off the sides of the bridge is a hole; off the ENDS is the next
		# segment's problem, and the caller that cares must check z itself.
		return GridConfig.Kind.HOLE
	return kinds[z][x]

func height_at(x: int, z: int) -> int:
	if not in_bounds(x, z):
		return 0
	return heights[z][x]

func content_at(x: int, z: int) -> int:
	if not in_bounds(x, z):
		return GridConfig.Content.NONE
	return contents[z][x]

func no_wall_at(x: int, z: int) -> bool:
	if not in_bounds(x, z):
		return false
	return no_wall[z][x]

# The deck height a segment starts and finishes at, used to stack segments into a
# continuous run. Taken as the height of the WIDEST run of solid cells in the
# row, not the maximum: a single stray pillar cell at a different height should
# not decide where the next segment joins.
func entry_height() -> int:
	return _row_height(0)

func exit_height() -> int:
	return _row_height(length - 1)

func _row_height(z: int) -> int:
	var tally: Dictionary = {}
	var best_height := 0
	var best_count := 0
	for x in width:
		if not is_solid(x, z):
			continue
		var h: int = height_at(x, z)
		tally[h] = int(tally.get(h, 0)) + 1
		if int(tally[h]) > best_count:
			best_count = int(tally[h])
			best_height = h
	return best_height

func is_solid(x: int, z: int) -> bool:
	var k := kind_at(x, z)
	return k == GridConfig.Kind.DECK or k == GridConfig.Kind.WATER or k == GridConfig.Kind.RAMP

# A parapet exists on a solid cell's edge that faces OFF THE SIDE OF THE BRIDGE,
# unless the author suppressed it. Authors place the absence; the presence is
# derived -- so a file that says nothing produces a bridge you cannot walk off by
# accident, which is the right failure mode for hand-edited text.
#
# INTERIOR HOLES GET NO PARAPET, and that is deliberate on two counts. A gap in
# the decking is broken structure, not a railed balcony -- it is supposed to be
# something you fall into. And railing every hole would make it impossible to
# ever shove a stone through one, which the design calls out as the reward for
# rearranging the bridge.
func has_wall(x: int, z: int, dir: int) -> bool:
	if not is_solid(x, z):
		return false
	if no_wall_at(x, z):
		return false
	# NO PARAPET ON A RAMP, for now. A parapet is a box placed at a fixed height
	# above its cell's top face, and a ramp's top face is a SLOPE -- so the box
	# either floats off the low end or buries itself in the high one, and there is
	# no single height that is right along its length. Suppressed rather than
	# faked: an unrailed ramp is honest about being a slope you can fall off,
	# which is a fair thing to ask of a climb. A wall that follows the slope needs
	# a sheared box or a run of short ones, and that is a rendering job nobody has
	# asked for yet.
	if kind_at(x, z) == GridConfig.Kind.RAMP:
		return false
	var step: Vector2i = GridConfig.DIR_CELLS[dir]
	# Only the sides. The Z ends join the neighbouring segment, and walling them
	# would seal every segment shut.
	var nx := x + step.x
	return nx < 0 or nx >= width

# --- Parsing ------------------------------------------------------------------

static func from_file(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var bad = new()
		bad.errors.append("could not open %s (error %d)" % [path, FileAccess.get_open_error()])
		return bad
	var text := f.get_as_text()
	f.close()
	var seg = parse(text)
	if seg.name == "":
		seg.name = path.get_file().get_basename()
	return seg

static func parse(text: String):
	var seg = new()
	var layers: Dictionary = {}       # layer name -> Array[String] of rows
	var current_layer: String = ""

	for raw_line in text.split("\n"):
		# Only the RIGHT side is trimmed, and only of \r: leading spaces could be
		# meaningful in a future layer, and holes are `_` precisely so that
		# trailing-whitespace loss cannot corrupt a row.
		var line := raw_line.rstrip("\r")
		var stripped := line.strip_edges()

		if stripped.begins_with("#") or stripped == "":
			# Comments and blank lines are skipped everywhere, including inside a
			# layer -- a grid is much easier to read with the rows grouped.
			continue

		if stripped.begins_with("[") and stripped.ends_with("]"):
			current_layer = stripped.substr(1, stripped.length() - 2)
			layers[current_layer] = []
			continue

		if current_layer == "":
			var eq := stripped.find("=")
			if eq == -1:
				seg.errors.append("header line is not `key = value`: '%s'" % stripped)
				continue
			seg._set_header(stripped.substr(0, eq).strip_edges(), stripped.substr(eq + 1).strip_edges())
			continue

		layers[current_layer].append(line)

	seg._build(layers)
	return seg

func _set_header(key: String, value: String) -> void:
	match key:
		"name": name = value
		"base_height": base_height = int(value)
		"width": width = int(value)
		"length": length = int(value)
		"piece_exit": piece_exit = int(value)
		"piece_min_party": piece_min_party = maxi(1, int(value))
		"tags":
			for t in value.split(","):
				var tag := t.strip_edges()
				if tag != "":
					tags.append(tag)
		_:
			errors.append("unknown header key '%s'" % key)

func _build(layers: Dictionary) -> void:
	if not layers.has("deck"):
		errors.append("no [deck] layer")
		return

	var deck_rows: Array = layers["deck"]
	if length == 0:
		length = deck_rows.size()
	if deck_rows.size() != length:
		errors.append("[deck] has %d rows, header says length = %d" % [deck_rows.size(), length])
		return

	kinds = _grid(GridConfig.Kind.HOLE)
	heights = _grid(0)
	contents = _grid(GridConfig.Content.NONE)
	no_wall = _grid(false)

	_read_glyph_layer(deck_rows, "deck", GridConfig.DECK_GLYPHS, kinds)

	if layers.has("height"):
		_read_height_layer(layers["height"])
	if layers.has("content"):
		_read_glyph_layer(layers["content"], "content", GridConfig.CONTENT_GLYPHS, contents)
	if layers.has("no_wall"):
		_read_flag_layer(layers["no_wall"])

	for key in layers.keys():
		if key not in ["deck", "height", "content", "no_wall"]:
			errors.append("unknown layer [%s]" % key)

func _grid(fill) -> Array:
	var rows: Array = []
	for z in length:
		var row: Array = []
		row.resize(width)
		row.fill(fill)
		rows.append(row)
	return rows

func _check_row(layer: String, z: int, row: String) -> bool:
	if row.length() != width:
		errors.append("[%s] row %d is %d chars, expected %d" % [layer, z, row.length(), width])
		return false
	return true

func _read_glyph_layer(rows: Array, layer: String, glyphs: Dictionary, target: Array) -> void:
	if rows.size() != length:
		errors.append("[%s] has %d rows, expected %d" % [layer, rows.size(), length])
		return
	for z in length:
		var row: String = rows[z]
		if not _check_row(layer, z, row):
			continue
		for x in width:
			var glyph := row[x]
			if not glyphs.has(glyph):
				errors.append("[%s] unknown glyph '%s' at row %d col %d" % [layer, glyph, z, x])
				continue
			target[z][x] = glyphs[glyph]

func _read_height_layer(rows: Array) -> void:
	if rows.size() != length:
		errors.append("[height] has %d rows, expected %d" % [rows.size(), length])
		return
	for z in length:
		var row: String = rows[z]
		if not _check_row("height", z, row):
			continue
		for x in width:
			var digit := row[x]
			var value := "0123456789abcdef".find(digit.to_lower())
			if value == -1:
				errors.append("[height] '%s' at row %d col %d is not a hex digit" % [digit, z, x])
				continue
			heights[z][x] = value

func _read_flag_layer(rows: Array) -> void:
	if rows.size() != length:
		errors.append("[no_wall] has %d rows, expected %d" % [rows.size(), length])
		return
	for z in length:
		var row: String = rows[z]
		if not _check_row("no_wall", z, row):
			continue
		for x in width:
			var glyph := row[x]
			if glyph == "X" or glyph == "x":
				no_wall[z][x] = true
			elif glyph != ".":
				errors.append("[no_wall] '%s' at row %d col %d is not 'X' or '.'" % [glyph, z, x])
