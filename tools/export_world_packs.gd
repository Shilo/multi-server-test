extends SceneTree

const NET_CONFIG := preload("res://shared/net/net_config.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var output_dir := _arg_value("--output-dir", ProjectSettings.globalize_path("res://builds/world_packs"))
	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	if error != OK:
		push_error("Could not create world pack output dir %s err=%d" % [output_dir, error])
		return 1

	var packed_count := 0
	for world_key in NET_CONFIG.world_keys():
		if _pack_world(str(world_key), output_dir) != OK:
			return 1
		packed_count += 1

	print("WORLD_PACK_EXPORT_DONE count=%d dir=%s" % [packed_count, output_dir])
	return 0


func _pack_world(world_key: String, output_dir: String) -> Error:
	var source_dir := "%s/%s" % [NET_CONFIG.WORLD_SCENE_DIR, world_key]
	var files: PackedStringArray = []
	_collect_files(source_dir, files)
	if files.is_empty():
		push_error("World %s has no packable files under %s" % [world_key, source_dir])
		return ERR_FILE_NOT_FOUND

	var output_name := "%s.pck" % world_key
	var temp_name := "%s.uploading" % output_name
	var output_path := output_dir.path_join(output_name)
	var temp_path := output_dir.path_join(temp_name)
	var output_access := DirAccess.open(output_dir)
	if output_access == null:
		push_error("Could not open world pack output dir %s" % output_dir)
		return ERR_CANT_OPEN
	if output_access.file_exists(temp_name):
		output_access.remove(temp_name)
	if output_access.file_exists(output_name):
		output_access.remove(output_name)

	var packer := PCKPacker.new()
	var error := packer.pck_start(temp_path)
	if error != OK:
		push_error("Could not start PCK %s err=%d" % [temp_path, error])
		return error

	for target_path in files:
		var source_path := ProjectSettings.globalize_path(target_path)
		error = packer.add_file(target_path, source_path)
		if error != OK:
			push_error("Could not add %s to %s err=%d" % [target_path, temp_path, error])
			return error

	error = packer.flush()
	if error != OK:
		push_error("Could not finish PCK %s err=%d" % [temp_path, error])
		return error

	error = output_access.rename(temp_name, output_name)
	if error != OK:
		push_error("Could not publish PCK %s err=%d" % [output_path, error])
		return error

	var size := FileAccess.get_size(output_path)
	var modified_time := FileAccess.get_modified_time(output_path)
	if size <= 0 or modified_time <= 0:
		push_error("Could not read metadata for %s" % output_path)
		return ERR_FILE_CANT_READ

	print("WORLD_PACK_EXPORTED key=%s path=%s size=%d modified_time=%d files=%d" % [
		world_key,
		output_path,
		size,
		modified_time,
		files.size(),
	])
	return OK


func _collect_files(dir_path: String, files: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Could not open world folder %s" % dir_path)
		return

	dir.list_dir_begin()
	while true:
		var file_name := dir.get_next()
		if file_name.is_empty():
			break
		if file_name.begins_with("."):
			continue

		var child_path := dir_path.path_join(file_name)
		if dir.current_is_dir():
			_collect_files(child_path, files)
		elif _is_packable_file(file_name):
			files.append(child_path)
	dir.list_dir_end()


func _is_packable_file(file_name: String) -> bool:
	return not file_name.ends_with(".uid")


func _arg_value(name: String, default_value: String) -> String:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("%s=" % name):
			return arg.get_slice("=", 1)
	return default_value
