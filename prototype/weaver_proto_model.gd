@tool
extends RefCounted
class_name WeaverProtoModel

#
# Placeholder data model for the WeaveRD graph prototype. Nothing here talks to the godot_weave_rd module yet.
#
#  - Views render in array order (index 0 renders first).
#  - Each view holds lanes (spiders). Only one lane of a view runs per frame (one camera per viewport).
#  - Each lane has one column of node ids per stage (EffectCallbackType). Inside a column, top runs first.
#  - Nodes own named placeholder resources. A binding means "consumer reads producer's resource".
#  - A binding is valid when the producer runs before the consumer in the same frame.
#

signal changed

const STAGE_COUNT := 5
const STAGE_NAMES: PackedStringArray = ["Pre-opaque", "Post-opaque", "Post-sky", "Pre-transparent", "Post-transparent"]
const STAGE_SHORT: PackedStringArray = ["Pre-O", "Post-O", "Sky", "Pre-T", "Post-T"]

# Array of { id, name, path_lane, lanes: Array of { id, name, columns: Array (STAGE_COUNT) of Array[int] } }
var views: Array = []
# node id -> { id, name, resources: Array[String] }
var nodes: Dictionary = {}
# Array of { producer: int, resource: String, consumer: int }
var bindings: Array = []

var _next_id := 1
var _batching := false


#
# Structure
#
func add_view(view_name: String = "") -> int:
	var id := _new_id()
	if view_name.is_empty():
		view_name = "View %d" % views.size()
	views.append({ "id": id, "name": view_name, "path_lane": 0, "lanes": [] })
	_notify()
	return id

func add_lane(view_id: int, lane_name: String = "") -> int:
	var view := get_view(view_id)
	if view.is_empty():
		return -1
	var columns: Array = []
	for i in STAGE_COUNT:
		columns.append([])
	if lane_name.is_empty():
		lane_name = "Camera slot %d" % (view.lanes as Array).size()
	var id := _new_id()
	(view.lanes as Array).append({ "id": id, "name": lane_name, "columns": columns })
	_notify()
	return id

func add_node(view_id: int, lane_id: int, stage: int, node_name: String = "") -> int:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return -1
	var id := _new_id()
	if node_name.is_empty():
		node_name = "Pass %d" % id
	nodes[id] = { "id": id, "name": node_name, "resources": [] }
	(lane.columns[stage] as Array).append(id)
	_notify()
	return id

func remove_node(node_id: int) -> void:
	var loc := locate(node_id)
	if loc.is_empty():
		return
	(_column_at(loc) as Array).erase(node_id)
	nodes.erase(node_id)
	bindings = bindings.filter(func(b): return b.producer != node_id and b.consumer != node_id)
	_notify()

# Moves a node to another stage column (possibly in another lane or view). Bindings are kept even if
# the move makes them invalid, so the UI can show them as broken instead of silently dropping them.
func move_node(node_id: int, view_id: int, lane_id: int, stage: int, index: int) -> void:
	var loc := locate(node_id)
	var lane := get_lane(view_id, lane_id)
	if loc.is_empty() or lane.is_empty():
		return
	var from_col: Array = _column_at(loc)
	var to_col: Array = lane.columns[stage]
	if is_same(from_col, to_col) and loc.index < index:
		index -= 1
	from_col.remove_at(loc.index)
	to_col.insert(clampi(index, 0, to_col.size()), node_id)
	_notify()

func set_path_lane(view_id: int, lane_index: int) -> void:
	var view := get_view(view_id)
	if view.is_empty():
		return
	view.path_lane = lane_index
	_notify()


#
# Placeholder resources
#
func add_resource(node_id: int) -> String:
	var node: Dictionary = nodes.get(node_id, {})
	if node.is_empty():
		return ""
	var resources: Array = node.resources
	var n := resources.size() + 1
	var res_name := "res_%d" % n
	while resources.has(res_name):
		n += 1
		res_name = "res_%d" % n
	resources.append(res_name)
	_notify()
	return res_name

func remove_resource(node_id: int, resource: String) -> void:
	var node: Dictionary = nodes.get(node_id, {})
	if node.is_empty():
		return
	(node.resources as Array).erase(resource)
	bindings = bindings.filter(func(b): return not (b.producer == node_id and b.resource == resource))
	_notify()


#
# Bindings
#

# Returns "" when consumer may read a resource owned by producer, otherwise the reason it can't.
func bind_error(producer: int, consumer: int) -> String:
	if producer == consumer:
		return "A node can't read its own resource."
	var p := locate(producer)
	var c := locate(consumer)
	if p.is_empty() or c.is_empty():
		return "Unknown node."
	if p.view < c.view:
		return ""
	if p.view > c.view:
		return "\"%s\" renders after this view." % views[p.view].name
	if p.lane != c.lane:
		return "Lanes in one view never run in the same frame."
	if p.stage < c.stage or (p.stage == c.stage and p.index < c.index):
		return ""
	return "\"%s\" runs after this node." % nodes[producer].name

func bind(producer: int, resource: String, consumer: int) -> String:
	var err := bind_error(producer, consumer)
	if err.is_empty() and is_bound(producer, resource, consumer):
		err = "Already bound."
	if err.is_empty():
		bindings.append({ "producer": producer, "resource": resource, "consumer": consumer })
		_notify()
	return err

func unbind(producer: int, resource: String, consumer: int) -> void:
	bindings = bindings.filter(func(b): return not (b.producer == producer and b.resource == resource and b.consumer == consumer))
	_notify()

func is_bound(producer: int, resource: String, consumer: int) -> bool:
	for b in bindings:
		if b.producer == producer and b.resource == resource and b.consumer == consumer:
			return true
	return false

func bindings_of_consumer(consumer: int) -> Array:
	return bindings.filter(func(b): return b.consumer == consumer)


#
# Queries
#

# Returns { view, lane, stage, index } (all indices) or {} if the node doesn't exist.
func locate(node_id: int) -> Dictionary:
	for vi in views.size():
		var lanes: Array = views[vi].lanes
		for li in lanes.size():
			var columns: Array = lanes[li].columns
			for s in STAGE_COUNT:
				var index := (columns[s] as Array).find(node_id)
				if index >= 0:
					return { "view": vi, "lane": li, "stage": s, "index": index }
	return {}

# 1-based run position of a node inside its own lane.
func lane_order_index(node_id: int) -> int:
	var loc := locate(node_id)
	if loc.is_empty():
		return 0
	var columns: Array = views[loc.view].lanes[loc.lane].columns
	var n := 0
	for s in int(loc.stage):
		n += (columns[s] as Array).size()
	return n + int(loc.index) + 1

# Node ids in execution order for one frame: the selected lane (path_lane) of every view.
func execution_path() -> Array:
	var path: Array = []
	for view in views:
		var lanes: Array = view.lanes
		if lanes.is_empty():
			continue
		var lane: Dictionary = lanes[clampi(view.path_lane, 0, lanes.size() - 1)]
		for s in STAGE_COUNT:
			path.append_array(lane.columns[s])
	return path

func get_view(view_id: int) -> Dictionary:
	for view in views:
		if view.id == view_id:
			return view
	return {}

func get_lane(view_id: int, lane_id: int) -> Dictionary:
	var view := get_view(view_id)
	if view.is_empty():
		return {}
	for lane in view.lanes:
		if lane.id == lane_id:
			return lane
	return {}

func node_name(node_id: int) -> String:
	return nodes.get(node_id, {}).get("name", "?")

static func resource_key(producer: int, resource: String) -> String:
	return "%d/%s" % [producer, resource]

static func resource_color(producer: int, resource: String) -> Color:
	var h := float(absi(hash(resource_key(producer, resource))) % 997) / 997.0
	return Color.from_hsv(h, 0.5, 0.9)


#
# Demo data
#
func seed_demo() -> void:
	_batching = true
	views.clear()
	nodes.clear()
	bindings.clear()
	_next_id = 1

	var minimap_view := add_view("Minimap (SubViewport)")
	var minimap_lane := add_lane(minimap_view, "Minimap camera")
	var minimap := add_node(minimap_view, minimap_lane, 4, "Minimap")
	_add_named_resource(minimap, "minimap_tex")

	var main_view := add_view("Main (root window)")
	var main_lane := add_lane(main_view, "Main camera")
	var cine_lane := add_lane(main_view, "Cinematic camera")
	var voxels := add_node(main_view, main_lane, 0, "Voxels")
	_add_named_resource(voxels, "voxel_depth")
	_add_named_resource(voxels, "voxel_normals")
	var ao := add_node(main_view, main_lane, 1, "Ambient occlusion")
	_add_named_resource(ao, "ao")
	var compose := add_node(main_view, main_lane, 4, "Compose")
	var outline := add_node(main_view, main_lane, 4, "Outline")
	var blur := add_node(main_view, cine_lane, 4, "Blur")
	_add_named_resource(blur, "blurred")

	bind(voxels, "voxel_normals", ao)
	bind(ao, "ao", compose)
	bind(minimap, "minimap_tex", compose)
	bind(voxels, "voxel_depth", outline)

	_batching = false
	_notify()


func _add_named_resource(node_id: int, resource: String) -> void:
	(nodes[node_id].resources as Array).append(resource)

func _column_at(loc: Dictionary) -> Array:
	return views[loc.view].lanes[loc.lane].columns[loc.stage]

func _new_id() -> int:
	_next_id += 1
	return _next_id - 1

func _notify() -> void:
	if not _batching:
		changed.emit()
