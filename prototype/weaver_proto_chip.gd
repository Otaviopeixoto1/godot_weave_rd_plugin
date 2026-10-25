@tool
extends PanelContainer
class_name WeaverProtoChip

#
# A resource chip on a node card. Owned chips (solid) are resources the card's node produces.
# Read chips (outlined) are resources the node is bound to. Any chip can be dragged onto another
# card to bind that card's node to the same resource. Hovering a chip highlights its links.
#

var canvas: WeaverProtoCanvas
var card: WeaverProtoCard
var producer: int
var resource: String
var consumer := -1  # -1 for an owned chip, otherwise the node reading the resource


func setup(p_canvas: WeaverProtoCanvas, p_card: WeaverProtoCard, p_producer: int, p_resource: String, p_consumer: int = -1) -> WeaverProtoChip:
	canvas = p_canvas
	card = p_card
	producer = p_producer
	resource = p_resource
	consumer = p_consumer
	mouse_filter = Control.MOUSE_FILTER_STOP

	var model := canvas.model
	var color := WeaverProtoModel.resource_color(producer, resource)
	var error := "" if consumer < 0 else model.bind_error(producer, consumer)

	var label := Label.new()
	var close := WeaverProtoStyle.small_button("×", "")
	if consumer < 0:
		label.text = resource
		label.add_theme_color_override("font_color", WeaverProtoStyle.DARK_TEXT)
		close.add_theme_color_override("font_color", WeaverProtoStyle.DARK_TEXT)
		add_theme_stylebox_override("panel", WeaverProtoStyle.box(color, Color.TRANSPARENT, 0, 8, 3))
		tooltip_text = "Owned by \"%s\". Drag onto a later node to bind it." % model.node_name(producer)
		close.tooltip_text = "Delete this placeholder resource"
		close.pressed.connect(func(): model.remove_resource(producer, resource))
	else:
		label.text = "%s.%s" % [model.node_name(producer), resource]
		var border := color if error.is_empty() else WeaverProtoStyle.INVALID
		add_theme_stylebox_override("panel", WeaverProtoStyle.box(Color(color, 0.15), border, 1, 8, 3))
		if error.is_empty():
			tooltip_text = "Reads %s from \"%s\"." % [resource, model.node_name(producer)]
		else:
			label.text = "! " + label.text
			tooltip_text = "Broken binding: " + error
		close.tooltip_text = "Unbind"
		close.pressed.connect(func(): model.unbind(producer, resource, consumer))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(label)
	row.add_child(close)
	add_child(row)

	mouse_entered.connect(func(): canvas.set_highlight(producer, resource))
	mouse_exited.connect(func(): canvas.set_highlight(-1, ""))
	canvas.register_chip(self)
	return self


func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview := Label.new()
	preview.text = "%s.%s" % [canvas.model.node_name(producer), resource]
	set_drag_preview(preview)
	canvas.begin_chip_drag(producer, resource)
	return { "kind": "weave_chip", "producer": producer, "resource": resource }

# Drops that land on a chip go to the card that holds it.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return card.can_accept(data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	card.accept(data)
