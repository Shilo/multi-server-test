extends Node

const CACHE_DIR: String = "user://pack_rat_http_zip_smoke_cache"
const SERVER_DIR: String = "user://pack_rat_http_zip_smoke_server"
const ZIP_PATH: String = "user://pack_rat_http_zip_smoke_server/hub.zip"
const MOUNTED_MARKER: String = "res://pack_rat_http_zip_smoke_marker.txt"

var _server: TCPServer = TCPServer.new()
var _zip_bytes: PackedByteArray = []
var _url: String = ""
var _head_count: int = 0
var _get_count: int = 0
var _etag: String = "\"packrat-zip-smoke-v1\""


func _new_options() -> PackRatOptions:
	var options: PackRatOptions = PackRatOptions.new()
	options.use_threads = false
	return options


func _ready() -> void:
	set_process(false)
	_clear_directory(CACHE_DIR)
	_clear_directory(SERVER_DIR)
	_make_directory(SERVER_DIR)
	_build_zip("mounted-from-packrat-zip")

	var listen_error: Error = _server.listen(0, "127.0.0.1")
	if listen_error != OK:
		_fail("Could not start local HTTP server (error %d)." % listen_error)
		return

	_url = "http://127.0.0.1:%d/hub.zip" % _server.get_local_port()
	set_process(true)
	await get_tree().process_frame

	var options: PackRatOptions = _new_options()
	options.id = "http_zip_smoke"
	options.cache_dir = CACHE_DIR
	options.entry_path = MOUNTED_MARKER
	options.timeout_seconds = 10.0

	var first: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not first.ok or not first.mounted or first.from_cache:
		_fail("Expected ZIP load to download and mount. Result: %s" % JSON.stringify(first.to_dictionary()))
		return

	if first.local_path.get_extension().to_lower() != "zip":
		_fail("Expected cached ZIP path to keep .zip extension, got %s." % first.local_path)
		return

	if FileAccess.get_file_as_string(MOUNTED_MARKER).strip_edges() != "mounted-from-packrat-zip":
		_fail("Mounted ZIP marker was not readable from res://.")
		return

	var second: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not second.ok or not second.from_cache or not second.mounted:
		_fail("Expected second ZIP load to mount from cache. Result: %s" % JSON.stringify(second.to_dictionary()))
		return

	if _get_count != 1:
		_fail("Expected ZIP to download once, got %d GET requests." % _get_count)
		return

	if _head_count != 1:
		_fail("Expected ZIP cache hit to check freshness once, got %d HEAD requests." % _head_count)
		return

	var offset_options: PackRatOptions = _new_options()
	offset_options.id = "http_zip_smoke"
	offset_options.cache_dir = CACHE_DIR
	offset_options.timeout_seconds = 10.0
	offset_options.offset = 1
	var offset_result: PackRatResult = await PackRat.load_resource_pack(_url, offset_options)
	if offset_result.ok:
		_fail("Expected ZIP load with nonzero offset to fail.")
		return

	print("PackRat HTTP ZIP smoke passed. HEAD=%d GET=%d cache=%s" % [_head_count, _get_count, second.local_path])
	_server.stop()
	get_tree().quit()


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		_serve_peer(peer)


func _serve_peer(peer: StreamPeerTCP) -> void:
	var request: String = ""
	var wait_until: int = Time.get_ticks_msec() + 1000

	while Time.get_ticks_msec() < wait_until and request.find("\r\n\r\n") < 0:
		if peer.get_available_bytes() > 0:
			request += peer.get_utf8_string(peer.get_available_bytes())
		else:
			await get_tree().process_frame

	var method: String = request.get_slice(" ", 0)
	var path: String = request.get_slice(" ", 1)
	if path != "/hub.zip":
		_write_not_found(peer)
	elif method == "HEAD":
		_head_count += 1
		_write_response(peer, false)
	elif method == "GET":
		_get_count += 1
		_write_response(peer, true)
	else:
		_write_not_found(peer)

	peer.disconnect_from_host()


func _write_response(peer: StreamPeerTCP, include_body: bool) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/zip\r\n"
		+ "Content-Length: %d\r\n" % _zip_bytes.size()
		+ "ETag: %s\r\n" % _etag
		+ "Access-Control-Allow-Origin: *\r\n"
		+ "Access-Control-Expose-Headers: ETag, Content-Length\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())

	if include_body:
		peer.put_data(_zip_bytes)


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


func _build_zip(marker: String) -> void:
	if FileAccess.file_exists(ZIP_PATH):
		DirAccess.remove_absolute(ZIP_PATH)

	var writer: ZIPPacker = ZIPPacker.new()
	var open_error: Error = writer.open(ZIP_PATH)
	if open_error != OK:
		_fail("Could not open ZIP writer (error %d)." % open_error)
		return

	var start_error: Error = writer.start_file(MOUNTED_MARKER.trim_prefix("res://"))
	if start_error != OK:
		_fail("Could not start ZIP marker file (error %d)." % start_error)
		return

	var write_error: Error = writer.write_file(marker.to_utf8_buffer())
	if write_error != OK:
		_fail("Could not write ZIP marker file (error %d)." % write_error)
		return

	var close_file_error: Error = writer.close_file()
	if close_file_error != OK:
		_fail("Could not close ZIP marker file (error %d)." % close_file_error)
		return

	var close_error: Error = writer.close()
	if close_error != OK:
		_fail("Could not close ZIP writer (error %d)." % close_error)
		return

	_zip_bytes = FileAccess.get_file_as_bytes(ZIP_PATH)
	if _zip_bytes.is_empty():
		_fail("Smoke ZIP was empty.")


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
