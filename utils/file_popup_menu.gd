@tool
extends PopupMenu

@export var webFileDialog: FileDialog

func _ready():
	id_pressed.connect(_on_id_pressed)

func _on_id_pressed(i: int):
	match i:
		0:
			pass
		1:
			if(webFileDialog != null):
				webFileDialog.popup_centered_clamped()
