@tool
extends RefCounted
class_name WeaverProtoModel

#
# Data model of the WeaveRD editor, parsed from a real WeaverWeb (open_web) and written back to it on every edit.
#
#  - Views render in array order (index 0 renders first).
#  - A view is identified by its WeaverViewSlot and a lane (WeaverSpider) by its WeaverCameraSlot (header-is-slot):
#    views and lanes have no names of their own and can't be created without a slot.
#  - Each view holds lanes (WeaverSpiders). Only one lane (WeaverSpider) of a view runs per frame (one camera per viewport).
#  - Each lane (WeaverSpider) has one column of node ids per stage (EffectCallbackType). Inside a column, top runs first.
#    In the WeaverSpider the column order is the order of its weaver_nodes array, filtered by stage.
#  - Nodes are the WeaverWebNodes (or plain CompositorEffects) of the WeaverSpider.
#
# Prototype only: the frame resources of each node (named strings) and the bindings between them are still kept in
# memory, they are NOT saved in the web. A binding means "consumer reads producer's resource", and it is valid when
# the producer runs before the consumer in the same frame.
#
# Ids are given per resource instance and kept for the editor session, so reload() keeps the frame resources and
# bindings of nodes that are still in the web.
#

signal changed
signal dirty_changed(dirty: bool)

const STAGE_COUNT := 5
const STAGE_NAMES: PackedStringArray = ["Pre-opaque", "Post-opaque", "Post-sky", "Pre-transparent", "Post-transparent"]
const STAGE_SHORT: PackedStringArray = ["Pre-O", "Post-O", "Sky", "Pre-T", "Post-T"]

# The edited web. null when no web is open.
var web: WeaverWeb
# True when the web was edited after it was opened or last saved.
var dirty := false

# Array of { id, resource: WeaverView, slot, path_lane, kept, lanes: Array of { id, resource: WeaverSpider, slot, kept, columns: Array (STAGE_COUNT) of Array[int] } }
# kept: entries of the resource array the UI doesn't show (null rows the inspector added, duplicates). They are written back at the end.
var views: Array = []
# node id -> { id, resource: WeaverWebNode or CompositorEffect, resources: Array[String] (prototype frame resources) }
var nodes: Dictionary = {}
# Array of { producer: int, resource: String, consumer: int }
var bindings: Array = []

var _kept_views: Array = []
var _ids := {} # Resource -> id
var _next_id := 1


#
# Web
#

# Opens a web for editing. Frame resources and bindings of the previous web are dropped.
func open_web(p_web: WeaverWeb) -> void:
	web = p_web
	_ids.clear()
	nodes.clear()
	bindings.clear()
	views.clear()
	_set_dirty(false)
	reload()

func close_web() -> void:
	open_web(null)

# Parses the web again (after it was edited somewhere else, e.g. in the inspector).
func reload() -> void:
	var old_nodes := nodes
	var old_path_lanes := {}
	for view in views:
		old_path_lanes[view.id] = view.path_lane
	views = []
	nodes = {}
	_kept_views = []

	if web != null:
		var seen := {}
		for view_res in web.weaver_views:
			if view_res == null or seen.has(view_res):
				_kept_views.append(view_res)
				continue
			seen[view_res] = true
			var view_id := _id_for(view_res)
			var view := { "id": view_id, "resource": view_res, "slot": view_res.slot, "path_lane": old_path_lanes.get(view_id, 0), "kept": [], "lanes": [] }
			for spider in view_res.weaver_spiders:
				if spider == null or seen.has(spider):
					view.kept.append(spider)
					continue
				seen[spider] = true
				view.lanes.append(_parse_lane(spider, old_nodes, seen))
			views.append(view)

	bindings = bindings.filter(func(b): return nodes.has(b.producer) and nodes.has(b.consumer))
	_notify()

func _parse_lane(spider: WeaverSpider, old_nodes: Dictionary, seen: Dictionary) -> Dictionary:
	var columns: Array = []
	for i in STAGE_COUNT:
		columns.append([])
	var lane := { "id": _id_for(spider), "resource": spider, "slot": spider.slot, "kept": [], "columns": columns }
	for entry in spider.weaver_nodes:
		var stage := entry_stage(entry)
		if stage < 0 or seen.has(entry):
			lane.kept.append(entry)
			continue
		seen[entry] = true
		var id := _id_for(entry)
		nodes[id] = { "id": id, "resource": entry, "resources": old_nodes.get(id, {}).get("resources", []) }
		(columns[stage] as Array).append(id)
	return lane

# Saves the web to its file.
func save() -> Error:
	if web == null or web.resource_path.is_empty():
		return ERR_UNCONFIGURED
	var err := ResourceSaver.save(web)
	if err == OK:
		_set_dirty(false)
	return err

func has_web() -> bool:
	return web != null

func web_name() -> String:
	if web == null:
		return "No web"
	return web.resource_path.get_file() if not web.resource_path.is_empty() else "(unsaved web)"

# Stage column of a spider entry, or -1 when the entry is not a node (null or another resource type).
static func entry_stage(entry: Resource) -> int:
	if entry is WeaverWebNode:
		return clampi(entry.stage, 0, STAGE_COUNT - 1)
	if entry is CompositorEffect:
		return clampi(entry.effect_callback_type, 0, STAGE_COUNT - 1)
	return -1


#
# Structure (written to the web)
#
func add_view(slot: WeaverViewSlot) -> int:
	if web == null:
		push_error("Open a WeaverWeb first.")
		return -1
	if slot == null:
		push_error("A view needs a WeaverViewSlot.")
		return -1
	var res := WeaverView.new()
	var id := _id_for(res)
	views.append({ "id": id, "resource": res, "slot": slot, "path_lane": 0, "kept": [], "lanes": [] })
	_edited()
	return id

func remove_view(view_id: int) -> void:
	var view := get_view(view_id)
	if view.is_empty():
		return
	for lane in view.lanes:
		_forget_lane_nodes(lane)
	views.erase(view)
	_edited()

func add_lane(view_id: int, slot: WeaverCameraSlot) -> int:
	var view := get_view(view_id)
	if view.is_empty():
		return -1
	if slot == null:
		push_error("A lane (WeaverSpider) needs a WeaverCameraSlot.")
		return -1
	var columns: Array = []
	for i in STAGE_COUNT:
		columns.append([])
	var res := WeaverSpider.new()
	var id := _id_for(res)
	(view.lanes as Array).append({ "id": id, "resource": res, "slot": slot, "kept": [], "columns": columns })
	_edited()
	return id

func remove_lane(view_id: int, lane_id: int) -> void:
	var view := get_view(view_id)
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return
	_forget_lane_nodes(lane)
	(view.lanes as Array).erase(lane)
	view.path_lane = clampi(view.path_lane, 0, maxi((view.lanes as Array).size() - 1, 0))
	_edited()

func set_view_slot(view_id: int, slot: WeaverViewSlot) -> void:
	var view := get_view(view_id)
	if view.is_empty() or slot == null:
		return
	view.slot = slot
	_edited()

func set_lane_slot(view_id: int, lane_id: int, slot: WeaverCameraSlot) -> void:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty() or slot == null:
		return
	lane.slot = slot
	_edited()

# Called after a slot was renamed so headers and the matrix pick up the new name. The slot file is saved by
# WeaverSlotLibrary, the web itself doesn't change.
func slot_renamed() -> void:
	_notify()

# Adds a new WeaverWebNode at the end of a stage column.
func add_node(view_id: int, lane_id: int, stage: int, node_name_: String = "") -> int:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return -1
	var res := WeaverWebNode.new()
	res.stage = stage
	res.resource_name = node_name_ if not node_name_.is_empty() else _unique_node_name()
	var id := _id_for(res)
	nodes[id] = { "id": id, "resource": res, "resources": [] }
	(lane.columns[stage] as Array).append(id)
	_edited()
	return id

func remove_node(node_id: int) -> void:
	var loc := locate(node_id)
	if loc.is_empty():
		return
	(_column_at(loc) as Array).erase(node_id)
	nodes.erase(node_id)
	bindings = bindings.filter(func(b): return b.producer != node_id and b.consumer != node_id)
	_edited()

func rename_node(node_id: int, new_name: String) -> void:
	var node: Dictionary = nodes.get(node_id, {})
	if node.is_empty():
		return
	(node.resource as Resource).resource_name = new_name.strip_edges()
	_edited()

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
	_edited()

# Which lane (WeaverSpider) of a view the matrix shows. Editor state only.
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
# other views). except_id is the view or lane (WeaverSpider) whose slot is being changed, so its own slot stays selectable.
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
# Frame resources (prototype, in memory only)
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
# Bindings (prototype, in memory only)
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
	return "\"%s\" runs after this node." % node_name(producer)

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

# 1-based run position of a node inside its own lane (WeaverSpider).
func lane_order_index(node_id: int) -> int:
	var loc := locate(node_id)
	if loc.is_empty():
		return 0
	var columns: Array = views[loc.view].lanes[loc.lane].columns
	var n := 0
	for s in int(loc.stage):
		n += (columns[s] as Array).size()
	return n + int(loc.index) + 1

# Node ids in execution order for one frame: the selected lane (WeaverSpider) (path_lane) of every view.
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

func node_resource(node_id: int) -> Resource:
	return nodes.get(node_id, {}).get("resource")

# The node's resource_name, else its script's class name or file name, else its class.
func node_name(node_id: int) -> String:
	var res := node_resource(node_id)
	if res == null:
		return "?"
	if not res.resource_name.is_empty():
		return res.resource_name
	var script := res.get_script() as Script
	if script != null:
		if not script.get_global_name().is_empty():
			return script.get_global_name()
		if not script.resource_path.is_empty() and not script.resource_path.contains("::"):
			return script.resource_path.get_file().get_basename()
	return res.get_class()

# True for plain CompositorEffects (not WeaverWebNodes) in a WeaverSpider.
func is_plain_effect(node_id: int) -> bool:
	var res := node_resource(node_id)
	return res is CompositorEffect

static func resource_key(producer: int, resource: String) -> String:
	return "%d/%s" % [producer, resource]

static func resource_color(producer: int, resource: String) -> Color:
	var h := float(absi(hash(resource_key(producer, resource))) % 997) / 997.0
	return Color.from_hsv(h, 0.5, 0.9)


#
# Internals
#

# Writes the model back into the web resources: slots, the WeaverSpiders of each WeaverView, the weaver_nodes of each
# WeaverSpider (column order, stage by stage) and the stage of each node.
func _write_web() -> void:
	if web == null:
		return
	var view_list: Array[WeaverView] = []
	for view in views:
		var view_res: WeaverView = view.resource
		view_res.slot = view.slot
		var spiders: Array[WeaverSpider] = []
		for lane in view.lanes:
			var spider: WeaverSpider = lane.resource
			spider.slot = lane.slot
			var entries: Array[Resource] = []
			for s in STAGE_COUNT:
				for id in lane.columns[s]:
					var res: Resource = nodes[id].resource
					if res is WeaverWebNode:
						if res.stage != s:
							res.stage = s
					elif res is CompositorEffect:
						if res.effect_callback_type != s:
							res.effect_callback_type = s
					entries.append(res)
			entries.append_array(lane.kept)
			spider.weaver_nodes = entries
			spiders.append(spider)
		spiders.append_array(view.kept)
		view_res.weaver_spiders = spiders
		view_list.append(view_res)
	view_list.append_array(_kept_views)
	web.weaver_views = view_list
	web.emit_changed()

func _forget_lane_nodes(lane: Dictionary) -> void:
	for column in lane.columns:
		for id in column:
			nodes.erase(id)
	bindings = bindings.filter(func(b): return nodes.has(b.producer) and nodes.has(b.consumer))

func _unique_node_name() -> String:
	var taken := {}
	for id in nodes:
		taken[node_name(id)] = true
	var n := nodes.size() + 1
	while taken.has("Pass %d" % n):
		n += 1
	return "Pass %d" % n

func _column_at(loc: Dictionary) -> Array:
	return views[loc.view].lanes[loc.lane].columns[loc.stage]

func _id_for(res: Resource) -> int:
	if not _ids.has(res):
		_ids[res] = _next_id
		_next_id += 1
	return _ids[res]

func _set_dirty(value: bool) -> void:
	if dirty == value:
		return
	dirty = value
	dirty_changed.emit(dirty)

# A change to the web itself: written back to the resources and marks the web as unsaved.
func _edited() -> void:
	_write_web()
	_set_dirty(true)
	changed.emit()

# A change to editor-only state (frame resources, bindings, the matrix lane).
func _notify() -> void:
	changed.emit()
