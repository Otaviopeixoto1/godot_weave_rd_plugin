@tool
extends GraphEdit

#
# TODO: 
#  - Serialization: Import some serialized resource for figuring all connections
#  -- This should depend on the godot_weave_rd module, so the module will export the settings and connections
#  
#  - Typing: We need to reflect the connection types from the Weave RenderGraph Nodes
#
#  - Fixed Nodes: WE will hook into the rendering pipeline injection points, therefore we must pre-register them
#  -- These will appear on the graph as fixed nodes 
#

@export var contextMenuPopup: PopupMenu

func _gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if (contextMenuPopup != null):
				contextMenuPopup.popup(Rect2i(get_global_mouse_position().x, get_global_mouse_position().y, 100, 30))


func _ready():
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int):
	print("CONNECT - from: (%s, %s) -> to: (%s, %s)"  % [from_node, from_port, to_node, to_port])
	connect_node(from_node, from_port, to_node, to_port)

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int):
	print("DISCONNECT - from: (%s, %s) -> to: (%s, %s)"  % [from_node, from_port, to_node, to_port])
	disconnect_node(from_node, from_port, to_node, to_port)
