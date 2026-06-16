extends Node

const EDITOR_PACK_EXPORT_SCRIPT: GDScript = preload("res://addons/pack_rat/resource_pack/pack_rat_editor_pack_export.gd")

const CACHE_DIR: String = "user://pack_rat_editor_export_preset_smoke_cache"
const WAREHOUSE_URL: String = "https://example.com/packs/warehouse.pck"
const WAREHOUSE_PRESET_NAME: String = "Warehouse DLC"
const GALLERY_URL: String = "https://example.com/packs/gallery.zip"
const GALLERY_PRESET_NAME: String = "Gallery DLC"


func _ready() -> void:
	if not OS.has_feature("editor"):
		print("PackRat editor export preset smoke skipped outside editor.")
		get_tree().quit()
		return

	_clear_directory(CACHE_DIR)
	var warehouse_export_path: String = await EDITOR_PACK_EXPORT_SCRIPT.exported_pack_path(WAREHOUSE_PRESET_NAME, CACHE_DIR)
	var gallery_export_path: String = await EDITOR_PACK_EXPORT_SCRIPT.exported_pack_path(GALLERY_PRESET_NAME, CACHE_DIR)
	DirAccess.remove_absolute(warehouse_export_path)
	DirAccess.remove_absolute(gallery_export_path)
	if not warehouse_export_path.begins_with(CACHE_DIR.path_join("editor_exports")):
		_fail("Expected editor export preset output to live under the selected cache dir, got %s." % warehouse_export_path)
		return

	var options: PackRatOptions = PackRatOptions.new()
	options.id = "editor-export-warehouse"
	options.cache_dir = CACHE_DIR
	options.editor_pack_export_preset = WAREHOUSE_PRESET_NAME
	options.capture_timings = true

	var first: PackRatResult = await PackRat.load_resource_pack(WAREHOUSE_URL, options)
	if not first.ok or first.from_cache:
		_fail("Expected editor export preset to build, copy, and mount. Result: %s" % JSON.stringify(first.to_dictionary()))
		return

	if not FileAccess.file_exists(warehouse_export_path):
		_fail("Expected editor export preset to create %s." % warehouse_export_path)
		return

	var exported_modified_time: int = int(FileAccess.get_modified_time(warehouse_export_path))
	var second: PackRatResult = await PackRat.load_resource_pack(WAREHOUSE_URL, options)
	if not second.ok or not second.from_cache:
		_fail("Expected editor export preset second load to use cache. Result: %s" % JSON.stringify(second.to_dictionary()))
		return

	if int(FileAccess.get_modified_time(warehouse_export_path)) != exported_modified_time:
		_fail("Expected fresh editor export preset pack to be reused across calls.")
		return

	var zip_options: PackRatOptions = options.copy()
	zip_options.id = "editor-export-gallery"
	zip_options.editor_pack_export_preset = GALLERY_PRESET_NAME
	var zip_result: PackRatResult = await PackRat.load_resource_pack(GALLERY_URL, zip_options)
	if not zip_result.ok or zip_result.local_path.get_extension() != "zip":
		_fail("Expected editor ZIP export preset to build, copy, and mount as ZIP. Result: %s" % JSON.stringify(zip_result.to_dictionary()))
		return

	var missing_options: PackRatOptions = options.copy()
	missing_options.editor_pack_export_preset = "PackRat Missing Export Preset"
	missing_options.id = "missing-editor-export"
	var missing: PackRatResult = await PackRat.load_resource_pack(WAREHOUSE_URL, missing_options)
	if missing.ok or not missing.error.contains("could not find export preset"):
		_fail("Expected missing editor export preset to fail clearly. Result: %s" % JSON.stringify(missing.to_dictionary()))
		return

	print("PackRat editor export preset smoke passed.")
	get_tree().quit()


func _clear_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return

	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return

	directory.list_dir_begin()
	var name: String = directory.get_next()
	while not name.is_empty():
		var child_path: String = path.path_join(name)
		if directory.current_is_dir():
			_clear_directory(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		name = directory.get_next()
	directory.list_dir_end()


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
