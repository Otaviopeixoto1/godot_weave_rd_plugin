@tool
extends ConfirmationDialog
class_name WeaverProtoRenameDialog

#
# Small dialog asking for a new name, shared by everything that can be renamed in the UI (slots, nodes).
# open() shows it with the current name selected. on_renamed receives the trimmed new name; it isn't called on cancel
# or when the name is empty.
#

var _edit: LineEdit
var _on_renamed: Callable


func _init() -> void:
	ok_button_text = "Rename"
	_edit = LineEdit.new()
	add_child(_edit)
	register_text_enter(_edit)
	confirmed.connect(_on_confirmed)
	_edit.text_changed.connect(_update_ok_button)


func open(dialog_title: String, current_name: String, on_renamed: Callable) -> void:
	title = dialog_title
	_on_renamed = on_renamed
	_edit.text = current_name
	_update_ok_button(current_name)
	popup_centered(Vector2i(320, 0))
	_edit.grab_focus()
	_edit.select_all()


func _update_ok_button(text: String) -> void:
	get_ok_button().disabled = text.strip_edges().is_empty()

func _on_confirmed() -> void:
	var new_name := _edit.text.strip_edges()
	if not new_name.is_empty():
		_on_renamed.call(new_name)
