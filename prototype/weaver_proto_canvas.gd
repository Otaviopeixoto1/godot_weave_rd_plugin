@tool
extends Control
class_name WeaverProtoCanvas

#
# Main canvas: views left to right in render order, lanes (spiders) stacked inside each view, and
# one column per stage inside each lane. Order is given by position only. Resource links are not
# drawn at rest: hovering a chip (or a matrix row) draws its links on a transparent overlay.
#

signal highlight_changed(producer: int, resource: String)
signal status_changed(text: String, ok: bool)

var model: WeaverProtoModel

var _scroll: ScrollContainer
var _views_box: HBoxContainer
var _overlay: Control

var _cards := {}     # node id -> WeaverProtoCard
var _out_chips := {} # resource key -> owned WeaverProtoChip
var _in_chips := {}  # resource key -> Array of read WeaverProtoChips

var _hl_producer := -1
var _hl_resource := ""


func _init() -> void:
	clip_contents = true

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)

	_views_box = HBoxContainer.new()
	_views_box.add_theme_constant_override("separation", 16)
	_scroll.add_child(_views_box)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_scroll.get_h_scroll_bar().value_changed.connect(func(_v): _overlay.queue_redraw())
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v): _overlay.queue_redraw())


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		for card in _cards.values():
			card.set_drop_state(WeaverProtoCard.DropState.NONE)
		show_status("", true)


func rebuild() -> void:
	_cards.clear()
	_out_chips.clear()
	_in_chips.clear()
	for child in _views_box.get_children():
		_views_box.remove_child(child)
		child.queue_free()

	for vi in model.views.size():
		_views_box.add_child(_build_view(model.views[vi], vi))

	if model.views.is_empty():
		var hint := Label.new()
		hint.text = "No views yet. Add one with + View."
		_views_box.add_child(hint)
	_overlay.queue_redraw()


#
# Called by cards and chips
#
func register_card(card: WeaverProtoCard) -> void:
	_cards[card.node_id] = card

func register_chip(chip: WeaverProtoChip) -> void:
	var key := WeaverProtoModel.resource_key(chip.producer, chip.resource)
	if chip.consumer < 0:
		_out_chips[key] = chip
	else:
		if not _in_chips.has(key):
			_in_chips[key] = []
		_in_chips[key].append(chip)

func set_highlight(producer: int, resource: String) -> void:
	if producer == _hl_producer and resource == _hl_resource:
		return
	_hl_producer = producer
	_hl_resource = resource
	_overlay.queue_redraw()
	highlight_changed.emit(producer, resource)

# Marks every card as a valid or invalid drop target while a chip is being dragged.
func begin_chip_drag(producer: int, resource: String) -> void:
	for node_id in _cards:
		var ok := model.bind_error(producer, node_id).is_empty() and not model.is_bound(producer, resource, node_id)
		_cards[node_id].set_drop_state(WeaverProtoCard.DropState.VALID if ok else WeaverProtoCard.DropState.INVALID)

func show_status(text: String, ok: bool) -> void:
	status_changed.emit(text, ok)


#
# Building
#
func _build_view(view: Dictionary, view_index: int) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", WeaverProtoStyle.box(Color.TRANSPARENT, WeaverProtoStyle.VIEW_BORDER, 1, 8, 10))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "View %d  ·  %s" % [view_index, view.name]
	title.tooltip_text = "Views render left to right. A node can read resources from any earlier view."
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var add_lane := WeaverProtoStyle.small_button("+ Lane", "Add a spider (camera slot) to this view")
	add_lane.pressed.connect(func(): model.add_lane(view.id))
	header.add_child(add_lane)

	var lanes: Array = view.lanes
	if lanes.is_empty():
		var hint := Label.new()
		hint.text = "No lanes yet. Add one with + Lane."
		hint.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
		box.add_child(hint)
	for li in lanes.size():
		box.add_child(_build_lane(view, li))
	return panel

func _build_lane(view: Dictionary, lane_index: int) -> Control:
	var lane: Dictionary = view.lanes[lane_index]
	var in_path: bool = clampi(view.path_lane, 0, (view.lanes as Array).size() - 1) == lane_index

	var panel := PanelContainer.new()
	var bg := WeaverProtoStyle.LANE_LIVE_BG if in_path else WeaverProtoStyle.LANE_IDLE_BG
	panel.add_theme_stylebox_override("panel", WeaverProtoStyle.box(bg, Color.TRANSPARENT, 0, 6, 6))

	var box := VBoxContainer.new()
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = lane.name
	title.tooltip_text = "Only one lane of a view runs per frame, so lanes can't share resources."
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	if in_path:
		var tag := Label.new()
		tag.text = "● in matrix"
		tag.add_theme_color_override("font_color", WeaverProtoStyle.VALID)
		header.add_child(tag)
	else:
		var show_button := WeaverProtoStyle.small_button("Show in matrix", "Use this lane for the view's frame path in the matrix")
		show_button.pressed.connect(func(): model.set_path_lane(view.id, lane_index))
		header.add_child(show_button)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 6)
	box.add_child(columns)
	for stage in WeaverProtoModel.STAGE_COUNT:
		columns.add_child(WeaverProtoColumn.new().setup(self, view.id, lane.id, stage))
	return panel


#
# Link overlay
#
func _draw_overlay() -> void:
	if _hl_producer < 0:
		return
	var key := WeaverProtoModel.resource_key(_hl_producer, _hl_resource)
	var source: Control = _out_chips.get(key)
	if source == null or not is_instance_valid(source):
		return
	var color := WeaverProtoModel.resource_color(_hl_producer, _hl_resource)
	var to_local := _overlay.get_global_transform().affine_inverse()

	var source_rect := to_local * source.get_global_rect()
	_overlay.draw_rect(source_rect.grow(2), color, false, 2.0)
	var start := Vector2(source_rect.end.x, source_rect.get_center().y)

	for chip in _in_chips.get(key, []):
		if not is_instance_valid(chip):
			continue
		var rect: Rect2 = to_local * (chip as Control).get_global_rect()
		var end := Vector2(rect.position.x, rect.get_center().y)
		var valid: bool = model.bind_error(_hl_producer, chip.consumer).is_empty()
		var link_color := color if valid else WeaverProtoStyle.INVALID
		var bend := maxf(60.0, absf(end.x - start.x) * 0.4)
		var points := PackedVector2Array()
		for i in 25:
			points.append(start.bezier_interpolate(start + Vector2(bend, 0), end - Vector2(bend, 0), end, i / 24.0))
		_overlay.draw_polyline(points, link_color, 2.0, true)
		_overlay.draw_rect(rect.grow(2), link_color, false, 2.0)
