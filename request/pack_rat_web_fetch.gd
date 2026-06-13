class_name PackRatWebFetch extends RefCounted
## Browser-native file downloader for Godot Web exports.
##
## [PackRatWebFetch] is a node-free alternative to [HTTPRequest] for large Web
## downloads. It uses browser [code]fetch()[/code], streams decoded response
## bytes into a Godot file, supports progress and cancellation callbacks, and
## returns [PackRatWebFetchResult].

## Smallest supported download chunk size in bytes.
const MIN_CHUNK_SIZE: int = 256

## Largest supported download chunk size in bytes. This matches [HTTPRequest].
const MAX_CHUNK_SIZE: int = 16 * 1024 * 1024

## Balanced default download chunk size for large files.
const DEFAULT_CHUNK_SIZE: int = 8 * 1024 * 1024

## Returns [code]true[/code] when browser [code]fetch()[/code] streaming is available.
static func is_available() -> bool:
	return PackRatWebFetchBridge.is_available()


## Downloads [param url] into [param download_path].
##
## [param progress_callback], when valid, is called as
## [code]progress_callback.call(downloaded_bytes, total_bytes)[/code]. Browser
## fetch often cannot expose a reliable decoded total, so [code]total_bytes[/code]
## may be [code]0[/code].
##
## [param cancel_callback], when valid, is polled once per frame. Returning
## [code]true[/code] aborts the request.
static func download_file(
	url: String,
	download_path: String,
	request_headers: PackedStringArray = PackedStringArray(),
	timeout_seconds: float = 120.0,
	download_chunk_size: int = DEFAULT_CHUNK_SIZE,
	max_redirects: int = 8,
	progress_callback: Callable = Callable(),
	cancel_callback: Callable = Callable(),
	maximum_size: int = 0,
	capture_timings: bool = false
) -> PackRatWebFetchResult:
	var total_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var timings_msec: Dictionary = {}
	var bridge: Object = PackRatWebFetchBridge.javascript_bridge()
	if bridge == null:
		return _finish_timing(PackRatWebFetchResult.failed("JavaScriptBridge is not available."), timings_msec, total_start_msec, capture_timings)

	var invalid_header_error: String = _invalid_header_error(request_headers)
	if not invalid_header_error.is_empty():
		return _finish_timing(PackRatWebFetchResult.failed(invalid_header_error), timings_msec, total_start_msec, capture_timings)

	var setup_start_msec: int = _timing_start(capture_timings)
	if not PackRatWebFetchBridge.ensure_installed(bridge):
		return _finish_timing(PackRatWebFetchResult.failed("Browser fetch helper could not be installed."), timings_msec, total_start_msec, capture_timings)
	_record_timing(timings_msec, capture_timings, "setup_msec", setup_start_msec)

	var tree: SceneTree = Engine.get_main_loop()
	if tree == null:
		return _finish_timing(PackRatWebFetchResult.failed("Browser fetch needs a running SceneTree."), timings_msec, total_start_msec, capture_timings)

	var temp_path: String = _temporary_path(download_path, "download")
	var file: FileAccess = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _finish_timing(PackRatWebFetchResult.failed(
			"Could not open temporary download file %s (error %d)." % [temp_path, FileAccess.get_open_error()],
			HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN
		), timings_msec, total_start_msec, capture_timings)

	var state: Dictionary = {
		"done": false,
		"error": "",
		"response_code": 0,
		"headers": PackedStringArray(),
		"file": file,
		"temp_path": temp_path,
		"written_bytes": 0,
	}
	file = null

	var callbacks: Array[Variant] = []
	var request_id: String = "%d-%d" % [Time.get_ticks_usec(), randi()]
	var progress_events: Array[int] = [0]
	var write_chunks: Array[int] = [0]
	var write_max_chunk_size: Array[int] = [0]
	var write_msec: Array[int] = [0]
	var effective_chunk_size: int = clampi(download_chunk_size, MIN_CHUNK_SIZE, MAX_CHUNK_SIZE)

	var progress_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 3 or String(args[0]) != request_id:
			return

		progress_events[0] += 1
		if progress_callback.is_valid():
			progress_callback.call(int(args[1]), int(args[2]))

	var chunk_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 2 or String(args[0]) != request_id:
			return

		var buffer: Variant = args[1]
		if not PackRatWebFetchBridge.is_js_buffer(bridge, buffer):
			_fail_active_download(state, bridge, request_id, "Browser fetch did not return a chunk byte buffer.", HTTPRequest.RESULT_REQUEST_FAILED)
			return

		var chunk_write_start_msec: int = _timing_start(capture_timings)
		var bytes: PackedByteArray = PackRatWebFetchBridge.js_buffer_to_packed_byte_array(bridge, buffer)
		if bytes.size() > effective_chunk_size:
			_fail_active_download(state, bridge, request_id, "Browser fetch returned a chunk larger than download_chunk_size.", HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED)
			return

		var next_written_bytes: int = int(state.get("written_bytes", 0)) + bytes.size()
		if maximum_size > 0 and next_written_bytes > maximum_size:
			_fail_active_download(state, bridge, request_id, "Downloaded file size exceeded maximum_size: expected %d bytes." % maximum_size, HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED)
			return

		var output_file: FileAccess = state["file"]
		if output_file == null:
			_fail_active_download(state, bridge, request_id, "Browser fetch download file was closed before the transfer finished.", HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR)
			return

		output_file.store_buffer(bytes)
		var file_error: Error = output_file.get_error()
		if file_error != OK:
			_fail_active_download(state, bridge, request_id, "Could not write download file %s (error %d)." % [download_path, file_error], HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR)
			return

		state["written_bytes"] = next_written_bytes
		write_chunks[0] += 1
		write_max_chunk_size[0] = maxi(write_max_chunk_size[0], bytes.size())
		if capture_timings:
			write_msec[0] += Time.get_ticks_msec() - chunk_write_start_msec

	var done_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 3 or String(args[0]) != request_id:
			return

		state["response_code"] = int(args[1])
		state["headers"] = _headers_from_json(String(args[2]))
		state["done"] = true

	var error_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 2 or String(args[0]) != request_id:
			return

		if String(state["error"]).is_empty():
			state["error"] = String(args[1])
			state["result_code"] = _result_code_for_error(String(args[1]))
		state["done"] = true

	callbacks.append(bridge.call("create_callback", progress_callable))
	callbacks.append(bridge.call("create_callback", chunk_callable))
	callbacks.append(bridge.call("create_callback", done_callable))
	callbacks.append(bridge.call("create_callback", error_callable))

	var start_request_msec: int = _timing_start(capture_timings)
	var did_start: bool = PackRatWebFetchBridge.start_download(
		bridge,
		request_id,
		url,
		JSON.stringify(_header_lines(request_headers)),
		roundi(timeout_seconds * 1000.0),
		effective_chunk_size,
		max_redirects,
		callbacks[0],
		callbacks[1],
		callbacks[2],
		callbacks[3]
	)
	if not did_start:
		_close_file(state)
		_remove_temp_file(state)
		return _finish_timing(PackRatWebFetchResult.failed("Browser fetch bridge is not available."), timings_msec, total_start_msec, capture_timings)
	_record_timing(timings_msec, capture_timings, "start_msec", start_request_msec)

	var transfer_start_msec: int = _timing_start(capture_timings)
	var deadline_msec: int = Time.get_ticks_msec() + roundi(timeout_seconds * 1000.0) if timeout_seconds > 0.0 else 0
	while not bool(state["done"]):
		if cancel_callback.is_valid() and bool(cancel_callback.call()):
			_cancel(bridge, request_id)
			_close_file(state)
			state["error"] = PackRatWebFetchResult.ERROR_CANCELED
			state["result_code"] = HTTPRequest.RESULT_REQUEST_FAILED
			state["done"] = true
			break

		if deadline_msec > 0 and Time.get_ticks_msec() >= deadline_msec:
			_cancel(bridge, request_id)
			_close_file(state)
			state["error"] = "HTTP request timed out."
			state["result_code"] = HTTPRequest.RESULT_TIMEOUT
			state["done"] = true
			break
		await tree.process_frame

	_close_file(state)
	_record_timing(timings_msec, capture_timings, "transfer_msec", transfer_start_msec)
	if capture_timings:
		timings_msec["progress_frames"] = progress_events[0]
		timings_msec["write_msec"] = write_msec[0]
		timings_msec["write_chunks"] = write_chunks[0]
		timings_msec["write_max_chunk_size"] = write_max_chunk_size[0]

	if not String(state["error"]).is_empty():
		_remove_temp_file(state)
		return _finish_timing(PackRatWebFetchResult.failed(
			String(state["error"]),
			state.get("result_code", HTTPRequest.RESULT_REQUEST_FAILED)
		), timings_msec, total_start_msec, capture_timings)

	var fetch_result: PackRatWebFetchResult = PackRatWebFetchResult.new()
	fetch_result.result_code = HTTPRequest.RESULT_SUCCESS
	fetch_result.response_code = int(state["response_code"])
	fetch_result.headers = state["headers"] as PackedStringArray
	fetch_result.ok = fetch_result.response_code >= 200 and fetch_result.response_code < 300
	fetch_result.downloaded_bytes = int(state["written_bytes"])
	fetch_result.download_path = download_path
	fetch_result.write_chunks = write_chunks[0]
	fetch_result.write_max_chunk_size = write_max_chunk_size[0]
	if not fetch_result.ok:
		_remove_temp_file(state)
		fetch_result.error = "HTTP request failed (result %d, response %d)." % [fetch_result.result_code, fetch_result.response_code]
		return _finish_timing(fetch_result, timings_msec, total_start_msec, capture_timings)

	var finalize_error: Error = _finalize_temp_file(temp_path, download_path)
	if finalize_error != OK:
		_remove_temp_file(state)
		return _finish_timing(PackRatWebFetchResult.failed(
			"Could not move downloaded file into place (error %d)." % finalize_error,
			HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR
		), timings_msec, total_start_msec, capture_timings)

	return _finish_timing(fetch_result, timings_msec, total_start_msec, capture_timings)


static func _headers_from_json(headers_json: String) -> PackedStringArray:
	var headers: PackedStringArray = []
	var parsed: Variant = JSON.parse_string(headers_json)
	if not (parsed is Array):
		return headers

	for entry in parsed:
		if entry is Array and entry.size() >= 2:
			headers.append("%s: %s" % [String(entry[0]), String(entry[1])])

	return headers


static func _header_lines(headers: PackedStringArray) -> Array[String]:
	var lines: Array[String] = []
	for header in headers:
		lines.append(header)
	return lines


static func _invalid_header_error(headers: PackedStringArray) -> String:
	for index in range(headers.size()):
		var sanitized: String = headers[index].strip_edges()
		if sanitized.is_empty():
			return "Invalid HTTP header at index %d: empty." % index

		if sanitized.find(":") < 1:
			return (
				"Invalid HTTP header at index %d: String must contain header-value pair, delimited by ':', but was: '%s'."
				% [index, headers[index]]
			)

	return ""


static func _cancel(bridge: Object, request_id: String) -> void:
	PackRatWebFetchBridge.cancel(bridge, request_id)


static func _fail_active_download(
	state: Dictionary,
	bridge: Object,
	request_id: String,
	message: String,
	result_code: HTTPRequest.Result
) -> void:
	if String(state["error"]).is_empty():
		state["error"] = message
		state["result_code"] = result_code
	state["done"] = true
	_close_file(state)
	_cancel(bridge, request_id)


static func _close_file(state: Dictionary) -> void:
	var file: FileAccess = state.get("file", null)
	if file != null:
		file.flush()
		file.close()
		state["file"] = null


static func _remove_temp_file(state: Dictionary) -> void:
	var temp_path: String = String(state.get("temp_path", ""))
	if not temp_path.is_empty() and FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)


static func _temporary_path(path: String, label: String) -> String:
	return "%s.%s-%d-%d.part" % [path, label, Time.get_ticks_usec(), randi()]


static func _finalize_temp_file(temp_path: String, path: String) -> Error:
	var backup_path: String = _temporary_path(path, "backup")
	var had_existing_file: bool = FileAccess.file_exists(path)
	if had_existing_file:
		var backup_error: Error = DirAccess.rename_absolute(path, backup_path)
		if backup_error != OK:
			return backup_error

	var rename_error: Error = DirAccess.rename_absolute(temp_path, path)
	if rename_error != OK:
		if had_existing_file and FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, path)
		return rename_error

	if had_existing_file and FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	return OK


static func _result_code_for_error(message: String) -> HTTPRequest.Result:
	if message == "HTTP request timed out.":
		return HTTPRequest.RESULT_TIMEOUT
	return HTTPRequest.RESULT_REQUEST_FAILED


static func _timing_start(capture_timings: bool) -> int:
	return Time.get_ticks_msec() if capture_timings else 0


static func _record_timing(timings_msec: Dictionary, capture_timings: bool, key: String, start_msec: int) -> void:
	if capture_timings:
		timings_msec[key] = Time.get_ticks_msec() - start_msec


static func _finish_timing(
	result: PackRatWebFetchResult,
	timings_msec: Dictionary,
	total_start_msec: int,
	capture_timings: bool
) -> PackRatWebFetchResult:
	if capture_timings:
		timings_msec["total_msec"] = Time.get_ticks_msec() - total_start_msec
		result.timings_msec = timings_msec
	return result
