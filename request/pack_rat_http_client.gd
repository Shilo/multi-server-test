class_name PackRatHttpClient extends RefCounted
## Internal HTTPRequest wrapper used by PackRat runtime requests.


## Reads remote freshness metadata with an HTTP HEAD request.
static func freshness_metadata(url: String, options: PackRatOptions, owner: PackRatRequest) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = await request(url, "", options, owner, HTTPClient.METHOD_HEAD)
	if not response.ok:
		var empty_response: PackRatHttpResponse = PackRatHttpResponse.new()
		empty_response.timings_msec = response.timings_msec
		return empty_response

	return response


## Performs one temporary HTTP request and streams progress into [param owner].
static func request(
	url: String,
	download_path: String,
	options: PackRatOptions,
	owner: PackRatRequest,
	method: HTTPClient.Method = HTTPClient.METHOD_GET
) -> PackRatHttpResponse:
	if (
		options.use_web_fetch
		and method == HTTPClient.METHOD_GET
		and not download_path.is_empty()
		and PackRatWebFetchClient.is_available()
	):
		return await PackRatWebFetchClient.download(url, download_path, options, owner)

	var capture_timings: bool = options.capture_timings
	var total_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var timings_msec: Dictionary = {}
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		return _finish_timing(PackRatHttpResponse.failed("HTTPRequest needs a running SceneTree."), timings_msec, total_start_msec, capture_timings)

	var setup_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var http_request: HTTPRequest = HTTPRequest.new()
	http_request.accept_gzip = false
	http_request.download_file = download_path
	http_request.download_chunk_size = clampi(options.download_chunk_size, 256, 16 * 1024 * 1024)
	http_request.max_redirects = options.max_redirects
	http_request.timeout = options.timeout_seconds
	_record_timing(timings_msec, capture_timings, "http_setup_msec", setup_start_msec)

	var add_node_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	if tree.root.is_node_ready():
		tree.root.add_child(http_request)
	else:
		tree.root.add_child.call_deferred(http_request)
		await tree.process_frame
	_record_timing(timings_msec, capture_timings, "http_add_node_msec", add_node_start_msec)

	if not http_request.is_inside_tree():
		http_request.queue_free()
		return _finish_timing(PackRatHttpResponse.failed("HTTPRequest could not enter the scene tree."), timings_msec, total_start_msec, capture_timings)

	owner._set_http_request(http_request)
	var start_request_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var start_error: Error = http_request.request(url, options.request_headers, method)
	_record_timing(timings_msec, capture_timings, "http_start_msec", start_request_msec)
	if start_error != OK:
		owner._set_http_request(null)
		http_request.queue_free()
		return _finish_timing(PackRatHttpResponse.failed("HTTPRequest failed to start (error %d)." % start_error), timings_msec, total_start_msec, capture_timings)

	var completed: Array = []
	http_request.request_completed.connect(func(result_code: HTTPRequest.Result, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.append(result_code)
		completed.append(response_code)
		completed.append(headers)
	, CONNECT_ONE_SHOT)

	var transfer_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var progress_frames: int = 0
	while completed.is_empty():
		if owner.is_canceled():
			http_request.cancel_request()
			owner._set_http_request(null)
			http_request.queue_free()
			if capture_timings:
				timings_msec["http_progress_frames"] = progress_frames
			_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
			return _finish_timing(PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED), timings_msec, total_start_msec, capture_timings)

		if not download_path.is_empty():
			if capture_timings:
				progress_frames += 1
			var total_bytes: int = http_request.get_body_size()
			if total_bytes <= 0 and options.has_expected_size():
				total_bytes = options.expected_size
			owner._set_progress(http_request.get_downloaded_bytes(), total_bytes)
		await tree.process_frame

	if capture_timings:
		timings_msec["http_progress_frames"] = progress_frames
	_record_timing(timings_msec, capture_timings, "http_transfer_msec", transfer_start_msec)
	var cleanup_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	owner._set_http_request(null)
	http_request.queue_free()
	_record_timing(timings_msec, capture_timings, "http_cleanup_msec", cleanup_start_msec)

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	var headers: PackedStringArray = completed[2]

	return _finish_timing(PackRatHttpResponse.from_completed(result_code, response_code, headers), timings_msec, total_start_msec, capture_timings)


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
