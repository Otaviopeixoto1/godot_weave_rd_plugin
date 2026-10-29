@tool
extends VBoxContainer
class_name WeaverProtoMatrix

#
# Resource matrix for one frame path (one lane per view). Columns are nodes in execution order,
# rows are the resources those nodes own. W = owner, R = bound reader. Empty cells can be clicked
# to bind, R cells to unbind. Cells that would break ordering are disabled and explain why.
#

const CELL_SIZE := Vector2(110, 28)

var model: WeaverProtoModel
var canvas: WeaverProtoCanvas

var _path_bar: HBoxContainer
var _grid: GridContainer
var _empty_hint: Label
var _row_labels := {} # resource key -> Label


func setup(p_model: WeaverProtoModel, p_canvas: WeaverProtoCanvas) -> WeaverProtoMatrix:
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
	_empty_hint.text = "No resources on this frame path. Add one with + res on a node card."
	_empty_hint.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	scroll_box.add_child(_empty_hint)

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
	corner.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	_grid.add_child(corner)
	for node_id in path:
		_grid.add_child(_make_header(node_id))

	var row_count := 0
	for producer in path:
		for resource in model.nodes[producer].resources:
			_add_row(path, producer, resource)
			row_count += 1
	_empty_hint.visible = row_count == 0


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
		view_label.text = "  " + WeaverProtoModel.slot_name(view.slot)
		view_label.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
		_path_bar.add_child(view_label)
		var picker := OptionButton.new()
		picker.focus_mode = Control.FOCUS_NONE
		for lane in lanes:
			picker.add_icon_item(WeaverProtoStyle.editor_icon("Camera3D"), WeaverProtoModel.slot_name(lane.slot))
		picker.select(clampi(view.path_lane, 0, lanes.size() - 1))
		var view_id: int = view.id
		picker.item_selected.connect(func(index): model.set_path_lane(view_id, index))
		_path_bar.add_child(picker)


func _make_header(node_id: int) -> Control:
	var loc := model.locate(node_id)
	var label := Label.new()
	label.text = "V%d · %s\n#%d %s" % [loc.view, WeaverProtoModel.STAGE_SHORT[loc.stage], model.lane_order_index(node_id), model.node_name(node_id)]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size.x = CELL_SIZE.x
	label.clip_text = true
	return label

func _add_row(path: Array, producer: int, resource: String) -> void:
	var key := WeaverProtoModel.resource_key(producer, resource)
	var row_label := Label.new()
	row_label.text = "%s.%s" % [model.node_name(producer), resource]
	row_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row_label.mouse_entered.connect(func(): canvas.set_highlight(producer, resource))
	row_label.mouse_exited.connect(func(): canvas.set_highlight(-1, ""))
	_grid.add_child(row_label)
	_row_labels[key] = row_label

	# Lifetime: from the owner's column to the last column that reads the resource.
	var first := path.find(producer)
	var last := first
	for i in path.size():
		if model.is_bound(producer, resource, path[i]):
			last = maxi(last, i)

	for i in path.size():
		_grid.add_child(_make_cell(producer, resource, path[i], i > first and i < last))

func _make_cell(producer: int, resource: String, node_id: int, in_lifetime: bool) -> Button:
	var color := WeaverProtoModel.resource_color(producer, resource)
	var cell := Button.new()
	cell.custom_minimum_size = CELL_SIZE
	cell.focus_mode = Control.FOCUS_NONE
	cell.mouse_entered.connect(func(): canvas.set_highlight(producer, resource))
	cell.mouse_exited.connect(func(): canvas.set_highlight(-1, ""))

	var error := model.bind_error(producer, node_id)
	var style: StyleBoxFlat
	if node_id == producer:
		cell.text = "W"
		cell.tooltip_text = "Owned by \"%s\"." % model.node_name(producer)
		cell.add_theme_color_override("font_color", WeaverProtoStyle.DARK_TEXT)
		cell.add_theme_color_override("font_hover_color", WeaverProtoStyle.DARK_TEXT)
		style = WeaverProtoStyle.box(color, Color.TRANSPARENT, 0, 4, 2)
	elif model.is_bound(producer, resource, node_id):
		cell.text = "R" if error.is_empty() else "R !"
		cell.tooltip_text = "Click to unbind." if error.is_empty() else "Broken binding: %s Click to unbind." % error
		style = WeaverProtoStyle.box(Color(color, 0.2), color if error.is_empty() else WeaverProtoStyle.INVALID, 2, 4, 2)
		cell.pressed.connect(func(): model.unbind(producer, resource, node_id))
	elif error.is_empty():
		cell.tooltip_text = "Click to bind \"%s\" to %s." % [model.node_name(node_id), resource]
		style = WeaverProtoStyle.box(Color(color, 0.12 if in_lifetime else 0.0), Color(1, 1, 1, 0.12), 1, 4, 2)
		cell.pressed.connect(func(): model.bind(producer, resource, node_id))
	else:
		cell.text = "–"
		cell.tooltip_text = error
		cell.disabled = true
		style = WeaverProtoStyle.box(Color(0, 0, 0, 0.25), Color.TRANSPARENT, 0, 4, 2)
	WeaverProtoStyle.apply_button(cell, style)
	return cell


func _on_highlight_changed(producer: int, resource: String) -> void:
	var key := WeaverProtoModel.resource_key(producer, resource)
	for label_key in _row_labels:
		var label: Label = _row_labels[label_key]
		if label_key == key:
			label.add_theme_color_override("font_color", WeaverProtoModel.resource_color(producer, resource))
		else:
			label.remove_theme_color_override("font_color")
