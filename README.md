# PackRat

PackRat is a runtime-first Godot addon for downloadable PCK/ZIP content packs.
The happy path is intentionally small:

```gdscript
var result := await PackRat.prepare("https://example.com/packs/hub.pck")
```

PackRat downloads to `user://pack_rat`, keeps stable cache entries separate from
temporary `.part` files, freshness-checks cached content with HTTP metadata when
servers expose it, and mounts PCK/ZIP files with
`ProjectSettings.load_resource_pack(..., false)` by default.

No `EditorPlugin`, autoload, or project setting is required for runtime use.
`PackRat.prepare()` creates a `PackRatService` node under the scene tree root on
first use. Projects that want dependency injection can create their own service
node and call `PackRat.use_service(service)`.

## Options

```gdscript
var options := PackRatOptions.new()
options.id = "hub"
options.entry_path = "res://dlc/hub/main.tscn"
options.expected_sha256 = "..."

var result := await PackRat.prepare("https://example.com/packs/hub.pck", options)
```

Server-provided descriptors can go through the same one-call path or the explicit
descriptor helper:

```gdscript
var descriptor := PackRatDescriptor.from_dict(route["pack"])
var result := await PackRat.prepare_descriptor(descriptor)
```

Important defaults:

- `cache_dir = "user://pack_rat"`
- `replace_files = false`
- `.pck` and `.zip` URLs mount as resource packs
- unknown extensions download as cached files
- `allow_unverified_remote = true` for the one-URL development path

HTTP `ETag`, `Last-Modified`, and `Content-Length` support freshness decisions,
but they are not cryptographic integrity. Set `expected_sha256` or
`allow_unverified_remote = false` when PackRat should reject unverified remote
content.

Downloaded resource packs use versioned cache filenames. PackRat prefers the
expected SHA-256 when present; otherwise it derives a short token from exposed
HTTP freshness metadata or, as a last resort, the source URL. This avoids
overwriting a PCK file that Godot may already have mounted for the life of the
process.

Godot does not expose a public unload operation for resource packs. If a newer
pack contains the same internal `res://` paths as an already mounted pack,
`replace_files=false` keeps the original mapping active. PackRat still downloads
and caches the newer pack, but the game should restart or opt into
`replace_files=true` when same-path replacement is intentional.

## Extension Points

The public API stays simple, but the internals are subclassable:

- `PackRatSourceResolver`
- `PackRatFreshnessChecker`
- `PackRatCacheStore`
- `PackRatValidator`
- `PackRatInstaller`

Assign custom instances on `PackRatOptions` for one call, or configure a custom
`PackRatService` and pass it to `PackRat.use_service(service)`.

## Smoke Tests

```powershell
godot --headless --path . "res://tests/pack_rat_component_smoke.tscn"
godot --headless --path . "res://tests/pack_rat_http_pck_smoke.tscn"
```
