@tool
extends PanelContainer
class_name WeaverProtoCard

#
# A card for one entry of a WeaverSpider (a WeaverWebNode or a plain CompositorEffect). Drag the card to move it to
# another stage column (or lane/view). Right-click the title to rename the node. Double-click the card or use the edit
# button to open the resource in the Inspector, the script button attaches/edits its script or changes its class (WeaverProtoNodeScripts).
# Drop a resource chip on it to bind the node to that resource.
#

enum DropState { NONE, VALID, INVALID }
enum ScriptMenu { EDIT, ATTACH, DETACH, CHANGE_CLASS }

var canvas: WeaverProtoCanvas
var column: WeaverProtoColumn
var node_id: int

var _style: StyleBoxFlat


func setup(p_canvas: WeaverProtoCanvas, p_column: WeaverProtoColumn, p_node_id: int) -> WeaverProtoCard:
	canvas = p_canvas
	column = p_column
	node_id = p_node_id
	mouse_filter = Control.MOUSE_FILTER_STOP

	var model := canvas.model
	_style = WeaverProtoStyle.box(WeaverProtoStyle.CARD_BG, WeaverProtoStyle.CARD_BORDER)
	add_theme_stylebox_override("panel", _style)

	var box := VBoxContainer.new()
	add_child(box)

	#
	# Header
	#
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 4)
	box.add_child(title_row)
	
	var title := Label.new()
	title.text = model.node_name(node_id)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = false
	title.tooltip_text = "%s\nDrag to move this node to another stage, lane, or view. Right-click to rename it." % model.node_resource(node_id).get_class()
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title_row.add_child(title)
	
	title.gui_input.connect(_on_title_gui_input.bind(title))

	if model.is_plain_effect(node_id):
		var tag := Label.new()
		tag.text = "effect"
		tag.tooltip_text = "Plain CompositorEffect: runs as is, it has no setup/cleanup hooks."
		tag.mouse_filter = Control.MOUSE_FILTER_PASS
		tag.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
		title_row.add_child(tag)
	
	var buttons_row := HBoxContainer.new()
	buttons_row.add_theme_constant_override("separation", 0)
	title_row.add_child(buttons_row)
	
	buttons_row.add_child(_make_script_button())
	
	var edit_button := WeaverProtoStyle.small_button("", "Edit in the Inspector")
	edit_button.icon = WeaverProtoStyle.editor_icon("Edit")
	edit_button.pressed.connect(func(): canvas.inspect_node(node_id))
	buttons_row.add_child(edit_button)
	
	var delete_button := WeaverProtoStyle.small_button("×", "Remove the node from the WeaverSpider")
	delete_button.pressed.connect(func(): model.remove_node(node_id))
	buttons_row.add_child(delete_button)
	
	
	#
	# Content
	#
	# TODO: Make this the "Creates" Section. Add labels
	var owns := HFlowContainer.new()
	owns.add_theme_constant_override("h_separation", 4)
	owns.add_theme_constant_override("v_separation", 4)
	box.add_child(owns)
	for resource in model.nodes[node_id].resources:
		owns.add_child(WeaverProtoChip.new().setup(canvas, self, node_id, resource))
	
	var add_button := WeaverProtoStyle.small_button("+ res", "Add a frame resource (prototype: kept in memory, not saved in the web)")
	add_button.pressed.connect(func(): model.add_resource(node_id))
	owns.add_child(add_button)
	
	#
	# TODO: ADD a "Writes" Section
	#
	
	var reads := model.bindings_of_consumer(node_id)
	if not reads.is_empty():
		var reads_label := Label.new()
		reads_label.text = "reads"
		reads_label.add_theme_color_override("font_color", WeaverProtoStyle.MUTED_TEXT)
		box.add_child(reads_label)
		var reads_box := HFlowContainer.new()
		reads_box.add_theme_constant_override("h_separation", 4)
		reads_box.add_theme_constant_override("v_separation", 4)
		box.add_child(reads_box)
		for b in reads:
			reads_box.add_child(WeaverProtoChip.new().setup(canvas, self, b.producer, b.resource, node_id))
	
	
	canvas.register_card(self)
	return self

#func _on_card

# Script menu: attach a new or existing script (WeaverWebNode-based), edit / detach it, or change the node's class.
# The icon shows whether a script is attached.
func _make_script_button() -> MenuButton:
	var res := canvas.model.node_resource(node_id)
	var script := res.get_script() as Script
	var button := MenuButton.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.icon = WeaverProtoStyle.editor_icon("Script" if script != null else "ScriptCreate")
	if script != null:
		button.tooltip_text = "Script: %s" % (script.resource_path if not script.resource_path.is_empty() else "built-in")
	else:
		button.tooltip_text = "Attach a script to customize the rendering (_setup, _render, _cleanup)."

	var popup := button.get_popup()
	var scripts := canvas.node_scripts
	if script != null:
		popup.add_icon_item(WeaverProtoStyle.editor_icon("Script"), "Edit Script", ScriptMenu.EDIT)
		popup.add_icon_item(WeaverProtoStyle.editor_icon("ScriptCreate"), "Attach Another Script...", ScriptMenu.ATTACH)
		popup.add_icon_item(WeaverProtoStyle.editor_icon("ScriptRemove"), "Detach Script", ScriptMenu.DETACH)
	else:
		popup.add_icon_item(WeaverProtoStyle.editor_icon("ScriptCreate"), "Attach Script...", ScriptMenu.ATTACH)
	if res is WeaverWebNode:
		popup.add_separator()
		popup.add_icon_item(WeaverProtoStyle.editor_icon("RotateLeft"), "Change Class...", ScriptMenu.CHANGE_CLASS)
	popup.id_pressed.connect(func(id: int):
		match id:
			ScriptMenu.EDIT: scripts.edit_script(node_id)
			ScriptMenu.ATTACH: scripts.attach_script(node_id)
			ScriptMenu.DETACH: scripts.detach_script(node_id)
			ScriptMenu.CHANGE_CLASS: scripts.change_class(node_id)
	)
	return button


func set_drop_state(state: DropState) -> void:
	match state:
		DropState.VALID:
			_style.border_color = WeaverProtoStyle.VALID
			_style.set_border_width_all(2)
			modulate = Color.WHITE
		DropState.INVALID:
			_style.border_color = WeaverProtoStyle.CARD_BORDER
			_style.set_border_width_all(1)
			modulate = Color(1, 1, 1, 0.4)
		_:
			_style.border_color = WeaverProtoStyle.CARD_BORDER
			_style.set_border_width_all(1)
			modulate = Color.WHITE


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
		canvas.inspect_node(node_id)
		accept_event()

func _on_title_gui_input(event: InputEvent, title: Label) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		canvas.rename_node(node_id)
		title.accept_event()


func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview := Label.new()
	preview.text = canvas.model.node_name(node_id)
	set_drag_preview(preview)
	return { "kind": "weave_card", "node": node_id }

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return can_accept(data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	accept(data)


func can_accept(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	match data.get("kind"):
		"weave_chip":
			var model := canvas.model
			var error := model.bind_error(data.producer, node_id)
			if error.is_empty() and model.is_bound(data.producer, data.resource, node_id):
				error = "Already bound."
			if error.is_empty():
				canvas.show_status("Bind %s.%s to \"%s\"" % [model.node_name(data.producer), data.resource, model.node_name(node_id)], true)
			else:
				canvas.show_status("Can't bind: " + error, false)
			return error.is_empty()
		"weave_card":
			return column.can_accept(data)
	return false

func accept(data: Variant) -> void:
	match data.get("kind"):
		"weave_chip":
			canvas.model.bind(data.producer, data.resource, node_id)
		"weave_card":
			column.accept(data)
