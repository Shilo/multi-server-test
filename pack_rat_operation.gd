class_name PackRatOperation
extends RefCounted

signal completed

var result: PackRatResult


func finish(value: PackRatResult) -> void:
	result = value
	completed.emit()
