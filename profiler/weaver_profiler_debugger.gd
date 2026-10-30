@tool
extends EditorDebuggerPlugin
class_name WeaverProfilerDebugger

#
# Adds a WeaverProfilerPanel to each debugger session and connects it to the WeaverProfiler of the running game.
#

const PROFILER_NAME := "weaver_profiler"
const TAB_NAME := "WeaveRD Profiler"

var _panels: Dictionary[int, WeaverProfilerPanel] = {}


func _has_capture(capture: String) -> bool:
	return capture == PROFILER_NAME


func _capture(message: String, data: Array, session_id: int) -> bool:
	if message != PROFILER_NAME + ":frames" or not _panels.has(session_id):
		return false
	_panels[session_id].add_frames(data)
	return true


func _setup_session(session_id: int) -> void:
	var panel := WeaverProfilerPanel.new()
	panel.name = TAB_NAME
	_panels[session_id] = panel

	# Connected with the id: a lambda holding the session would keep it alive through its own signal.
	var session := get_session(session_id)
	session.add_session_tab(panel)
	session.started.connect(_on_session_started.bind(session_id))
	panel.capture_toggled.connect(_on_capture_toggled.bind(session_id))


# Capture can be turned on before the game runs, and stays on between runs.
func _on_session_started(session_id: int) -> void:
	if _panels[session_id].is_capturing():
		get_session(session_id).toggle_profiler(PROFILER_NAME, true)


func _on_capture_toggled(enabled: bool, session_id: int) -> void:
	var session := get_session(session_id)
	if session.is_active():
		session.toggle_profiler(PROFILER_NAME, enabled)
