@tool
extends Control
class_name GraphPopupTrigger

@export var popup: Popup

func _gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if (popup != null):
				popup.popup_centered_clamped()
