extends RefCounted

# THE HUD PIECES A MODE CAN ASK FOR, by id. A mode names the ids it wants
# (BaseMode.hud_widgets); the HUD builds those and only those, and frees them
# again when the round's mode stops asking. So the race brings its lap clock, and
# a mode that needs a fuel gauge adds a script here and names it -- nothing in the
# HUD has to learn that the mode exists.
#
# A widget is a Control with `build(make_label: Callable)` and `refresh(model)`,
# where `model` is the whole HudModel.build() dictionary.

const WIDGETS := {
	"lap_clock": preload("res://scripts/ui/hud/widgets/lap_clock.gd"),
}

static func exists(id: String) -> bool:
	return WIDGETS.has(id)

static func make(id: String) -> Control:
	if not WIDGETS.has(id):
		return null
	var widget: Control = WIDGETS[id].new()
	widget.name = "Widget_" + id
	return widget
