@tool
extends RefCounted
class_name WeaverModel

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
# Resources (T-025/T-026) are saved in the web: each lane (WeaverSpider) has its resources, the bindings of its nodes'
# slots (WeaverResourceBinding) and the lane resources it provides to shared resources (WeaverSharedOutput); the web has
# the shared resources. Slots come from the node scripts (WeaverWebNode.get_resource_slots()). Errors and versions come
# from the module (WeaverWeb.validate() and get_resource_versions()), recomputed on every change (_analyze()).
# Every create slot makes its own lane resource: the model adds it (named after the slot) and binds it, so a create slot
# is never assigned by hand. Removing or moving the node removes or moves what it created.
#
# Ids are given per resource instance and kept for the editor session.
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
# node id -> { id, resource: WeaverWebNode or CompositorEffect }
var nodes: Dictionary = {}

# WeaverWeb.validate() of the last change, and its resource issues indexed for the UI.
var issues: Array = []
var _slot_issues := {} # "node_id/slot" -> issue (errors win over warnings)
var _lane_issues := {} # lane id -> Array of issues about the lane (no node)
# "node_id/slot" -> get_resource_versions() record: every lane under the frame path of the views before it.
var _versions := {}

var _kept_views: Array = []
var _ids := {} # Resource -> id
var _next_id := 1


#
# Web
#

func open_web(p_web: WeaverWeb) -> void:
	web = p_web
	_ids.clear()
	nodes.clear()
	views.clear()
	_set_dirty(false)
	reload()

func close_web() -> void:
	open_web(null)

# Parses the web again (after it was edited somewhere else, e.g. in the inspector).
func reload() -> void:
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
				view.lanes.append(_parse_lane(spider, seen))
			views.append(view)

	# Webs saved before a script got a create slot (or edited outside the plugin) get their created resources now.
	if _ensure_created_resources():
		_write_web()
		_set_dirty(true)
	_notify()

func _parse_lane(spider: WeaverSpider, seen: Dictionary) -> Dictionary:
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
		nodes[id] = { "id": id, "resource": entry }
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

# Moves a view in the render order. `index` is an insertion point in the current order (0..views.size(): before the
# view at that index, or at the end), like a drop between two views. Views render in array order, so this can change
# which views may read a shared resource; validation reports what breaks.
func move_view(view_id: int, index: int) -> void:
	var view := get_view(view_id)
	if view.is_empty():
		return
	var from := views.find(view)
	var to := insertion_to_index(from, index, views.size())
	if to == from:
		return
	views.remove_at(from)
	views.insert(to, view)
	_edited()

# Moves a lane (WeaverSpider) inside its view. `index` is an insertion point like in move_view(). The matrix keeps
# showing the same lane.
func move_lane(view_id: int, lane_id: int, index: int) -> void:
	var view := get_view(view_id)
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return
	var lanes: Array = view.lanes
	var from := lanes.find(lane)
	var to := insertion_to_index(from, index, lanes.size())
	if to == from:
		return
	var path_lane: Dictionary = lanes[clampi(view.path_lane, 0, lanes.size() - 1)]
	lanes.remove_at(from)
	lanes.insert(to, lane)
	view.path_lane = lanes.find(path_lane)
	_edited()

# Where an item at `from` ends up when dropped at insertion point `index` (the item is taken out first).
static func insertion_to_index(from: int, index: int, count: int) -> int:
	var to := clampi(index, 0, count)
	if to > from:
		to -= 1
	return clampi(to, 0, count - 1)

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

# Adds a node at the end of a stage column. type_name is WeaverWebNode (default), a native class derived from it or a
# script class (class_name) extending it. Plain WeaverWebNodes get a "Pass N" name; other types show their class name.
func add_node(view_id: int, lane_id: int, stage: int, node_name_: String = "", type_name: String = "WeaverWebNode") -> int:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return -1
	var res := instantiate_node_type(type_name)
	if res == null:
		push_error("\"%s\" is not a WeaverWebNode type." % type_name)
		return -1
	res.stage = stage
	if not node_name_.is_empty():
		res.resource_name = node_name_
	elif type_name == "WeaverWebNode":
		res.resource_name = _unique_node_name()
	var id := _id_for(res)
	nodes[id] = { "id": id, "resource": res }
	(lane.columns[stage] as Array).append(id)
	_edited()
	return id

# Removes the node and its slot bindings. Bindings that expected its writes go back to the created/provided version.
func remove_node(node_id: int) -> void:
	var loc := locate(node_id)
	if loc.is_empty():
		return
	var res := node_resource(node_id)
	var made := created_resources(node_id)
	(_column_at(loc) as Array).erase(node_id)
	nodes.erase(node_id)
	for spider in _all_spiders():
		spider.bindings = Array(spider.bindings).filter(func(b): return b != null and b.node != res)
		for b in spider.bindings:
			if b.after == res:
				b.after = null
	# What it created goes with it (slots still bound to it show as unbound).
	for created in made:
		_drop_lane_resource(created)
	_edited()

func rename_node(node_id: int, new_name: String) -> void:
	var node: Dictionary = nodes.get(node_id, {})
	if node.is_empty():
		return
	(node.resource as Resource).resource_name = new_name.strip_edges()
	_edited()

# Attaches a script to a node's resource, or detaches it with null. Returns "" or why the script can't be used.
# The script must extend the resource's native class (WeaverWebNode, or CompositorEffect for plain effects).
func set_node_script(node_id: int, script: Script) -> String:
	var res := node_resource(node_id)
	if res == null:
		return "Unknown node."
	if script != null and not ClassDB.is_parent_class(script.get_instance_base_type(), res.get_class()):
		return "%s extends %s, not %s." % [script.resource_path.get_file(), script.get_instance_base_type(), res.get_class()]
	res.set_script(script)
	_edited()
	return ""

# Replaces a node's resource with a new one of another WeaverWebNode type (see add_node), keeping its name, stage and
# flags. The node keeps its id, so its frame resources and bindings stay. Returns "" or why it can't.
func change_node_type(node_id: int, type_name: String) -> String:
	var node: Dictionary = nodes.get(node_id, {})
	var old := node_resource(node_id) as WeaverWebNode
	if old == null:
		return "Only WeaverWebNodes can change their type."
	var res := instantiate_node_type(type_name)
	if res == null:
		return "\"%s\" is not a WeaverWebNode type." % type_name
	for property in ["resource_name", "enabled", "stage", "access_resolved_color", "access_resolved_depth", "needs_motion_vectors", "needs_normal_roughness", "needs_separate_specular"]:
		res.set(property, old.get(property))
	_ids.erase(old)
	_ids[res] = node_id
	node.resource = res
	# Bindings follow the node (they are checked against the new class's slots by the validation).
	for spider in _all_spiders():
		for b in spider.bindings:
			if b == null:
				continue
			if b.node == old:
				b.node = res
			if b.after == old:
				b.after = res
	_edited()
	return ""

# A new resource of a WeaverWebNode type: a native class (WeaverWebNode or derived) or a global script class extending
# one. Script classes are built as their native base with the script attached, so no script code runs in the editor
# unless the script is @tool. Returns null for anything else.
static func instantiate_node_type(type_name: String) -> WeaverWebNode:
	if ClassDB.class_exists(type_name):
		if not ClassDB.is_parent_class(type_name, "WeaverWebNode") or not ClassDB.can_instantiate(type_name):
			return null
		return ClassDB.instantiate(type_name) as WeaverWebNode
	for info in ProjectSettings.get_global_class_list():
		if info["class"] == type_name:
			var script := load(info.path) as Script
			if script == null or not script.can_instantiate() or not ClassDB.is_parent_class(script.get_instance_base_type(), "WeaverWebNode"):
				return null
			var res := ClassDB.instantiate(script.get_instance_base_type()) as WeaverWebNode
			res.set_script(script)
			return res
	return null

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
	# Bindings live in the node's lane: they move with it (and show as broken if their resources stayed behind).
	var from_spider: WeaverSpider = views[loc.view].lanes[loc.lane].resource
	var to_spider: WeaverSpider = lane.resource
	if from_spider != to_spider:
		var res := node_resource(node_id)
		var made := created_resources(node_id, from_spider)
		var moving: Array = Array(from_spider.bindings).filter(func(b): return b != null and b.node == res)
		from_spider.bindings = Array(from_spider.bindings).filter(func(b): return not moving.has(b))
		to_spider.bindings = Array(to_spider.bindings) + moving
		# The resources it creates move too (renamed if the name is taken there).
		for created in made:
			from_spider.resources = Array(from_spider.resources).filter(func(r): return r != created)
			from_spider.shared_outputs = Array(from_spider.shared_outputs).filter(func(o): return o != null and o.resource != created)
			created.resource_name = _unique_name(created.resource_name, Array(to_spider.resources))
			to_spider.resources = Array(to_spider.resources) + [created]
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
# Resources (saved in the web, T-025)
#
const BUFFER := WeaverResourceHandle.TYPE_BUFFER
const IMAGE := WeaverResourceHandle.TYPE_IMAGE
const SINGLE := WeaverResourceHandle.SHAPE_SINGLE
const LIST := WeaverResourceHandle.SHAPE_LIST

# "buffer", "image list"...
static func kind_name(kind: int, shape: int = SINGLE) -> String:
	return ("buffer" if kind == BUFFER else "image") + (" list" if shape == LIST else "")

# "a buffer", "an image list"...
static func kind_phrase(kind: int, shape: int = SINGLE) -> String:
	return ("a " if kind == BUFFER else "an ") + kind_name(kind, shape)

# A resource's name as the panel shows it: lists end with [].
static func display_name(res: Resource) -> String:
	return res.resource_name + ("[]" if res.shape == LIST else "")

# Slots of a node: Array of { name, access, type, shape, handle_class } (none for plain CompositorEffects).
func node_slots(node_id: int) -> Array:
	var res := node_resource(node_id)
	return res.get_resource_slots() if res is WeaverWebNode else []

func slot_info(node_id: int, slot: StringName) -> Dictionary:
	for s in node_slots(node_id):
		if s.name == slot:
			return s
	return {}

func lane_resources(view_id: int, lane_id: int) -> Array:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return []
	return Array((lane.resource as WeaverSpider).resources).filter(func(r): return r != null)

func shared_resources() -> Array:
	if web == null:
		return []
	return Array(web.shared_resources).filter(func(r): return r != null)

func add_lane_resource(view_id: int, lane_id: int, resource_name: String, kind: int, shape: int = SINGLE) -> WeaverResource:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return null
	var res := WeaverResource.new()
	res.resource_name = _unique_name(resource_name, lane_resources(view_id, lane_id))
	res.kind = kind
	res.shape = shape
	var spider: WeaverSpider = lane.resource
	spider.resources = Array(spider.resources) + [res]
	_edited()
	return res

func rename_resource(res: Resource, new_name: String) -> void:
	if res == null or new_name.strip_edges().is_empty():
		return
	res.resource_name = new_name.strip_edges()
	_edited()

# Removes a lane resource, the bindings to it and what it provides.
func remove_lane_resource(res: WeaverResource) -> void:
	var owner := resource_lane(res)
	if owner.is_empty():
		return
	var spider: WeaverSpider = owner.lane.resource
	spider.resources = Array(spider.resources).filter(func(r): return r != res)
	spider.bindings = Array(spider.bindings).filter(func(b): return b != null and b.resource != res)
	spider.shared_outputs = Array(spider.shared_outputs).filter(func(o): return o != null and o.resource != res)
	_edited()

# Removes a shared resource, what provides it and the bindings to it.
func remove_shared(shared: WeaverSharedResource) -> void:
	if web == null:
		return
	web.shared_resources = Array(web.shared_resources).filter(func(r): return r != shared)
	for spider in _all_spiders():
		spider.shared_outputs = Array(spider.shared_outputs).filter(func(o): return o != null and o.shared != shared)
		spider.bindings = Array(spider.bindings).filter(func(b): return b != null and b.resource != shared)
	_edited()

# The lane owning a lane resource: { view, lane } (model dictionaries), or {}.
func resource_lane(res: WeaverResource) -> Dictionary:
	for view in views:
		for lane in view.lanes:
			if Array((lane.resource as WeaverSpider).resources).has(res):
				return { "view": view, "lane": lane }
	return {}

func slot_binding(node_id: int, slot: StringName) -> WeaverResourceBinding:
	var loc := locate(node_id)
	if loc.is_empty():
		return null
	var spider: WeaverSpider = views[loc.view].lanes[loc.lane].resource
	return spider.find_binding(node_resource(node_id), slot)

# What a drop of `res` on a node's slot does: { action: "bind" | "share" | "refuse", reason: String }.
# from_view / from_lane: where the dragged resource comes from (for lane resources: their lane).
func drop_action(node_id: int, slot: StringName, res: Resource) -> Dictionary:
	var info := slot_info(node_id, slot)
	var loc := locate(node_id)
	if info.is_empty() or loc.is_empty() or res == null:
		return _refuse("Unknown slot.")
	if info.access == WeaverResourceHandle.ACCESS_CREATE:
		return _refuse("A create slot makes its own resource: drag it from here into the slots that use it.")
	if res.kind != info.type or res.shape != info.shape:
		return _refuse("%s is %s slot, %s is %s." % [slot, kind_phrase(info.type, info.shape), res.resource_name, kind_phrase(res.kind, res.shape)])
	if res is WeaverSharedResource:
		if info.access == WeaverResourceHandle.ACCESS_CREATE:
			return _refuse("A create slot makes a resource of its lane: it can't take a shared resource.")
		var source := shared_source_view(res)
		if source >= 0 and loc.view <= source:
			return _refuse("%s is provided by view %d: only later views can use it." % [res.resource_name, source])
		return { "action": "bind", "reason": "Bind %s to %s.%s" % [res.resource_name, node_name(node_id), slot] }
	var owner := resource_lane(res)
	if owner.is_empty():
		return _refuse("%s is not in this web." % res.resource_name)
	var owner_view := views.find(owner.view)
	if owner.lane == views[loc.view].lanes[loc.lane]:
		if info.access == WeaverResourceHandle.ACCESS_CREATE:
			var creator := creator_of(res)
			if creator >= 0 and creator != node_id:
				return _refuse("%s is already created by %s." % [res.resource_name, node_name(creator)])
		return { "action": "bind", "reason": "Bind %s to %s.%s" % [res.resource_name, node_name(node_id), slot] }
	if owner_view == loc.view:
		return _refuse("Lanes of one view never run in the same frame.")
	if owner_view > loc.view:
		return _refuse("%s belongs to view %d, which renders after this one." % [res.resource_name, owner_view])
	if info.access == WeaverResourceHandle.ACCESS_CREATE:
		return _refuse("A create slot makes a resource of its own lane.")
	return { "action": "share", "reason": "Share %s with later views and bind it to %s.%s" % [res.resource_name, node_name(node_id), slot] }

# Binds a slot (replacing its binding). `after` is the newest producer at the node's place, so the binding starts valid.
func bind_slot(node_id: int, slot: StringName, res: Resource) -> String:
	var action := drop_action(node_id, slot, res)
	if action.action != "bind":
		return action.reason
	var loc := locate(node_id)
	var spider: WeaverSpider = views[loc.view].lanes[loc.lane].resource
	var node_res := node_resource(node_id)
	var binding := WeaverResourceBinding.new()
	binding.node = node_res
	binding.slot = slot
	binding.resource = res
	binding.after = null if slot_info(node_id, slot).access == WeaverResourceHandle.ACCESS_CREATE else newest_producer(node_id, res)
	spider.bindings = Array(spider.bindings).filter(func(b): return b != null and not (b.node == node_res and b.slot == slot)) + [binding]
	_edited()
	return ""

func unbind_slot(node_id: int, slot: StringName) -> void:
	var loc := locate(node_id)
	if loc.is_empty():
		return
	var spider: WeaverSpider = views[loc.view].lanes[loc.lane].resource
	var node_res := node_resource(node_id)
	spider.bindings = Array(spider.bindings).filter(func(b): return b != null and not (b.node == node_res and b.slot == slot))
	_edited()

# Points a stale binding at the newest version.
func rebind_to_newest(node_id: int, slot: StringName) -> void:
	var binding := slot_binding(node_id, slot)
	if binding == null:
		return
	binding.after = newest_producer(node_id, binding.resource)
	_edited()

# Creates a shared resource from a lane resource of an earlier view, provided by its lane, and binds the slot to it.
func share_resource(res: WeaverResource, node_id: int, slot: StringName) -> String:
	var owner := resource_lane(res)
	if owner.is_empty() or web == null:
		return "Unknown resource."
	var shared := WeaverSharedResource.new()
	shared.resource_name = _unique_name(res.resource_name, shared_resources())
	shared.kind = res.kind
	shared.shape = res.shape
	web.shared_resources = Array(web.shared_resources) + [shared]
	_set_output(owner.lane.resource, shared, res)
	var error := bind_slot(node_id, slot, shared)
	if not error.is_empty():
		_edited()
	return error

# Makes a lane provide one of its resources to a shared resource (replaces what it provided before).
func provide(view_id: int, lane_id: int, shared: WeaverSharedResource, res: WeaverResource) -> String:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty() or shared == null or res == null:
		return "Unknown lane or resource."
	if not Array((lane.resource as WeaverSpider).resources).has(res):
		return "%s is not a resource of this lane." % res.resource_name
	if res.kind != shared.kind or res.shape != shared.shape:
		return "%s is %s, %s is %s." % [res.resource_name, kind_phrase(res.kind, res.shape), shared.resource_name, kind_phrase(shared.kind, shared.shape)]
	_set_output(lane.resource, shared, res)
	_edited()
	return ""

func unprovide(view_id: int, lane_id: int, shared: WeaverSharedResource) -> void:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return
	var spider: WeaverSpider = lane.resource
	spider.shared_outputs = Array(spider.shared_outputs).filter(func(o): return o != null and o.shared != shared)
	_edited()

# The lane resource a lane provides to a shared resource, or null.
func provided_by(view_id: int, lane_id: int, shared: WeaverSharedResource) -> WeaverResource:
	var lane := get_lane(view_id, lane_id)
	if lane.is_empty():
		return null
	for o in (lane.resource as WeaverSpider).shared_outputs:
		if o != null and o.shared == shared:
			return o.resource
	return null

# Index of the first view whose lanes provide the shared resource, -1 when none does.
func shared_source_view(shared: Resource) -> int:
	for vi in views.size():
		for lane in views[vi].lanes:
			for o in (lane.resource as WeaverSpider).shared_outputs:
				if o != null and o.shared == shared:
					return vi
	return -1

# The node whose create slot is bound to a lane resource, -1 when none.
func creator_of(res: WeaverResource) -> int:
	var owner := resource_lane(res)
	if owner.is_empty():
		return -1
	for b in (owner.lane.resource as WeaverSpider).bindings:
		if b != null and b.resource == res and b.node != null and _ids.has(b.node):
			var id: int = _ids[b.node]
			if slot_info(id, b.slot).get("access", -1) == WeaverResourceHandle.ACCESS_CREATE:
				return id
	return -1

# The node whose write is the newest version of `res` where node_id runs (null: as created, or as provided), following the
# frame path of the matrix for shared resources.
func newest_producer(node_id: int, res: Resource) -> WeaverWebNode:
	var loc := locate(node_id)
	if loc.is_empty():
		return null
	var producer: WeaverWebNode = null
	var path := frame_path()
	for vi in loc.view + 1:
		var li: int = loc.lane if vi == loc.view else path[vi]
		if li < 0:
			continue
		var lane: Dictionary = views[vi].lanes[li]
		if vi < loc.view and not (res is WeaverSharedResource):
			continue
		for id in lane_order(lane):
			if id == node_id:
				return producer
			var b: WeaverResourceBinding = (lane.resource as WeaverSpider).find_binding(node_resource(id), _slot_of(lane, id, res))
			if b == null or b.resource != res:
				continue
			var access: int = slot_info(id, b.slot).get("access", -1)
			if access == WeaverResourceHandle.ACCESS_WRITE:
				producer = node_resource(id)
			elif access == WeaverResourceHandle.ACCESS_CREATE:
				producer = null
		if vi < loc.view and res is WeaverSharedResource and provided_by(views[vi].id, lane.id, res) != null:
			producer = null
	return producer

# Node ids of a lane in execution order.
func lane_order(lane: Dictionary) -> Array:
	var order: Array = []
	for s in STAGE_COUNT:
		order.append_array(lane.columns[s])
	return order

# The lane index the matrix uses for each view (-1 for a view without lanes).
func frame_path() -> PackedInt32Array:
	var path := PackedInt32Array()
	for view in views:
		var lanes: Array = view.lanes
		path.append(clampi(view.path_lane, 0, lanes.size() - 1) if not lanes.is_empty() else -1)
	return path

func _slot_of(lane: Dictionary, node_id: int, res: Resource) -> StringName:
	for b in (lane.resource as WeaverSpider).bindings:
		if b != null and b.node == node_resource(node_id) and b.resource == res:
			return b.slot
	return &""

func _set_output(spider: WeaverSpider, shared: WeaverSharedResource, res: WeaverResource) -> void:
	var output := WeaverSharedOutput.new()
	output.shared = shared
	output.resource = res
	spider.shared_outputs = Array(spider.shared_outputs).filter(func(o): return o != null and o.shared != shared) + [output]

func _refuse(reason: String) -> Dictionary:
	return { "action": "refuse", "reason": reason }

func _unique_name(base: String, taken_from: Array) -> String:
	var base_name := base.strip_edges() if not base.strip_edges().is_empty() else "resource"
	var taken := {}
	for r in taken_from:
		taken[r.resource_name] = true
	var candidate := base_name
	var n := 2
	while taken.has(candidate):
		candidate = "%s_%d" % [base_name, n]
		n += 1
	return candidate

func _all_spiders() -> Array:
	var spiders: Array = []
	for view in views:
		for lane in view.lanes:
			spiders.append(lane.resource)
	return spiders


#
# Created resources: every create slot makes its own lane resource
#

# The lane resources a node's create slots are bound to (in p_spider, the node's lane by default).
func created_resources(node_id: int, p_spider: WeaverSpider = null) -> Array:
	var spider := p_spider
	if spider == null:
		var loc := locate(node_id)
		if loc.is_empty():
			return []
		spider = views[loc.view].lanes[loc.lane].resource
	var res := node_resource(node_id)
	var made: Array = []
	for s in node_slots(node_id):
		if s.access != WeaverResourceHandle.ACCESS_CREATE:
			continue
		var b := spider.find_binding(res, s.name)
		if b != null and b.resource is WeaverResource:
			made.append(b.resource)
	return made

# Gives every create slot without a lane resource one, named after the slot and bound to it, and keeps the type and
# shape of the ones they have in sync with the slot. Returns true when the web changed.
func _ensure_created_resources() -> bool:
	var added := false
	for view in views:
		for lane in view.lanes:
			var spider: WeaverSpider = lane.resource
			for id in lane_order(lane):
				var res := node_resource(id)
				for s in node_slots(id):
					if s.access != WeaverResourceHandle.ACCESS_CREATE:
						continue
					var b := spider.find_binding(res, s.name)
					if b != null and b.resource is WeaverResource and Array(spider.resources).has(b.resource):
						# The slot owns its resource: it follows the slot when the script changes its type or shape.
						if b.resource.kind != s.type or b.resource.shape != s.shape:
							b.resource.kind = s.type
							b.resource.shape = s.shape
							added = true
						continue
					var made := WeaverResource.new()
					made.resource_name = _unique_name(s.name, Array(spider.resources))
					made.kind = s.type
					made.shape = s.shape
					spider.resources = Array(spider.resources) + [made]
					var binding := WeaverResourceBinding.new()
					binding.node = res
					binding.slot = s.name
					binding.resource = made
					spider.bindings = Array(spider.bindings).filter(func(x): return x != null and not (x.node == res and x.slot == s.name)) + [binding]
					added = true
	return added

# Removes a lane resource and everything bound to it, without notifying (callers do).
func _drop_lane_resource(res: WeaverResource) -> void:
	for spider in _all_spiders():
		spider.resources = Array(spider.resources).filter(func(r): return r != res)
		spider.bindings = Array(spider.bindings).filter(func(b): return b != null and b.resource != res)
		spider.shared_outputs = Array(spider.shared_outputs).filter(func(o): return o != null and o.resource != res)


#
# Validation and versions (from the module)
#

# The worst issue of a slot ({} when it is fine).
func slot_issue(node_id: int, slot: StringName) -> Dictionary:
	return _slot_issues.get("%d/%s" % [node_id, slot], {})

func lane_issues(lane_id: int) -> Array:
	return _lane_issues.get(lane_id, [])

# Issues that mention a shared resource (source view and lane problems, unused...).
func shared_issues(shared: WeaverSharedResource) -> Array:
	var needle := "shared resource %s" % shared.resource_name
	return issues.filter(func(i): return i.has("node") and needle in String(i.message))

# get_resource_versions() record of a bound slot ({} when unbound or unknown).
func slot_version(node_id: int, slot: StringName) -> Dictionary:
	return _versions.get("%d/%s" % [node_id, slot], {})

# "v1", "v2", "v1→v2" for a slot, "" when unknown.
func slot_version_text(node_id: int, slot: StringName) -> String:
	var record := slot_version(node_id, slot)
	if record.is_empty():
		return ""
	if record.version_in == record.version_out or record.access == WeaverResourceHandle.ACCESS_CREATE:
		return "v%d" % record.version_out
	return "v%d→v%d" % [record.version_in, record.version_out]

# Newest version of a lane resource at the end of its lane (0 when nothing made it).
func lane_resource_version(res: WeaverResource) -> int:
	var version := 0
	for record in _versions.values():
		if record.resource == res:
			version = maxi(version, record.version_out)
	return version

# Records of a shared resource on the current frame path, in execution order.
func shared_records(shared: WeaverSharedResource) -> Array:
	var path := frame_path()
	var records: Array = []
	for key in _versions:
		var record: Dictionary = _versions[key]
		if record.resource == shared and record.view < path.size() and path[record.view] == record.lane:
			records.append(record)
	records.sort_custom(func(a, b): return a.view < b.view or (a.view == b.view and a.order < b.order))
	return records

func _analyze() -> void:
	issues = []
	_slot_issues.clear()
	_lane_issues.clear()
	_versions.clear()
	if web == null:
		return
	issues = web.validate()
	for issue in issues:
		if not issue.has("node"):
			continue
		var lane := _lane_at(issue.view, issue.lane)
		if lane.is_empty():
			continue
		var node_id := _node_at(lane, issue.node)
		if node_id < 0 or String(issue.slot).is_empty():
			if not _lane_issues.has(lane.id):
				_lane_issues[lane.id] = []
			_lane_issues[lane.id].append(issue)
			continue
		var key := "%d/%s" % [node_id, issue.slot]
		var current: Dictionary = _slot_issues.get(key, {})
		if current.is_empty() or (current.severity != "error" and issue.severity == "error"):
			_slot_issues[key] = issue

	# Every lane, with the matrix's frame path for the views before it.
	var path := frame_path()
	for vi in views.size():
		for li in (views[vi].lanes as Array).size():
			var lane_path := path.duplicate()
			lane_path[vi] = li
			for record in web.get_resource_versions(lane_path):
				if record.view != vi or record.lane != li:
					continue
				var lane := _lane_at(vi, li)
				var node_id := _node_at(lane, record.node)
				if node_id < 0:
					continue
				record.node_id = node_id
				record.order = lane_order(lane).find(node_id)
				_versions["%d/%s" % [node_id, record.slot]] = record

func _lane_at(view_index: int, lane_index: int) -> Dictionary:
	if view_index < 0 or view_index >= views.size():
		return {}
	var lanes: Array = views[view_index].lanes
	return lanes[lane_index] if lane_index >= 0 and lane_index < lanes.size() else {}

# Node id of an index into the lane's weaver_nodes (as written by _write_web), -1 when it isn't a node of the model.
func _node_at(lane: Dictionary, index: int) -> int:
	var entries: Array = (lane.resource as WeaverSpider).weaver_nodes
	if index < 0 or index >= entries.size() or entries[index] == null:
		return -1
	return _ids.get(entries[index], -1)


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

# A stable color per resource name (shared resources and lane resources with the same name differ).
static func resource_color(res: Resource) -> Color:
	if res == null:
		return Color.GRAY
	var key := ("shared:" if res is WeaverSharedResource else "lane:") + res.resource_name
	var h := float(absi(hash(key)) % 997) / 997.0
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
	_ensure_created_resources()
	_write_web()
	_set_dirty(true)
	_analyze()
	changed.emit()

# A change to editor-only state (frame resources, bindings, the matrix lane).
func _notify() -> void:
	_analyze()
	changed.emit()
