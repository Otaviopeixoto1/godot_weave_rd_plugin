@tool
extends Control
class_name WeaverProtoArrow

#
# Short, thick arrow showing execution order: DOWN between the cards of a column, RIGHT between the stage columns of a
# lane (WeaverSpider) and between views. Kept small so it doesn't space the columns and cards out.
#

enum Direction { DOWN, RIGHT }

const LENGTH := 14.0
const THICKNESS := 5.0
const HEAD := 13.0

var direction := Direction.DOWN
var color := WeaverProtoStyle.ARROW
# For RIGHT arrows: distance from the top to the arrow's center, so it lines up with the column headers instead of
# floating in the middle of tall columns. Negative centers it.
var top_offset := -1.0


func setup(p_direction: Direction, p_tooltip: String = "", p_top_offset: float = -1.0) -> WeaverProtoArrow:
	direction = p_direction
	top_offset = p_top_offset
	tooltip_text = p_tooltip
	mouse_filter = Control.MOUSE_FILTER_PASS if not p_tooltip.is_empty() else Control.MOUSE_FILTER_IGNORE
	if direction == Direction.DOWN:
		custom_minimum_size = Vector2(HEAD, LENGTH)
	else:
		custom_minimum_size = Vector2(LENGTH, HEAD)
		size_flags_vertical = Control.SIZE_FILL
	return self


func _draw() -> void:
	if direction == Direction.DOWN:
		var x := size.x * 0.5
		var head_y := size.y - HEAD * 0.6
		draw_line(Vector2(x, 0), Vector2(x, head_y), color, THICKNESS)
		draw_colored_polygon(PackedVector2Array([Vector2(x - HEAD * 0.5, head_y), Vector2(x + HEAD * 0.5, head_y), Vector2(x, size.y)]), color)
	else:
		var y := top_offset if top_offset >= 0.0 else size.y * 0.5
		var head_x := size.x - HEAD * 0.6
		draw_line(Vector2(0, y), Vector2(head_x, y), color, THICKNESS)
		draw_colored_polygon(PackedVector2Array([Vector2(head_x, y - HEAD * 0.5), Vector2(head_x, y + HEAD * 0.5), Vector2(size.x, y)]), color)
