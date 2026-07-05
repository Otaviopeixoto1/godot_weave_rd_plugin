extends Object
class_name WeaverStateCache

const BASE_CACHE_DIR = "res://.godot/plugins/weaver"


class WeaverEditorData:
	const _EDITOR_CACHE_FILE := BASE_CACHE_DIR + "/editor_state.cfg" 
	var opened_web: WeaverWeb = null
	
	func save() -> Error:
		var cfg := ConfigFile.new()
		var openedWebUID = ""
		if (opened_web):
			openedWebUID = ResourceUID.path_to_uid(opened_web.resource_path)
			
		cfg.set_value("opened_web", "uid", openedWebUID)
		DirAccess.make_dir_recursive_absolute(BASE_CACHE_DIR)
		return cfg.save(_EDITOR_CACHE_FILE)
		
	static func load_or_default() -> WeaverEditorData:
		var cache := WeaverEditorData.new()
		var cfg := ConfigFile.new()
		if cfg.load(_EDITOR_CACHE_FILE) != OK:
			cache.save()
			return cache

		var currentOpenedUID: String = cfg.get_value("opened_web", "uid", "")
		var uid: int = ResourceUID.text_to_id(currentOpenedUID)
		if (ResourceUID.has_id(uid)):
			var path := ResourceUID.get_id_path(uid)
			if path.is_empty():
				return cache
			var web := ResourceLoader.load(path) as WeaverWeb
			if web:
				cache.opened_web = web
		return cache
