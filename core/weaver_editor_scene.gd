@tool
extends MarginContainer
class_name WeaverEditorScene

func setup_for_plugin():
	#TODO: enable the graph to work. this is to stop the scene editor from loading the nodes
	#      and triggering unwanted functions
	var mainGraph: WeaverWebGraph = %WeaverWebGraph
	if (mainGraph):
		mainGraph.enable_dynamic_mode()
	
	pass

func cleanup_plugin():
	#TODO: cleanup any resources allocated for the plugin here
	pass
