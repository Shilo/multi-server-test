class_name PackRatEditorPackExport extends RefCounted
## Internal editor helper that builds temporary packs with Godot's export pipeline.

const _EXPORT_DIR: String = "user://pack_rat/editor_exports"

static var last_error: String = ""


## Returns [code]true[/code] when editor preset export is available in this process.
static func is_available() -> bool:
	return OS.has_feature("editor")


## Builds or reuses the temporary pack for [param preset_name].
static func exported_pack_path(preset_name: String) -> String:
	last_error = ""
	var clean_name: String = preset_name.strip_edges()
	if clean_name.is_empty() or not is_available():
		return ""

	var config: ConfigFile = ConfigFile.new()
	var config_error: Error = config.load("res://export_presets.cfg")
	if config_error != OK:
		last_error = "could not read res://export_presets.cfg (error %d)." % config_error
		return ""

	var section: String = _preset_section(config, clean_name)
	if section.is_empty():
		last_error = "could not find export preset: %s." % clean_name
		return ""

	var extension: String = _preset_extension(config, section)
	var output_path: String = _EXPORT_DIR.path_join("%s.%s" % [PackRatCachePaths.safe_name(clean_name), extension])
	PackRatCacheFiles.ensure_dir(_EXPORT_DIR)
	if _is_export_fresh(output_path):
		return output_path

	var output_global_path: String = ProjectSettings.globalize_path(output_path)
	var project_global_path: String = ProjectSettings.globalize_path("res://")
	var arguments: PackedStringArray = PackedStringArray([
		"--headless",
		"--path",
		project_global_path,
		"--export-pack",
		clean_name,
		output_global_path,
	])
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), arguments, output, true, true)
	if exit_code != 0:
		last_error = "editor export preset '%s' failed with exit code %d.\n%s" % [
			clean_name,
			exit_code,
			"\n".join(output),
		]
		return ""

	if not FileAccess.file_exists(output_path):
		last_error = "editor export preset '%s' did not create %s." % [clean_name, output_path]
		return ""

	return output_path


static func _preset_section(config: ConfigFile, preset_name: String) -> String:
	for section in config.get_sections():
		if not str(section).begins_with("preset.") or str(section).ends_with(".options"):
			continue

		if str(config.get_value(section, "name", "")) == preset_name:
			return str(section)

	return ""


static func _preset_extension(config: ConfigFile, section: String) -> String:
	var export_path: String = str(config.get_value(section, "export_path", ""))
	var extension: String = export_path.get_extension().to_lower()
	return extension if extension == "zip" else "pck"


static func _is_export_fresh(output_path: String) -> bool:
	if not FileAccess.file_exists(output_path):
		return false

	var output_modified_time: int = int(FileAccess.get_modified_time(output_path))
	if FileAccess.file_exists("res://export_presets.cfg"):
		var config_modified_time: int = int(FileAccess.get_modified_time("res://export_presets.cfg"))
		if config_modified_time > output_modified_time:
			return false

	return _newest_resource_modified_time("res://") <= output_modified_time


static func _newest_resource_modified_time(path: String) -> int:
	var newest: int = 0
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return newest

	directory.list_dir_begin()
	var item: String = directory.get_next()
	while not item.is_empty():
		if item.begins_with("."):
			item = directory.get_next()
			continue

		var item_path: String = path.path_join(item)
		if directory.current_is_dir():
			newest = maxi(newest, _newest_resource_modified_time(item_path))
		else:
			newest = maxi(newest, int(FileAccess.get_modified_time(item_path)))

		item = directory.get_next()

	directory.list_dir_end()
	return newest
