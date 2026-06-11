class_name PackRatValidator
extends RefCounted


func validate(
	local_path: String,
	descriptor: PackRatDescriptor,
	metadata: Dictionary
) -> PackRatValidationResult:
	return PackRatValidationResult.failed("PackRatValidator.validate() must be implemented by subclasses.")
