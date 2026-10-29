@tool
extends PopupPanel
class_name WeaverProtoSlotPicker

#
# Popup used by "+ View", "+ Lane" and "Change slot". Nothing is added until a slot is chosen: pick an existing slot
# file of the right type (slots already used in this web / view are greyed out with the reason, free slots first),
# or type a name to create a new slot file in the slot directory. Esc closes it without changes.
#

var _title: Label
var _list: ItemList
var _name_edit: LineEdit
var _error: Label

var _kind: int
var _slots: Array = []
var _on_chosen: Callable


func _init() -> void:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 0)
	add_child(box)

	_title = Label.new()
	_title.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	box.add_child(_title)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 180)
	_list.item_selected.connect(_on_item_selected)
	box.add_child(_list)

	var row := HBoxContainer.new()
	box.add_child(row)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "New slot name"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(_t): _create())
	_name_edit.text_changed.connect(func(_t): _error.text = "")
	row.add_child(_name_edit)
	var create := Button.new()
	create.text = "Create"
	create.pressed.connect(_create)
	row.add_child(create)

	_error = Label.new()
	_error.add_theme_color_override("font_color", WeaverProtoStyle.INVALID)
	box.add_child(_error)


# used: slot -> reason it can't be picked. extra_slots: in-memory slots the model already uses (demo slots).
func open(kind: int, title: String, used: Dictionary, extra_slots: Array, on_chosen: Callable, near: Rect2) -> void:
	_kind = kind
	_on_chosen = on_chosen
	_title.text = title
	_name_edit.text = ""
	_error.text = ""

	_slots.clear()
	for path in WeaverSlotLibrary.find_slot_files(kind):
		var slot := load(path)
		if slot != null:
			_slots.append(slot)
	for slot in extra_slots:
		if slot != null and not _slots.has(slot):
			_slots.append(slot)
	_slots.sort_custom(func(a, b):
		if used.has(a) != used.has(b):
			return not used.has(a)
		return WeaverProtoModel.slot_name(a).naturalnocasecmp_to(WeaverProtoModel.slot_name(b)) < 0)

	_list.clear()
	var icon := WeaverProtoStyle.editor_icon("SubViewport" if kind == WeaverSlotLibrary.KIND_VIEW else "Camera3D")
	for slot in _slots:
		var text := WeaverProtoModel.slot_name(slot)
		if slot.resource_path.is_empty():
			text += "  (unsaved)"
		var index := _list.add_item(text, icon)
		if used.has(slot):
			_list.set_item_text(index, "%s  ·  %s" % [text, used[slot]])
			_list.set_item_disabled(index, true)
			_list.set_item_tooltip(index, used[slot])
		else:
			_list.set_item_tooltip(index, slot.resource_path if not slot.resource_path.is_empty() else "Demo slot kept in memory.")
	if _slots.is_empty():
		_error.text = ""
		_title.text += "\nNo slot files yet. Create one below."

	reset_size()
	popup(Rect2i(Vector2i(near.position + Vector2(0, near.size.y)), Vector2i.ZERO))
	_name_edit.grab_focus()


func _on_item_selected(index: int) -> void:
	if _list.is_item_disabled(index):
		_list.deselect(index)
		return
	_choose(_slots[index])

func _create() -> void:
	var slot_name := _name_edit.text.strip_edges()
	if slot_name.is_empty():
		_error.text = "Enter a slot name first."
		return
	var slot := WeaverSlotLibrary.create_slot(_kind, slot_name)
	if slot == null:
		_error.text = "Couldn't save the slot. See the Output panel."
		return
	_choose(slot)

func _choose(slot: Resource) -> void:
	hide()
	if _on_chosen.is_valid():
		_on_chosen.call(slot)
