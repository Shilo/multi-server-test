class_name PackRatWebFetchResult extends RefCounted
## Result returned by [method PackRatWebFetch.download_file].

## Failure message used when the caller's cancel callback stops the request.
const ERROR_CANCELED: String = "Request canceled."

## [code]true[/code] when the request finished successfully with a 2xx response.
var ok: bool = false

## Failure text when [member ok] is [code]false[/code].
var error: String = ""

## HTTPRequest-compatible result code for callers that already handle Godot HTTP results.
var result_code: HTTPRequest.Result = HTTPRequest.RESULT_SUCCESS

## HTTP status code returned by the server.
var response_code: int = 0

## Response headers returned by the browser.
var headers: PackedStringArray = []

## Decoded bytes written to [member download_path].
var downloaded_bytes: int = 0

## Destination file path written by the request.
var download_path: String = ""

## Number of chunks written to [member download_path].
var write_chunks: int = 0

## Largest chunk written to [member download_path].
var write_max_chunk_size: int = 0

## Millisecond timings for the low-level fetch request.
var timings_msec: Dictionary = {}


## Creates a failed result with [param message].
static func failed(
	message: String,
	result: HTTPRequest.Result = HTTPRequest.RESULT_REQUEST_FAILED
) -> PackRatWebFetchResult:
	var fetch_result: PackRatWebFetchResult = PackRatWebFetchResult.new()
	fetch_result.error = message
	fetch_result.result_code = result
	return fetch_result
