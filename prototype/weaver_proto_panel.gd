@tool
extends VBoxContainer
class_name WeaverProtoPanel

#
# Root of the resource-binding prototype shown in the WeaveRD main screen: a toolbar, the canvas on
# top and the resource matrix below. Both are rebuilt from WeaverProtoModel whenever it changes.
# Placeholder data only: nothing is saved and nothing reaches the godot_weave_rd module.
#

var model := WeaverProtoModel.new()

var _canvas: WeaverProtoCanvas
var _matrix: WeaverProtoMatrix
var _status: Label


func _init() -> void:
	name = "WeaveRDPrototype"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	add_child(toolbar)
	var add_view := Button.new()
	add_view.text = "+ View"
	add_view.tooltip_text = "Add a view. Views render left to right."
	add_view.pressed.connect(func(): model.add_view())
	toolbar.add_child(add_view)
	var reset := Button.new()
	reset.text = "Reset demo"
	reset.pressed.connect(model.seed_demo)
	toolbar.add_child(reset)
	var note := Label.new()
	note.text = "Prototype: placeholder resources, nothing is saved. Hover a chip to see its links, drag it onto a card to bind."
	note.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	toolbar.add_child(note)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toolbar.add_child(_status)

	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	_canvas = WeaverProtoCanvas.new()
	_canvas.model = model
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_stretch_ratio = 2.0
	_canvas.custom_minimum_size.y = 220
	_canvas.status_changed.connect(_on_status_changed)
	split.add_child(_canvas)

	_matrix = WeaverProtoMatrix.new().setup(model, _canvas)
	_matrix.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_matrix.custom_minimum_size.y = 160
	split.add_child(_matrix)

	model.changed.connect(_rebuild, CONNECT_DEFERRED)
	model.seed_demo()


# Same entry points as WeaverEditorScene so the plugin can swap between them.
func setup_for_plugin() -> void:
	pass

func cleanup_plugin() -> void:
	pass


func _rebuild() -> void:
	_canvas.rebuild()
	_matrix.rebuild()

func _on_status_changed(text: String, ok: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", WeaverProtoStyle.VALID if ok else WeaverProtoStyle.INVALID)
