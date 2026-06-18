@tool
extends FileDialog

func _ready():
	file_selected.connect(_on_file_selected)
	close_requested.connect(_on_close_requested)

func _on_file_selected(filePath: String):
	print("selected: ", filePath)

func _on_close_requested():
	hide()
	
