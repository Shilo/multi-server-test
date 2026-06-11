class_name PackRatSha256Validator
extends PackRatValidator


func validate(
	local_path: String,
	descriptor: PackRatDescriptor,
	metadata: Dictionary
) -> PackRatValidationResult:
	if descriptor.expected_sha256.is_empty():
		if descriptor.allow_unverified_remote:
			return PackRatValidationResult.new()

		return PackRatValidationResult.failed(
			"Remote content has no expected_sha256 and allow_unverified_remote is false."
		)

	var actual_sha256 := FileAccess.get_sha256(local_path).to_lower()
	if actual_sha256.is_empty():
		return PackRatValidationResult.failed("Could not compute SHA-256 for %s." % local_path)

	if actual_sha256 != descriptor.expected_sha256:
		return PackRatValidationResult.failed(
			"SHA-256 mismatch for %s: expected %s, got %s." %
			[local_path, descriptor.expected_sha256, actual_sha256]
		)

	var result := PackRatValidationResult.new()
	result.sha256 = actual_sha256
	return result
