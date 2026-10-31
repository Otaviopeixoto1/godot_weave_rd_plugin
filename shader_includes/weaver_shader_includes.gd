@tool
extends Node
class_name WeaverShaderIncludes

#
# Godot expands #include when a .glsl is imported and only tracks the .glsl itself, so editing an include leaves the shaders
# using it on old SPIR-V. This reimports them: each shader has a fingerprint made from its includes, and a shader whose
# fingerprint changed is reimported. Runs before Play, when the editor gets focus and once at startup.
#
# Only shaders the editor knows about are checked, so deleted or renamed ones simply drop out. A shader with a missing or
# empty include is never reimported: the import would fail and replace its working SPIR-V. It keeps the stored fingerprint,
# so its reimported if the include comes back different.
#

const SHADER_EXTENSION := "glsl"
const FINGERPRINT_FILE := "weaver_shader_includes.cfg"
const FINGERPRINT_SECTION := "fingerprints"
const UNUSABLE := "unusable"

var _warned: Dictionary[String, bool] = {}


func _ready() -> void:
	set_process(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		set_process(true)


# Processing is only on while a check is pending: it waits for the scan the editor starts when it gets focus. Timers and
# call_deferred() can't be used here, reimport_files() shows a progress dialog that breaks both.
func _process(_delta: float) -> void:
	if not _is_busy():
		set_process(false)
		check()


# _build() can't wait for a scan: the scan only finishes on the main thread, which is blocked here.
func check_before_run() -> void:
	if _is_busy():
		push_warning("WeaveRD: The editor is scanning files, shaders using edited includes may not be up to date in this run.")
		set_process(true)
	else:
		check()


func check() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	var shaders := _find_shaders(filesystem.get_filesystem())
	if shaders.is_empty():
		return # The first scan may not be done: keep the stored fingerprints.

	var config := ConfigFile.new()
	var config_path := EditorInterface.get_editor_paths().get_project_settings_dir().path_join(FINGERPRINT_FILE)
	var first_run := config.load(config_path) != OK

	var warned := _warned
	_warned = {}

	var stale := PackedStringArray()
	var fingerprints := ConfigFile.new()
	for shader in shaders:
		var stored: String = config.get_value(FINGERPRINT_SECTION, shader, "")
		var fingerprint := _fingerprint(shader, warned)
		if fingerprint == UNUSABLE:
			fingerprint = stored
		elif not stored.is_empty() and fingerprint != stored:
			stale.append(shader)
		if not fingerprint.is_empty():
			fingerprints.set_value(FINGERPRINT_SECTION, shader, fingerprint)

	if not stale.is_empty():
		print("WeaveRD: Includes changed, reimporting: ", ", ".join(stale))
		filesystem.reimport_files(stale)

	# Saved last, so an interrupted reimport runs again. Rewritten whole, so deleted and renamed shaders don't stay in the file.
	if first_run or fingerprints.encode_to_text() != config.encode_to_text():
		fingerprints.save(config_path)


func _is_busy() -> bool:
	var filesystem := EditorInterface.get_resource_filesystem()
	return filesystem.is_scanning() or filesystem.is_importing()


func _find_shaders(directory: EditorFileSystemDirectory) -> PackedStringArray:
	var shaders := PackedStringArray()
	for i in directory.get_subdir_count():
		shaders.append_array(_find_shaders(directory.get_subdir(i)))
	for i in directory.get_file_count():
		var path := directory.get_file_path(i)
		# The editor's list can be behind what's on disk until its next scan.
		if path.get_extension() == SHADER_EXTENSION and FileAccess.file_exists(path) and FileAccess.file_exists(path + ".import"):
			shaders.append(path)
	return shaders


# Returns the shader's fingerprint, empty if it has no includes, or UNUSABLE if reimporting it would fail.
func _fingerprint(shader: String, warned: Dictionary[String, bool]) -> String:
	var parts := PackedStringArray()
	var usable := true
	for include in _parse_includes(FileAccess.get_file_as_string(shader)):
		if ShaderIncludeDB.has_built_in_include_file(include):
			continue
		var path := shader.get_base_dir().path_join(include) if include.is_relative_path() else include

		# Godot's import also treats an empty include as a failed one.
		var text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
		if text.is_empty():
			_warn("%s: The include '%s' is missing or empty, the shader was not reimported." % [shader, include], warned)
			usable = false
			continue

		for nested in _parse_includes(text):
			if not ShaderIncludeDB.has_built_in_include_file(nested):
				_warn("%s: The #include of '%s' won't work, Godot doesn't expand nested includes." % [path, nested], warned)
		parts.append("%s:%s" % [path, text.md5_text()])

	if not usable:
		return UNUSABLE
	return "|".join(parts).md5_text() if not parts.is_empty() else ""


func _parse_includes(text: String) -> PackedStringArray:
	var includes := PackedStringArray()
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if not stripped.begins_with("#include"):
			continue
		var include := stripped.trim_prefix("#include").strip_edges()
		if include.length() > 2 and include.begins_with("\"") and include.ends_with("\""):
			includes.append(include.substr(1, include.length() - 2).strip_edges())
	return includes


# Warns once until the problem goes away, instead of on every check.
func _warn(message: String, warned: Dictionary[String, bool]) -> void:
	_warned[message] = true
	if not warned.has(message):
		push_warning("WeaveRD: " + message)
