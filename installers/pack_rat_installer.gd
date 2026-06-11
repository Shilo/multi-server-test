class_name PackRatInstaller
extends RefCounted


func install(descriptor: PackRatDescriptor, result: PackRatResult) -> PackRatResult:
	return PackRatResult.failed("PackRatInstaller.install() must be implemented by subclasses.", descriptor.source_url)
