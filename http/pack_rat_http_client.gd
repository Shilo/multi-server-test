class_name PackRatHttpClient
extends RefCounted


func request_metadata(
	owner: Node,
	url: String,
	headers: PackedStringArray,
	timeout_seconds: float,
	max_redirects: int
) -> PackRatHttpResponse:
	return await _request(owner, url, headers, HTTPClient.METHOD_HEAD, "", timeout_seconds, max_redirects)


func download(
	owner: Node,
	url: String,
	headers: PackedStringArray,
	download_path: String,
	timeout_seconds: float,
	max_redirects: int
) -> PackRatHttpResponse:
	return await _request(owner, url, headers, HTTPClient.METHOD_GET, download_path, timeout_seconds, max_redirects)


func _request(
	owner: Node,
	url: String,
	headers: PackedStringArray,
	method: int,
	download_path: String,
	timeout_seconds: float,
	max_redirects: int
) -> PackRatHttpResponse:
	var response := PackRatHttpResponse.new()
	response.final_url = url

	if owner == null or not is_instance_valid(owner):
		response.error = "HTTPRequest needs a live owner node."
		return response

	var request := HTTPRequest.new()
	request.accept_gzip = false
	request.download_file = download_path
	request.max_redirects = max_redirects
	request.timeout = timeout_seconds
	owner.add_child(request)

	var start_error := request.request(url, headers, method)
	if start_error != OK:
		response.result = start_error
		response.error = "HTTPRequest.request() failed to start with error %d." % start_error
		request.queue_free()
		return response

	var completed: Array = await request.request_completed
	response.result = int(completed[0])
	response.response_code = int(completed[1])
	response.headers = completed[2]
	response.body = completed[3]
	response.parse_headers()
	request.queue_free()
	return response
