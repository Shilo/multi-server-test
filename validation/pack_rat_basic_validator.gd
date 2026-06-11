class_name PackRatBasicValidator
extends PackRatValidator


func validate(
	local_path: String,
	descriptor: PackRatDescriptor,
	metadata: Dictionary
) -> PackRatValidationResult:
	if local_path.is_empty() or not FileAccess.file_exists(local_path):
		return PackRatValidationResult.failed("Downloaded file does not exist: %s." % local_path)

	var actual_size := FileAccess.get_size(local_path)
	if actual_size <= 0:
		return PackRatValidationResult.failed("Downloaded file is empty: %s." % local_path)

	if descriptor.expected_size > 0 and actual_size != descriptor.expected_size:
		return PackRatValidationResult.failed(
			"Downloaded file size mismatch for %s: expected %d bytes, got %d bytes." %
			[local_path, descriptor.expected_size, actual_size]
		)

	var result := PackRatValidationResult.new()
	if descriptor.expected_sha256.is_empty() and descriptor.allow_unverified_remote:
		result.add_warning(
			"PackRat verified download completion and size, but no SHA-256/signature was provided for cryptographic integrity."
		)
	return result
