@tool
extends Object
class_name WeaverProtoStyle

# Shared colors and StyleBox helpers for the prototype UI (tuned for the default dark editor theme).

const CARD_BG := Color(0.16, 0.17, 0.2)
const CARD_BORDER := Color(0.32, 0.34, 0.4)
const COLUMN_BG := Color(1, 1, 1, 0.03)
const VIEW_BORDER := Color(0.55, 0.5, 0.85, 0.8)
const LANE_LIVE_BG := Color(0.2, 0.6, 0.5, 0.12)
const LANE_IDLE_BG := Color(1, 1, 1, 0.02)
const VALID := Color(0.35, 0.8, 0.55)
const INVALID := Color(0.9, 0.35, 0.35)
const DARK_TEXT := Color(0.08, 0.08, 0.1)
const MUTED_TEXT := Color(0.6, 0.62, 0.68)


static func box(bg: Color, border: Color = Color.TRANSPARENT, border_width: int = 1, radius: int = 4, margin: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_width if border.a > 0.0 else 0)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	return sb

static func apply_button(button: Button, normal: StyleBoxFlat) -> void:
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.15)
	for state in ["normal", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed"]:
		button.add_theme_stylebox_override(state, hover)

static func small_button(text: String, tooltip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tooltip
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_constant_override("h_separation", 0)
	return b
