extends Node

const CACHE_DIR: String = "user://pack_rat_performance_smoke_cache"
const SERVER_DIR: String = "user://pack_rat_performance_smoke_server"
const PACK_PATH: String = "user://pack_rat_performance_smoke_server/perf.pck"
const MARKER_SOURCE_PATH: String = "user://pack_rat_performance_smoke_server/marker.txt"
const PAYLOAD_SOURCE_PATH: String = "user://pack_rat_performance_smoke_server/payload.bin"
const LEGACY_CHUNK_SIZE: int = 64 * 1024
const OPTIMIZED_CHUNK_SIZE: int = 4 * 1024 * 1024
const LARGE_CHUNK_SIZE: int = 10 * 1024 * 1024
const MAX_CHUNK_SIZE: int = PackRatOptions.MAX_DOWNLOAD_CHUNK_SIZE
const REQUESTED_MAX_CHUNK_SIZE: int = 20 * 1024 * 1024
const PAYLOAD_BYTES: int = 10 * 1024 * 1024
const SERVER_CHUNK_SIZE: int = 20 * 1024 * 1024
const OVERHEAD_LIMIT_MSEC: int = 1000

var _server: TCPServer = TCPServer.new()
var _pack_bytes: PackedByteArray = []
var _url: String = ""
var _active_peers: int = 0


func _ready() -> void:
	Engine.max_fps = 60
	set_process(false)
	_clear_directory(CACHE_DIR)
	_clear_directory(SERVER_DIR)
	_make_directory(CACHE_DIR)
	_make_directory(SERVER_DIR)

	var listen_error: Error = _server.listen(0, "127.0.0.1")
	if listen_error != OK:
		_fail("Could not start performance HTTP server (error %d)." % listen_error)
		return

	_url = "http://127.0.0.1:%d/perf.pck" % _server.get_local_port()
	set_process(true)
	await get_tree().process_frame

	var raw_legacy: Dictionary = await _raw_case("raw_64k", LEGACY_CHUNK_SIZE)
	if raw_legacy.is_empty():
		return

	var raw_optimized: Dictionary = await _raw_case("raw_4m", OPTIMIZED_CHUNK_SIZE)
	if raw_optimized.is_empty():
		return

	var raw_large: Dictionary = await _raw_case("raw_10m", LARGE_CHUNK_SIZE)
	if raw_large.is_empty():
		return

	var raw_max: Dictionary = await _raw_case("raw_16m", MAX_CHUNK_SIZE)
	if raw_max.is_empty():
		return

	if int(raw_legacy.get("progress_frames", 0)) <= int(raw_optimized.get("progress_frames", 0)):
		_fail("Expected raw 64 KiB HTTP chunks to need more frames than raw 4 MiB chunks. legacy=%s optimized=%s" % [
			JSON.stringify(raw_legacy),
			JSON.stringify(raw_optimized),
		])
		return

	var lean: PackRatResult = await _packrat_case("packrat_lean_4m", OPTIMIZED_CHUNK_SIZE, false)
	if not lean.ok:
		return

	var profiled: PackRatResult = await _packrat_case("packrat_profiled_4m", OPTIMIZED_CHUNK_SIZE, true)
	if not profiled.ok:
		return

	var large: PackRatResult = await _packrat_case("packrat_profiled_10m", LARGE_CHUNK_SIZE, true)
	if not large.ok:
		return

	var requested_max: PackRatResult = await _packrat_case("packrat_profiled_20m_requested", REQUESTED_MAX_CHUNK_SIZE, true)
	if not requested_max.ok:
		return

	if int(requested_max.timings_msec.get("effective_download_chunk_size", 0)) != MAX_CHUNK_SIZE:
		_fail("Expected requested 20 MiB PackRat chunk size to clamp to 16 MiB. Result: %s" % JSON.stringify(requested_max.timings_msec))
		return

	var legacy: PackRatResult = await _packrat_case("packrat_profiled_64k", LEGACY_CHUNK_SIZE, true)
	if not legacy.ok:
		return

	var legacy_frames: int = int(legacy.timings_msec.get("download_http_progress_frames", 0))
	var optimized_frames: int = int(profiled.timings_msec.get("download_http_progress_frames", 0))
	if legacy_frames <= optimized_frames:
		_fail("Expected 64 KiB HTTP chunks to need more progress frames than 4 MiB chunks. legacy=%d optimized=%d" % [legacy_frames, optimized_frames])
		return

	var raw_total_msec: int = int(raw_optimized.get("total_msec", 0))
	var lean_total_msec: int = int(lean.timings_msec.get("external_total_msec", 0))
	if lean_total_msec > raw_total_msec + OVERHEAD_LIMIT_MSEC:
		_fail("Expected lean PackRat overhead to stay below %d ms. raw=%s packrat=%s" % [
			OVERHEAD_LIMIT_MSEC,
			JSON.stringify(raw_optimized),
			JSON.stringify(lean.timings_msec),
		])
		return

	await _finish_success("PackRat performance smoke passed. raw_64k=%s raw_4m=%s raw_10m=%s raw_16m=%s lean=%s profiled_4m=%s profiled_10m=%s profiled_20m=%s legacy=%s" % [
		JSON.stringify(raw_legacy),
		JSON.stringify(raw_optimized),
		JSON.stringify(raw_large),
		JSON.stringify(raw_max),
		JSON.stringify(lean.timings_msec),
		JSON.stringify(profiled.timings_msec),
		JSON.stringify(large.timings_msec),
		JSON.stringify(requested_max.timings_msec),
		JSON.stringify(legacy.timings_msec),
	])


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		_serve_peer(peer)


func _packrat_case(id: String, download_chunk_size: int, capture_timings: bool) -> PackRatResult:
	_build_pack(id)
	var options: PackRatOptions = PackRatOptions.new()
	options.id = id
	options.cache_dir = CACHE_DIR
	options.entry_path = _mounted_marker(id)
	options.expected_size = _pack_bytes.size()
	options.timeout_seconds = 30.0
	options.download_chunk_size = download_chunk_size
	options.capture_timings = capture_timings

	var progress_events: Array[int] = [0]
	var total_start_msec: int = Time.get_ticks_msec()
	var request: PackRatRequest = PackRat.load_resource_pack_async(_url, options)
	request.progress_changed.connect(func(_downloaded_bytes: int, _total_bytes: int) -> void:
		progress_events[0] += 1
	)
	await request.completed
	var external_total_msec: int = Time.get_ticks_msec() - total_start_msec
	var result: PackRatResult = request.result
	if result == null:
		_fail("Expected performance case %s to produce a result." % id)
		return PackRatResult.failed(_url, "Missing result.")

	if not capture_timings and not result.timings_msec.is_empty():
		_fail("Expected lean performance case %s to skip internal timings." % id)
		return result

	result.timings_msec["external_total_msec"] = external_total_msec
	result.timings_msec["signal_progress_events"] = progress_events[0]
	result.timings_msec["configured_download_chunk_size"] = download_chunk_size
	result.timings_msec["effective_download_chunk_size"] = clampi(download_chunk_size, PackRatOptions.MIN_DOWNLOAD_CHUNK_SIZE, MAX_CHUNK_SIZE)
	result.timings_msec["capture_timings"] = capture_timings
	if not result.ok:
		_fail("Expected performance case %s to load. Result: %s" % [id, JSON.stringify(result.to_dictionary())])
		return result

	if progress_events[0] <= 0:
		_fail("Expected performance case %s to emit progress_changed at least once." % id)
		return result

	if capture_timings:
		for key in [
			"download_msec",
			"download_http_progress_frames",
			"download_http_transfer_msec",
			"cache_finalize_msec",
			"mount_msec",
			"total_msec",
		]:
			if not result.timings_msec.has(key):
				_fail("Expected performance case %s timings to include %s. Result: %s" % [id, key, JSON.stringify(result.to_dictionary())])
				return result

	print("PackRat performance smoke %s timings %s" % [id, JSON.stringify(result.timings_msec)])
	return result


func _raw_case(id: String, download_chunk_size: int) -> Dictionary:
	_build_pack(id)
	var download_path: String = CACHE_DIR.path_join("%s.pck" % id)
	DirAccess.remove_absolute(download_path)

	var timings: Dictionary = {
		"configured_download_chunk_size": download_chunk_size,
		"raw_godot_api": true,
	}
	var total_start_msec: int = Time.get_ticks_msec()
	var request: HTTPRequest = HTTPRequest.new()
	request.accept_gzip = true
	request.download_file = download_path
	request.download_chunk_size = download_chunk_size
	request.timeout = 30.0
	add_child(request)

	var completed: Array = []
	request.request_completed.connect(func(result_code: HTTPRequest.Result, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.append(result_code)
		completed.append(response_code)
	, CONNECT_ONE_SHOT)

	var start_request_msec: int = Time.get_ticks_msec()
	var start_error: Error = request.request(_url)
	timings["request_start_msec"] = Time.get_ticks_msec() - start_request_msec
	if start_error != OK:
		request.queue_free()
		_fail("Raw case %s failed to start HTTPRequest (error %d)." % [id, start_error])
		return {}

	var transfer_start_msec: int = Time.get_ticks_msec()
	var progress_frames: int = 0
	while completed.is_empty():
		progress_frames += 1
		await get_tree().process_frame

	timings["http_transfer_msec"] = Time.get_ticks_msec() - transfer_start_msec
	timings["progress_frames"] = progress_frames
	request.queue_free()

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_fail("Raw case %s HTTP failed: result=%d response=%d." % [id, result_code, response_code])
		return timings

	var size_start_msec: int = Time.get_ticks_msec()
	var downloaded_size: int = FileAccess.get_size(download_path)
	timings["file_size_msec"] = Time.get_ticks_msec() - size_start_msec
	if downloaded_size != _pack_bytes.size():
		_fail("Raw case %s size mismatch: expected %d, got %d." % [id, _pack_bytes.size(), downloaded_size])
		return timings

	var mount_start_msec: int = Time.get_ticks_msec()
	var mounted: bool = ProjectSettings.load_resource_pack(download_path)
	timings["mount_msec"] = Time.get_ticks_msec() - mount_start_msec
	timings["total_msec"] = Time.get_ticks_msec() - total_start_msec
	timings["downloaded_size"] = downloaded_size
	if not mounted:
		_fail("Raw case %s failed ProjectSettings.load_resource_pack()." % id)
		return timings

	if not FileAccess.file_exists(_mounted_marker(id)):
		_fail("Raw case %s did not expose mounted marker %s." % [id, _mounted_marker(id)])
		return timings

	print("PackRat performance smoke %s timings %s" % [id, JSON.stringify(timings)])
	return timings


func _serve_peer(peer: StreamPeerTCP) -> void:
	_active_peers += 1
	var request: String = ""
	var wait_until: int = Time.get_ticks_msec() + 1000

	while Time.get_ticks_msec() < wait_until and request.find("\r\n\r\n") < 0:
		if peer.get_available_bytes() > 0:
			request += peer.get_utf8_string(peer.get_available_bytes())
		else:
			await get_tree().process_frame

	var method: String = request.get_slice(" ", 0)
	var path: String = request.get_slice(" ", 1).get_slice("?", 0)
	if path != "/perf.pck":
		_write_not_found(peer)
	elif method == "HEAD":
		_write_response(peer, false)
	elif method == "GET":
		await _write_response(peer, true)
	else:
		_write_not_found(peer)

	peer.disconnect_from_host()
	peer = null
	_active_peers -= 1


func _write_response(peer: StreamPeerTCP, include_body: bool) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "Content-Length: %d\r\n" % _pack_bytes.size()
		+ "ETag: \"packrat-performance-smoke\"\r\n"
		+ "Access-Control-Allow-Origin: *\r\n"
		+ "Access-Control-Expose-Headers: ETag, Content-Length\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())

	if not include_body:
		return

	var offset: int = 0
	while offset < _pack_bytes.size():
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return

		var chunk: PackedByteArray = _pack_bytes.slice(offset, mini(offset + SERVER_CHUNK_SIZE, _pack_bytes.size()))
		var write_result: Array = peer.put_partial_data(chunk)
		var error: Error = write_result[0]
		var written: int = int(write_result[1])
		if error != OK:
			return
		if written <= 0:
			await get_tree().process_frame
			continue

		offset += written
		await get_tree().process_frame


func _write_not_found(peer: StreamPeerTCP) -> void:
	var body: PackedByteArray = "not found".to_utf8_buffer()
	var headers: String = (
		"HTTP/1.1 404 Not Found\r\n"
		+ "Content-Length: %d\r\n" % body.size()
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())
	peer.put_data(body)


func _mounted_marker(id: String) -> String:
	return "res://pack_rat_performance_smoke/%s/marker.txt" % id


func _mounted_payload(id: String) -> String:
	return "res://pack_rat_performance_smoke/%s/payload.bin" % id


func _build_pack(id: String) -> void:
	var marker: FileAccess = FileAccess.open(MARKER_SOURCE_PATH, FileAccess.WRITE)
	if marker == null:
		_fail("Could not write performance marker source (error %d)." % FileAccess.get_open_error())
		return

	marker.store_string("performance-smoke-%s" % id)
	marker = null

	var payload: FileAccess = FileAccess.open(PAYLOAD_SOURCE_PATH, FileAccess.WRITE)
	if payload == null:
		_fail("Could not write performance payload source (error %d)." % FileAccess.get_open_error())
		return

	var block: PackedByteArray = PackedByteArray()
	block.resize(1024 * 1024)
	for index in range(block.size()):
		block[index] = (index * 31 + 17) & 0xff

	for _block_index in range(int(PAYLOAD_BYTES / block.size())):
		payload.store_buffer(block)
	payload = null

	var packer: PCKPacker = PCKPacker.new()
	var start_error: Error = packer.pck_start(PACK_PATH)
	if start_error != OK:
		_fail("Could not start performance PCK packer (error %d)." % start_error)
		return

	var add_error: Error = packer.add_file(_mounted_marker(id), MARKER_SOURCE_PATH)
	if add_error != OK:
		_fail("Could not add performance marker to PCK (error %d)." % add_error)
		return

	add_error = packer.add_file(_mounted_payload(id), PAYLOAD_SOURCE_PATH)
	if add_error != OK:
		_fail("Could not add performance payload to PCK (error %d)." % add_error)
		return

	var flush_error: Error = packer.flush()
	if flush_error != OK:
		_fail("Could not flush performance PCK (error %d)." % flush_error)
		return

	_pack_bytes = FileAccess.get_file_as_bytes(PACK_PATH)
	if _pack_bytes.is_empty():
		_fail("Performance PCK was empty.")


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
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		child = dir.get_next()

	dir.list_dir_end()


func _fail(message: String) -> void:
	_server.stop()
	push_error(message)
	get_tree().quit(1)


func _finish_success(message: String) -> void:
	set_process(false)
	var wait_until: int = Time.get_ticks_msec() + 3000
	while _active_peers > 0 and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	print(message)
	_server.stop()
	get_tree().quit()
