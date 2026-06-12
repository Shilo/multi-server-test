class_name PackRatWebFetchClient extends RefCounted
## Internal browser fetch downloader used by PackRat Web exports.
##
## Godot's Web HTTPClient can only advance once per engine frame, so large
## browser-provided chunks can still trickle into Godot slowly. This helper
## lets the browser fetch the file at native speed, then writes the finished
## bytes into Godot's user file system for the normal cache and mount pipeline.

const _MAX_DOWNLOAD_BYTES: int = 512 * 1024 * 1024
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

	window.__packratWebFetchDownload = async function(id, url, headerLinesJson, timeoutMs, progressCallback, doneCallback, errorCallback) {
		const key = String(id);
		const controller = new AbortController();
		let timeoutHandle = 0;
		window.__packratWebFetchActive.set(key, controller);

		try {
			const headerLines = JSON.parse(headerLinesJson || "[]");
			const request = {
				headers: window.__packratWebFetchHeaders(headerLines),
				signal: controller.signal,
			};
			if (timeoutMs > 0) {
				timeoutHandle = setTimeout(() => controller.abort("timeout"), timeoutMs);
			}

			const response = await fetch(url, request);
			const headers = JSON.stringify(Array.from(response.headers.entries()));
			const total = Number(response.headers.get("content-length") || 0);

			if (!response.body || !response.body.getReader) {
				const fallbackBuffer = await response.arrayBuffer();
				if (fallbackBuffer.byteLength > 536870912) {
					throw new Error("Downloaded pack is too large for the Web fast path.");
				}
				progressCallback(key, fallbackBuffer.byteLength, total);
				doneCallback(key, response.status, headers, fallbackBuffer);
				return;
			}

			const reader = response.body.getReader();
			const chunks = [];
			let received = 0;
			let lastProgressAt = 0;

			while (true) {
				const result = await reader.read();
				if (result.done) {
					break;
				}

				const chunk = result.value;
				chunks.push(chunk);
				received += chunk.byteLength;
				if (received > 536870912) {
					throw new Error("Downloaded pack is too large for the Web fast path.");
				}

				const now = performance.now();
				if (now - lastProgressAt >= PROGRESS_INTERVAL_MS || received === total) {
					lastProgressAt = now;
					progressCallback(key, received, total);
				}
			}

			const merged = new Uint8Array(received);
			let offset = 0;
			for (const chunk of chunks) {
				merged.set(chunk, offset);
				offset += chunk.byteLength;
			}
			progressCallback(key, received, total);
			doneCallback(key, response.status, headers, merged.buffer);
		} catch (error) {
			const message = error && error.message ? error.message : String(error);
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
	return OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")


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
	var write_start_msec: Array[int] = [0]

	var progress_callable: Callable = func(args: Array) -> void:
		if args.size() < 3 or String(args[0]) != request_id:
			return

		progress_events[0] += 1
		var downloaded_bytes: int = int(args[1])
		var total_bytes: int = int(args[2])
		if options.has_expected_size():
			total_bytes = options.expected_size
		owner._set_progress(downloaded_bytes, total_bytes)

	var done_callable: Callable = func(args: Array) -> void:
		if args.size() < 4 or String(args[0]) != request_id:
			return

		state["response_code"] = int(args[1])
		state["headers"] = _headers_from_json(String(args[2]))
		var buffer: Variant = args[3]
		if not bool(bridge.call("is_js_buffer", buffer)):
			state["error"] = "Browser fetch did not return a byte buffer."
			state["done"] = true
			return

		write_start_msec[0] = _timing_start(capture_timings)
		var bytes: PackedByteArray = bridge.call("js_buffer_to_packed_byte_array", buffer)
		if bytes.size() > _MAX_DOWNLOAD_BYTES:
			state["error"] = "Downloaded pack is too large for the Web fast path."
			state["done"] = true
			return

		var file: FileAccess = FileAccess.open(download_path, FileAccess.WRITE)
		if file == null:
			state["error"] = "Could not open download file %s (error %d)." % [download_path, FileAccess.get_open_error()]
			state["done"] = true
			return

		file.store_buffer(bytes)
		var file_error: Error = file.get_error()
		file = null
		if file_error != OK:
			state["error"] = "Could not write download file %s (error %d)." % [download_path, file_error]
		state["done"] = true

	var error_callable: Callable = func(args: Array) -> void:
		if args.size() < 2 or String(args[0]) != request_id:
			return

		state["error"] = String(args[1])
		state["done"] = true

	callbacks.append(bridge.call("create_callback", progress_callable))
	callbacks.append(bridge.call("create_callback", done_callable))
	callbacks.append(bridge.call("create_callback", error_callable))

	var start_request_msec: int = _timing_start(capture_timings)
	var header_lines_json: String = JSON.stringify(_header_lines(options.request_headers))
	var timeout_msec: int = roundi(options.timeout_seconds * 1000.0)
	var web_fetch: Object = bridge.call("get_interface", "__packratWebFetchBridge")
	if web_fetch == null:
		return _finish_timing(PackRatHttpResponse.failed("PackRat browser fetch bridge is not available."), timings_msec, total_start_msec, capture_timings)

	web_fetch.call(
		"download",
		request_id,
		url,
		header_lines_json,
		timeout_msec,
		callbacks[0],
		callbacks[1],
		callbacks[2]
	)
	_record_timing(timings_msec, capture_timings, "http_start_msec", start_request_msec)

	var transfer_start_msec: int = _timing_start(capture_timings)
	while not bool(state["done"]):
		if owner.is_canceled():
			_cancel(bridge, request_id)
			_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
			timings_msec["http_progress_frames"] = progress_events[0]
			return _finish_timing(PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED), timings_msec, total_start_msec, capture_timings)
		await tree.process_frame

	_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
	if capture_timings:
		timings_msec["http_progress_frames"] = progress_events[0]
		if write_start_msec[0] > 0:
			_record_timing(timings_msec, capture_timings, "http_write_msec", write_start_msec[0])

	if not String(state["error"]).is_empty():
		return _finish_timing(PackRatHttpResponse.failed(String(state["error"])), timings_msec, total_start_msec, capture_timings)

	var response: PackRatHttpResponse = PackRatHttpResponse.from_completed(
		HTTPRequest.RESULT_SUCCESS,
		int(state["response_code"]),
		state["headers"] as PackedStringArray
	)
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


static func _cancel(bridge: Object, request_id: String) -> void:
	var web_fetch: Object = bridge.call("get_interface", "__packratWebFetchBridge")
	if web_fetch != null:
		web_fetch.call("cancel", request_id)


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
