# Universal DLC Addon Spike

Date: 2026-06-10

This spike explores a reusable Godot addon for downloadable content. The goal is
not a world-pack system, a multiplayer transfer system, or a VirtuCade-specific
manifest format. The target is a small runtime library that can make any
downloadable content item available from cache or network, then let game code
load resources from that content.

The motivating call shape is:

```gdscript
var content := await DLC.prepare("hub")
if content.ok:
	var scene := load("res://server/worlds/hub/hub.tscn")
```

The API should not use `ensure_*` naming. The word is too vague for a public
surface because it hides which work may happen: cache lookup, freshness check,
download, validation, install, pack mount, or resource verification.

## Recommendation

Build the addon as a runtime-first library under `res://addons/godot_dlc/`.
Do not require it to be enabled as an editor plugin.

Godot editor plugins are for editor integration. The docs describe plugins as a
way to extend the editor, and the editor identifies them through `plugin.cfg`
plus a tool script under `addons/plugin_name`. Runtime scripts in an `addons/`
folder can still be referenced by normal `preload()`, `load()`, autoload, or
scene references without enabling a plugin.

The addon should expose:

- A static facade, probably `class_name DLC`, for simple calls.
- A hidden or autoloadable `DLCService` node for `HTTPRequest`, queues, progress,
  cancellation, and test injection.
- Optional editor tooling later for autoload registration, config editing, pack
  export, and upload scripts.

The high-level method should be:

```gdscript
var result := await DLC.prepare("content_id")
```

`prepare()` means: resolve source, check cache, check freshness when possible,
download when stale or missing, validate, install or mount, and return a result
that tells the caller what happened. It does not mean "load the scene" because a
generic DLC addon should not know whether the caller wants a scene, texture,
script, audio bank, mod descriptor, or data file.

Use `replace_files=false` by default when mounting resource packs. Godot's
default replacement behavior is powerful for patches, but risky for a universal
DLC/mod addon. A content pack should normally live under a project-owned
namespace such as `res://dlc/<publisher>/<id>/...`, or under any explicit project
path the host app chooses.

For this project specifically, `res://server/worlds/` is still fine. The
`server/`, `client/`, and `shared/` folders are export-bundle ownership labels.
That concern ends at what gets bundled into each executable or artifact. At
runtime, a downloaded pack can mount resources at `res://server/worlds/hub/...`
because that path is not user-facing. A universal addon should not dictate that
folder policy.

## Why A Plugin Is Not Required

A required editor plugin would add friction for the base runtime use case. The
lowest-friction install should be:

```gdscript
const DLC := preload("res://addons/godot_dlc/dlc.gd")

func _ready() -> void:
	DLC.configure(preload("res://dlc_config.tres"))
	var content := await DLC.prepare("hub")
```

or, if the addon uses `class_name DLC`, simply:

```gdscript
func _ready() -> void:
	var content := await DLC.prepare("hub")
```

GDScript supports static functions for helper libraries. The caveat is that
network downloads need nodes: `HTTPRequest` is a `Node`, and Godot's docs warn
not to run simultaneous requests through a single `HTTPRequest` node. A pure
static implementation would quickly become awkward.

The practical compromise is:

```gdscript
class_name DLC
extends RefCounted

static var _service: DLCService

static func prepare(content: Variant, options: Dictionary = {}) -> DLCResult:
	var service := _get_or_create_service()
	return await service.prepare(content, options)
```

`_get_or_create_service()` can attach one internal service node to the current
`SceneTree` root on first use. Projects that prefer explicit setup can add the
service as an autoload or call `DLC.use_service(custom_service)`.

An optional editor plugin is still useful later, but only as sugar:

- Register `DLCService` as an autoload.
- Add project settings under `addons/godot_dlc/*`.
- Provide an editor UI for content item definitions.
- Export selected folders to PCK files.
- Generate `.sha256` sidecars.
- Upload to GitHub Releases, GitHub Pages, or a VPS folder.

That plugin should not be required by exported clients.

## High-Level API Shape

The addon should optimize for one obvious call and a few explicit lower-level
calls.

Recommended primary API:

```gdscript
var result := await DLC.prepare("hub")
```

Recommended direct URL API:

```gdscript
var result := await DLC.prepare("https://example.com/dlc/hub.pck", {
	"sha256_url": "https://example.com/dlc/hub.pck.sha256",
	"cache_key": "hub",
	"install": "resource_pack",
	"replace_files": false,
})
```

Recommended configured item API:

```gdscript
DLC.configure({
	"cache_dir": "user://dlc",
	"items": {
		"hub": {
			"url": "https://example.com/dlc/hub.pck",
			"sha256_url": "https://example.com/dlc/hub.pck.sha256",
			"install": "resource_pack",
			"replace_files": false,
			"mount_prefix": "res://server/worlds/hub",
			"entry": "res://server/worlds/hub/hub.tscn"
		}
	}
})

var result := await DLC.prepare("hub")
if result.ok:
	var scene := load(result.entry_path)
```

Minimal lower-level calls:

```gdscript
var status := await DLC.check("hub")
var file := await DLC.download("hub")
var mounted := DLC.mount("hub")
DLC.clear_cache("hub")
```

Do not make callers pass large metadata dictionaries to the primary method.
Prefer a configured registry of content items, plus small options only for
direct URL use and overrides.

## Result Object

Return a structured result instead of `bool`. A boolean forces the caller to ask
more questions immediately.

```gdscript
class_name DLCResult
extends RefCounted

var ok: bool
var id: StringName
var status: StringName # ready, cached, downloaded, mounted, failed
var from_cache: bool
var local_path: String
var source_url: String
var final_url: String
var version_token: String
var sha256: String
var size: int
var mounted: bool
var entry_path: String
var mount_prefix: String
var error: String
var response_code: int

func resource(relative_path: String) -> String:
	return mount_prefix.path_join(relative_path)
```

The object should report what happened, but not expose raw GitHub API payloads or
force application code to understand the cache database.

## No-Manifest Server Mode

A server manifest is not required for the basic case. The server can host plain
files:

```text
hub.pck
hub.pck.sha256
arena.pck
arena.pck.sha256
```

The client config maps content IDs to URLs:

```gdscript
"hub": {
	"url": "https://cdn.example.com/dlc/hub.pck",
	"sha256_url": "https://cdn.example.com/dlc/hub.pck.sha256",
	"entry": "res://server/worlds/hub/hub.tscn"
}
```

At runtime:

1. Fetch `hub.pck.sha256`.
2. Compare it to the cached hash in `user://dlc/cache.json`.
3. If the hash changed or no cached file exists, download `hub.pck` to a temp
   path.
4. Compute `FileAccess.get_sha256(temp_path)`.
5. Rename to a content-addressed cache path, such as
   `user://dlc/hub/<sha256>.pck`.
6. Mount the local PCK with `ProjectSettings.load_resource_pack()`.
7. Return a `DLCResult`.

This is the best default because it is server-agnostic, CDN-friendly, and
requires only one tiny sidecar file. The sidecar is not a manifest; it is just an
integrity and freshness token.

If even the sidecar is undesired, the addon can use `HEAD` response metadata
such as `ETag`, `Last-Modified`, and `Content-Length`. That is acceptable for
local testing or trusted static hosting, but weaker:

- `Content-Length` is a sanity check, not a version identity.
- `Last-Modified` can be imprecise.
- `ETag` is opaque, sometimes weak, and in browser exports is only readable when
  CORS exposes it.
- A changed remote PCK cannot be proven valid without either downloading it or
  fetching a trusted hash from somewhere.

Comparing "cached PCK metadata" to "remote PCK metadata" only works if the host
exposes useful metadata over HTTP or a provider API. A remote PCK does not expose
its internal pack metadata to the client until the client downloads it.

## When A Manifest Is Worth It

A manifest becomes useful when the app needs discovery rather than lookup.

Use no server manifest when:

- The game already knows all content IDs it may request.
- Each content item has a known URL or URL template.
- Freshness comes from versioned URLs, `.sha256` sidecars, or HTTP validators.
- The server is just static hosting.

Use a small manifest when:

- The server controls the active catalog.
- New content should appear without a base client update.
- The server needs feature flags, compatibility ranges, channels, or rollbacks.
- Multiple related files must be installed together.
- The client needs a title, description, entry path, dependencies, or minimum app
  version from the server.

Minimal manifest shape:

```json
{
  "schema": 1,
  "items": {
    "hub": {
      "url": "hub.pck",
      "sha256": "39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186",
      "size": 14528,
      "entry": "res://server/worlds/hub/hub.tscn"
    }
  }
}
```

The addon should support this, but not require it.

## Hosting Providers

### Plain HTTP Or VPS

This should be the reference provider. It works for local testing and production:

```text
https://game.example.com/dlc/hub.pck
https://game.example.com/dlc/hub.pck.sha256
```

Recommended headers:

```text
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: ETag, Content-Length, Last-Modified
Cache-Control: no-cache                  # for .sha256 or catalog files
Cache-Control: public, max-age=31536000  # for hash-named PCKs
Content-Type: application/octet-stream   # for .pck
```

For local development, the addon should work with URLs like:

```text
http://127.0.0.1:19100/dlc/hub.pck
```

### GitHub Pages

GitHub Pages is a good no-server static host for public test content, small
catalogs, and sidecars. It is less attractive for high-volume production DLC
because GitHub Pages has published site size and soft bandwidth limits.

Good layout:

```text
https://owner.github.io/repo/dlc/hub.pck
https://owner.github.io/repo/dlc/hub.pck.sha256
```

For Web exports, this is probably the easiest GitHub option because it behaves
like static hosting. The addon should still treat it as plain HTTP and should
not need a GitHub-specific code path.

### GitHub Releases

GitHub Releases can host public PCK assets without a custom server. A direct
latest-release asset URL can be:

```text
https://github.com/owner/repo/releases/latest/download/hub.pck
```

The GitHub Release Assets API also returns metadata such as
`browser_download_url`, `size`, `updated_at`, and `digest` for release assets.
That API response can replace a custom manifest for public release assets.

Recommended addon provider:

```gdscript
var result := await DLC.prepare({
	"provider": "github_release",
	"owner": "owner",
	"repo": "repo",
	"asset": "hub.pck",
	"tag": "latest"
})
```

Provider behavior:

1. Request latest release or a specific tag.
2. Find the asset by exact name or pattern.
3. Use `digest` as the hash when present.
4. Use `browser_download_url` for browser downloads.
5. Handle `200` and `302` if using the release asset API download endpoint.

Risk: browser exports are subject to CORS and redirect behavior. This needs a
real Web export test before relying on GitHub Releases for production downloads.

### GitHub Repository Raw Files

Raw repository URLs are okay for small public files, pinned commits, demos, and
sidecars. They are a poor primary home for large PCKs.

The GitHub Contents API has size constraints and warns that download URLs expire
and should be freshly obtained. It is better as a provider for small config or
hash files than for game content binaries.

### Third-Party CDNs

The generic HTTP provider should already support S3, Cloudflare R2, Bunny,
Netlify, Vercel, Apache, nginx, and similar hosts. Provider-specific code should
only be added when it removes real complexity from the public API.

## Cache And Freshness Strategy

The cache should live under `user://dlc` by default:

```text
user://dlc/cache.json
user://dlc/hub/39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186.pck
```

Cache record:

```json
{
  "schema": 1,
  "items": {
    "hub": {
      "source_url": "https://cdn.example.com/dlc/hub.pck",
      "final_url": "https://cdn.example.com/dlc/hub.pck",
      "version_token": "sha256:39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186",
      "sha256": "39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186",
      "size": 14528,
      "etag": "",
      "last_modified": "",
      "local_path": "user://dlc/hub/39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186.pck",
      "installed_at_unix": 1781078400
    }
  }
}
```

Freshness preference:

1. Immutable versioned URL or hash-named PCK.
2. SHA-256 in local config or provider metadata.
3. `.sha256` sidecar at a stable URL.
4. Manifest/catalog hash.
5. `ETag`.
6. `Last-Modified`.
7. `Content-Length`.

The addon should never treat `Content-Length` alone as proof that the content is
correct.

For Web exports, `user://` persistence depends on browser IndexedDB/cookie
settings. Godot documents that incognito/private browsing and some iframe cookie
settings can prevent persistence. The addon should expose cache misses normally
and should not assume Web storage is permanent.

## Install Modes

The addon should be generic enough for more than PCKs, but PCK resource packs
should be the first vertical slice.

Initial modes:

- `resource_pack`: download `.pck` or `.zip`, validate, mount with
  `ProjectSettings.load_resource_pack()`.
- `file`: download and validate a standalone file to `user://`, return local
  path.

Possible later modes:

- `zip_extract`: download a generic ZIP and extract to `user://dlc/<id>/files`.
- `directory_index`: download multiple files listed in a small catalog.
- `custom`: call a project-provided installer object.

PCK mode should not literally unpack files. Godot mounts `.pck` and `.zip` files
into the virtual `res://` filesystem. After mounting, resources can be loaded as
if they were present from the beginning, but `DirAccess` may not show the new
`res://` contents. Callers should know the resource paths they intend to load,
or the pack should contain a known descriptor path.

## Pack Path Policy

For a universal addon, the pack's internal resource paths are project policy.
The addon should only require that paths do not accidentally collide.

Good generic paths:

```text
res://dlc/acme/arena/main.tscn
res://mods/acme/skin_pack/skin.tres
res://episodes/episode_01/entry.tscn
```

Good current-project paths:

```text
res://server/worlds/hub/hub.tscn
res://server/worlds/left_world/left_world.tscn
```

The current project's `server/worlds/` location is developer-facing, not
player-facing. It communicates export ownership: server exports include these
resources, client exports omit them, and downloaded client packs can mount them
later. The addon should not fight that.

## Server-Side Workflow

The server-side story should be boring.

For a VPS or local static server:

```powershell
# Export PCK however the project wants.
godot --headless --path . --export-pack "Hub World Pack" builds/dlc/hub.pck

# Write tiny sidecar.
Get-FileHash builds/dlc/hub.pck -Algorithm SHA256 |
	ForEach-Object { $_.Hash.ToLowerInvariant() } |
	Set-Content builds/dlc/hub.pck.sha256

# Serve builds/dlc as static files.
```

For GitHub Pages:

```text
docs/dlc/hub.pck
docs/dlc/hub.pck.sha256
```

For GitHub Releases:

```text
release asset: hub.pck
release asset: hub.pck.sha256
```

The addon can later ship helper scripts:

```text
addons/godot_dlc/tools/export_pack.ps1
addons/godot_dlc/tools/write_sha256.ps1
addons/godot_dlc/tools/upload_github_release.ps1
```

Those tools should be optional. A team should be able to use its own CI and only
produce downloadable PCKs plus sidecars.

## Proposed Addon Layout

```text
addons/godot_dlc/
  dlc.gd                         # class_name DLC, static facade
  dlc_service.gd                 # Node that owns HTTPRequest instances
  dlc_result.gd                  # result object
  dlc_config.gd                  # Resource or dictionary parser
  dlc_item.gd                    # optional Resource for editor-friendly config
  cache/
    dlc_cache_db.gd
  sources/
    dlc_http_source.gd
    dlc_github_release_source.gd
    dlc_github_pages_source.gd   # probably just HTTP defaults
  validators/
    dlc_sha256_validator.gd
    dlc_http_validator.gd
  installers/
    dlc_resource_pack_installer.gd
    dlc_file_installer.gd
  editor/
    plugin.cfg                   # optional later
    plugin.gd                    # optional later
  tools/
    export_pack.ps1              # optional later
```

Only `dlc.gd` and runtime dependencies need to ship in the client. The editor
folder can be excluded from exports.

## Implementation Flow

`await DLC.prepare("hub")` should do this:

1. Resolve `"hub"` against configured content items or providers.
2. Compute a stable `cache_key`.
3. Load `user://dlc/cache.json`.
4. Fetch freshness metadata when configured:
   - `.sha256` sidecar,
   - provider metadata,
   - `HEAD` validators,
   - or manifest item data.
5. If the cached file matches the current version token and still exists, skip
   the download.
6. Download to a temp path with `HTTPRequest.download_file`.
7. Validate size and SHA-256 when available.
8. Move the file to a content-addressed cache path.
9. Update the cache database atomically.
10. Install:
    - PCK/ZIP resource pack: `ProjectSettings.load_resource_pack(local_path,
      replace_files)`.
    - File mode: leave it in cache and return the local path.
11. Optionally verify configured `entry` or `required_resources` with
    `ResourceLoader.exists()`.
12. Return `DLCResult`.

The method should not hide errors. It should return `ok=false` with a specific
`status` and `error` string.

## Important Godot Constraints

`ProjectSettings.load_resource_pack(pack, replace_files := true, offset := 0)`
mounts local `.pck` and `.zip` files into `res://`. If a mounted pack contains
the same path as an existing resource, it replaces that resource unless
`replace_files=false`.

No public `unload_resource_pack()` API surfaced in the docs or inspected source.
Treat mounted resource packs as process-lifetime. For updates to an already
mounted content ID, prefer hash-named internal paths, restart, or mount a newer
pack only if replacement semantics are intentional.

Load DLC before loading resources that the DLC might replace. Godot resource
caching can otherwise keep the older resource object alive.

Do not depend on `DirAccess` to discover newly mounted `res://` contents. Use
known paths, a tiny in-pack descriptor, or explicit item config.

For Web exports:

- Network requests are subject to browser same-origin and CORS rules.
- `user://` persistence depends on browser storage settings.
- Downloads should use `HTTPRequest.download_file` so large PCKs are written to
  disk instead of held in memory.
- Test real Web exports for GitHub Releases redirects before blessing them as a
  default provider.

## Suggested First Spike

Implement one generic vertical slice around the current `hub.pck`, but do not
name the addon APIs around worlds.

1. Create `addons/godot_dlc/` runtime files only.
2. Add `DLC.prepare()` with ID and direct URL support.
3. Support plain HTTP `.pck` plus `.sha256` sidecar.
4. Store cache state in `user://dlc/cache.json`.
5. Mount with `replace_files=false` by default, with per-item override.
6. Replace `client/world_pack_manager.gd` call site with a configured generic
   DLC item for `hub`.
7. Keep the existing world manifest for master/world transfer while the generic
   addon handles only content availability.
8. Add a local smoke test:
   - delete `user://dlc`,
   - request `hub`,
   - confirm download and mount,
   - request `hub` again,
   - confirm cache hit,
   - change `.sha256`,
   - confirm redownload or validation failure.

## Open Questions

- Should the one-call method be `prepare()` or `install()`? This spike recommends
  `prepare()` because it covers cached, freshly downloaded, and mounted states
  without implying that all future runs are permanently installed.
- Should the static facade auto-create the service node, or should projects
  explicitly autoload `DLCService`? Auto-create gives the easiest one-call API;
  autoload gives clearer progress/cancel integration.
- Should the addon include a tiny in-pack descriptor convention, such as
  `res://dlc/<id>/dlc.json`? This would help generic discovery after mount, but
  should not be required.
- Should GitHub Releases be a first-class provider in the first implementation,
  or should it wait until plain HTTP and GitHub Pages-style hosting are stable?
- How much Web storage pressure is acceptable for cached PCKs before the addon
  needs cache eviction policy?

## Sources

Godot documentation:

- [Exporting packs, patches, and mods](https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html)
- [ProjectSettings.load_resource_pack](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-method-load-resource-pack)
- [HTTPRequest](https://docs.godotengine.org/en/stable/classes/class_httprequest.html)
- [GDScript static functions](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html#static-functions)
- [Singletons / Autoload](https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html)
- [Making plugins](https://docs.godotengine.org/en/stable/tutorials/plugins/editor/making_plugins.html)
- [Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

GitHub and Web documentation:

- [GitHub release asset API](https://docs.github.com/en/rest/releases/assets)
- [GitHub linking to latest release assets](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub repository contents API](https://docs.github.com/en/rest/repos/contents)
- [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)
- [MDN CORS safelisted response headers](https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_response_header)
- [MDN Access-Control-Expose-Headers](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Expose-Headers)

Local code reviewed:

- `client/world_pack_manager.gd`
- `tools/export_world_pack.ps1`
- `server/worlds/world_manifest.json`
- `export_presets.cfg`
- `C:/Programming_Files/Godot/godot-master/core/config/project_settings.cpp`
- `C:/Programming_Files/Godot/godot-master/core/io/file_access.cpp`
- `C:/Programming_Files/Godot/godot-master/scene/main/http_request.cpp`
- `C:/Programming_Files/Godot/godot-master/editor/plugins/editor_plugin_settings.cpp`
