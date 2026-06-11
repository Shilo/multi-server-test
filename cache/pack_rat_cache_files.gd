class_name PackRatCacheFiles extends RefCounted
## Internal filesystem mutation helpers for PackRat cache files.


static func ensure_dir(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create %s (error %d)." % [path, error])


static func has_matching_cache_file(cache_dir: String, id: String) -> bool:
	var dir: DirAccess = DirAccess.open(cache_dir)
	if dir == null:
		return false

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		if not dir.current_is_dir() and PackRatCachePaths.cached_filename_matches_id(child, id):
			dir.list_dir_end()
			return true

		child = dir.get_next()

	dir.list_dir_end()
	return false


static func clear_unmounted_cache_files(cache_dir: String, id: String = "", keep_path: String = "") -> Error:
	var dir: DirAccess = DirAccess.open(cache_dir)
	if dir == null:
		return OK

	var first_error: Error = OK
	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = cache_dir.path_join(child)
		if dir.current_is_dir():
			var nested_error: Error = clear_unmounted_cache_files(child_path, id, keep_path)
			if is_real_remove_error(nested_error) and first_error == OK:
				first_error = nested_error
			_remove_empty_directory(child_path)
		elif PackRatCachePaths.is_cache_pack_file(child):
			if keep_path.is_empty() or PackRatCachePaths.normalized_cache_dir(child_path) != PackRatCachePaths.normalized_cache_dir(keep_path):
				if id.is_empty() or PackRatCachePaths.cached_filename_matches_id(child, id):
					var remove_error: Error = remove_cache_file(child_path, cache_dir)
					if is_real_remove_error(remove_error) and first_error == OK:
						first_error = remove_error

		child = dir.get_next()

	dir.list_dir_end()
	return first_error


static func clear_part_files(cache_dir: String) -> Error:
	var tmp_dir: String = cache_dir.path_join("tmp")
	var dir: DirAccess = DirAccess.open(tmp_dir)
	if dir == null:
		return OK

	var first_error: Error = OK
	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = tmp_dir.path_join(child)
		var remove_error: Error = OK
		if dir.current_is_dir():
			remove_error = _clear_directory(child_path)
			if remove_error == OK:
				remove_error = DirAccess.remove_absolute(child_path)
		elif child.ends_with(".part"):
			remove_error = DirAccess.remove_absolute(child_path)

		if is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

		child = dir.get_next()

	dir.list_dir_end()
	return first_error


static func remove_cache_file(path: String, cache_dir: String) -> Error:
	if path.is_empty():
		return ERR_DOES_NOT_EXIST

	if not PackRatCachePaths.is_cache_child_path(path, cache_dir):
		return ERR_INVALID_DATA

	if not FileAccess.file_exists(path):
		return ERR_DOES_NOT_EXIST

	if PackRatMountRegistry.is_mounted_path(path):
		return ERR_BUSY

	return DirAccess.remove_absolute(path)


static func is_real_remove_error(error: Error) -> bool:
	return error != OK and error != ERR_DOES_NOT_EXIST and error != ERR_BUSY


static func _clear_directory(path: String) -> Error:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return OK

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = path.path_join(child)
		var error: Error = OK
		if dir.current_is_dir():
			error = _clear_directory(child_path)
			if error == OK:
				error = DirAccess.remove_absolute(child_path)
		else:
			error = DirAccess.remove_absolute(child_path)

		if error != OK:
			dir.list_dir_end()
			dir = null
			return error

		child = dir.get_next()

	dir.list_dir_end()
	dir = null
	return OK


static func _remove_empty_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var first_child: String = dir.get_next()
	dir.list_dir_end()
	dir = null
	if first_child.is_empty():
		DirAccess.remove_absolute(path)
