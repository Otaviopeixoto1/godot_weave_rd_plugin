@tool
class_name WeaverShaderClasses
extends Node

#
# Keeps the generated shader classes in sync with their shaders. A .glsl with a `// @weaver class_name <Name>` comment gets a
# <shader>.gen.gd next to it (built by WeaverShaderClassWriter).
#
# Each pass:
# - finds the existing generated files and the shader each one belongs to (from the UID in its SHADER preload),
# - moves a generated file next to its shader when the shader was moved or renamed,
# - regenerates the classes, writing a file only when its text changed,
# - warns about duplicate or taken class names (the second class is not written) and about generated files whose shader
#   was deleted or lost its directive. Nothing is ever deleted: user code may still use the class.
#
# Passes run after reimports (only for the reimported shaders), and fully at startup, on focus, before Play, after FileSystem
# dock moves and from Project > Tools > Regenerate. Like WeaverShaderIncludes they run from _process once the editor is idle
#

var _full_pass_queued := true
var _force_queued := false
var _queued_shaders := PackedStringArray()
var _warned: Dictionary[String, bool] = {}
var _generation_warned: Dictionary[String, bool] = {}


func _ready() -> void:
	EditorInterface.get_resource_filesystem().resources_reimported.connect(_on_resources_reimported)
	var dock := EditorInterface.get_file_system_dock()
	dock.files_moved.connect(_on_files_moved)
	dock.folder_moved.connect(_on_files_moved)
	dock.file_removed.connect(_on_file_removed)
	set_process(true)


func _exit_tree() -> void:
	EditorInterface.get_resource_filesystem().resources_reimported.disconnect(_on_resources_reimported)
	var dock := EditorInterface.get_file_system_dock()
	dock.files_moved.disconnect(_on_files_moved)
	dock.folder_moved.disconnect(_on_files_moved)
	dock.file_removed.disconnect(_on_file_removed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_queue_full_pass()


func _process(_delta: float) -> void:
	if _is_busy() or not _is_scanned():
		return
	set_process(false)
	var force := _force_queued
	var full := _full_pass_queued or force
	var only := _queued_shaders
	_force_queued = false
	_full_pass_queued = false
	_queued_shaders = PackedStringArray()
	sync(PackedStringArray() if full else only, force)


# Project > Tools > "WeaveRD: Regenerate shader classes": every class is regenerated and every warning shown again.
func regenerate_all() -> void:
	_force_queued = true
	set_process(true)


# _build() can't wait for a scan: the scan only finishes on the main thread, which is blocked here.
func check_before_run() -> void:
	if _is_busy() or not _is_scanned():
		_queue_full_pass()
	else:
		sync()


func _queue_full_pass() -> void:
	_full_pass_queued = true
	set_process(true)


func _on_resources_reimported(paths: PackedStringArray) -> void:
	for path in paths:
		if path.get_extension() == "glsl" and path not in _queued_shaders:
			_queued_shaders.append(path)
	if not _queued_shaders.is_empty():
		set_process(true)


func _on_files_moved(_old_path: String, _new_path: String) -> void:
	_queue_full_pass()


func _on_file_removed(_path: String) -> void:
	_queue_full_pass()


func _is_busy() -> bool:
	var filesystem := EditorInterface.get_resource_filesystem()
	return filesystem.is_scanning() or filesystem.is_importing()


# Before the editor's first scan its file list is empty: a pass would see every generated file as an orphan.
func _is_scanned() -> bool:
	var root := EditorInterface.get_resource_filesystem().get_filesystem()
	return root != null and (root.get_file_count() > 0 or root.get_subdir_count() > 0)


# Generates the classes of `only` (every opted-in shader when empty). Moves, conflicts and orphans are always checked.
func sync(only := PackedStringArray(), force := false) -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	var shaders := PackedStringArray()
	var generated := PackedStringArray()
	_find_files(filesystem.get_filesystem(), shaders, generated)
	shaders.sort()

	var warned := {} if force else _warned
	_warned = {}
	if force:
		_generation_warned = {}

	# Opted-in shaders and the generated file currently belonging to each one.
	var opted := {} # shader -> class name
	for shader in shaders:
		var name := WeaverShaderClassWriter.find_class_name(FileAccess.get_file_as_string(shader))
		if not name.is_empty():
			opted[shader] = name

	var owner_of := {} # generated file -> shader ("" when the shader is gone)
	var file_of := {} # shader -> generated file
	for file in generated:
		var shader := _shader_of(file)
		owner_of[file] = shader
		# A file at the expected path wins over a stray copy.
		if opted.has(shader) and (not file_of.has(shader) or file == WeaverShaderClassWriter.generated_path(shader)):
			file_of[shader] = file

	# Classes of other scripts, which a generated class can't take.
	var other_classes := {} # class name -> script path
	for info in ProjectSettings.get_global_class_list():
		if not owner_of.has(info.path):
			other_classes[info.class] = info.path

	var claimed := {} # class name -> shader
	for shader: String in opted:
		var name: String = opted[shader]
		var target := WeaverShaderClassWriter.generated_path(shader)
		var current: String = file_of.get(shader, "")

		if not WeaverShaderClassWriter.is_usable_class_name(name):
			_warn("%s: \"%s\" can't be used as a class name (not an identifier, or a built-in class or type)." % [shader, name], warned)
			continue
		if claimed.has(name):
			_warn("%s and %s both use the class name %s. The class of %s was not written." % [claimed[name], shader, name, shader], warned)
			continue
		if other_classes.has(name):
			_warn("%s: the class name %s is already used by %s. Its class was not written." % [shader, name, other_classes[name]], warned)
			continue
		claimed[name] = shader

		var moved := false
		if not current.is_empty() and current != target:
			if FileAccess.file_exists(target):
				_warn("%s was moved, but its class %s can't follow it: %s already exists." % [shader, current, target], warned)
				continue
			_move(current, target)
			owner_of.erase(current)
			owner_of[target] = shader
			file_of[shader] = target
			moved = true
		elif current.is_empty() and FileAccess.file_exists(target):
			_warn("%s: its class can't be written, %s already exists and was not generated by WeaveRD." % [shader, target], warned)
			continue

		if only.is_empty() or moved or shader in only:
			var problems := PackedStringArray()
			var text := WeaverShaderClassWriter.generate(shader, name, problems)
			for problem in problems:
				if not _generation_warned.has(problem):
					_generation_warned[problem] = true
					push_warning("WeaveRD: " + problem)
			if text.is_empty():
				continue # Failed import or reflection (already reported): the previous class is kept.
			if not FileAccess.file_exists(target) or FileAccess.get_file_as_string(target) != text:
				_write(target, text)
				owner_of[target] = shader

	for file: String in owner_of:
		var shader: String = owner_of[file]
		if shader.is_empty():
			_warn("%s has no shader anymore (it was deleted). The class is kept, delete the file when nothing uses it." % file, warned)
		elif not opted.has(shader):
			_warn("%s: %s has no `// @weaver class_name` directive anymore. The class is kept, delete the file when nothing uses it." % [file, shader], warned)
		elif file_of.get(shader, file) != file:
			_warn("%s is a copy of %s, the class of %s. Delete one of them." % [file, file_of[shader], shader], warned)


func _find_files(directory: EditorFileSystemDirectory, shaders: PackedStringArray, generated: PackedStringArray) -> void:
	for i in directory.get_subdir_count():
		_find_files(directory.get_subdir(i), shaders, generated)

	for i in directory.get_file_count():
		var path := directory.get_file_path(i)
		# The editor's list can be behind what's on disk until its next scan.
		if not FileAccess.file_exists(path):
			continue

		if path.get_extension() == "glsl" and FileAccess.file_exists(path + ".import"):
			shaders.append(path)
		elif path.ends_with(WeaverShaderClassWriter.GENERATED_EXTENSION) and _is_generated(path):
			generated.append(path)


func _is_generated(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	return file != null and file.get_line().begins_with(WeaverShaderClassWriter.HEADER_PREFIX)


# The shader a generated file preloads (followed by UID, so a moved shader is found at its new path), or "" when it is gone.
func _shader_of(generated_file: String) -> String:
	var found := RegEx.create_from_string("const SHADER: RDShaderFile = preload\\(\"([^\"]+)\"\\)").search(FileAccess.get_file_as_string(generated_file))
	if found == null:
		return ""

	var reference := found.get_string(1)
	var path := reference
	if reference.begins_with("uid://"):
		var id := ResourceUID.text_to_id(reference)
		path = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return path if not path.is_empty() and FileAccess.file_exists(path) else ""


# The editor is told right away, so the global class points to the new path before the class is regenerated there.
func _move(from: String, to: String) -> void:
	DirAccess.rename_absolute(from, to)
	if FileAccess.file_exists(from + ".uid"):
		DirAccess.rename_absolute(from + ".uid", to + ".uid")

	# A loaded class keeps working under its new path.
	if ResourceLoader.has_cached(from):
		(load(from) as Script).take_over_path(to)

	var filesystem := EditorInterface.get_resource_filesystem()
	filesystem.update_file(from)
	filesystem.update_file(to)
	print("WeaveRD: Moved %s to %s, next to its shader." % [from, to])


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("WeaveRD: Can't write %s (%s)." % [path, error_string(FileAccess.get_open_error())])
		return

	file.store_string(text)
	file.close()

	# Updates the global class list (a new or renamed class) before the script is compiled again.
	EditorInterface.get_resource_filesystem().update_file(path)

	# An already loaded class is updated in place, so open scripts see the new members right away.
	if ResourceLoader.has_cached(path):
		var script := load(path) as Script
		script.source_code = text
		script.reload(true)


# Warns once until the problem goes away, instead of on every pass.
func _warn(message: String, warned: Dictionary) -> void:
	_warned[message] = true
	if not warned.has(message):
		push_warning("WeaveRD: " + message)
