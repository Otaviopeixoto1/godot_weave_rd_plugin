@tool
extends VBoxContainer
class_name WeaverProfilerPanel

#
# Tab of the debugger panel: the capture controls, the frame time graph and, on its left, the sections of the latest frame
# sorted from the highest time to the lowest.
#

const SECTIONS_WIDTH := 220.0

signal capture_toggled(enabled: bool)

var _capture_button: Button
var _graph: WeaverProfilerGraph
var _sections: VBoxContainer
var _section_rows: Dictionary[String, HBoxContainer] = {}


func _init() -> void:
	var toolbar := HBoxContainer.new()
	add_child(toolbar)

	_capture_button = Button.new()
	_capture_button.text = "Capture"
	_capture_button.toggle_mode = true
	_capture_button.tooltip_text = "Measure the sections marked with begin_capture() / end_capture() in the running game."
	_capture_button.toggled.connect(func(enabled: bool): capture_toggled.emit(enabled))
	toolbar.add_child(_capture_button)

	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(clear)
	toolbar.add_child(clear_button)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = SECTIONS_WIDTH * EditorInterface.get_editor_scale()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)

	_sections = VBoxContainer.new()
	_sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_sections)

	_graph = WeaverProfilerGraph.new()
	split.add_child(_graph)


func is_capturing() -> bool:
	return _capture_button.button_pressed


func add_frames(frames: Array) -> void:
	_graph.add_frames(frames)

	var names: PackedStringArray = frames.back()[0]
	var times_ms: PackedFloat32Array = frames.back()[1]

	# A section can run more than once in a frame (one per camera).
	var section_times: Dictionary[String, float] = {}
	for section in names.size():
		section_times[names[section]] = section_times.get(names[section], 0.0) + times_ms[section]

	var sorted_names := section_times.keys()
	sorted_names.sort_custom(func(a: String, b: String): return section_times[a] > section_times[b])

	for row in _section_rows.values():
		row.visible = false
	for i in sorted_names.size():
		var row := _section_row(sorted_names[i])
		row.visible = true
		row.get_child(1).text = "%.2f ms" % section_times[sorted_names[i]]
		_sections.move_child(row, i)


func clear() -> void:
	_graph.clear()
	for child in _sections.get_children():
		child.queue_free()
	_section_rows.clear()


func _section_row(section_name: String) -> HBoxContainer:
	if _section_rows.has(section_name):
		return _section_rows[section_name]

	var row := HBoxContainer.new()
	_sections.add_child(row)
	_section_rows[section_name] = row

	var name_label := Label.new()
	name_label.text = section_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.add_theme_color_override("font_color", _graph.color_of(section_name))
	row.add_child(name_label)

	var time_label := Label.new()
	row.add_child(time_label)
	return row
