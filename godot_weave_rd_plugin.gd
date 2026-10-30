@tool
extends EditorPlugin

const MainPanel = preload("res://addons/godot_weave_rd_plugin/scenes/weave_rd_scene.tscn")
# Shows the resource-binding prototype (prototype/) instead of the WeaverWeb graph scene.
const USE_PROTOTYPE := true

var main_panel_instance: Control
var profiler_debugger: WeaverProfilerDebugger

func _enable_plugin() -> void:
	# Add autoloads here.
	pass


func _disable_plugin() -> void:
	# Remove autoloads here.
	pass


func _enter_tree() -> void:
	if USE_PROTOTYPE:
		main_panel_instance = WeaverProtoPanel.new()
	else:
		main_panel_instance = MainPanel.instantiate() as WeaverEditorScene
	main_panel_instance.call("setup_for_plugin")
	
	# Add the main panel to the editor's main viewport.
	EditorInterface.get_editor_main_screen().add_child(main_panel_instance)
	# Hide the main panel. Very much required.
	_make_visible(false)

	profiler_debugger = WeaverProfilerDebugger.new()
	add_debugger_plugin(profiler_debugger)

func _exit_tree() -> void:
	remove_debugger_plugin(profiler_debugger)
	if main_panel_instance:
		main_panel_instance.call("cleanup_plugin")
		main_panel_instance.queue_free()

func _has_main_screen():
	return true


func _make_visible(visible):
	if main_panel_instance:
		main_panel_instance.visible = visible


# Ctrl+S / Save All also save the web open in the prototype.
func _save_external_data() -> void:
	if main_panel_instance is WeaverProtoPanel and main_panel_instance.has_unsaved_web():
		main_panel_instance.save_web()

# Asked when the editor quits (for_scene is empty): lets the user save an edited web first.
func _get_unsaved_status(for_scene: String) -> String:
	if for_scene.is_empty() and main_panel_instance is WeaverProtoPanel and main_panel_instance.has_unsaved_web():
		return "Save changes to %s before closing?" % main_panel_instance.model.web_name()
	return ""


func _get_plugin_name():
	return "WeaveRD"

#func _handles(object: Object) -> bool:
#	USE TO CONTROL AUTO FOCUS WHEN A NODE OF A SPECIFIC TYPE IS SELECTED	

func _get_plugin_icon():
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")
