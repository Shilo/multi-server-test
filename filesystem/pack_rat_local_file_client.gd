class_name PackRatLocalFileClient extends RefCounted
## Internal local-file reader used by PackRat for editor/dev pack sources.

const _WEEKDAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const _MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


## Returns [code]true[/code] when [param source] can identify a local pack file.
static func is_local_pack_source(source: String) -> bool:
	var path: String = path_from_source(source)
	if path.is_empty():
		return false

	var extension: String = path.get_extension().to_lower()
	return extension == "pck" or extension == "zip"


## Converts [code]file://[/code], [code]res://[/code], [code]user://[/code], or absolute paths into FileAccess paths.
static func path_from_source(source: String) -> String:
	var value: String = source.strip_edges()
	if PackRatCachePaths.is_http_url(value):
		return ""

	if value.begins_with("file://"):
		value = value.trim_prefix("file://").uri_decode()
		if value.length() >= 3 and value.substr(0, 1) == "/" and value.substr(2, 1) == ":":
			value = value.substr(1)
		return value.replace("\\", "/").simplify_path()

	if value.begins_with("res://") or value.begins_with("user://"):
		var global_path: String = ProjectSettings.globalize_path(value).replace("\\", "/").simplify_path()
		if FileAccess.file_exists(global_path):
			return global_path

		return value.replace("\\", "/").simplify_path()

	if value.is_absolute_path():
		return value.replace("\\", "/").simplify_path()

	return ""


## Reads local file freshness metadata.
static func metadata(source_path: String) -> PackRatHttpResponse:
	if source_path.is_empty():
		return PackRatHttpResponse.failed("Local pack path was empty.")

	if not FileAccess.file_exists(source_path):
		return PackRatHttpResponse.failed("Local pack file does not exist: %s." % source_path)

	if not is_local_pack_source(source_path):
		return PackRatHttpResponse.failed("Local pack source must be a .pck or .zip file: %s." % source_path)

	var response: PackRatHttpResponse = PackRatHttpResponse.new()
	response.ok = true
	response.response_code = 0
	response.content_length = FileAccess.get_size(source_path)
	var modified_time: int = int(FileAccess.get_modified_time(source_path))
	response.last_modified = http_date_from_unix(modified_time)
	response.etag = ("local:%s:%d:%d" % [source_path, response.content_length, modified_time]).sha256_text().substr(0, 16)
	response.content_type = "application/zip" if source_path.get_extension().to_lower() == "zip" else "application/octet-stream"
	return response


## Copies a local pack into [param download_path] with progress and cancellation checks.
static func copy_to_cache_part(
	source_path: String,
	download_path: String,
	options: PackRatOptions,
	owner: PackRatRequest
) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = metadata(source_path)
	if not response.ok:
		return response

	var source_file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if source_file == null:
		return PackRatHttpResponse.failed("Could not open local pack file: %s." % source_path)

	var target_file: FileAccess = FileAccess.open(download_path, FileAccess.WRITE)
	if target_file == null:
		source_file.close()
		return PackRatHttpResponse.failed("Could not create local pack cache part: %s." % download_path)

	var chunk_size: int = clampi(
		options.download_chunk_size,
		PackRatOptions.MIN_DOWNLOAD_CHUNK_SIZE,
		PackRatOptions.MAX_DOWNLOAD_CHUNK_SIZE
	)
	var total_size: int = response.content_length
	var simulated_seconds: float = _simulated_load_seconds(options, total_size)
	if simulated_seconds > 0.0:
		chunk_size = mini(chunk_size, maxi(PackRatOptions.MIN_DOWNLOAD_CHUNK_SIZE, ceili(float(total_size) / 20.0)))

	var copied_size: int = 0
	owner._set_progress(0, total_size)

	var tree: SceneTree = Engine.get_main_loop()
	var start_msec: int = Time.get_ticks_msec()
	while copied_size < total_size:
		if owner.is_canceled():
			source_file.close()
			target_file.close()
			return PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED)

		var read_size: int = mini(chunk_size, total_size - copied_size)
		var buffer: PackedByteArray = source_file.get_buffer(read_size)
		if buffer.is_empty() and read_size > 0:
			source_file.close()
			target_file.close()
			return PackRatHttpResponse.failed("Could not read local pack file: %s." % source_path)

		target_file.store_buffer(buffer)
		copied_size += buffer.size()
		if simulated_seconds > 0.0 and not await _wait_for_simulated_progress(start_msec, copied_size, total_size, simulated_seconds, owner, tree):
			source_file.close()
			target_file.close()
			return PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED)

		owner._set_progress(copied_size, total_size)
		if tree != null:
			await tree.process_frame

	source_file.close()
	target_file.close()
	response.ok = true
	return response


static func _simulated_load_seconds(options: PackRatOptions, total_size: int) -> float:
	if not OS.has_feature("editor") or total_size <= 0:
		return 0.0

	return maxf(options.editor_simulated_local_load_seconds, 0.0)


static func _wait_for_simulated_progress(
	start_msec: int,
	copied_size: int,
	total_size: int,
	simulated_seconds: float,
	owner: PackRatRequest,
	tree: SceneTree
) -> bool:
	if tree == null:
		return true

	var target_msec: int = start_msec + int(simulated_seconds * 1000.0 * (float(copied_size) / float(total_size)))
	while Time.get_ticks_msec() < target_msec:
		if owner.is_canceled():
			return false

		await tree.process_frame

	return not owner.is_canceled()


## Formats [param unix_time] as an HTTP-style UTC date.
static func http_date_from_unix(unix_time: int) -> String:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(unix_time)
	var weekday_index: int = int(date.get("weekday", 0))
	var month_index: int = int(date.get("month", 1)) - 1
	return "%s, %02d %s %04d %02d:%02d:%02d GMT" % [
		_WEEKDAYS[clampi(weekday_index, 0, _WEEKDAYS.size() - 1)],
		int(date.get("day", 1)),
		_MONTHS[clampi(month_index, 0, _MONTHS.size() - 1)],
		int(date.get("year", 1970)),
		int(date.get("hour", 0)),
		int(date.get("minute", 0)),
		int(date.get("second", 0)),
	]
