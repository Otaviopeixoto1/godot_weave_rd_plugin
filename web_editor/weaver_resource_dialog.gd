@tool
extends ConfirmationDialog
class_name WeaverResourceDialog

#
# Asks for the name and kind (buffer / image) of a new lane resource. on_created receives (name, kind); it isn't called
# on cancel or with an empty name.
#

var _name_edit: LineEdit
var _kind: OptionButton
var _on_created: Callable


func _init() -> void:
	title = "New resource"
	ok_button_text = "Add"

	var box := VBoxContainer.new()
	add_child(box)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "probes"
	box.add_child(_name_edit)

	_kind = OptionButton.new()
	_kind.add_item("Buffer", WeaverResourceHandle.TYPE_BUFFER)
	_kind.add_item("Image", WeaverResourceHandle.TYPE_IMAGE)
	box.add_child(_kind)

	var hint := Label.new()
	hint.text = "A node of the lane creates it through a create slot."
	hint.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
	box.add_child(hint)

	register_text_enter(_name_edit)
	confirmed.connect(_on_confirmed)
	_name_edit.text_changed.connect(func(text: String): get_ok_button().disabled = text.strip_edges().is_empty())


func open(lane_name: String, on_created: Callable) -> void:
	title = "New resource in %s" % lane_name
	_on_created = on_created
	_name_edit.text = ""
	get_ok_button().disabled = true
	popup_centered(Vector2i(320, 0))
	_name_edit.grab_focus()


func _on_confirmed() -> void:
	var resource_name := _name_edit.text.strip_edges()
	if not resource_name.is_empty():
		_on_created.call(resource_name, _kind.get_selected_id())
