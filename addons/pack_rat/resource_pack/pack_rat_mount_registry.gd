class_name PackRatMountRegistry extends RefCounted
## Internal process-lifetime registry for mounted PackRat resource packs.

static var _mounted_paths_by_id: Dictionary = {}
static var _mounted_signatures_by_id: Dictionary = {}
static var _mounted_paths: Dictionary = {}


## Mounts [member PackRatResult.local_path] when it is a PCK or ZIP resource pack.
static func mount_if_pack(result: PackRatResult, options: PackRatOptions) -> PackRatResult:
	var extension: String = result.local_path.get_extension().to_lower()
	if extension != "pck" and extension != "zip":
		return PackRatResult.failed(result.source_url, "PackRat only mounts .pck and .zip files.")

	if extension == "zip" and options.offset != 0:
		return PackRatResult.failed(result.source_url, "Godot only supports nonzero resource pack offsets for .pck files.")

	var signature: String = mount_signature(result.local_path, options)
	var previous_signature: String = str(_mounted_signatures_by_id.get(result.id, ""))
	if result.status == PackRatResult.STATUS_CACHE_HIT and previous_signature == signature:
		result.ok = true
		result.mounted = true
		result.entry_path = options.entry_path
		return result

	var previous_path: String = str(_mounted_paths_by_id.get(result.id, ""))
	if result.status == PackRatResult.STATUS_DOWNLOADED and previous_path == result.local_path:
		result.add_warning(
			"PackRat replaced a pack at an already-mounted path for id '%s'. Godot resource packs stay mounted for the life of the process." % result.id
		)

	result.mounted = ProjectSettings.load_resource_pack(result.local_path, options.replace_files, options.offset)
	if not result.mounted:
		return PackRatResult.failed(result.source_url, "Godot could not mount %s." % result.local_path)

	if not previous_path.is_empty() and previous_path != result.local_path:
		result.add_warning(
			"PackRat mounted a different pack for id '%s'. Godot resource packs stay mounted for the life of the process." % result.id
		)
	_mounted_paths_by_id[result.id] = result.local_path
	_mounted_signatures_by_id[result.id] = signature
	_mounted_paths[result.local_path] = true

	result.ok = true
	result.entry_path = options.entry_path
	return result


## Returns [code]true[/code] when [param path] is already mounted in this process.
static func is_mounted_path(path: String) -> bool:
	return _mounted_paths.has(path) or _mounted_paths.has(PackRatCachePaths.normalized_cache_dir(path))


## Returns the cheap file signature used to detect changed mounted cache files.
static func mount_signature(path: String, options: PackRatOptions) -> String:
	return "%s:%s:%d:%d:%d" % [
		path,
		str(options.replace_files),
		options.offset,
		FileAccess.get_size(path),
		FileAccess.get_modified_time(path),
	]


## Returns the last mounted local path for [param id], or an empty string.
static func mounted_path_for_id(id: String) -> String:
	return str(_mounted_paths_by_id.get(id, ""))
