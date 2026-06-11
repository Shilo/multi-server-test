class_name PackRatResourcePackInstaller
extends PackRatInstaller


func install(descriptor: PackRatDescriptor, result: PackRatResult) -> PackRatResult:
	var mounted := ProjectSettings.load_resource_pack(result.local_path, descriptor.replace_files)
	if not mounted:
		return PackRatResult.failed("Godot could not mount resource pack %s." % result.local_path, descriptor.source_url)

	result.ok = true
	result.mounted = true
	result.status = PackRatResult.STATUS_MOUNTED if result.status.is_empty() else result.status
	return result
