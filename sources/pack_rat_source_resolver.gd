class_name PackRatSourceResolver
extends RefCounted


func resolve(source: Variant, options: PackRatOptions) -> PackRatDescriptor:
	return PackRatDescriptor.invalid("PackRatSourceResolver.resolve() must be implemented by subclasses.")
