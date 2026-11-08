@tool
extends HBoxContainer
class_name WeaverSlotRow

#
# One resource slot of a node card: access (C create, R read, W write), slot name, then the bound resource with its
# version, or a dashed target to drop a resource on. Drops are checked by WeaverModel.drop_action(): a resource of the
# same lane is bound, a resource of an earlier view is shared (after a confirmation), anything else is refused with the
# reason in the status bar. A stale binding (an older version than the newest) offers to rebind to the newest version.
#

const ACCESS_LETTERS := ["R", "W", "C"]
const ACCESS_NAMES := ["reads", "writes (read-modify-write)", "creates"]

var canvas: WeaverCanvas
var node_id: int
var slot: Dictionary


func setup(p_canvas: WeaverCanvas, p_node_id: int, p_slot: Dictionary) -> WeaverSlotRow:
	canvas = p_canvas
	node_id = p_node_id
	slot = p_slot
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var model := canvas.model
	var kind_name := "buffer" if slot.type == WeaverModel.BUFFER else "image"

	var access := Label.new()
	access.text = ACCESS_LETTERS[slot.access]
	access.tooltip_text = "%s %s (%s)" % [ACCESS_NAMES[slot.access].capitalize(), "a buffer" if slot.type == WeaverModel.BUFFER else "an image", slot.handle_class]
	access.mouse_filter = Control.MOUSE_FILTER_PASS
	access.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
	access.custom_minimum_size.x = 12
	add_child(access)

	var name_label := Label.new()
	name_label.text = slot.name
	name_label.add_theme_font_size_override("font_size", 12)
	add_child(name_label)

	canvas.register_slot_row(self)
	var binding := model.slot_binding(node_id, slot.name)
	var issue := model.slot_issue(node_id, slot.name)
	var error: bool = not issue.is_empty() and issue.severity == "error"
	if (binding == null or binding.resource == null) and slot.access == WeaverResourceHandle.ACCESS_CREATE:
		# The model gives every create slot its resource; this only shows until it does.
		add_child(WeaverChip.new().setup(canvas, null, "creates a %s" % kind_name, WeaverChip.Look.DASHED, "The node creates this resource itself."))
		return self
	if binding == null or binding.resource == null:
		var hint := "drop %s" % ("a buffer" if slot.type == WeaverModel.BUFFER else "an image")
		var tooltip := "Drag a %s here: from a lane's resources or from another slot." % kind_name
		if not issue.is_empty():
			tooltip = issue.message + "\n" + tooltip
		add_child(WeaverChip.new().setup(canvas, null, hint, WeaverChip.Look.DASHED, tooltip, error))
		return self

	var res: Resource = binding.resource
	var version := model.slot_version_text(node_id, slot.name)
	var text := ("◆ " if res is WeaverSharedResource else "") + res.resource_name + (" " + version if not version.is_empty() else "")
	var look := WeaverChip.Look.SOLID if slot.access == WeaverResourceHandle.ACCESS_CREATE else WeaverChip.Look.OUTLINE
	var tooltip: String = issue.message if not issue.is_empty() else "%s %s%s. Drag it into another slot to use it there." % [
			ACCESS_NAMES[slot.access].capitalize(), res.resource_name, " (" + version + ")" if not version.is_empty() else ""]
	if slot.access == WeaverResourceHandle.ACCESS_CREATE:
		# Made by the node itself: no unbinding. Right-click to rename it.
		var chip := WeaverChip.new().setup(canvas, res, text, look, tooltip + "\nRight-click to rename it.", error)
		chip.on_context = canvas.rename_resource.bind(res)
		add_child(chip)
	else:
		add_child(WeaverChip.new().setup(canvas, res, text, look, tooltip, error, func(): model.unbind_slot(node_id, slot.name), "Unbind this slot"))

	# Stale bindings (they expect a version that was written over) can be pointed at the newest one.
	if error and "expects" in String(issue.message):
		var rebind := WeaverStyle.small_button("↻", "Rebind to the newest version")
		rebind.pressed.connect(func(): model.rebind_to_newest(node_id, slot.name))
		add_child(rebind)
	return self


# Shows whether a dragged resource can go into this slot.
func set_drop_hint(res: Resource) -> void:
	if res == null:
		modulate = Color.WHITE
		return
	var action := canvas.model.drop_action(node_id, slot.name, res)
	modulate = Color.WHITE if action.action != "refuse" else Color(1, 1, 1, 0.35)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return can_accept(data)

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	accept(data)

func can_accept(data: Variant) -> bool:
	if not data is Dictionary or data.get("kind") != "weave_resource":
		return false
	var action := canvas.model.drop_action(node_id, slot.name, data.resource)
	canvas.show_status(action.reason if action.action != "refuse" else "Can't bind: " + action.reason, action.action != "refuse")
	return action.action != "refuse"

func accept(data: Variant) -> void:
	var res: Resource = data.resource
	var action := canvas.model.drop_action(node_id, slot.name, res)
	match action.action:
		"bind":
			var error := canvas.model.bind_slot(node_id, slot.name, res)
			if not error.is_empty():
				canvas.show_status(error, false)
		"share":
			canvas.confirm_share(res, node_id, slot.name)
