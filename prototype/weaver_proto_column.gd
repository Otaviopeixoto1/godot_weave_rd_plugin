@tool
extends PanelContainer
class_name WeaverProtoColumn

#
# One stage (EffectCallbackType) column inside a lane. Cards run top to bottom.
# Dropping a card here moves the node into this stage at the drop position.
#

var canvas: WeaverProtoCanvas
var view_id: int
var lane_id: int
var stage: int

var _list: VBoxContainer


func setup(p_canvas: WeaverProtoCanvas, p_view_id: int, p_lane_id: int, p_stage: int) -> WeaverProtoColumn:
	canvas = p_canvas
	view_id = p_view_id
	lane_id = p_lane_id
	stage = p_stage
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(180, 80)
	add_theme_stylebox_override("panel", WeaverProtoStyle.box(WeaverProtoStyle.COLUMN_BG))

	var box := VBoxContainer.new()
	add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var label := Label.new()
	label.text = WeaverProtoModel.STAGE_SHORT[stage]
	label.tooltip_text = WeaverProtoModel.STAGE_NAMES[stage]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)
	var add_button := WeaverProtoStyle.small_button("+", "Add a node to this stage")
	add_button.pressed.connect(func(): canvas.model.add_node(view_id, lane_id, stage))
	header.add_child(add_button)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	box.add_child(_list)
	var lane := canvas.model.get_lane(view_id, lane_id)
	for node_id in lane.columns[stage]:
		_list.add_child(WeaverProtoCard.new().setup(canvas, self, node_id))
	return self


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return can_accept(data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	accept(data)


func can_accept(data: Variant) -> bool:
	if not data is Dictionary or data.get("kind") != "weave_card":
		return false
	canvas.show_status("Move \"%s\" to %s" % [canvas.model.node_name(data.node), WeaverProtoModel.STAGE_NAMES[stage]], true)
	return true

func accept(data: Variant) -> void:
	canvas.model.move_node(data.node, view_id, lane_id, stage, _insert_index(get_global_mouse_position().y))


func _insert_index(global_y: float) -> int:
	var index := 0
	for card in _list.get_children():
		var rect := (card as Control).get_global_rect()
		if global_y < rect.get_center().y:
			return index
		index += 1
	return index
