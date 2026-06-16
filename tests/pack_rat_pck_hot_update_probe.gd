extends Node

const WORK_DIR: String = "user://pack_rat_pck_hot_update_probe"
const LIVE_PACK: String = "user://pack_rat_pck_hot_update_probe/live.pck"
const TEMP_PACK: String = "user://pack_rat_pck_hot_update_probe/live.pck.part"
const VERSIONED_PACK_V1: String = "user://pack_rat_pck_hot_update_probe/live-v1.pck"
const VERSIONED_PACK_V2: String = "user://pack_rat_pck_hot_update_probe/live-v2.pck"
const MARKER_PATH: String = "res://pack_rat_hot_update_probe/marker.txt"
const EXTRA_PATH: String = "res://pack_rat_hot_update_probe/extra.txt"
const RESOURCE_PATH: String = "res://pack_rat_hot_update_probe/version.tres"


func _ready() -> void:
	_clear_directory(WORK_DIR)
	_make_directory(WORK_DIR)

	if not _write_pack(LIVE_PACK, "one", ""):
		return

	if not ProjectSettings.load_resource_pack(LIVE_PACK, true):
		_fail("Could not mount initial live pack.")
		return

	var first_read: String = FileAccess.get_file_as_string(MARKER_PATH)
	if first_read != "one":
		_fail("Expected initial marker 'one', got '%s'." % first_read)
		return

	var first_resource: Resource = ResourceLoader.load(RESOURCE_PATH)
	if first_resource == null or first_resource.resource_name != "one":
		_fail("Expected initial resource name 'one'.")
		return

	if not _write_pack(TEMP_PACK, "two-longer", "padding-before-marker-to-shift-pack-layout"):
		return
	DirAccess.rename_absolute(ProjectSettings.globalize_path(TEMP_PACK), ProjectSettings.globalize_path(LIVE_PACK))

	var read_after_replace_before_reload: String = FileAccess.get_file_as_string(MARKER_PATH)
	if read_after_replace_before_reload == "two-longer":
		_fail("Expected same-path replacement before load_resource_pack() to be unsafe, but it read the new marker cleanly.")
		return

	if not ProjectSettings.load_resource_pack(LIVE_PACK, true):
		_fail("Could not remount overwritten live pack.")
		return

	var read_after_same_path_reload: String = FileAccess.get_file_as_string(MARKER_PATH)
	if read_after_same_path_reload != "two-longer":
		_fail("Expected same-path reload to read 'two-longer', got '%s'." % read_after_same_path_reload)
		return

	var cached_resource_after_reload: Resource = ResourceLoader.load(RESOURCE_PATH)
	if cached_resource_after_reload == null or cached_resource_after_reload.resource_name != "one":
		_fail("Expected default ResourceLoader cache to keep initial resource after same-path reload.")
		return

	var ignored_cache_resource: Resource = ResourceLoader.load(RESOURCE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if ignored_cache_resource == null or ignored_cache_resource.resource_name != "two-longer":
		_fail("Expected CACHE_MODE_IGNORE to load updated resource after same-path reload.")
		return

	if not _write_pack(VERSIONED_PACK_V1, "versioned-one", ""):
		return
	if not _write_pack(VERSIONED_PACK_V2, "versioned-two", "separate-pack-file"):
		return

	if not ProjectSettings.load_resource_pack(VERSIONED_PACK_V1, true):
		_fail("Could not mount versioned v1 pack.")
		return
	if FileAccess.get_file_as_string(MARKER_PATH) != "versioned-one":
		_fail("Expected versioned v1 marker.")
		return

	if not ProjectSettings.load_resource_pack(VERSIONED_PACK_V2, true):
		_fail("Could not mount versioned v2 pack.")
		return
	if FileAccess.get_file_as_string(MARKER_PATH) != "versioned-two":
		_fail("Expected versioned v2 marker.")
		return

	var versioned_cached_resource: Resource = ResourceLoader.load(RESOURCE_PATH)
	var versioned_ignored_resource: Resource = ResourceLoader.load(RESOURCE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if versioned_cached_resource == null or versioned_cached_resource.resource_name != "one":
		_fail("Expected default ResourceLoader cache to keep original resource after versioned pack mount.")
		return
	if versioned_ignored_resource == null or versioned_ignored_resource.resource_name != "versioned-two":
		_fail("Expected CACHE_MODE_IGNORE to load updated resource after versioned pack mount.")
		return

	print(
		"PackRat PCK hot-update probe passed. replace_before_reload='%s' cached_resource='%s' ignored_cache_resource='%s'" %
		[read_after_replace_before_reload, cached_resource_after_reload.resource_name, ignored_cache_resource.resource_name]
	)
	get_tree().quit()


func _write_pack(path: String, marker: String, extra: String) -> bool:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var marker_source_path: String = WORK_DIR.path_join("marker-source.txt")
	var marker_file: FileAccess = FileAccess.open(marker_source_path, FileAccess.WRITE)
	if marker_file == null:
		_fail("Could not open marker source for %s." % path)
		return false
	marker_file.store_string(marker)
	marker_file = null

	var resource_source_path: String = WORK_DIR.path_join("version-source.tres")
	var resource_file: FileAccess = FileAccess.open(resource_source_path, FileAccess.WRITE)
	if resource_file == null:
		_fail("Could not open resource source for %s." % path)
		return false
	resource_file.store_string('[gd_resource type="Resource" format=3]\n\n[resource]\nresource_name = "%s"\n' % marker)
	resource_file = null

	var packer: PCKPacker = PCKPacker.new()
	var error: Error = packer.pck_start(path)
	if error != OK:
		_fail("Could not start PCK %s (error %d)." % [path, error])
		return false

	if not extra.is_empty():
		var extra_source_path: String = WORK_DIR.path_join("extra-source.txt")
		var extra_file: FileAccess = FileAccess.open(extra_source_path, FileAccess.WRITE)
		if extra_file == null:
			_fail("Could not open extra source for %s." % path)
			return false
		extra_file.store_string(extra)
		extra_file = null

		error = packer.add_file(EXTRA_PATH, extra_source_path)
		if error != OK:
			_fail("Could not add extra file to %s (error %d)." % [path, error])
			return false

	error = packer.add_file(MARKER_PATH, marker_source_path)
	if error != OK:
		_fail("Could not add marker file to %s (error %d)." % [path, error])
		return false

	error = packer.add_file(RESOURCE_PATH, resource_source_path)
	if error != OK:
		_fail("Could not add resource file to %s (error %d)." % [path, error])
		return false

	error = packer.flush()
	if error != OK:
		_fail("Could not flush PCK %s (error %d)." % [path, error])
		return false

	return true


func _make_directory(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		_fail("Could not create directory %s (error %d)." % [path, error])


func _clear_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = path.path_join(child)
		if dir.current_is_dir():
			_clear_directory(child_path)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child_path))
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child_path))
		child = dir.get_next()

	dir.list_dir_end()


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
