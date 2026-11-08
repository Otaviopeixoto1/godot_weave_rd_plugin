@tool
extends VBoxContainer
class_name WeaverMatrix

#
# Resource matrix for one frame path (one lane per view). Columns are nodes in execution order, rows are the lane
# resources of the path's lanes and the shared resources (◆). A cell shows how the node's slot uses the resource:
# C (creates, v1), R (reads vN), W (writes vN→vN+1); red cells have an error from WeaverWeb.validate() (in the tooltip).
# Clicking a cell opens a menu: bind one of the node's slots that can take the resource (sharing it when it comes from an
# earlier view), rebind a stale slot to the newest version, or unbind.
#

const CELL_SIZE := Vector2(110, 28)
const ACCESS_LETTERS := ["R", "W", "C"]

var model: WeaverModel
var canvas: WeaverCanvas

var _path_bar: HBoxContainer
var _grid: GridContainer
var _empty_hint: Label
var _row_labels := {} # Resource -> Label
var _menu: PopupMenu
var _menu_actions: Array[Callable] = []


func setup(p_model: WeaverModel, p_canvas: WeaverCanvas) -> WeaverMatrix:
	model = p_model
	canvas = p_canvas

	_path_bar = HBoxContainer.new()
	add_child(_path_bar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var scroll_box := VBoxContainer.new()
	scroll.add_child(scroll_box)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	scroll_box.add_child(_grid)
	_empty_hint = Label.new()
	_empty_hint.text = "No resources on this frame path. Nodes with create slots make them."
	_empty_hint.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
	scroll_box.add_child(_empty_hint)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(func(id: int): _menu_actions[id].call())
	add_child(_menu)

	canvas.highlight_changed.connect(_on_highlight_changed)
	return self


func rebuild() -> void:
	_rebuild_path_bar()
	_row_labels.clear()
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()

	var path := model.execution_path()
	_grid.columns = path.size() + 1

	var corner := Label.new()
	corner.text = "Resource  \\  node"
	corner.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
	_grid.add_child(corner)
	for node_id in path:
		_grid.add_child(_make_header(node_id))

	var rows := 0
	var lanes := model.frame_path()
	for vi in model.views.size():
		if lanes[vi] < 0:
			continue
		var view: Dictionary = model.views[vi]
		var lane: Dictionary = view.lanes[lanes[vi]]
		for res in model.lane_resources(view.id, lane.id):
			_add_row(path, res, "V%d · %s" % [vi, res.resource_name])
			rows += 1
	for shared in model.shared_resources():
		_add_row(path, shared, "◆ " + shared.resource_name)
		rows += 1
	_empty_hint.visible = rows == 0


func _rebuild_path_bar() -> void:
	for child in _path_bar.get_children():
		_path_bar.remove_child(child)
		child.queue_free()
	var label := Label.new()
	label.text = "Frame path:"
	_path_bar.add_child(label)
	for view in model.views:
		var lanes: Array = view.lanes
		if lanes.is_empty():
			continue
		var view_label := Label.new()
		view_label.text = "  " + WeaverModel.slot_name(view.slot)
		view_label.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
		_path_bar.add_child(view_label)
		var picker := OptionButton.new()
		picker.focus_mode = Control.FOCUS_NONE
		for lane in lanes:
			picker.add_icon_item(WeaverStyle.editor_icon("Camera3D"), WeaverModel.slot_name(lane.slot))
		picker.select(clampi(view.path_lane, 0, lanes.size() - 1))
		var view_id: int = view.id
		picker.item_selected.connect(func(index): model.set_path_lane(view_id, index))
		_path_bar.add_child(picker)


func _make_header(node_id: int) -> Control:
	var loc := model.locate(node_id)
	var label := Label.new()
	label.text = "V%d · %s\n#%d %s" % [loc.view, WeaverModel.STAGE_SHORT[loc.stage], model.lane_order_index(node_id), model.node_name(node_id)]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size.x = CELL_SIZE.x
	label.clip_text = true
	return label


# The slots of a node bound to a resource.
func _bound_slots(node_id: int, res: Resource) -> Array:
	return model.node_slots(node_id).filter(func(s):
		var binding := model.slot_binding(node_id, s.name)
		return binding != null and binding.resource == res)


func _add_row(path: Array, res: Resource, text: String) -> void:
	var row_label := Label.new()
	row_label.text = text
	row_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row_label.tooltip_text = "%s %s" % ["Shared resource" if res is WeaverSharedResource else "Lane resource", res.resource_name]
	row_label.mouse_entered.connect(func(): canvas.set_highlight(res))
	row_label.mouse_exited.connect(func(): canvas.set_highlight(null))
	_grid.add_child(row_label)
	_row_labels[res] = row_label

	# Lifetime: from the first to the last node using it on this path.
	var first := -1
	var last := -1
	for i in path.size():
		if not _bound_slots(path[i], res).is_empty():
			first = i if first < 0 else first
			last = i
	for i in path.size():
		_grid.add_child(_make_cell(path[i], res, first >= 0 and i > first and i < last))


func _make_cell(node_id: int, res: Resource, in_lifetime: bool) -> Button:
	var color := WeaverModel.resource_color(res)
	var cell := Button.new()
	cell.custom_minimum_size = CELL_SIZE
	cell.focus_mode = Control.FOCUS_NONE
	cell.mouse_entered.connect(func(): canvas.set_highlight(res))
	cell.mouse_exited.connect(func(): canvas.set_highlight(null))

	var style: StyleBoxFlat
	var bound := _bound_slots(node_id, res)
	if not bound.is_empty():
		var parts := PackedStringArray()
		var tips := PackedStringArray()
		var error := false
		for s in bound:
			var version := model.slot_version_text(node_id, s.name)
			parts.append("%s %s" % [ACCESS_LETTERS[s.access], version])
			var issue := model.slot_issue(node_id, s.name)
			if not issue.is_empty():
				tips.append(String(issue.message))
				error = error or issue.severity == "error"
			else:
				tips.append("%s.%s %s." % [model.node_name(node_id), s.name, version])
		cell.text = ("! " if error else "") + " ".join(parts)
		cell.tooltip_text = "\n".join(tips) + "\nClick for options."
		var creates: bool = bound.any(func(s): return s.access == WeaverResourceHandle.ACCESS_CREATE)
		if creates:
			cell.add_theme_color_override("font_color", WeaverStyle.DARK_TEXT)
			cell.add_theme_color_override("font_hover_color", WeaverStyle.DARK_TEXT)
			style = WeaverStyle.box(color, WeaverStyle.INVALID if error else Color.TRANSPARENT, 2 if error else 0, 4, 2)
		else:
			style = WeaverStyle.box(Color(color, 0.2), WeaverStyle.INVALID if error else color, 2, 4, 2)
		cell.pressed.connect(_open_menu.bind(cell, node_id, res))
	else:
		var candidates := _candidates(node_id, res)
		if candidates.is_empty():
			cell.text = "–"
			cell.tooltip_text = _refusal(node_id, res)
			cell.disabled = true
			style = WeaverStyle.box(Color(0, 0, 0, 0.25), Color.TRANSPARENT, 0, 4, 2)
		else:
			cell.tooltip_text = "Click to bind %s to a slot of %s." % [res.resource_name, model.node_name(node_id)]
			style = WeaverStyle.box(Color(color, 0.12 if in_lifetime else 0.0), Color(1, 1, 1, 0.12), 1, 4, 2)
			cell.pressed.connect(_open_menu.bind(cell, node_id, res))
	WeaverStyle.apply_button(cell, style)
	return cell


# Slots of the node that can take the resource: [{ slot, action }].
func _candidates(node_id: int, res: Resource) -> Array:
	var result: Array = []
	for s in model.node_slots(node_id):
		var action := model.drop_action(node_id, s.name, res)
		if action.action != "refuse":
			result.append({ "slot": s, "action": action })
	return result

func _refusal(node_id: int, res: Resource) -> String:
	var slots := model.node_slots(node_id)
	if slots.is_empty():
		return "%s has no resource slots." % model.node_name(node_id)
	return model.drop_action(node_id, slots[0].name, res).reason


func _open_menu(cell: Control, node_id: int, res: Resource) -> void:
	_menu.clear()
	_menu_actions.clear()
	for s in _bound_slots(node_id, res):
		var slot_name: StringName = s.name
		var issue := model.slot_issue(node_id, slot_name)
		if not issue.is_empty() and issue.severity == "error" and "expects" in String(issue.message):
			_add_item("Rebind %s to the newest version" % slot_name, model.rebind_to_newest.bind(node_id, slot_name))
		if s.access != WeaverResourceHandle.ACCESS_CREATE:
			_add_item("Unbind %s" % slot_name, model.unbind_slot.bind(node_id, slot_name))
	for candidate in _candidates(node_id, res):
		var slot: Dictionary = candidate.slot
		var slot_name: StringName = slot.name
		var bound := model.slot_binding(node_id, slot_name)
		if bound != null and bound.resource == res:
			continue
		var replaces := " (replaces %s)" % bound.resource.resource_name if bound != null and bound.resource != null else ""
		if candidate.action.action == "share":
			_add_item("Share and bind to %s (%s)%s" % [slot_name, ACCESS_LETTERS[slot.access], replaces], canvas.confirm_share.bind(res, node_id, slot_name))
		else:
			_add_item("Bind to %s (%s)%s" % [slot_name, ACCESS_LETTERS[slot.access], replaces], func(): model.bind_slot(node_id, slot_name, res))
	if _menu_actions.is_empty():
		return
	var rect := cell.get_screen_position()
	_menu.position = Vector2i(rect + Vector2(0, cell.size.y))
	_menu.popup()

func _add_item(text: String, action: Callable) -> void:
	_menu.add_item(text, _menu_actions.size())
	_menu_actions.append(action)


func _on_highlight_changed(resource: Resource) -> void:
	for res in _row_labels:
		var label: Label = _row_labels[res]
		if res == resource:
			label.add_theme_color_override("font_color", WeaverModel.resource_color(res))
		else:
			label.remove_theme_color_override("font_color")
