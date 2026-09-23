extends RefCounted
class_name PowerShellHost
## Runs the generated PowerShell helpers (input, overlay click-through, the
## overlay watchdog, the stop hotkey). Two rules, both about running exactly
## what this build generated and nothing else:
##
## * powershell.exe is started by its full System32 path. A bare name is
##   looked up in the app's own folder and in the working directory *before*
##   System32 (CreateProcess search order), so a binary planted next to the
##   exe would be run instead.
## * A helper script is checked (and rewritten unless it is this build's
##   exactly) immediately before every launch, and lives in the local
##   (non-roaming) profile rather than user://, so the file on disk can
##   never be an older or edited copy by the time it runs.

static var _executable := ""
static var _script_dir := ""
static var _write_lock := Mutex.new()


## Full path of Windows PowerShell: under %SystemRoot%, else the stock
## C:\Windows. Falls back to the bare name only when neither has it
## (CreateProcess still resolves that).
static func executable() -> String:
	if _executable.is_empty():
		var found := "powershell.exe"
		for root in [OS.get_environment("SystemRoot"), "C:\\Windows"]:
			if root.is_empty():
				continue
			var full: String = root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
			if FileAccess.file_exists(full):
				found = full.replace("/", "\\")
				break
		_executable = found
	return _executable


## The arguments that run `script_path` non-interactively without a window.
static func file_args(script_path: String) -> PackedStringArray:
	return PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", script_path,
	])


## Where the helper scripts are kept: the app's folder under the local
## profile (%LOCALAPPDATA%\Godot\app_userdata\<app>), or the user:// folder
## when that cannot be created.
static func script_dir() -> String:
	if _script_dir.is_empty():
		var dir := ""
		var cache := OS.get_cache_dir()
		if not cache.is_empty():
			var app_name := String(ProjectSettings.get_setting("application/config/name", "Loop Automator"))
			var local := cache.path_join("Godot/app_userdata").path_join(app_name)
			if DirAccess.make_dir_recursive_absolute(local) == OK:
				dir = local
		_script_dir = dir if not dir.is_empty() else OS.get_user_data_dir()
	return _script_dir


## Writes `content` to `<script_dir>/<file_name>` and returns the absolute
## path, or "" if it could not be written. Call it right before each launch.
## A file that already holds exactly `content` is left alone: opening it to
## write empties it first, and another helper of this app (the playback
## backend and the screen reader both start one, from worker threads) may
## be reading it that moment.
static func write_script(file_name: String, content: String) -> String:
	_write_lock.lock()
	var path := script_dir().path_join(file_name)
	# Byte for byte: a string read stops at a NUL, and PowerShell runs
	# whatever comes after one.
	var written := FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path) == content.to_utf8_buffer()
	if not written:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(content)
			f.close()
			written = true
	_write_lock.unlock()
	if not written:
		return ""
	# Older builds kept the scripts in user://; a copy left there is stale.
	var legacy := "user://" + file_name
	if path != ProjectSettings.globalize_path(legacy) and FileAccess.file_exists(legacy):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
	return ProjectSettings.globalize_path(path)
