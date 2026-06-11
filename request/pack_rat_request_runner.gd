class_name PackRatRequestRunner extends Node
## Internal scene-tree node that keeps a [PackRatRequest] coroutine alive.

var _request: PackRatRequest


## Starts the request and frees this runner when it finishes.
func start(request: PackRatRequest) -> void:
	_request = request
	_run()


func _run() -> void:
	if _request == null:
		queue_free()
		return

	var request: PackRatRequest = _request
	var result: PackRatResult = await PackRatLoader.load(request)
	request._finish(result)
	_request = null
	queue_free()
