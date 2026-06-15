class_name PackRatEditorPackExport extends RefCounted
## Internal editor helper that builds temporary packs with Godot's export pipeline.

const _SIGNATURE_EXTENSION: String = "signature"

static var last_error: String = ""


## Returns [code]true[/code] when editor preset export is available in this process.
static func is_available() -> bool:
	return OS.has_feature("editor")


## Builds or reuses the temporary pack for [param preset_name].
static func exported_pack_path(
	preset_name: String,
	cache_dir: String = "user://pack_rat",
	owner: PackRatRequest = null
) -> String:
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
	var export_dir: String = _export_dir(cache_dir)
	var output_path: String = export_dir.path_join("%s.%s" % [PackRatCachePaths.safe_name(clean_name), extension])
	var signature_path: String = "%s.%s" % [output_path, _SIGNATURE_EXTENSION]
	var signature: String = _preset_signature(config, section)
	PackRatCacheFiles.ensure_dir(export_dir)
	if _is_export_fresh(output_path, signature_path, signature):
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
	var pid: int = OS.create_process(OS.get_executable_path(), arguments, false)
	if pid == -1:
		last_error = "could not start editor export preset '%s'." % clean_name
		return ""

	var tree: SceneTree = Engine.get_main_loop()
	while OS.is_process_running(pid):
		if owner != null and owner.is_canceled():
			OS.kill(pid)
			last_error = PackRatResult.ERROR_CANCELED
			return ""

		if tree != null:
			await tree.process_frame
		else:
			OS.delay_msec(50)

	var exit_code: int = OS.get_process_exit_code(pid)
	if exit_code != 0:
		last_error = "editor export preset '%s' failed with exit code %d." % [clean_name, exit_code]
		return ""

	if not FileAccess.file_exists(output_path):
		last_error = "editor export preset '%s' did not create %s." % [clean_name, output_path]
		return ""

	signature = _preset_signature(config, section)
	_save_signature(signature_path, signature)
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


static func _export_dir(cache_dir: String) -> String:
	return PackRatCachePaths.normalized_cache_dir(cache_dir).path_join("editor_exports")


static func _is_export_fresh(output_path: String, signature_path: String, signature: String) -> bool:
	if not FileAccess.file_exists(output_path):
		return false

	if signature.is_empty() or not FileAccess.file_exists(signature_path):
		return false

	if FileAccess.get_file_as_string(signature_path).strip_edges() != signature:
		return false

	return true


static func _preset_signature(config: ConfigFile, section: String) -> String:
	var context: HashingContext = HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""

	context.update(str(FileAccess.get_sha256("res://export_presets.cfg")).to_utf8_buffer())
	var paths: PackedStringArray = _preset_watch_paths(config, section)
	for path in paths:
		_hash_path(context, path)

	return context.finish().hex_encode()


static func _preset_watch_paths(config: ConfigFile, section: String) -> PackedStringArray:
	var filter: String = str(config.get_value(section, "export_filter", "all_resources"))
	var paths: PackedStringArray = []
	if filter == "customized":
		var customized_files: Dictionary = config.get_value(section, "customized_files", {})
		for key in customized_files.keys():
			var mode: String = str(customized_files[key])
			if mode == "keep" or mode == "strip":
				paths.append(str(key))
	elif filter == "resources" or filter == "scenes":
		paths = PackedStringArray(config.get_value(section, "export_files", PackedStringArray()))

	if paths.is_empty():
		paths.append("res://")

	paths.sort()
	return paths


static func _hash_path(context: HashingContext, path: String) -> void:
	var normalized_path: String = path.replace("\\", "/").simplify_path()
	var filesystem_path: String = _filesystem_path(normalized_path)
	context.update(normalized_path.to_utf8_buffer())
	if DirAccess.dir_exists_absolute(filesystem_path):
		_hash_directory(context, filesystem_path, normalized_path)
	elif FileAccess.file_exists(filesystem_path):
		_hash_file(context, filesystem_path)
	else:
		context.update("missing".to_utf8_buffer())


static func _filesystem_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()

	return path


static func _hash_directory(context: HashingContext, path: String, logical_path: String) -> void:
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		context.update("unreadable-directory".to_utf8_buffer())
		return

	var children: PackedStringArray = []
	directory.list_dir_begin()
	var item: String = directory.get_next()
	while not item.is_empty():
		if not item.begins_with("."):
			children.append(item)
		item = directory.get_next()
	directory.list_dir_end()

	children.sort()
	for child in children:
		var item_path: String = path.path_join(child)
		var item_logical_path: String = logical_path.path_join(child)
		context.update(item_logical_path.to_utf8_buffer())
		if DirAccess.dir_exists_absolute(item_path):
			_hash_directory(context, item_path, item_logical_path)
		else:
			_hash_file(context, item_path)


static func _hash_file(context: HashingContext, path: String) -> void:
	var size: int = FileAccess.get_size(path)
	var modified_time: int = int(FileAccess.get_modified_time(path))
	context.update(("%d:%d:" % [size, modified_time]).to_utf8_buffer())
	var file_hash: String = FileAccess.get_sha256(path)
	context.update(file_hash.to_utf8_buffer())


static func _save_signature(signature_path: String, signature: String) -> void:
	var file: FileAccess = FileAccess.open(signature_path, FileAccess.WRITE)
	if file == null:
		return

	file.store_string(signature)
	file.close()
