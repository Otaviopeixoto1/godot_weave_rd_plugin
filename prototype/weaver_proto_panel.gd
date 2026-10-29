@tool
extends VBoxContainer
class_name WeaverProtoPanel

#
# Root of the WeaveRD main screen: a toolbar, the canvas on top and the resource matrix below. Both are rebuilt from
# WeaverProtoModel whenever it changes.
#
# The toolbar's Web menu picks the WeaverWeb being edited: any web saved in the project, Open... (file picker) or
# New... (creates and saves an empty web). Edits are written to the web right away and saved with Save, Ctrl+S or
# Save All in the editor; switching to another web saves the current one first. The last opened web is reopened
# the next time the editor starts.
# Frame resources and their bindings are still prototype data kept in memory (see WeaverProtoModel).
#

enum WebMenuId { NEW = 1000, OPEN, SHOW, INSPECT, CLOSE }

var model := WeaverProtoModel.new()

var _canvas: WeaverProtoCanvas
var _matrix: WeaverProtoMatrix
var _status: Label
var _web_menu: MenuButton
var _add_view: Button
var _save: Button
var _reload: Button
var _issues: Label
var _open_dialog: EditorFileDialog
var _new_dialog: EditorFileDialog
var _menu_webs: PackedStringArray = []


func _init() -> void:
	name = "WeaveRDPrototype"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	add_child(toolbar)

	_web_menu = MenuButton.new()
	_web_menu.flat = false
	_web_menu.icon = WeaverProtoStyle.editor_icon("Load")
	_web_menu.tooltip_text = "The WeaverWeb being edited. Pick a saved web, open one from a file or create a new one."
	_web_menu.about_to_popup.connect(_fill_web_menu)
	_web_menu.get_popup().id_pressed.connect(_on_web_menu_id_pressed)
	toolbar.add_child(_web_menu)

	_save = Button.new()
	_save.text = "Save"
	_save.tooltip_text = "Save the web to its file (Ctrl+S in the editor also saves it)."
	_save.pressed.connect(save_web)
	toolbar.add_child(_save)

	_reload = Button.new()
	_reload.icon = WeaverProtoStyle.editor_icon("Reload")
	_reload.tooltip_text = "Parse the web again, e.g. after editing it in the Inspector."
	_reload.pressed.connect(model.reload)
	toolbar.add_child(_reload)

	toolbar.add_child(VSeparator.new())

	_add_view = Button.new()
	_add_view.text = "+ View"
	_add_view.tooltip_text = "Add a view: pick or create its view slot. Views render left to right."
	_add_view.pressed.connect(func(): _canvas.pick_view_slot(_add_view))
	toolbar.add_child(_add_view)

	_issues = Label.new()
	_issues.mouse_filter = Control.MOUSE_FILTER_PASS
	toolbar.add_child(_issues)

	var note := Label.new()
	note.text = "Frame resources (chips) are prototype data: not saved. Hover a chip to see its links, drag it onto a card to bind."
	note.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	note.clip_text = true
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.mouse_filter = Control.MOUSE_FILTER_PASS
	note.tooltip_text = note.text
	toolbar.add_child(note)
	_status = Label.new()
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

	_open_dialog = _make_dialog(EditorFileDialog.FILE_MODE_OPEN_FILE, "Open a WeaverWeb")
	_open_dialog.file_selected.connect(open_web_path)
	_new_dialog = _make_dialog(EditorFileDialog.FILE_MODE_SAVE_FILE, "Create a new WeaverWeb")
	_new_dialog.file_selected.connect(create_web)

	model.changed.connect(_rebuild, CONNECT_DEFERRED)
	model.dirty_changed.connect(func(_d): _update_toolbar())
	_rebuild()


# Same entry points as WeaverEditorScene so the plugin can swap between them.
func setup_for_plugin() -> void:
	var cache := WeaverStateCache.WeaverEditorData.load_or_default()
	if cache.opened_web != null:
		open_web(cache.opened_web)

func cleanup_plugin() -> void:
	pass


func _notification(what: int) -> void:
	# Pick up edits made in the Inspector while the main screen was hidden.
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and model.has_web():
		model.reload()


#
# Web
#
func open_web(web: WeaverWeb) -> void:
	if web == model.web:
		model.reload()
		return
	if model.dirty:
		save_web()
	model.open_web(web)
	var cache := WeaverStateCache.WeaverEditorData.new()
	cache.opened_web = web
	cache.save()
	show_status("Opened %s" % model.web_name() if web != null else "", true)

func open_web_path(path: String) -> void:
	var web := ResourceLoader.load(path) as WeaverWeb
	if web == null:
		show_status("%s is not a WeaverWeb." % path.get_file(), false)
		return
	open_web(web)

# Creates an empty web at path, saves it and opens it.
func create_web(path: String) -> void:
	if path.get_extension().is_empty():
		path += ".tres"
	var web := WeaverWeb.new()
	web.resource_path = path
	var err := ResourceSaver.save(web, path)
	if err != OK:
		show_status("Couldn't save %s (%s)." % [path, error_string(err)], false)
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	open_web(web)

func save_web() -> void:
	if not model.has_web():
		return
	var err := model.save()
	if err == OK:
		EditorInterface.get_resource_filesystem().update_file(model.web.resource_path)
		show_status("Saved %s" % model.web_name(), true)
	else:
		show_status("Couldn't save %s (%s)." % [model.web_name(), error_string(err)], false)

func has_unsaved_web() -> bool:
	return model.has_web() and model.dirty

func show_status(text: String, ok: bool) -> void:
	_on_status_changed(text, ok)


func _make_dialog(mode: EditorFileDialog.FileMode, title: String) -> EditorFileDialog:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = mode
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.title = title
	dialog.add_filter("*.tres", "WeaverWeb (text)")
	dialog.add_filter("*.res", "WeaverWeb (binary)")
	add_child(dialog)
	return dialog

func _fill_web_menu() -> void:
	var popup := _web_menu.get_popup()
	popup.clear()
	_menu_webs = WeaverSlotLibrary.find_webs()
	if _menu_webs.is_empty():
		popup.add_item("No WeaverWeb saved in the project")
		popup.set_item_disabled(popup.item_count - 1, true)
	for i in _menu_webs.size():
		popup.add_radio_check_item(_menu_webs[i].trim_prefix("res://"), i)
		popup.set_item_checked(popup.item_count - 1, model.has_web() and model.web.resource_path == _menu_webs[i])
	popup.add_separator()
	popup.add_icon_item(WeaverProtoStyle.editor_icon("New"), "New web...", WebMenuId.NEW)
	popup.add_icon_item(WeaverProtoStyle.editor_icon("Load"), "Open...", WebMenuId.OPEN)
	popup.add_separator()
	popup.add_item("Edit in the Inspector", WebMenuId.INSPECT)
	popup.add_item("Show in FileSystem", WebMenuId.SHOW)
	popup.add_item("Close web", WebMenuId.CLOSE)
	for id in [WebMenuId.INSPECT, WebMenuId.SHOW, WebMenuId.CLOSE]:
		popup.set_item_disabled(popup.get_item_index(id), not model.has_web())

func _on_web_menu_id_pressed(id: int) -> void:
	match id:
		WebMenuId.NEW:
			_new_dialog.current_file = "new_web.tres"
			_new_dialog.popup_file_dialog()
		WebMenuId.OPEN:
			_open_dialog.popup_file_dialog()
		WebMenuId.INSPECT:
			EditorInterface.edit_resource(model.web)
		WebMenuId.SHOW:
			EditorInterface.select_file(model.web.resource_path)
		WebMenuId.CLOSE:
			open_web(null)
		_:
			if id >= 0 and id < _menu_webs.size():
				open_web_path(_menu_webs[id])


func _rebuild() -> void:
	_update_toolbar()
	_canvas.rebuild()
	_matrix.rebuild()

func _update_toolbar() -> void:
	var has_web := model.has_web()
	_web_menu.text = "Web: %s%s" % [model.web_name(), " (*)" if model.dirty else ""]
	_web_menu.tooltip_text = (model.web.resource_path if has_web else "No web open.") + "\nPick a saved web, open one from a file or create a new one."
	_save.disabled = not has_web or not model.dirty
	_reload.disabled = not has_web
	_add_view.disabled = not has_web

	# Problems that stop the web from binding to a scene (WeaverWeb.validate()).
	var errors := 0
	var lines: PackedStringArray = []
	if has_web:
		for issue in model.web.validate():
			if issue.severity == "error":
				errors += 1
			lines.append("%s: %s" % [String(issue.severity).capitalize(), issue.message])
	_issues.visible = not lines.is_empty()
	_issues.text = "%d issue%s" % [lines.size(), "" if lines.size() == 1 else "s"]
	_issues.tooltip_text = "\n".join(lines)
	_issues.add_theme_color_override("font_color", WeaverProtoStyle.INVALID if errors > 0 else WeaverProtoStyle.MUTED_TEXT)

func _on_status_changed(text: String, ok: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", WeaverProtoStyle.VALID if ok else WeaverProtoStyle.INVALID)
