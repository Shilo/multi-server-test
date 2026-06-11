class_name PackRatHttpSourceResolver
extends PackRatSourceResolver


func resolve(source: Variant, options: PackRatOptions) -> PackRatDescriptor:
	if options == null:
		options = PackRatOptions.new()

	if source is PackRatDescriptor:
		return source

	if source is Dictionary:
		return PackRatDescriptor.from_dictionary(source, options)

	if source is String:
		var url := str(source).strip_edges()
		if url.begins_with("http://") or url.begins_with("https://"):
			return PackRatDescriptor.from_url(url, options)

		return PackRatDescriptor.invalid(
			"PackRat v1 resolves direct HTTP(S) URLs. Pass a URL or subclass PackRatSourceResolver for ID/provider lookup."
		)

	return PackRatDescriptor.invalid("Unsupported PackRat source type: %s." % typeof(source))
