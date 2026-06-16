extends SceneTree
## Updates or verifies the PackRat Portal demo catalog after Godot exports packs.

const DEFAULT_OUTPUT_DIR: String = "build/packs"

const _CATALOG_PATH: String = "res://demo/demo_catalog.gd"
const _OUTPUT_ARG: String = "--output-dir="
const _CHECK_ARG: String = "--check"


func _init() -> void:
	var output_dir: String = DEFAULT_OUTPUT_DIR
	var check_only: bool = false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(_OUTPUT_ARG):
			output_dir = argument.substr(_OUTPUT_ARG.length())
		elif argument == _CHECK_ARG:
			check_only = true

	var result: Dictionary = sync(output_dir, check_only)
	if not bool(result.get("ok", false)):
		printerr(result.get("error", "Unknown demo pack catalog error."))
		quit(1)
		return

	print(JSON.stringify(result, "\t"))
	quit()


## Updates or checks committed demo pack sizes and version tokens.
static func sync(output_dir: String = DEFAULT_OUTPUT_DIR, check_only: bool = false) -> Dictionary:
	var warehouse_path: String = output_dir.path_join(PackRatDemoCatalog.WAREHOUSE_FILE_NAME)
	var gallery_path: String = output_dir.path_join(PackRatDemoCatalog.GALLERY_FILE_NAME)
	var warehouse_size: int = FileAccess.get_size(warehouse_path)
	var gallery_size: int = FileAccess.get_size(gallery_path)
	var warehouse_token: String = _file_version_token(warehouse_path)
	var gallery_token: String = _file_version_token(gallery_path)
	var result: Dictionary = {
		"ok": false,
		"error": "",
		"warehouse_path": warehouse_path,
		"gallery_path": gallery_path,
		"warehouse_size": warehouse_size,
		"gallery_size": gallery_size,
		"warehouse_version_token": warehouse_token,
		"gallery_version_token": gallery_token,
	}

	if warehouse_size <= 0:
		result.error = "Missing or empty warehouse pack: %s" % warehouse_path
		return result
	if gallery_size <= 0:
		result.error = "Missing or empty gallery pack: %s" % gallery_path
		return result

	if check_only:
		result.error = _catalog_mismatch_error(warehouse_size, gallery_size, warehouse_token, gallery_token)
		result.ok = result.error.is_empty()
		return result

	var catalog_error: Error = _write_catalog_metadata(
		warehouse_size,
		gallery_size,
		warehouse_token,
		gallery_token
	)
	if catalog_error != OK:
		result.error = "Could not update demo catalog sizes (error %d)." % catalog_error
		return result

	result.ok = true
	return result


static func _catalog_mismatch_error(
	warehouse_size: int,
	gallery_size: int,
	warehouse_version_token: String,
	gallery_version_token: String
) -> String:
	if PackRatDemoCatalog.WAREHOUSE_FILE_SIZE != warehouse_size:
		return "Warehouse catalog size is stale. Expected %d, exported %d." % [
			PackRatDemoCatalog.WAREHOUSE_FILE_SIZE,
			warehouse_size,
		]
	if PackRatDemoCatalog.GALLERY_FILE_SIZE != gallery_size:
		return "Gallery catalog size is stale. Expected %d, exported %d." % [
			PackRatDemoCatalog.GALLERY_FILE_SIZE,
			gallery_size,
		]
	if PackRatDemoCatalog.WAREHOUSE_VERSION_TOKEN != warehouse_version_token:
		return "Warehouse catalog token is stale. Expected %s, exported %s." % [
			PackRatDemoCatalog.WAREHOUSE_VERSION_TOKEN,
			warehouse_version_token,
		]
	if PackRatDemoCatalog.GALLERY_VERSION_TOKEN != gallery_version_token:
		return "Gallery catalog token is stale. Expected %s, exported %s." % [
			PackRatDemoCatalog.GALLERY_VERSION_TOKEN,
			gallery_version_token,
		]

	return ""


static func _write_catalog_metadata(
	warehouse_size: int,
	gallery_size: int,
	warehouse_version_token: String,
	gallery_version_token: String
) -> Error:
	var text: String = FileAccess.get_file_as_string(_CATALOG_PATH)
	if text.is_empty():
		return FAILED

	if not _has_int_const(text, "WAREHOUSE_FILE_SIZE") or not _has_int_const(text, "GALLERY_FILE_SIZE"):
		return FAILED
	if not _has_string_const(text, "WAREHOUSE_VERSION_TOKEN") or not _has_string_const(text, "GALLERY_VERSION_TOKEN"):
		return FAILED

	text = _replace_int_const(text, "WAREHOUSE_FILE_SIZE", warehouse_size)
	text = _replace_int_const(text, "GALLERY_FILE_SIZE", gallery_size)
	text = _replace_string_const(text, "WAREHOUSE_VERSION_TOKEN", warehouse_version_token)
	text = _replace_string_const(text, "GALLERY_VERSION_TOKEN", gallery_version_token)

	var file: FileAccess = FileAccess.open(_CATALOG_PATH, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(text)
	return OK


static func _has_int_const(text: String, name: String) -> bool:
	return text.contains("const %s: int =" % name)


static func _has_string_const(text: String, name: String) -> bool:
	return text.contains("const %s: String =" % name)


static func _replace_int_const(text: String, name: String, value: int) -> String:
	var pattern: RegEx = RegEx.new()
	var error: Error = pattern.compile("const %s: int = \\d+" % name)
	if error != OK:
		return text

	return pattern.sub(text, "const %s: int = %d" % [name, value], false)


static func _replace_string_const(text: String, name: String, value: String) -> String:
	var pattern: RegEx = RegEx.new()
	var error: Error = pattern.compile("const %s: String = \"[^\"]*\"" % name)
	if error != OK:
		return text

	return pattern.sub(text, "const %s: String = \"%s\"" % [name, value], false)


static func _file_version_token(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return str(FileAccess.get_size(path))

	var hash: HashingContext = HashingContext.new()
	var error: Error = hash.start(HashingContext.HASH_SHA256)
	if error != OK:
		return str(FileAccess.get_size(path))

	var chunk: PackedByteArray = file.get_buffer(64 * 1024)
	while not chunk.is_empty():
		hash.update(chunk)
		chunk = file.get_buffer(64 * 1024)

	var digest: String = hash.finish().hex_encode().substr(0, 12)
	return "%d-%s" % [FileAccess.get_size(path), digest]
