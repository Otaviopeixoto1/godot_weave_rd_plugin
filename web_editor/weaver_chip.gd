@tool
extends PanelContainer
class_name WeaverChip

#
# A resource chip (lane resources, shared resources, slot bindings, shared tracks). The look says what it is:
#  - SOLID: a resource a lane has or provides, or a shared resource at its source view.
#  - OUTLINE: a slot that reads or writes it.
#  - DASHED: a place it can go (an empty slot, a lane that must provide it, a view where it is available).
# Any chip with a resource can be dragged into a slot. Hovering highlights every chip of the same resource.
# A chip can also accept drops (on_can_drop / on_drop), and run actions when clicked (on_click, on_context for right click).
#

enum Look { SOLID, OUTLINE, DASHED }

var canvas: WeaverCanvas
var resource: Resource # null for chips that only stand for a place
var on_click: Callable
var on_context: Callable # Right click.
var on_can_drop: Callable # (data) -> String: "" when the drop is accepted, otherwise why not
var on_drop: Callable # (data)

var _label: Label


func setup(p_canvas: WeaverCanvas, p_resource: Resource, text: String, look: Look, tooltip: String, error := false, on_close := Callable(),
		close_tooltip := "") -> WeaverChip:
	canvas = p_canvas
	resource = p_resource
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = tooltip

	var color := WeaverModel.resource_color(resource) if resource != null else WeaverStyle.MUTED_TEXT
	var text_color := WeaverStyle.DARK_TEXT
	match look:
		Look.SOLID:
			add_theme_stylebox_override("panel", WeaverStyle.box(color, WeaverStyle.INVALID if error else Color.TRANSPARENT, 2 if error else 0, 8, 3))
		Look.OUTLINE:
			add_theme_stylebox_override("panel", WeaverStyle.box(Color(color, 0.15), WeaverStyle.INVALID if error else color, 1, 8, 3))
			text_color = Color.WHITE
		Look.DASHED:
			add_theme_stylebox_override("panel", WeaverStyle.box(Color.TRANSPARENT, WeaverStyle.INVALID if error else Color(1, 1, 1, 0.25), 1, 8, 3))
			text_color = WeaverStyle.INVALID if error else WeaverStyle.MUTED_TEXT

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	add_child(row)
	_label = Label.new()
	_label.text = ("! " if error and look != Look.DASHED else "") + text
	_label.add_theme_color_override("font_color", text_color)
	_label.add_theme_font_size_override("font_size", 12)
	row.add_child(_label)
	if on_close.is_valid():
		var close := WeaverStyle.small_button("×", close_tooltip)
		close.add_theme_color_override("font_color", text_color)
		close.pressed.connect(on_close)
		row.add_child(close)

	if resource != null:
		mouse_entered.connect(func(): canvas.set_highlight(resource))
		mouse_exited.connect(func(): canvas.set_highlight(null))
		canvas.register_chip(self)
	return self


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and on_click.is_valid():
		on_click.call()
		accept_event()
	elif mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and on_context.is_valid():
		on_context.call()
		accept_event()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if resource == null:
		return null
	var preview := Label.new()
	preview.text = WeaverModel.display_name(resource)
	set_drag_preview(preview)
	canvas.begin_resource_drag(resource)
	return { "kind": "weave_resource", "resource": resource }


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if on_can_drop.is_valid():
		var error: String = on_can_drop.call(data)
		canvas.show_status(error if not error.is_empty() else "Drop to apply", error.is_empty())
		return error.is_empty()
	# Drops on a chip of a slot row go to the row.
	var row := get_parent()
	if row is WeaverSlotRow:
		return row.can_accept(data)
	return false

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if on_drop.is_valid():
		on_drop.call(data)
		return
	var row := get_parent()
	if row is WeaverSlotRow:
		row.accept(data)
