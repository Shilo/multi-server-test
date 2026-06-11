class_name PackRatRequestRunner extends Node
## Internal scene-tree node that keeps a [PackRatRequest] coroutine alive.

var _request: PackRatRequest
var _flight_key: String = ""


## Starts the request on the next idle frame.
func start(request: PackRatRequest, flight_key: String) -> void:
	_request = request
	_flight_key = flight_key
	call_deferred("_run")


func _run() -> void:
	var result: PackRatResult = await PackRat._load_resource_pack(_request)
	PackRat._finish_resource_pack_request(_request, _flight_key, result)
	queue_free()
