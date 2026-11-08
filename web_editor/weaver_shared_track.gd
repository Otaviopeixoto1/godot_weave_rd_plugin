@tool
extends HBoxContainer
class_name WeaverSharedTrack

#
# One shared resource above the views: a line from its source view to the right edge (it is available to every later
# view), with a chip above each view. At the source view a solid chip shows the provided version and how many lanes
# provide it; later views show what their lane on the frame path does with it (R / W with versions, click to find the
# node), or a dashed "available vN" when they don't use it. Cells follow the widths of the views below (sync_widths).
#

var canvas: WeaverCanvas
var shared: WeaverSharedResource
var _source := -1
var _broken := false
var _cells: Array[Control] = []
var _spacers: Array[Control] = []


func setup(p_canvas: WeaverCanvas, p_shared: WeaverSharedResource) -> WeaverSharedTrack:
	canvas = p_canvas
	shared = p_shared
	add_theme_constant_override("separation", 4)
	custom_minimum_size.y = 26
	var model := canvas.model
	_source = model.shared_source_view(shared)
	var shared_errors := model.shared_issues(shared).filter(func(i): return i.severity == "error")
	_broken = _source < 0 or not shared_errors.is_empty()

	for vi in model.views.size():
		if vi > 0:
			var spacer := Control.new()
			_spacers.append(spacer)
			add_child(spacer)
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 4)
		cell.alignment = BoxContainer.ALIGNMENT_BEGIN
		_cells.append(cell)
		add_child(cell)

	var remove := func(): canvas.confirm("Remove the shared resource \"%s\"? The lanes stop providing it and the slots using it are unbound." % shared.resource_name,
			"Remove", model.remove_shared.bind(shared))
	if _source < 0:
		if not _cells.is_empty():
			_cells[0].add_child(WeaverChip.new().setup(canvas, shared, "◆ %s · not provided" % shared.resource_name, WeaverChip.Look.SOLID,
					"No view provides this shared resource. Make a lane provide one of its resources to it.", true, remove, "Remove the shared resource"))
		return self

	# Source view.
	var path := model.frame_path()
	var view: Dictionary = model.views[_source]
	var lanes: Array = view.lanes
	var providing := 0
	var lines := PackedStringArray()
	for lane in lanes:
		var res: WeaverResource = model.provided_by(view.id, lane.id, shared)
		if res != null:
			providing += 1
			lines.append("%s provides %s v%d" % [WeaverModel.slot_name(lane.slot), res.resource_name, model.lane_resource_version(res)])
		else:
			lines.append("%s doesn't provide it" % WeaverModel.slot_name(lane.slot))

	for issue in shared_errors:
		lines.append("! " + String(issue.message))

	var provided_version := _provided_version(model, path)
	var text := "◆ %s · provided v%d · %d/%d lanes" % [shared.resource_name, provided_version, providing, lanes.size()]
	_cells[_source].add_child(WeaverChip.new().setup(canvas, shared, text, WeaverChip.Look.SOLID,
			"Shared resource: every view after view %d can read or write it.\n%s" % [_source, "\n".join(lines)], providing < lanes.size() or _broken,
			remove, "Remove the shared resource"))

	# Later views: what their lane on the frame path does with it.
	var current := provided_version
	var records := model.shared_records(shared)
	for vi in range(_source + 1, model.views.size()):
		var here := records.filter(func(r): return r.view == vi)
		if here.is_empty():
			if path[vi] >= 0:
				_cells[vi].add_child(WeaverChip.new().setup(canvas, shared, "available v%d" % current, WeaverChip.Look.DASHED,
						"%s is available here: drag this chip into a slot of this view to use it." % shared.resource_name))
			continue
		for record in here:
			var write: bool = record.access == WeaverResourceHandle.ACCESS_WRITE
			var version := "v%d→v%d" % [record.version_in, record.version_out] if write else "v%d" % record.version_out
			var issue := model.slot_issue(record.node_id, record.slot)
			var node_id: int = record.node_id
			var chip := WeaverChip.new().setup(canvas, shared, "%s %s %s · %s ▸" % ["W" if write else "R", shared.resource_name, version, model.node_name(node_id)],
					WeaverChip.Look.OUTLINE, (String(issue.message) + "\n" if not issue.is_empty() else "") + "Click to show %s." % model.node_name(node_id),
					not issue.is_empty() and issue.severity == "error")
			chip.on_click = func(): canvas.focus_node(node_id)
			_cells[vi].add_child(chip)
			current = record.version_out
	return self


func _provided_version(model: WeaverModel, path: PackedInt32Array) -> int:
	var lane_index: int = path[_source] if _source < path.size() else -1
	if lane_index < 0:
		return 0
	var lane: Dictionary = model.views[_source].lanes[lane_index]
	var res := model.provided_by(model.views[_source].id, lane.id, shared)
	return model.lane_resource_version(res) if res != null else 0


# Cell widths follow the view panels and the arrows between them.
func sync_widths(view_widths: Array, arrow_widths: Array) -> void:
	for i in mini(_cells.size(), view_widths.size()):
		_cells[i].custom_minimum_size.x = view_widths[i]
	for i in mini(_spacers.size(), arrow_widths.size()):
		_spacers[i].custom_minimum_size.x = arrow_widths[i]
	queue_redraw()


func _draw() -> void:
	var start := 0.0
	if _source >= 0 and _source < _cells.size():
		start = _cells[_source].position.x
	var y := size.y * 0.5
	var color := WeaverStyle.INVALID if _broken else WeaverModel.resource_color(shared)
	if _broken:
		draw_dashed_line(Vector2(start, y), Vector2(size.x, y), color, 2.0, 6.0)
	else:
		draw_line(Vector2(start, y), Vector2(size.x, y), color, 2.0)
