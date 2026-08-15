extends SceneTree

# Stamps "AI Generated" onto every generated image, as a POST STEP.
#
# Deliberately not asked of the image model. The prompts tell it not to render
# text at all -- and a model that does render text renders it differently every
# time, in the style of the image, which is exactly what a provenance label must
# not be. Applied here it is identical on every image and cannot be argued with.
#
# IDEMPOTENT via art/.stamped: stamping twice would print the label over itself
# slightly offset, and there is no way to tell a stamped image from an unstamped
# one by looking at the pixels.
#
# Windowed, not headless: it composites through a SubViewport, and --headless
# disables all rendering. Run it as:
#   godot --path . --script scripts/shots/stamp.gd -- <dir>

const LABEL := "AI Generated"
const MARGIN := 0.018       # of the image's shorter side
const TEXT_HEIGHT := 0.026  # of the image's shorter side

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: --script scripts/shots/stamp.gd -- <dir> [<dir>...]")
		quit(1)
		return
	for dir in args:
		await _stamp_dir(str(dir))
	quit(0)

func _stamp_dir(dir: String) -> void:
	var ledger: String = dir.path_join(".stamped")
	var done := {}
	if FileAccess.file_exists(ledger):
		for line in FileAccess.get_file_as_string(ledger).split("\n", false):
			done[line.strip_edges()] = true

	for name in DirAccess.get_files_at(dir):
		if not (name.ends_with(".jpg") or name.ends_with(".png")):
			continue
		if done.has(name):
			print("[STAMP] %s already stamped" % name)
			continue
		var path: String = dir.path_join(name)
		var image := Image.load_from_file(path)
		if image == null:
			printerr("[STAMP] could not load ", name)
			continue
		var stamped := await _compose(image)
		if stamped == null:
			continue
		var err: int = stamped.save_jpg(path, 0.92) if name.ends_with(".jpg") else stamped.save_png(path)
		print("[STAMP] %s %s" % [name, "ok" if err == OK else "FAILED"])
		if err == OK:
			done[name] = true

	var out := FileAccess.open(ledger, FileAccess.WRITE)
	if out != null:
		for name in done:
			out.store_line(str(name))
		out.close()

func _compose(image: Image) -> Image:
	var size := Vector2i(image.get_width(), image.get_height())
	var short: float = float(mini(size.x, size.y))

	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var plate := TextureRect.new()
	plate.texture = ImageTexture.create_from_image(image)
	plate.size = Vector2(size)
	viewport.add_child(plate)

	var label := Label.new()
	label.text = LABEL
	label.add_theme_font_size_override("font_size", int(round(short * TEXT_HEIGHT)))
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	# An outline rather than a backing plate: the label has to stay legible over
	# a white paper background and over a near-black one, and a plate large
	# enough to guarantee that would cover more of the image than the text does.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	label.add_theme_constant_override("outline_size", maxi(2, int(round(short * 0.004))))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	var inset: float = short * MARGIN
	label.position = Vector2(inset, inset)
	label.size = Vector2(size) - Vector2(inset * 2.0, inset * 2.0)
	viewport.add_child(label)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var out: Image = viewport.get_texture().get_image()
	viewport.queue_free()
	return out
