class_name PackRatFileInstaller
extends PackRatInstaller


func install(descriptor: PackRatDescriptor, result: PackRatResult) -> PackRatResult:
	result.ok = true
	result.mounted = false
	return result
