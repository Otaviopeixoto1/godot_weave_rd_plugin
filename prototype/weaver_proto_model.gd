@tool
extends RefCounted
class_name WeaverProtoModel

#
# Placeholder data model for the WeaveRD graph prototype. Nothing here talks to the godot_weave_rd module yet,
# except for the slots, which are real WeaverViewSlot / WeaverCameraSlot resources.
#
#  - Views render in array order (index 0 renders first).
#  - A view is identified by its WeaverViewSlot and a lane by its WeaverCameraSlot (header-is-slot): views and lanes
#    have no names of their own and can't be created without a slot.
#  - Each view holds lanes (spiders). Only one lane of a view runs per frame (one camera per viewport).
#  - Each lane has one column of node ids per stage (EffectCallbackType). Inside a column, top runs first.
#  - Nodes own named placeholder resources. A binding means "consumer reads producer's resource".
#  - A binding is valid when the producer runs before the consumer in the same frame.
#

signal changed

const STAGE_COUNT := 5
const STAGE_NAMES: PackedStringArray = ["Pre-opaque", "Post-opaque", "Post-sky", "Pre-transparent", "Post-transparent"]
const STAGE_SHORT: PackedStringArray = ["Pre-O", "Post-O", "Sky", "Pre-T", "Post-T"]

# Array of { id, slot, path_lane, lanes: Array of { id, slot, columns: Array (STAGE_COUNT) of Array[int] } }
# slot is a WeaverViewSlot / WeaverCameraSlot, or null only for data that predates slots.
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
func add_view(slot: WeaverViewSlot) -> int:
	if slot == null:
		push_error("A view needs a WeaverViewSlot.")
		return -1
	var id := _new_id()
	views.append({ "id": id, "slot": slot, "path_lane": 0, "lanes": [] })
	_notify()
	return id

func add_lane(view_id: int, slot: WeaverCameraSlot) -> int:
	var view := get_view(view_id)
	if view.is_empty():
		return -1
	if slot == null:
		push_error("A lane needs a WeaverCameraSlot.")
		return -1
	var columns: Array = []
	for i in STAGE_COUNT:
		columns.append([])
	var id := _new_id()
	(view.lanes as Array).append({ "id": id, "slot": slot, "columns": columns })
	_notify()
	return id

func set_view_slot(view_id: int, slot: WeaverViewSlot) -> void:
	var view := get_view(view_id)
	if view.is_empty() or slot == null:
		return
	view.slot = slot
	_notify()

func set_lane_slot(view_id: int, lane_id: int, slot: WeaverCameraSlot) -> void:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty() or slot == null:
		return
	lane.slot = slot
	_notify()

# Called after a slot was renamed so headers and the matrix pick up the new name.
func slot_renamed() -> void:
	_notify()

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
# Slots
#
static func slot_name(slot: Resource) -> String:
	if slot == null:
		return "No slot"
	return WeaverSlotLibrary.get_display_name(slot)

# Slots already taken, for the slot picker: slot -> reason it can't be picked.
# View slots are unique in the web; camera slots are unique inside their view (the same camera slot may appear in
# other views). except_id is the view or lane whose slot is being changed, so its own slot stays selectable.
func used_view_slots(except_view_id: int = -1) -> Dictionary:
	var used := {}
	for view in views:
		if view.slot != null and view.id != except_view_id:
			used[view.slot] = "Already a view in this web."
	return used

func used_camera_slots(view_id: int, except_lane_id: int = -1) -> Dictionary:
	var used := {}
	var view := get_view(view_id)
	for lane in view.get("lanes", []):
		if lane.slot != null and lane.id != except_lane_id:
			used[lane.slot] = "Already a lane in this view."
	return used

# Returns "" when the view's slot is fine, otherwise what's wrong with it (missing, duplicate, file deleted).
func view_slot_error(view_id: int) -> String:
	var view := get_view(view_id)
	if view.is_empty():
		return ""
	if view.slot == null:
		return "This view has no slot. Scenes can't bind to it."
	for i in views.size():
		if views[i].id != view_id and views[i].slot == view.slot:
			return "View %d uses the same slot." % i
	return _slot_file_error(view.slot)

func lane_slot_error(view_id: int, lane_id: int) -> String:
	var view := get_view(view_id)
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return ""
	if lane.slot == null:
		return "This lane has no slot. Cameras can't bind to it."
	var lanes: Array = view.lanes
	for i in lanes.size():
		if lanes[i].id != lane_id and lanes[i].slot == lane.slot:
			return "Lane %d of this view uses the same slot." % i
	return _slot_file_error(lane.slot)

func _slot_file_error(slot: Resource) -> String:
	if not slot.resource_path.is_empty() and not slot.resource_path.contains("::") and not FileAccess.file_exists(slot.resource_path):
		return "The slot file %s is missing." % slot.resource_path
	return ""


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
		return "\"%s\" renders after this view." % slot_name(views[p.view].slot)
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

# The demo uses in-memory slots so opening the prototype doesn't write files into the project.
# They show as "unsaved"; use Change slot to swap in real slot files.
func seed_demo() -> void:
	_batching = true
	views.clear()
	nodes.clear()
	bindings.clear()
	_next_id = 1

	var minimap_view := add_view(_demo_slot(WeaverViewSlot.new(), "minimap"))
	var minimap_lane := add_lane(minimap_view, _demo_slot(WeaverCameraSlot.new(), "topdown"))
	var minimap := add_node(minimap_view, minimap_lane, 4, "Minimap")
	_add_named_resource(minimap, "minimap_tex")

	var main_view := add_view(_demo_slot(WeaverViewSlot.new(), "main"))
	var main_lane := add_lane(main_view, _demo_slot(WeaverCameraSlot.new(), "player"))
	var cine_lane := add_lane(main_view, _demo_slot(WeaverCameraSlot.new(), "cinematic"))
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


func _demo_slot(slot: Resource, slot_name_: String) -> Resource:
	slot.resource_name = slot_name_
	return slot

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
