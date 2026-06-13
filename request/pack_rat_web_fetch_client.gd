class_name PackRatWebFetchClient extends RefCounted
## Internal browser fetch downloader used by PackRat Web exports.
##
## Godot's Web HTTPClient can only advance once per engine frame, so large
## browser-provided chunks can still trickle into Godot slowly. This helper
## lets the browser fetch the file at native speed, then streams byte chunks
## into Godot's user file system for the normal cache and mount pipeline.

const _SCRIPT: String = """
(() => {
	if (window.__packratWebFetchDownload) {
		return true;
	}

	const PROGRESS_INTERVAL_MS = 500;

	window.__packratWebFetchActive = new Map();

	window.__packratWebFetchHeaders = function(headerLines) {
		const headers = {};
		for (const line of headerLines) {
			const separator = String(line).indexOf(":");
			if (separator <= 0) {
				continue;
			}
			const key = String(line).slice(0, separator).trim();
			const value = String(line).slice(separator + 1).trim();
			if (key) {
				headers[key] = value;
			}
		}
		return headers;
	};

	window.__packratWebFetchDownload = async function(id, url, headerLinesJson, timeoutMs, chunkSize, maxRedirects, progressCallback, chunkCallback, doneCallback, errorCallback) {
		const key = String(id);
		const controller = new AbortController();
		let timeoutHandle = 0;
		window.__packratWebFetchActive.set(key, controller);

		try {
			const headerLines = JSON.parse(headerLinesJson || "[]");
			const request = {
				headers: window.__packratWebFetchHeaders(headerLines),
				redirect: Number(maxRedirects) === 0 ? "error" : "follow",
				signal: controller.signal,
			};
			if (timeoutMs > 0) {
				timeoutHandle = setTimeout(() => controller.abort("timeout"), timeoutMs);
			}

			const response = await fetch(url, request);
			const headers = JSON.stringify(Array.from(response.headers.entries()));
			const total = 0;
			const targetChunkSize = Math.max(256, Math.min(Number(chunkSize) || 8388608, 16777216));
			if (response.status < 200 || response.status >= 300) {
				if (response.body && response.body.cancel) {
					try {
						await response.body.cancel();
					} catch (_cancelError) {}
				}
				doneCallback(key, response.status, headers);
				return;
			}

			const exactArrayBuffer = (bytes) => {
				if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
					return bytes.buffer;
				}

				return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
			};

			if (!response.body || !response.body.getReader) {
				throw new Error("Browser fetch streaming is not available.");
			}

			const reader = response.body.getReader();
			let chunks = [];
			let received = 0;
			let buffered = 0;
			let lastProgressAt = 0;

			const flush = () => {
				if (buffered <= 0) {
					return;
				}

				let merged;
				if (chunks.length === 1 && chunks[0].byteLength === buffered) {
					merged = chunks[0];
				} else {
					merged = new Uint8Array(buffered);
					let offset = 0;
					for (const chunk of chunks) {
						merged.set(chunk, offset);
						offset += chunk.byteLength;
					}
				}

				chunkCallback(key, exactArrayBuffer(merged));
				chunks = [];
				buffered = 0;
			};

			const appendChunk = (chunk) => {
				let offset = 0;
				while (offset < chunk.byteLength && !controller.signal.aborted) {
					const remainingTargetBytes = targetChunkSize - buffered;
					const remainingChunkBytes = chunk.byteLength - offset;
					const taken = Math.min(remainingTargetBytes, remainingChunkBytes);
					chunks.push(chunk.subarray(offset, offset + taken));
					buffered += taken;
					offset += taken;
					if (buffered === targetChunkSize) {
						flush();
					}
				}
			};

			while (true) {
				const result = await reader.read();
				if (result.done || controller.signal.aborted) {
					break;
				}

				const chunk = result.value;
				received += chunk.byteLength;
				appendChunk(chunk);

				const now = performance.now();
				if (now - lastProgressAt >= PROGRESS_INTERVAL_MS || received === total) {
					lastProgressAt = now;
					progressCallback(key, received, total);
				}
			}

			if (controller.signal.aborted) {
				throw new Error("Browser fetch aborted.");
			}

			flush();
			progressCallback(key, received, total);
			doneCallback(key, response.status, headers);
		} catch (error) {
			let message = error && error.message ? error.message : String(error);
			if (controller.signal.aborted) {
				const reason = controller.signal.reason;
				if (reason === "timeout") {
					message = "HTTP request timed out.";
				} else if (reason === "canceled") {
					message = "Request canceled.";
				}
			}
			errorCallback(key, message);
		} finally {
			window.__packratWebFetchActive.delete(key);
			if (timeoutHandle) {
				clearTimeout(timeoutHandle);
			}
		}
	};

	window.__packratWebFetchCancel = function(id) {
		const controller = window.__packratWebFetchActive.get(String(id));
		if (controller) {
			controller.abort("canceled");
		}
	};

	window.__packratWebFetchBridge = {
		download: window.__packratWebFetchDownload,
		cancel: window.__packratWebFetchCancel,
	};

	return true;
})()
"""


## Returns [code]true[/code] when the browser JavaScript bridge can be used.
static func is_available() -> bool:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return false

	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return false

	return bool(bridge.call("eval", "typeof fetch === 'function' && typeof ReadableStream === 'function' && typeof ReadableStream.prototype.getReader === 'function'", true))


## Downloads [param url] into [param download_path] using browser-native fetch.
static func download(
	url: String,
	download_path: String,
	options: PackRatOptions,
	owner: PackRatRequest
) -> PackRatHttpResponse:
	var capture_timings: bool = options.capture_timings
	var total_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var timings_msec: Dictionary = {}
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return _finish_timing(PackRatHttpResponse.failed("JavaScriptBridge is not available."), timings_msec, total_start_msec, capture_timings)

	var invalid_header_error: String = _invalid_header_error(options.request_headers)
	if not invalid_header_error.is_empty():
		return _finish_timing(PackRatHttpResponse.failed(invalid_header_error), timings_msec, total_start_msec, capture_timings)

	var setup_start_msec: int = _timing_start(capture_timings)
	if not _ensure_installed(bridge):
		return _finish_timing(PackRatHttpResponse.failed("PackRat browser fetch helper could not be installed."), timings_msec, total_start_msec, capture_timings)
	_record_timing(timings_msec, capture_timings, "http_setup_msec", setup_start_msec)

	var tree: SceneTree = Engine.get_main_loop()
	if tree == null:
		return _finish_timing(PackRatHttpResponse.failed("Browser fetch needs a running SceneTree."), timings_msec, total_start_msec, capture_timings)

	var state: Dictionary = {
		"done": false,
		"error": "",
		"response_code": 0,
		"headers": PackedStringArray(),
	}
	var callbacks: Array[Variant] = []
	var request_id: String = "%d-%d" % [Time.get_ticks_usec(), randi()]
	var progress_events: Array[int] = [0]
	var write_chunks: Array[int] = [0]
	var write_max_chunk_size: Array[int] = [0]
	var write_msec: Array[int] = [0]
	var effective_chunk_size: int = clampi(options.download_chunk_size, 256, 16 * 1024 * 1024)
	var file: FileAccess = FileAccess.open(download_path, FileAccess.WRITE)
	if file == null:
		return _finish_timing(PackRatHttpResponse.failed("Could not open download file %s (error %d)." % [download_path, FileAccess.get_open_error()]), timings_msec, total_start_msec, capture_timings)

	state["file"] = file
	file = null

	var progress_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 3 or String(args[0]) != request_id:
			return

		progress_events[0] += 1
		var downloaded_bytes: int = int(args[1])
		var total_bytes: int = int(args[2])
		if options.progress_total_size > 0:
			total_bytes = options.progress_total_size
		elif options.has_expected_size():
			total_bytes = options.expected_size
		owner._set_progress(downloaded_bytes, total_bytes)

	var chunk_callable: Callable = func(args: Array) -> void:
		if bool(state["done"]) or args.size() < 2 or String(args[0]) != request_id:
			return

		var buffer: Variant = args[1]
		if not bool(bridge.call("is_js_buffer", buffer)):
			_fail_active_download(state, bridge, request_id, "Browser fetch did not return a chunk byte buffer.")
			return

		var chunk_write_start_msec: int = _timing_start(capture_timings)
		var bytes: PackedByteArray = bridge.call("js_buffer_to_packed_byte_array", buffer)
		if bytes.size() > effective_chunk_size:
			_fail_active_download(state, bridge, request_id, "Browser fetch returned a chunk larger than download_chunk_size.")
			return

		var next_written_bytes: int = int(state.get("written_bytes", 0)) + bytes.size()
		if options.has_expected_size() and next_written_bytes > options.expected_size:
			_fail_active_download(state, bridge, request_id, "Downloaded pack size exceeded expected_size: expected %d bytes." % options.expected_size)
			return

		var output_file: FileAccess = state["file"]
		if output_file == null:
			_fail_active_download(state, bridge, request_id, "Browser fetch download file was closed before the transfer finished.")
			return

		output_file.store_buffer(bytes)
		var file_error: Error = output_file.get_error()
		if file_error != OK:
			_fail_active_download(state, bridge, request_id, "Could not write download file %s (error %d)." % [download_path, file_error])
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
		state["done"] = true

	callbacks.append(bridge.call("create_callback", progress_callable))
	callbacks.append(bridge.call("create_callback", chunk_callable))
	callbacks.append(bridge.call("create_callback", done_callable))
	callbacks.append(bridge.call("create_callback", error_callable))

	var start_request_msec: int = _timing_start(capture_timings)
	var header_lines_json: String = JSON.stringify(_header_lines(options.request_headers))
	var timeout_msec: int = roundi(options.timeout_seconds * 1000.0)
	var web_fetch: Object = bridge.call("get_interface", "__packratWebFetchBridge")
	if web_fetch == null:
		_close_file(state)
		return _finish_timing(PackRatHttpResponse.failed("PackRat browser fetch bridge is not available."), timings_msec, total_start_msec, capture_timings)

	web_fetch.call(
		"download",
		request_id,
		url,
		header_lines_json,
		timeout_msec,
		effective_chunk_size,
		options.max_redirects,
		callbacks[0],
		callbacks[1],
		callbacks[2],
		callbacks[3]
	)
	_record_timing(timings_msec, capture_timings, "http_start_msec", start_request_msec)

	var transfer_start_msec: int = _timing_start(capture_timings)
	while not bool(state["done"]):
		if owner.is_canceled():
			_cancel(bridge, request_id)
			_close_file(state)
			_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
			timings_msec["http_progress_frames"] = progress_events[0]
			return _finish_timing(PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED), timings_msec, total_start_msec, capture_timings)
		await tree.process_frame

	_close_file(state)
	_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
	if capture_timings:
		timings_msec["http_progress_frames"] = progress_events[0]
		timings_msec["http_write_msec"] = write_msec[0]
		timings_msec["http_write_chunks"] = write_chunks[0]
		timings_msec["http_write_max_chunk_size"] = write_max_chunk_size[0]

	if not String(state["error"]).is_empty():
		return _finish_timing(PackRatHttpResponse.failed(String(state["error"])), timings_msec, total_start_msec, capture_timings)

	var response: PackRatHttpResponse = PackRatHttpResponse.from_completed(
		HTTPRequest.RESULT_SUCCESS,
		int(state["response_code"]),
		state["headers"] as PackedStringArray
	)
	response.content_length = 0
	return _finish_timing(response, timings_msec, total_start_msec, capture_timings)


static func _ensure_installed(bridge: Object) -> bool:
	var installed: Variant = bridge.call("eval", "Boolean(window.__packratWebFetchDownload)", true)
	if bool(installed):
		return true

	bridge.call("eval", _SCRIPT, true)
	installed = bridge.call("eval", "Boolean(window.__packratWebFetchDownload)", true)
	return bool(installed)


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
	var web_fetch: Object = bridge.call("get_interface", "__packratWebFetchBridge")
	if web_fetch != null:
		web_fetch.call("cancel", request_id)


static func _fail_active_download(state: Dictionary, bridge: Object, request_id: String, message: String) -> void:
	if String(state["error"]).is_empty():
		state["error"] = message
	state["done"] = true
	_close_file(state)
	_cancel(bridge, request_id)


static func _close_file(state: Dictionary) -> void:
	var file: FileAccess = state.get("file", null)
	if file != null:
		state["file"] = null


static func _timing_start(capture_timings: bool) -> int:
	return Time.get_ticks_msec() if capture_timings else 0


static func _record_timing(timings_msec: Dictionary, capture_timings: bool, key: String, start_msec: int) -> void:
	if capture_timings:
		timings_msec[key] = Time.get_ticks_msec() - start_msec


static func _finish_timing(
	response: PackRatHttpResponse,
	timings_msec: Dictionary,
	total_start_msec: int,
	capture_timings: bool
) -> PackRatHttpResponse:
	if capture_timings:
		timings_msec["http_total_msec"] = Time.get_ticks_msec() - total_start_msec
		response.timings_msec = timings_msec
	return response
