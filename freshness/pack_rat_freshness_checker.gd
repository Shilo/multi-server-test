class_name PackRatFreshnessChecker
extends RefCounted


func check(
	owner: Node,
	descriptor: PackRatDescriptor,
	cache_store: PackRatCacheStore
) -> PackRatFreshnessDecision:
	var decision := PackRatFreshnessDecision.new()
	decision.reason = "PackRatFreshnessChecker.check() must be implemented by subclasses."
	return decision
