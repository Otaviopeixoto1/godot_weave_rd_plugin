@tool
extends Node
class_name WeaverProtoNodeScripts

#
# Scripts and classes of the nodes on the cards (owned by WeaverProtoCanvas).
#
#  - Attach script: the editor's own ScriptCreateDialog (like the Scene dock's "Attach Script"), locked to the node's
#    native class (WeaverWebNode, or CompositorEffect for plain effects). Loading an existing script works too.
#    On confirmation the script is attached to the node's resource, opened, and the Script screen is shown.
#  - Pick a class: the editor's create dialog over WeaverWebNode, which lists native subclasses and script classes
#    (class_name) extending it. Used to add a node and to change the class of an existing one.
#
# The dialog preselects a WeaverWebNode template with the _setup / _render / _cleanup callbacks. It is written to the
# editor's script_templates folder (not into the project) the first time it's needed.
#

const TEMPLATE_NAME := "weaver_render_pass.gd"
const TEMPLATE := """# meta-name: Weaver render pass
# meta-description: WeaverWebNode with the setup, render and cleanup callbacks. All three run on the render thread.
extends _BASE_


# Called once on the render thread before the first _render() of each camera's copy of this node.
# Create the RenderingDevice resources (shaders, pipelines, textures) here.
func _setup() -> void:
	pass


# Called every frame on the render thread, at this node's stage.
# render_data.get_render_scene_buffers() gives the camera's buffers.
func _render(stage: int, render_data: RenderData) -> void:
	pass


# Called on the render thread when the copy is removed (camera unbound, web changed, scene closed).
# Free everything created in _setup().
func _cleanup() -> void:
	pass
"""

signal status(text: String, ok: bool)

var model: WeaverProtoModel

var _dialog: ScriptCreateDialog
var _script_node := -1


func _init() -> void:
	_dialog = ScriptCreateDialog.new()
	_dialog.script_created.connect(_on_script_created)
	add_child(_dialog)


# Base native class a node's script must extend.
func script_base(node_id: int) -> String:
	return "CompositorEffect" if model.is_plain_effect(node_id) else "WeaverWebNode"

func attach_script(node_id: int) -> void:
	if model.node_resource(node_id) == null:
		return
	ensure_template()
	_script_node = node_id
	_dialog.config(script_base(node_id), _default_script_path(node_id), false, true)
	_dialog.popup_centered()

func edit_script(node_id: int) -> void:
	var res := model.node_resource(node_id)
	if res == null:
		return
	var script := res.get_script() as Script
	if script != null:
		EditorInterface.set_main_screen_editor("Script")
		EditorInterface.edit_script(script)

func detach_script(node_id: int) -> void:
	model.set_node_script(node_id, null)

# Opens the class picker; on_chosen receives the picked class name (native or script class).
func pick_node_class(title: String, current: String, on_chosen: Callable) -> void:
	var callback := func(type_name: String):
		if not type_name.is_empty():
			on_chosen.call(type_name)
	EditorInterface.popup_create_dialog(callback, "WeaverWebNode", current, title)

func add_node(view_id: int, lane_id: int, stage: int) -> void:
	var on_chosen := func(type_name: String):
		if model.add_node(view_id, lane_id, stage, "", type_name) < 0:
			status.emit("\"%s\" is not a WeaverWebNode type." % type_name, false)
	pick_node_class("Add a node to %s" % WeaverProtoModel.STAGE_NAMES[stage], "WeaverWebNode", on_chosen)

func change_class(node_id: int) -> void:
	var res := model.node_resource(node_id)
	if res == null:
		return
	var current: String = res.get_class()
	var script := res.get_script() as Script
	if script != null and not script.get_global_name().is_empty():
		current = script.get_global_name()
	var on_chosen := func(type_name: String):
		var err := model.change_node_type(node_id, type_name)
		status.emit(err if not err.is_empty() else "\"%s\" is now a %s." % [model.node_name(node_id), type_name], err.is_empty())
	pick_node_class("Change the class of \"%s\"" % model.node_name(node_id), current, on_chosen)


# Writes the WeaverWebNode template into the editor's script_templates folder if it isn't there yet.
static func ensure_template() -> void:
	var dir := EditorInterface.get_editor_paths().get_config_dir().path_join("script_templates").path_join("WeaverWebNode")
	var path := dir.path_join(TEMPLATE_NAME)
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(TEMPLATE)


# Next to the web, named after the node: res://webs/my_web.tres + "Grayscale" -> res://webs/grayscale.gd
func _default_script_path(node_id: int) -> String:
	var dir := "res://"
	if model.has_web() and not model.web.resource_path.is_empty():
		dir = model.web.resource_path.get_base_dir()
	var file_name := model.node_name(node_id).to_snake_case().validate_filename()
	if file_name.is_empty():
		file_name = "weaver_node"
	return dir.path_join(file_name + ".gd")

func _on_script_created(script: Script) -> void:
	var node_id := _script_node
	_script_node = -1
	if script == null or node_id < 0:
		return
	var err := model.set_node_script(node_id, script)
	if not err.is_empty():
		status.emit("Can't attach the script: " + err, false)
		return
	status.emit("Attached %s to \"%s\"." % [script.resource_path.get_file(), model.node_name(node_id)], true)
	edit_script(node_id)
