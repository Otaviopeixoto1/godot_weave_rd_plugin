@tool
extends Control
class_name WeaverCanvas

#
# Main canvas: views left to right in render order, lanes (WeaverSpiders) stacked inside each view, and
# one column per stage inside each lane (WeaverSpider). Short arrows show the order: between views, between the stage
# columns of a lane (WeaverSpider) and between the cards of a column.
#
# Resources (T-026): above the views, one WeaverSharedTrack per shared resource. Each lane shows its resources (made by
# its nodes' create slots; drag them into slots) and the shared resources it provides. Hovering a chip (or a matrix row) outlines
# every chip of that resource on a transparent overlay.
#

# Where the RIGHT arrows sit from the top, so they line up with the stage names / view headers.
const COLUMN_ARROW_Y := 18.0
const VIEW_ARROW_Y := 22.0

signal highlight_changed(resource: Resource)
signal status_changed(text: String, ok: bool)

var model: WeaverModel:
	set(value):
		model = value
		node_scripts.model = value

# Script / class actions of the cards (attach script, change class, add a node of a class).
var node_scripts: WeaverNodeScripts

var _scroll: ScrollContainer
var _tracks_box: VBoxContainer
var _views_box: HBoxContainer
var _overlay: Control

var _cards := {} # node id -> WeaverCard
var _chips := {} # Resource -> Array of WeaverChips showing it
var _slot_rows: Array = []
var _tracks: Array = []
var _view_panels: Array = []
var _view_arrows: Array = []

var _hl_resource: Resource

var _picker: WeaverSlotPicker
var _rename_dialog: WeaverRenameDialog
var _saved_webs: Array = [] # WeaverSlotLibrary.collect_web_slots(), refreshed on rebuild
var _confirm_dialog: ConfirmationDialog
var _confirm_action: Callable


func _init() -> void:
	clip_contents = true

	node_scripts = WeaverNodeScripts.new()
	node_scripts.status.connect(show_status)
	add_child(node_scripts)

	_picker = WeaverSlotPicker.new()
	add_child(_picker)

	_rename_dialog = WeaverRenameDialog.new()
	add_child(_rename_dialog)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.confirmed.connect(func(): _confirm_action.call())
	add_child(_confirm_dialog)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 2)
	_scroll.add_child(content)
	_tracks_box = VBoxContainer.new()
	_tracks_box.add_theme_constant_override("separation", 0)
	content.add_child(_tracks_box)
	_views_box = HBoxContainer.new()
	_views_box.add_theme_constant_override("separation", 4)
	_views_box.sort_children.connect(_sync_tracks)
	content.add_child(_views_box)

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
			card.set_drop_state(WeaverCard.DropState.NONE)
		for row in _slot_rows:
			if is_instance_valid(row):
				row.set_drop_hint(null)
		show_status("", true)


func rebuild() -> void:
	_cards.clear()
	_chips.clear()
	_slot_rows.clear()
	_tracks.clear()
	_view_panels.clear()
	_view_arrows.clear()
	_saved_webs = WeaverSlotLibrary.collect_web_slots()
	for box in [_views_box, _tracks_box]:
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()

	for vi in model.views.size():
		if vi > 0:
			var arrow := WeaverArrow.new().setup(WeaverArrow.Direction.RIGHT, "Renders after the view on the left.", VIEW_ARROW_Y)
			_view_arrows.append(arrow)
			_views_box.add_child(arrow)
		var panel := _build_view(model.views[vi], vi)
		_view_panels.append(panel)
		_views_box.add_child(panel)

	for shared in model.shared_resources():
		var track := WeaverSharedTrack.new().setup(self, shared)
		_tracks.append(track)
		_tracks_box.add_child(track)

	if model.views.is_empty():
		var hint := Label.new()
		hint.text = "No views yet. Add one with + View." if model.has_web() else "No web open. Open or create a WeaverWeb with the Web menu above."
		hint.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
		_views_box.add_child(hint)
	_overlay.queue_redraw()


#
# Called by cards and chips
#
func register_card(card: WeaverCard) -> void:
	_cards[card.node_id] = card

func register_chip(chip: WeaverChip) -> void:
	if not _chips.has(chip.resource):
		_chips[chip.resource] = []
	_chips[chip.resource].append(chip)

func register_slot_row(row: WeaverSlotRow) -> void:
	_slot_rows.append(row)

func set_highlight(resource: Resource) -> void:
	if resource == _hl_resource:
		return
	_hl_resource = resource
	_overlay.queue_redraw()
	highlight_changed.emit(resource)

# Dims the slots a dragged resource can't go into.
func begin_resource_drag(resource: Resource) -> void:
	for row in _slot_rows:
		if is_instance_valid(row):
			row.set_drop_hint(resource)

# Scrolls to a node's card.
func focus_node(node_id: int) -> void:
	var card: Control = _cards.get(node_id)
	if card != null and is_instance_valid(card):
		_scroll.ensure_control_visible(card)

func confirm(text: String, ok_text: String, action: Callable) -> void:
	_confirm(text, ok_text, action)

# Asks before turning a lane resource into a shared resource for a slot of a later view.
func confirm_share(res: WeaverResource, node_id: int, slot: StringName) -> void:
	var owner := model.resource_lane(res)
	if owner.is_empty():
		return
	var view_index := model.views.find(owner.view)
	var others := PackedStringArray()
	for lane in owner.view.lanes:
		if lane != owner.lane:
			others.append(WeaverModel.slot_name(lane.slot))
	var text := "Creates the shared resource \"%s\", provided by view %d (%s), and binds %s.%s to it." % [
			res.resource_name, view_index, WeaverModel.slot_name(owner.lane.slot), model.node_name(node_id), slot]
	if not others.is_empty():
		text += "\nThe other lanes of view %d (%s) must provide %s too." % [view_index, ", ".join(others),
				"a buffer" if res.kind == WeaverModel.BUFFER else "an image"]
	var share := func():
		var error := model.share_resource(res, node_id, slot)
		if not error.is_empty():
			show_status(error, false)
	_confirm(text, "Share", share, "Share %s with later views?" % res.resource_name)

func rename_resource(res: Resource) -> void:
	_rename_dialog.open("Rename resource", res.resource_name, func(new_name: String): model.rename_resource(res, new_name))

func show_status(text: String, ok: bool) -> void:
	status_changed.emit(text, ok)

# Opens a node's resource (WeaverWebNode / CompositorEffect) in the Inspector.
func inspect_node(node_id: int) -> void:
	var res := model.node_resource(node_id)
	if res != null:
		EditorInterface.edit_resource(res)

func rename_node(node_id: int) -> void:
	var on_renamed := func(new_name: String): model.rename_node(node_id, new_name)
	_rename_dialog.open("Rename node", model.node_name(node_id), on_renamed)

func _confirm(text: String, ok_text: String, action: Callable, dialog_title := "Please Confirm...") -> void:
	_confirm_dialog.title = dialog_title
	_confirm_action = action
	_confirm_dialog.dialog_text = text
	_confirm_dialog.ok_button_text = ok_text
	_confirm_dialog.popup_centered()


#
# Slots
#

# Opens the slot picker for a new view (view_id < 0) or to change a view's slot.
func pick_view_slot(near: Control, view_id: int = -1) -> void:
	var title := "New view: pick or create a view slot" if view_id < 0 else "Change the view slot"
	var on_chosen := func(slot):
		if view_id < 0:
			model.add_view(slot)
		else:
			model.set_view_slot(view_id, slot)
	_picker.open(WeaverSlotLibrary.KIND_VIEW, title, model.used_view_slots(view_id), _model_slots(true), on_chosen, _screen_rect(near))

# Opens the slot picker for a new lane (lane_id < 0) or to change a lane's slot.
func pick_lane_slot(near: Control, view_id: int, lane_id: int = -1) -> void:
	var title := "New lane: pick or create a camera slot" if lane_id < 0 else "Change the camera slot"
	var on_chosen := func(slot):
		if lane_id < 0:
			model.add_lane(view_id, slot)
		else:
			model.set_lane_slot(view_id, lane_id, slot)
	_picker.open(WeaverSlotLibrary.KIND_CAMERA, title, model.used_camera_slots(view_id, lane_id), _model_slots(false), on_chosen, _screen_rect(near))

func _screen_rect(control: Control) -> Rect2:
	return Rect2(control.get_screen_position(), control.size)

func rename_slot(slot: Resource) -> void:
	if slot == null:
		return
	var on_renamed := func(new_name: String):
		if slot.resource_path.is_empty():
			slot.resource_name = new_name
		else:
			WeaverSlotLibrary.rename_slot(slot, new_name)
		model.slot_renamed()
	_rename_dialog.open("Rename slot", WeaverModel.slot_name(slot), on_renamed)

# Slots the web already uses, so slots that aren't in the slot directory (embedded in the web or saved elsewhere)
# show up in the picker too.
func _model_slots(view_slots: bool) -> Array:
	var slots: Array = []
	for view in model.views:
		if view_slots:
			slots.append(view.slot)
		else:
			for lane in view.lanes:
				slots.append(lane.slot)
	return slots

# Saved webs using a slot, from the scan done in rebuild().
func _webs_using(slot: Resource) -> PackedStringArray:
	var webs: PackedStringArray = []
	if slot == null:
		return webs
	for web in _saved_webs:
		var used := false
		for view in web.views:
			if view.slot == slot or (view.lanes as Array).has(slot):
				used = true
		if used:
			webs.append(String(web.path).get_file())
	return webs


#
# Building
#
func _build_view(view: Dictionary, view_index: int) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", WeaverStyle.box(Color.TRANSPARENT, WeaverStyle.VIEW_BORDER, 1, 8, 10))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	
	var view_id: int = view.id
	var title := WeaverSlotHeader.new().setup(WeaverSlotLibrary.KIND_VIEW, view.slot, model.view_slot_error(view_id), _webs_using(view.slot), "%d · " % view_index)
	title.change_requested.connect(func(): pick_view_slot(title, view_id))
	title.rename_requested.connect(func(): rename_slot(view.slot))
	header.add_child(title)
	
	var add_lane := WeaverStyle.small_button("+ Lane", "Add a lane (WeaverSpider): pick or create its camera slot")
	add_lane.pressed.connect(func(): pick_lane_slot(add_lane, view_id))
	header.add_child(add_lane)
	
	var remove := WeaverStyle.small_button("×", "Remove this view from the web")
	remove.pressed.connect(func(): _confirm("Remove view \"%s\" and all its lanes and nodes from the web?" % WeaverModel.slot_name(view.slot), "Remove", model.remove_view.bind(view_id)))
	header.add_child(remove)

	var lanes: Array = view.lanes
	if lanes.is_empty():
		var hint := Label.new()
		hint.text = "No lanes yet. Add one with + Lane."
		hint.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
		box.add_child(hint)
	for li in lanes.size():
		box.add_child(_build_lane(view, li))
	return panel

func _build_lane(view: Dictionary, lane_index: int) -> Control:
	var lane: Dictionary = view.lanes[lane_index]
	var in_path: bool = clampi(view.path_lane, 0, (view.lanes as Array).size() - 1) == lane_index

	var panel := PanelContainer.new()
	var bg := WeaverStyle.LANE_LIVE_BG if in_path else WeaverStyle.LANE_IDLE_BG
	panel.add_theme_stylebox_override("panel", WeaverStyle.box(bg, Color.TRANSPARENT, 0, 6, 6))

	var box := VBoxContainer.new()
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var view_id: int = view.id
	var lane_id: int = lane.id
	var title := WeaverSlotHeader.new().setup(WeaverSlotLibrary.KIND_CAMERA, lane.slot, model.lane_slot_error(view_id, lane_id), _webs_using(lane.slot))
	title.change_requested.connect(func(): pick_lane_slot(title, view_id, lane_id))
	title.rename_requested.connect(func(): rename_slot(lane.slot))
	header.add_child(title)
	if in_path:
		var tag := Label.new()
		tag.text = "● in matrix"
		tag.add_theme_color_override("font_color", WeaverStyle.VALID)
		header.add_child(tag)
	else:
		var show_button := WeaverStyle.small_button("Show in matrix", "Use this lane for the view's frame path in the matrix")
		show_button.pressed.connect(func(): model.set_path_lane(view.id, lane_index))
		header.add_child(show_button)
	var remove := WeaverStyle.small_button("×", "Remove this lane (WeaverSpider) from the view")
	remove.pressed.connect(func(): _confirm("Remove lane \"%s\" and all its nodes from the view?" % WeaverModel.slot_name(lane.slot), "Remove", model.remove_lane.bind(view_id, lane_id)))
	header.add_child(remove)
	_build_lane_resources(box, view, lane)

	# Stage columns left to right in run order, with a short arrow between each pair.
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 2)
	box.add_child(columns)
	for stage in WeaverModel.STAGE_COUNT:
		if stage > 0:
			columns.add_child(WeaverArrow.new().setup(WeaverArrow.Direction.RIGHT, "Runs after the stage on the left.", COLUMN_ARROW_Y))
		columns.add_child(WeaverColumn.new().setup(self, view.id, lane.id, stage))
	return panel


#
# Link overlay
#
func _draw_overlay() -> void:
	if _hl_resource == null:
		return
	var color := WeaverModel.resource_color(_hl_resource)
	var to_local := _overlay.get_global_transform().affine_inverse()
	var centers := PackedVector2Array()
	for chip in _chips.get(_hl_resource, []):
		if not is_instance_valid(chip) or not (chip as Control).is_visible_in_tree():
			continue
		var rect: Rect2 = to_local * (chip as Control).get_global_rect()
		_overlay.draw_rect(rect.grow(2), color, false, 2.0)
		centers.append(rect.get_center())
	# A thin line through the chips, left to right, to follow the resource across the canvas.
	var sorted := Array(centers)
	sorted.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	for i in range(1, sorted.size()):
		_overlay.draw_line(sorted[i - 1], sorted[i], Color(color, 0.5), 1.0, true)


# Resources of a lane (drag them into slots) and the shared resources it provides.
func _build_lane_resources(box: VBoxContainer, view: Dictionary, lane: Dictionary) -> void:
	var view_id: int = view.id
	var lane_id: int = lane.id
	var view_index := model.views.find(view)

	var tray := HFlowContainer.new()
	tray.add_theme_constant_override("h_separation", 4)
	tray.add_theme_constant_override("v_separation", 4)
	box.add_child(tray)
	var label := Label.new()
	label.text = "resources"
	label.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
	tray.add_child(label)
	var lane_errors := model.lane_issues(lane_id)
	for res in model.lane_resources(view_id, lane_id):
		var version := model.lane_resource_version(res)
		var creator := model.creator_of(res)
		var problems: Array = lane_errors.filter(func(i): return " %s" % res.resource_name in String(i.message))
		var tooltip := "%s %s, %s.\nDrag it into a slot. Right-click to rename." % [
				"Buffer" if res.kind == WeaverModel.BUFFER else "Image", res.resource_name,
				"created by %s" % model.node_name(creator) if creator >= 0 else "nothing creates it anymore (no create slot is bound to it)"]
		for issue in problems:
			tooltip = String(issue.message) + "\n" + tooltip
		var chip := WeaverChip.new().setup(self, res, res.resource_name + (" v%d" % version if version > 0 else ""), WeaverChip.Look.SOLID, tooltip,
				problems.any(func(i): return i.severity == "error"),
				func(): _confirm("Remove the resource \"%s\" and its bindings from the lane?" % res.resource_name, "Remove", model.remove_lane_resource.bind(res)),
				"Remove the resource")
		chip.on_context = rename_resource.bind(res)
		tray.add_child(chip)

	# Shared resources this lane's view provides.
	var provided: Array = model.shared_resources().filter(func(sr): return model.shared_source_view(sr) == view_index)
	if not provided.is_empty():
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 4)
		box.add_child(row)
		var provides_label := Label.new()
		provides_label.text = "provides"
		provides_label.add_theme_color_override("font_color", WeaverStyle.MUTED_TEXT)
		row.add_child(provides_label)
		for shared in provided:
			var source: WeaverResource = model.provided_by(view_id, lane_id, shared)
			var chip: WeaverChip
			if source != null:
				chip = WeaverChip.new().setup(self, shared, "◆ %s ← %s v%d" % [shared.resource_name, source.resource_name, model.lane_resource_version(source)],
						WeaverChip.Look.SOLID, "This lane provides %s as %s to the later views. Drop another resource of the lane here to change it." % [
						source.resource_name, shared.resource_name], false, model.unprovide.bind(view_id, lane_id, shared), "Stop providing it")
			else:
				chip = WeaverChip.new().setup(self, shared, "needs: ◆ %s" % shared.resource_name, WeaverChip.Look.DASHED,
						"Another lane of this view provides %s, so this one must too. Drop one of this lane's resources here." % shared.resource_name, true)
			chip.on_can_drop = func(data) -> String:
				if not data is Dictionary or data.get("kind") != "weave_resource" or not data.resource is WeaverResource:
					return "Drop a resource of this lane."
				var res: WeaverResource = data.resource
				if not model.lane_resources(view_id, lane_id).has(res):
					return "Only a resource of this lane can be provided by it."
				if res.kind != shared.kind:
					return "%s is %s." % [shared.resource_name, "a buffer" if shared.kind == WeaverModel.BUFFER else "an image"]
				return ""
			chip.on_drop = func(data): model.provide(view_id, lane_id, shared, data.resource)
			row.add_child(chip)

	# Lane problems that are not about one slot.
	var other: Array = lane_errors.filter(func(i): return not model.lane_resources(view_id, lane_id).any(func(r): return " %s" % r.resource_name in String(i.message)))
	if not other.is_empty():
		var warning := Label.new()
		var errors := other.filter(func(i): return i.severity == "error").size()
		warning.text = "! %d issue%s" % [other.size(), "" if other.size() == 1 else "s"]
		warning.tooltip_text = "\n".join(other.map(func(i): return String(i.message)))
		warning.mouse_filter = Control.MOUSE_FILTER_STOP
		warning.add_theme_color_override("font_color", WeaverStyle.INVALID if errors > 0 else WeaverStyle.MUTED_TEXT)
		box.add_child(warning)


# The track cells follow the widths of the view panels below.
func _sync_tracks() -> void:
	var view_widths: Array = _view_panels.map(func(p): return (p as Control).size.x if is_instance_valid(p) else 0.0)
	var arrow_widths: Array = _view_arrows.map(func(a): return (a as Control).size.x if is_instance_valid(a) else 0.0)
	for track in _tracks:
		if is_instance_valid(track):
			track.sync_widths(view_widths, arrow_widths)
	_overlay.queue_redraw()
