class_name PackRatRequestRunner extends Node
## Internal scene-tree node that keeps a [PackRatRequest] coroutine alive.

var _request: PackRatRequest


## Starts the request on the next idle frame.
func start(request: PackRatRequest) -> void:
	_request = request
	call_deferred("_run")


func _run() -> void:
	var result: PackRatResult = await PackRat._load_resource_pack(_request)
	PackRat._finish_resource_pack_request(_request, result)
	queue_free()
