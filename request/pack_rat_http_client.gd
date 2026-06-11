class_name PackRatHttpClient extends RefCounted
## Internal HTTPRequest wrapper used by PackRat runtime requests.


## Reads remote freshness metadata with an HTTP HEAD request.
static func freshness_metadata(url: String, options: PackRatOptions, owner: PackRatRequest) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = await request(url, "", options, owner, HTTPClient.METHOD_HEAD)
	if not response.ok:
		return PackRatHttpResponse.new()

	return response


## Performs one temporary HTTP request and streams progress into [param owner].
static func request(
	url: String,
	download_path: String,
	options: PackRatOptions,
	owner: PackRatRequest,
	method: HTTPClient.Method = HTTPClient.METHOD_GET
) -> PackRatHttpResponse:
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		return PackRatHttpResponse.failed("HTTPRequest needs a running SceneTree.")

	var http_request: HTTPRequest = HTTPRequest.new()
	http_request.accept_gzip = false
	http_request.download_file = download_path
	http_request.max_redirects = options.max_redirects
	http_request.timeout = options.timeout_seconds
	if tree.root.is_node_ready():
		tree.root.add_child(http_request)
	else:
		tree.root.add_child.call_deferred(http_request)
		await tree.process_frame

	if not http_request.is_inside_tree():
		http_request.queue_free()
		return PackRatHttpResponse.failed("HTTPRequest could not enter the scene tree.")

	owner._set_http_request(http_request)
	var start_error: Error = http_request.request(url, options.request_headers, method)
	if start_error != OK:
		owner._set_http_request(null)
		http_request.queue_free()
		return PackRatHttpResponse.failed("HTTPRequest failed to start (error %d)." % start_error)

	var completed: Array = []
	http_request.request_completed.connect(func(result_code: HTTPRequest.Result, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.append(result_code)
		completed.append(response_code)
		completed.append(headers)
	, CONNECT_ONE_SHOT)

	while completed.is_empty():
		if owner.is_canceled():
			http_request.cancel_request()
			owner._set_http_request(null)
			http_request.queue_free()
			return PackRatHttpResponse.failed(PackRatResult.ERROR_CANCELED)

		if not download_path.is_empty():
			var total_bytes: int = http_request.get_body_size()
			if total_bytes <= 0 and options.has_expected_size():
				total_bytes = options.expected_size
			owner._set_progress(http_request.get_downloaded_bytes(), total_bytes)
		await tree.process_frame

	owner._set_http_request(null)
	http_request.queue_free()

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	var headers: PackedStringArray = completed[2]

	return PackRatHttpResponse.from_completed(result_code, response_code, headers)
