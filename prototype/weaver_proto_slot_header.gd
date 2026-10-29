@tool
extends PanelContainer
class_name WeaverProtoSlotHeader

#
# Header of a view column or lane. The header IS the slot: it shows the slot's name with a type icon and color
# (view = viewport/purple, camera = camera/teal) and its state. Double-click renames the slot, right-click opens
# Change slot / Rename / Show in FileSystem.
#
# States: no slot (red, "Assign"), duplicate (red), missing file (broken link), shared with saved webs (link icon),
# unsaved (in-memory demo slot, muted).
#

signal change_requested
signal rename_requested

enum MenuId { CHANGE, RENAME, SHOW }

var kind: int
var slot: Resource

var _menu: PopupMenu


func setup(p_kind: int, p_slot: Resource, error: String, webs: PackedStringArray, prefix: String = "") -> WeaverProtoSlotHeader:
	kind = p_kind
	slot = p_slot
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var color := WeaverProtoStyle.VIEW_SLOT if kind == WeaverSlotLibrary.KIND_VIEW else WeaverProtoStyle.CAMERA_SLOT
	var border := WeaverProtoStyle.INVALID if not error.is_empty() else color
	add_theme_stylebox_override("panel", WeaverProtoStyle.box(Color(color, 0.22), border, 2 if not error.is_empty() else 1, 6, 4))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	row.add_child(_icon("SubViewport" if kind == WeaverSlotLibrary.KIND_VIEW else "Camera3D"))

	var label := Label.new()
	label.text = prefix + WeaverProtoModel.slot_name(slot)
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)

	var type_text := "View slot" if kind == WeaverSlotLibrary.KIND_VIEW else "Camera slot"
	var tips: PackedStringArray = []

	if slot == null:
		label.add_theme_color_override("font_color", WeaverProtoStyle.INVALID)
		row.add_child(_icon("NodeWarning"))
		var assign := WeaverProtoStyle.small_button("Assign", "Pick a slot for this %s" % ("view" if kind == WeaverSlotLibrary.KIND_VIEW else "lane"))
		assign.add_theme_color_override("font_color", WeaverProtoStyle.INVALID)
		assign.pressed.connect(func(): change_requested.emit())
		row.add_child(assign)
		tips.append(error)
	else:
		tips.append("%s · %s" % [type_text, slot.resource_path if not slot.resource_path.is_empty() else "not saved to a file"])
		if not error.is_empty():
			var missing := error.begins_with("The slot file")
			row.add_child(_icon("Unlinked" if missing else "StatusError"))
			tips.append(error)
		if slot.resource_path.is_empty():
			label.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
			label.text += "  (unsaved)"
			tips.append("Demo slot kept in memory. Use Change slot to pick or create a slot file.")
		if not webs.is_empty():
			var link := _icon("Instance")
			link.tooltip_text = "Shared with: " + ", ".join(webs)
			row.add_child(link)
			tips.append("Shared with: %s. Renaming it renames it there too." % ", ".join(webs))
		tips.append("Double-click to rename, right-click for more.")
	tooltip_text = "\n".join(tips)

	_menu = PopupMenu.new()
	_menu.add_item("Change slot...", MenuId.CHANGE)
	_menu.add_item("Rename...", MenuId.RENAME)
	_menu.add_item("Show in FileSystem", MenuId.SHOW)
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)
	return self


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		if slot == null:
			change_requested.emit()
		else:
			rename_requested.emit()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		_menu.set_item_disabled(_menu.get_item_index(MenuId.RENAME), slot == null)
		_menu.set_item_disabled(_menu.get_item_index(MenuId.SHOW), slot == null or slot.resource_path.is_empty())
		_menu.reset_size()
		_menu.popup(Rect2i(Vector2i(get_screen_position() + mb.position), Vector2i.ZERO))
		accept_event()


func _on_menu_id_pressed(id: int) -> void:
	match id:
		MenuId.CHANGE:
			change_requested.emit()
		MenuId.RENAME:
			rename_requested.emit()
		MenuId.SHOW:
			EditorInterface.select_file(slot.resource_path)


func _icon(icon_name: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = WeaverProtoStyle.editor_icon(icon_name)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_PASS
	return rect
