class_name PackRatHttpResponse extends RefCounted
## Internal HTTP result used by [PackRat] while preparing a pack.

## [code]true[/code] when [HTTPRequest] finished successfully with a 2xx response.
var ok: bool = false

## Failure text when [member ok] is [code]false[/code].
var error: String = ""

## Result emitted by [signal HTTPRequest.request_completed].
var result_code: HTTPRequest.Result = HTTPRequest.RESULT_SUCCESS

## HTTP status code returned by the server.
var response_code: int = 0

## Remote ETag header used for freshness when available.
var etag: String = ""

## Remote Last-Modified header used for freshness when available.
var last_modified: String = ""

## Remote Content-Length header used for freshness when available.
var content_length: int = 0

## Remote Content-Type header used only for extensionless cache filenames.
var content_type: String = ""


## Creates a failed response with [param message].
static func failed(message: String) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = PackRatHttpResponse.new()
	response.error = message
	return response


## Creates a response from [signal HTTPRequest.request_completed] values.
static func from_completed(
	result: HTTPRequest.Result,
	code: int,
	headers: PackedStringArray
) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = PackRatHttpResponse.new()
	response.result_code = result
	response.response_code = code
	response.ok = result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	response.error = "HTTP request failed (result %d, response %d)." % [result, code]
	response.etag = _header_value(headers, "etag")
	response.last_modified = _header_value(headers, "last-modified")
	response.content_length = int(_header_value(headers, "content-length"))
	response.content_type = _header_value(headers, "content-type")
	return response


## Returns [code]true[/code] when at least one freshness field is available.
func has_freshness() -> bool:
	return not etag.is_empty() or not last_modified.is_empty() or content_length > 0


## Merges response metadata from [param other], keeping existing freshness fallbacks.
func merge_from(other: PackRatHttpResponse) -> void:
	result_code = other.result_code
	response_code = other.response_code
	if not other.etag.is_empty():
		etag = other.etag
	if not other.last_modified.is_empty():
		last_modified = other.last_modified
	if other.content_length > 0:
		content_length = other.content_length
	if not other.content_type.is_empty():
		content_type = other.content_type


## Copies this response's metadata into [param result].
func apply_to_result(result: PackRatResult) -> void:
	result.etag = etag
	result.last_modified = last_modified
	if content_length > 0:
		result.content_length = content_length
	result.response_code = response_code


static func _header_value(headers: PackedStringArray, name: String) -> String:
	var prefix: String = "%s:" % name.to_lower()
	for raw_header in headers:
		var header: String = str(raw_header)
		if header.to_lower().begins_with(prefix):
			return header.substr(prefix.length()).strip_edges()

	return ""
