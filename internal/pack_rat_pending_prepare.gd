class_name PackRatPendingPrepare extends RefCounted
## Internal pending prepare result used to de-dupe concurrent requests.

## Emitted when the shared prepare call finishes.
signal completed(result: PackRatResult)

## Result produced by the shared prepare call.
var result: PackRatResult


## Stores [param value] and wakes callers waiting on [signal completed].
func finish(value: PackRatResult) -> void:
	result = value
	completed.emit(result)
