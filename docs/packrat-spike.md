# PackRat Runtime DLC Addon Spike

Date: 2026-06-10

> Historical spike note: this document captures early design exploration and
> intentionally includes ideas rejected for the MVP, such as required SHA
> validation, install/freshness enums, and in-flight request de-dupe. Treat
> `README.md` and the live `addons/pack_rat/` API as the current product
> contract.

PackRat is a lightweight Godot addon for runtime downloadable content packs.
Its first job is to make the common case feel almost boring:

```gdscript
var result := await PackRat.load_resource_pack("https://example.com/packs/hub.pck")
if result.ok:
	var scene := load("res://server/worlds/hub/hub.tscn")
```

The addon should fetch, cache, freshness-check, mount, and report. The game
still decides what resource, scene, world, skin, mod, or data file to load after
the pack is ready.

## Design Bias

Prioritize the high-level API above everything else.

Earlier DLC research leaned toward manifests, sidecar hashes, and explicit pack
metadata. Those are still useful later, but PackRat's first public revision
should optimize for a user who only has a remote PCK URL and wants the pack to
be available.

The first version should avoid:

- mandatory manifests;
- mandatory `.sha256` sidecar files;
- giant dictionaries at call sites;
- requiring an enabled editor plugin;
- world-specific naming;
- forcing users to understand cache paths or temporary download paths.

The first version should provide:

- one-call URL mode;
- typed options for the few knobs that matter;
- automatic cache keys from URL/final URL;
- dynamic freshness checks from HTTP metadata when available;
- resource-pack mounting through `ProjectSettings.load_resource_pack()`;
- a structured result object;
- clear logs for download, cache hit, stale cache, mount, and failure.

## Recommended MVP API

### One URL

This is the main API. It should work without any project setup beyond adding the
addon scripts:

```gdscript
var result := await PackRat.load_resource_pack("https://cdn.example.com/world_packs/hub.pck")
```

Default behavior:

- infer `id` from filename: `hub`;
- infer install mode from extension: `.pck` and `.zip` mean resource pack;
- cache under `user://pack_rat`;
- check the remote URL with `HEAD` when possible;
- compare `ETag`, `Last-Modified`, and `Content-Length` against the cache
  record;
- download only when missing or stale;
- download to `.part`, then move into stable cache;
- mount with `replace_files=false`;
- return `PackRatResult`.

### Typed Options

Options should be a class, not a raw dictionary. A dictionary can be supported
later as a convenience adapter, but the documented API should teach a typed
surface.

```gdscript
var options := PackRatOptions.new()
options.id = "hub"
options.entry_path = "res://server/worlds/hub/hub.tscn"

var result := await PackRat.load_resource_pack("https://cdn.example.com/world_packs/hub.pck", options)
if result.ok:
	var scene := load(result.entry_path)
```

Possible `PackRatOptions` shape:

```gdscript
class_name PackRatOptions
extends RefCounted

enum InstallMode {
	AUTO,
	RESOURCE_PACK,
	FILE
}

enum FreshnessMode {
	AUTO,
	ALWAYS_CHECK,
	CACHE_FIRST,
	ALWAYS_DOWNLOAD
}

var id := ""
var cache_key := ""
var cache_dir := "user://pack_rat"
var install_mode := InstallMode.AUTO
var freshness_mode := FreshnessMode.AUTO
var replace_files := false
var entry_path := ""
var expected_sha256 := ""
var expected_size := 0
var request_headers: PackedStringArray = []
var timeout_seconds := 0.0
var allow_unverified_remote := true
```

`allow_unverified_remote` is intentionally permissive for the first revision
because the one-URL API is the main product promise. It should be loud in logs:
PackRat can confirm freshness and mountability without a hash, but it cannot
prove cryptographic integrity without a hash, signature, or trusted provider
digest.

### Server Payloads

Server-driven games should keep PackRat's public surface as URL plus options.
The game can read whatever route/catalog payload it wants, then copy only the
needed fields into [PackRatOptions].

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.id = route["pack"]["id"]
options.entry_path = route["pack"]["entry_path"]
options.expected_size = route["pack"].get("size", 0)
options.expected_modified_time = route["pack"].get("modified_time", 0)

var result := await PackRat.load_resource_pack(route["pack"]["url"], options)
```

Do not add descriptor objects or dictionary adapters until a real caller proves
that URL plus options is too clumsy.

## Freshness Without Extra Files

The user preference is no manifest and no required sidecar file. PackRat should
therefore use HTTP metadata first.

Default check:

1. Send `HEAD` to the remote URL.
2. Follow redirects and store the final URL.
3. Read cache validators when exposed:
   - `ETag`;
   - `Last-Modified`;
   - `Content-Length`.
4. Compare those values against `user://pack_rat/cache.json`.
5. If the cached local file exists and validators match, mount from cache.
6. If validators changed, are missing, or `HEAD` fails, download according to
   the freshness mode.

Cache record:

```json
{
  "schema": 1,
  "items": {
    "hub": {
      "source_url": "https://cdn.example.com/world_packs/hub.pck",
      "final_url": "https://cdn.example.com/world_packs/hub.pck",
      "etag": "\"abc123\"",
      "last_modified": "Wed, 10 Jun 2026 20:15:00 GMT",
      "content_length": 14528,
      "local_path": "user://pack_rat/hub/hub.pck",
      "mounted": false,
      "updated_at_unix": 1781122500
    }
  }
}
```

Important constraint: HTTP metadata is not the same as integrity validation.
It is good enough for "do I need to redownload?" when using trusted static
hosting. It is not enough for "is this exact file authentic?" PackRat should
keep that distinction clear in docs and logs without making the first API
annoying.

## Download And Cache Contract

Even the simple URL path must not corrupt the stable cache.

Flow:

```text
resolve source
check cache record
HEAD remote when possible
decide cached vs stale
download -> user://pack_rat/tmp/<cache_key>.part
basic validation -> HTTP 2xx, non-empty file, optional size/hash
move -> user://pack_rat/<id>/<filename-or-version>.pck
update cache.json
mount
return result
```

Rules:

- Never download directly over the stable cached file.
- Delete `.part` files after failed downloads or failed validation.
- If the new download fails, keep the old cache entry untouched.
- Deduplicate concurrent `load_resource_pack()` calls for the same cache key.
- Treat `replace_files=false` as the default.
- If `replace_files=true`, result/logs should make that obvious.

## Result Object

Use a result object, not a boolean.

```gdscript
class_name PackRatResult
extends RefCounted

var ok := false
var id := ""
var status := "" # cached, downloaded, mounted, failed
var from_cache := false
var mounted := false
var source_url := ""
var final_url := ""
var local_path := ""
var entry_path := ""
var etag := ""
var last_modified := ""
var content_length := 0
var sha256 := ""
var response_code := 0
var error := ""
```

The first version should make these statuses easy to assert in tests:

```text
downloaded
cache_hit
mounted
stale
failed
```

## Runtime Architecture

PackRat should be runtime-first. It should not require enabling an editor
plugin.

Suggested runtime layout:

```text
addons/pack_rat/
  pack_rat.gd              # class_name PackRat, static facade
  core/
    pack_rat_options.gd    # typed options
    pack_rat_result.gd     # result object
    pack_rat_request.gd    # progress/cancel/completed request handle
  cache/
    pack_rat_cache.gd
    pack_rat_cache_files.gd
    pack_rat_cache_paths.gd
    pack_rat_cache_record.gd
  request/
    pack_rat_http_client.gd
    pack_rat_http_response.gd
    pack_rat_request_runner.gd
  resource_pack/
    pack_rat_loader.gd
    pack_rat_mount_registry.gd
  filesystem/
    pack_rat_file_metadata.gd
```

The static facade should not require a service node or autoload:

```gdscript
class_name PackRat extends RefCounted

static func load_resource_pack(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	var request: PackRatRequest = load_resource_pack_async(url, options)
	await request.completed
	return request.result
```

Progress and cancellation use [PackRatRequest] from
[method PackRat.load_resource_pack_async], without making users install an
autoload.

## Web Export Constraints

PackRat exists partly because Web exports should not ship every mini-game or
large content pack up front. The first implementation should be browser-tested
early.

Risks:

- `HEAD` may be blocked or incomplete depending on CORS.
- `ETag` is not readable in browser contexts unless the server exposes it.
- `Last-Modified` and `Content-Length` are easier, but still host-dependent.
- GitHub Releases may redirect through URLs that are awkward for browser CORS.
- `user://` persistence maps to browser storage and can be cleared by the user.

Recommended first Web test:

```text
same-origin Web client + same-origin /packs/hub.pck
PackRat.load_resource_pack(url)
download -> mount -> load scene
refresh browser
PackRat.load_resource_pack(url)
cache hit -> mount -> load scene
replace remote pck
freshness check sees stale -> redownload
```

Do not freeze GitHub Releases or provider-specific APIs until that browser test
passes.

## Hosting Guidance

The simplest recommended host is plain static HTTP:

```text
https://example.com/packs/hub.pck
```

Useful headers:

```text
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: ETag, Content-Length, Last-Modified
Cache-Control: no-cache
Content-Type: application/octet-stream
```

For immutable files:

```text
https://example.com/packs/hub-39882095cc2b.pck
Cache-Control: public, max-age=31536000, immutable
```

GitHub Pages can be treated as plain HTTP for small public demos. GitHub
Releases should wait until browser redirect/CORS behavior is tested.

## MVP Scope

Build first:

- `PackRat.load_resource_pack(url: String, options: PackRatOptions = null)`;
- typed `PackRatOptions`;
- typed `PackRatResult`;
- `user://pack_rat/cache.json`;
- `HEAD` freshness check when possible;
- `HTTPRequest.download_file` to `.part`;
- PCK/ZIP mounting through `ProjectSettings.load_resource_pack()`;
- file mode only if it falls out naturally;
- in-flight dedupe per cache key;
- logs for download/cache hit/stale/mount/failure;
- minimal demo scene that calls `PackRat.load_resource_pack(url)`.

Defer:

- required manifests;
- GitHub Releases provider;
- GitHub API integration;
- ZIP extraction;
- dependency graphs;
- cache eviction policy;
- editor plugin UI;
- signing/encryption;
- automatic PCK export tooling.

## Open Questions

- Should the default no-hash mode be named `allow_unverified_remote=true`, or
  should that warning live only in docs/logs?
- Should `PackRat.load_resource_pack(url)` always send `HEAD`, or should it use
  cache-first with a max-age option to avoid one request per launch?
- Should `PackRatOptions` use plain properties only, or also builder helpers
  such as `PackRatOptions.resource_pack("hub")`?
- How much of `ETag`/`Last-Modified` can Godot Web builds actually read through
  `HTTPRequest` on the intended hosts?
- What should happen if a newer pack is downloaded after an older pack with the
  same internal `res://` paths is already mounted? For v1, document that mounted
  packs are process-lifetime and updates may require restart.

## Reference Material

- `docs/reference/universal-dlc-addon-spike.md`
- `docs/reference/dynamic-world-pck-streaming-research.md`
- `docs/reference/packrat-addon-branding-research.md`
