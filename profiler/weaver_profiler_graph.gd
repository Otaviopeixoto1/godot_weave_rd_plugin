@tool
extends Control
class_name WeaverProfilerGraph

#
# Scrolling frame time graph. Each frame is a bin: a stack of rectangles, one per captured section, sized by its time.
# New frames enter on the right and old ones leave on the left. The height of the graph is RANGE_MS.
#

const RANGE_MS := 60.0
const BIN_WIDTH := 5.0
const BIN_GAP := 1.0
const MAX_FRAMES := 1024
const GRID_LINES_MS: Array[float] = [16.67, 33.33]

const BACKGROUND := Color(0.1, 0.1, 0.12)
const GRID_COLOR := Color(1, 1, 1, 0.2)
const GRID_TEXT_COLOR := Color(1, 1, 1, 0.55)

# Each frame is [names: PackedStringArray, times_ms: PackedFloat32Array]
var _frames: Array = []
var _colors: Dictionary[String, Color] = {}


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, 160)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func color_of(section_name: String) -> Color:
	if not _colors.has(section_name):
		# In order of appearance: the golden ratio keeps the hues of consecutive sections far apart.
		_colors[section_name] = Color.from_hsv(fmod(0.6 + _colors.size() * 0.61803398875, 1.0), 0.65, 0.9)
	return _colors[section_name]


func add_frames(frames: Array) -> void:
	_frames.append_array(frames)
	if _frames.size() > MAX_FRAMES:
		_frames = _frames.slice(_frames.size() - MAX_FRAMES)
	queue_redraw()


func clear() -> void:
	_frames.clear()
	_colors.clear()
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)

	var editor_scale := EditorInterface.get_editor_scale()
	var ms_to_pixels := size.y / RANGE_MS
	var bin_width := BIN_WIDTH * editor_scale
	var bin_step := bin_width + BIN_GAP * editor_scale

	var x := size.x - bin_width
	for i in range(_frames.size() - 1, -1, -1):
		if x + bin_width < 0.0:
			break
		var names: PackedStringArray = _frames[i][0]
		var times_ms: PackedFloat32Array = _frames[i][1]
		var y := size.y
		for section in names.size():
			var height := times_ms[section] * ms_to_pixels
			y -= height
			draw_rect(Rect2(x, y, bin_width, height), color_of(names[section]))
		x -= bin_step

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	for ms in GRID_LINES_MS:
		var line_y := size.y - ms * ms_to_pixels
		draw_line(Vector2(0, line_y), Vector2(size.x, line_y), GRID_COLOR)
		draw_string(font, Vector2(4, line_y - 3), "%.1f ms" % ms, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, GRID_TEXT_COLOR)
	draw_string(font, Vector2(4, font_size + 2), "%d ms" % RANGE_MS, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, GRID_TEXT_COLOR)
