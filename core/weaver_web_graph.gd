@tool
extends GraphEdit
class_name WeaverWebGraph

const WeaverEditorData := WeaverStateCache.WeaverEditorData


#
# TODO: 
#  - IMPLEMENT VIEWS AND SPIDERS: 
#  - Views: these are isolated units that can share results with later views in the timeline
#  - Spiders: These are containers for nodes which by themselves represent atomic processing units in the
#             godot injection points. Spiders in the same view are COMPLETELY independent.
#             SPIDERS ARE GRAPHS OF NODES. Each spider will be represented by a random color
#             Nodes need some form of RUNTIME REFLECTION system working for them
#
#  - Serialization: Import some serialized resource for figuring all connections
#  -- This should depend on the godot_weave_rd module, so the module will export the settings and connections
#  
#  - Typing: We need to reflect the connection types from the Weave RenderGraph Nodes
#
  
# Dynamic mode indicates that the plugin was enabled and the graph can load/unload nodes in the scene tree
# This is used because these scripts are forced to be tool scripts. Dynamic mode helps diferentiate from the
# regular scene editor to the actual plugin scene
var _dynamic_mode: bool = false
var _editor_state: WeaverEditorData

# Nodes:
var weaver_view_node_scene = preload("res://addons/godot_weave_rd_plugin/scenes/graph/weaver_view_graph_node.tscn")

@onready var contextMenuPopup: PopupMenu = $WeaverContextMenu
@onready var fileDialog: FileDialog = $WeaverFileDialog

func _gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if (contextMenuPopup != null):
				contextMenuPopup.popup(Rect2i(get_global_mouse_position().x, get_global_mouse_position().y, 100, 30))

func _ready():
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	fileDialog.file_selected.connect(_on_web_file_selected)
	
	# Only load the configs and graph nodes if we are in dynamic mode
	if (!_dynamic_mode):
		return
	
	_editor_state = WeaverEditorData.load_or_default()
	if (_editor_state.opened_web):
		_load_web_graph(_editor_state.opened_web)

#
# Signal callbacks
#
func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int):
	print("CONNECT - from: (%s, %s) -> to: (%s, %s)"  % [from_node, from_port, to_node, to_port])
	connect_node(from_node, from_port, to_node, to_port)

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int):
	print("DISCONNECT - from: (%s, %s) -> to: (%s, %s)"  % [from_node, from_port, to_node, to_port])
	disconnect_node(from_node, from_port, to_node, to_port)

func _on_web_file_selected(filePath: String):
	print("LOADING: ", filePath)
	
	var web := ResourceLoader.load(filePath) as WeaverWeb
	if (web):
		loadWeb(web)

#
# Handlers
#

# This must be called from the EditorPlugin script. it will enable the graph to dynamically
# create and destroy nodes in the scene tree among other things...
func enable_dynamic_mode():
	_dynamic_mode = true

func loadWeb(web: WeaverWeb):
	_editor_state.opened_web = web
	_editor_state.save()
	_load_web_graph(web)

func _load_web_graph(web: WeaverWeb):
	if (!_dynamic_mode):
		print("WeaverRD: DYNAMIC MODE DISABLED (THE PLUGIN IS NOT ACTIVE AND THEREFORE NO NODES WILL BE LOADED)")
		return
	
	#TODO: Load all views and their spiders + nodes
	print("LOADING... numVIEWS: ", web.weaver_views.size())
	for view: WeaverView in web.weaver_views:
		var view_node: Node = weaver_view_node_scene.instantiate()
		add_child(view_node)
		
		
