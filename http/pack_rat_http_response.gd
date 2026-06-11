class_name PackRatHttpResponse
extends RefCounted

var result: int = HTTPRequest.RESULT_NO_RESPONSE
var response_code: int = 0
var headers: PackedStringArray = []
var body: PackedByteArray = []
var header_map: Dictionary = {}
var final_url: String = ""
var error: String = ""


func is_success() -> bool:
	return result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300


func get_header(name: String) -> String:
	return str(header_map.get(name.to_lower(), ""))


func get_content_length() -> int:
	var value := get_header("content-length")
	if value.is_valid_int():
		return int(value)
	return 0


func to_metadata() -> Dictionary:
	return {
		"final_url": final_url,
		"etag": get_header("etag"),
		"last_modified": get_header("last-modified"),
		"content_length": get_content_length(),
		"response_code": response_code,
	}


func parse_headers() -> void:
	header_map.clear()

	for raw_header in headers:
		var header := str(raw_header)
		var separator := header.find(":")
		if separator <= 0:
			continue

		var key := header.substr(0, separator).strip_edges().to_lower()
		var value := header.substr(separator + 1).strip_edges()
		header_map[key] = value
