class_name PackRatRequestRunner extends Node
## Internal scene-tree node that keeps a [PackRatRequest] coroutine alive.

var _request: PackRatRequest


## Starts the request on the next idle frame.
func start(request: PackRatRequest) -> void:
	_request = request
	_run.call_deferred()


func _run() -> void:
	var result: PackRatResult = await PackRatLoader.load(_request)
	_request._finish(result)
	queue_free()
