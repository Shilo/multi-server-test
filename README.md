# PackRat MVP

PackRat is a tiny runtime helper for downloading, caching, and mounting Godot
PCK/ZIP packs.

```gdscript
var result := await PackRat.prepare("https://example.com/packs/hub.pck")
```

The MVP is intentionally small:

- `pack_rat.gd`: the static `PackRat.prepare()` API and hidden service node.
- `pack_rat_service.gd`: the runtime worker node that owns `HTTPRequest`.
- `pack_rat_options.gd`: a few optional knobs.
- `pack_rat_result.gd`: a structured result object.

No editor plugin, manifest, SHA sidecar, provider system, descriptor object, or
custom installer workflow is required.

## What It Does

- Sends `HEAD` when a cached file exists.
- Compares `ETag`, `Last-Modified`, then `Content-Length` when available.
- Downloads missing or stale packs to `user://pack_rat/tmp/*.part`.
- Moves successful downloads into `user://pack_rat/<id>/`.
- Stores cache metadata in `user://pack_rat/cache.json`.
- Mounts `.pck` and `.zip` files with `replace_files=false` by default.
- Returns `PackRatResult` instead of a bare boolean.

## What It Does Not Do Yet

- No SHA-256 or signature validation.
- No manifests/catalogs.
- No GitHub/provider integrations.
- No custom source resolver/cache/installer/validator classes.
- No cache eviction.
- No unload/reload solution for already mounted same-path resources.
- No progress or cancellation API.
- No concurrent request de-duplication.

HTTP metadata is useful for freshness, not authenticity. It answers "does this
look changed?" rather than "is this trusted content?"

## Options

```gdscript
var options := PackRatOptions.new()
options.id = "hub"
options.entry_path = "res://worlds/hub/main.tscn"

var result := await PackRat.prepare("https://example.com/packs/hub.pck", options)
if result.ok:
	var scene := load(result.entry_path)
```

## Smoke Tests

```powershell
godot --headless --path . "res://tests/pack_rat_component_smoke.tscn"
godot --headless --path . "res://tests/pack_rat_http_pck_smoke.tscn"
```
