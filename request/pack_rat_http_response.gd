class_name PackRatHttpResponse extends RefCounted
## Internal HTTP result used by [PackRat] while loading a resource pack.

const _MONTHS: Dictionary = {
	"jan": 1,
	"feb": 2,
	"mar": 3,
	"apr": 4,
	"may": 5,
	"jun": 6,
	"jul": 7,
	"aug": 8,
	"sep": 9,
	"oct": 10,
	"nov": 11,
	"dec": 12,
}

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

## Comparable decoded byte size used for freshness when available.
var content_length: int = 0

## Raw HTTP Content-Length header. With gzip/deflate, this is transfer size.
var transfer_content_length: int = 0

## Remote Content-Encoding header, such as [code]gzip[/code] or [code]deflate[/code].
var content_encoding: String = ""

## Remote Content-Type header used only for extensionless cache filenames.
var content_type: String = ""

## Millisecond timings for the low-level HTTP request.
var timings_msec: Dictionary = {}


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
	var header_map: Dictionary = _header_map(headers)
	response.result_code = result
	response.response_code = code
	response.ok = result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	response.error = "HTTP request failed (result %d, response %d)." % [result, code]
	response.etag = str(header_map.get("etag", ""))
	response.last_modified = str(header_map.get("last-modified", ""))
	response.transfer_content_length = int(header_map.get("content-length", "0"))
	response.content_encoding = str(header_map.get("content-encoding", "")).to_lower()
	if not response.has_transfer_encoding() and response.transfer_content_length > 0:
		response.content_length = response.transfer_content_length
	response.content_type = str(header_map.get("content-type", ""))
	return response


## Parses an RFC 7231-style HTTP date into a Unix timestamp, or [code]0[/code] on failure.
static func parse_http_date_unix(value: String) -> int:
	var parts: PackedStringArray = value.strip_edges().split(" ", false)
	if parts.size() < 5:
		return 0

	var month: int = _month_number(parts[2])
	var time_parts: PackedStringArray = parts[4].split(":")
	if month <= 0 or time_parts.size() != 3:
		return 0

	return int(Time.get_unix_time_from_datetime_dict({
		"year": int(parts[3]),
		"month": month,
		"day": int(parts[1]),
		"hour": int(time_parts[0]),
		"minute": int(time_parts[1]),
		"second": int(time_parts[2]),
	}))


## Returns [code]true[/code] when at least one freshness field is available.
func has_freshness() -> bool:
	return not etag.is_empty() or not last_modified.is_empty() or content_length > 0


## Returns [code]true[/code] when the server sent compressed transfer bytes.
func has_transfer_encoding() -> bool:
	return content_encoding == "gzip" or content_encoding == "deflate"


## Merges response metadata from [param other], keeping existing freshness fallbacks.
func merge_from(other: PackRatHttpResponse) -> void:
	result_code = other.result_code
	response_code = other.response_code
	if not other.etag.is_empty():
		etag = other.etag
	if not other.last_modified.is_empty():
		last_modified = other.last_modified
	if not other.content_encoding.is_empty():
		content_encoding = other.content_encoding
	if other.transfer_content_length > 0:
		transfer_content_length = other.transfer_content_length
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


static func _header_map(headers: PackedStringArray) -> Dictionary:
	var output: Dictionary = {}
	for raw_header in headers:
		var header: String = str(raw_header)
		var separator: int = header.find(":")
		if separator <= 0:
			continue

		output[header.substr(0, separator).to_lower()] = header.substr(separator + 1).strip_edges()

	return output


static func _month_number(value: String) -> int:
	return int(_MONTHS.get(value.to_lower(), 0))
