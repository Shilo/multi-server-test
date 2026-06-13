class_name PackRatWebFetchBridge extends RefCounted
## Internal JavaScript bridge used by [PackRatWebFetch].
##
## This class owns the browser-side [code]fetch()[/code] implementation and
## the thin [JavaScriptBridge] calls needed to start, cancel, and receive
## streamed chunks. It does not know about PackRat cache or resource packs.

## Name of the browser global object installed by this bridge.
const BRIDGE_NAME: String = "__packRatWebFetchBridge"

const _BRIDGE_VERSION: int = 2
const _INSTALL_CHECK: String = "Boolean(window.__packRatWebFetchBridge && window.__packRatWebFetchBridge.version === %d && typeof window.__packRatWebFetchBridge.download === 'function' && typeof window.__packRatWebFetchBridge.cancel === 'function')" % _BRIDGE_VERSION
const _FEATURE_CHECK: String = "typeof fetch === 'function' && typeof AbortController === 'function' && typeof ReadableStream === 'function' && typeof ReadableStream.prototype.getReader === 'function'"
const _SCRIPT: String = """
(() => {
	const BRIDGE_VERSION = 2;
	if (
		window.__packRatWebFetchBridge &&
		window.__packRatWebFetchBridge.version === BRIDGE_VERSION &&
		typeof window.__packRatWebFetchBridge.download === "function" &&
		typeof window.__packRatWebFetchBridge.cancel === "function"
	) {
		return true;
	}

	const PROGRESS_INTERVAL_MS = 500;

	window.__packRatWebFetchActive = new Map();

	window.__packRatWebFetchHeaders = function(headerLines) {
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

	window.__packRatWebFetchDownload = async function(id, url, headerLinesJson, timeoutMs, chunkSize, maxRedirects, progressCallback, chunkCallback, doneCallback, errorCallback) {
		const key = String(id);
		let controller = null;
		let timeoutHandle = 0;

		try {
			controller = new AbortController();
			window.__packRatWebFetchActive.set(key, controller);
			const headerLines = JSON.parse(headerLinesJson || "[]");
			const request = {
				headers: window.__packRatWebFetchHeaders(headerLines),
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

				const now = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
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
			if (controller && controller.signal.aborted) {
				const reason = controller.signal.reason;
				if (reason === "timeout") {
					message = "HTTP request timed out.";
				} else if (reason === "canceled") {
					message = "Request canceled.";
				}
			}
			errorCallback(key, message);
		} finally {
			window.__packRatWebFetchActive.delete(key);
			if (timeoutHandle) {
				clearTimeout(timeoutHandle);
			}
		}
	};

	window.__packRatWebFetchCancel = function(id) {
		const controller = window.__packRatWebFetchActive.get(String(id));
		if (controller) {
			controller.abort("canceled");
		}
	};

	window.__packRatWebFetchBridge = {
		version: BRIDGE_VERSION,
		download: window.__packRatWebFetchDownload,
		cancel: window.__packRatWebFetchCancel,
	};

	return true;
})()
"""


## Returns [code]true[/code] when browser [code]fetch()[/code] streaming can be used.
static func is_available() -> bool:
	var bridge: Object = javascript_bridge()
	if bridge == null:
		return false

	return bool(bridge.call("eval", _FEATURE_CHECK, true))


## Returns the [JavaScriptBridge] singleton, or [code]null[/code] when unavailable.
static func javascript_bridge() -> Object:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return null

	return Engine.get_singleton("JavaScriptBridge")


## Installs the browser-side helper if needed and returns [code]true[/code] on success.
static func ensure_installed(bridge: Object) -> bool:
	var installed: Variant = bridge.call("eval", _INSTALL_CHECK, true)
	if bool(installed):
		return true

	bridge.call("eval", _SCRIPT, true)
	installed = bridge.call("eval", _INSTALL_CHECK, true)
	return bool(installed)


## Starts a browser [code]fetch()[/code] download through the installed bridge.
static func start_download(
	bridge: Object,
	request_id: String,
	url: String,
	header_lines_json: String,
	timeout_msec: int,
	chunk_size: int,
	max_redirects: int,
	progress_callback: Variant,
	chunk_callback: Variant,
	done_callback: Variant,
	error_callback: Variant
) -> bool:
	var web_fetch: Object = bridge.call("get_interface", BRIDGE_NAME)
	if web_fetch == null:
		return false

	web_fetch.call(
		"download",
		request_id,
		url,
		header_lines_json,
		timeout_msec,
		chunk_size,
		max_redirects,
		progress_callback,
		chunk_callback,
		done_callback,
		error_callback
	)
	return true


## Cancels the browser request with [param request_id] when it is still active.
static func cancel(bridge: Object, request_id: String) -> void:
	var web_fetch: Object = bridge.call("get_interface", BRIDGE_NAME)
	if web_fetch != null:
		web_fetch.call("cancel", request_id)


## Returns [code]true[/code] when [param value] is a JavaScript byte buffer.
static func is_js_buffer(bridge: Object, value: Variant) -> bool:
	return bool(bridge.call("is_js_buffer", value))


## Copies a JavaScript byte buffer into a Godot [PackedByteArray].
static func js_buffer_to_packed_byte_array(bridge: Object, value: Variant) -> PackedByteArray:
	return bridge.call("js_buffer_to_packed_byte_array", value)
