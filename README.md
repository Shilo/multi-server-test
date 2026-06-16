<img src="icon.svg" alt="PackRat icon" width="128">

# PackRat

Your helpful little companion to fetch, stash, and mount your cheesy content.

PackRat is a lightweight Godot addon that downloads, verifies, caches, and
mounts DLC/content packs at runtime. Use it for worlds, mods, patches, skins,
episodes, asset bundles, or standalone downloadable files.

```gdscript
var result: PackRatResult = await PackRat.load_resource_pack("https://example.com/packs/hub.pck")
```

No editor plugin, autoload, manifest, SHA sidecar, provider system, descriptor
object, or custom installer workflow is required.

## Why PackRat

| Feature | What it means |
| --- | --- |
| One-call happy path | Download, cache, mount, and get a result from one await. |
| PCK and ZIP packs | Use Godot's native runtime resource-pack support. |
| Fast Web downloads | Web exports use browser-native `fetch()` by default for near-browser transfer speed. |
| Large-file friendly | Bigger download chunks, gzip support, temp files, cancellation, and progress. |
| Simple cache rules | Use freshness headers, server-provided size/mtime, `offline_first`, or forced downloads. |
| Static-host friendly | Works with ordinary VPS/CDN/GitHub Pages URLs. |
| No manifest files | Upload only a `.pck` or `.zip` to your host; no `manifest.json`, SHA sidecar, or provider config is required. |
| No plugin workflow | Runtime code works by class name without enabling an editor plugin. |

## Table of Contents

- [Install](#install)
- [Requirements](#requirements)
- [Build and Host Packs](#build-and-host-packs)
- [Quick Start](#quick-start)
- [What PackRat Does](#what-packrat-does)
- [What PackRat Does Not Do](#what-packrat-does-not-do)
- [API](#api)
- [Options](#options)
- [Results](#results)
- [Progress And Cancellation](#progress-and-cancellation)
- [Web Fetch Helper](#web-fetch-helper)
- [Server Metadata Without Manifests](#server-metadata-without-manifests)
- [Offline-First Loads](#offline-first-loads)
- [Cache Behavior Matrix](#cache-behavior-matrix)
- [Web Export And CORS](#web-export-and-cors)
- [GitHub URL Helpers](#github-url-helpers)
- [Cache Cleanup](#cache-cleanup)
- [Security Notes](#security-notes)
- [Performance And Stability Notes](#performance-and-stability-notes)
- [Demo Scene](#demo-scene)
- [Smoke Tests](#smoke-tests)
- [Explicit Benchmarks](#explicit-benchmarks)
- [Troubleshooting](#troubleshooting)
- [Maintainer: publish the addon branch](#maintainer-publish-the-addon-branch)
- [Using PackRat as a subtree dependency](#using-packrat-as-a-subtree-dependency)
- [VS Code task for updating without typing the CLI command](#vs-code-task-for-updating-without-typing-the-cli-command)
- [Used By](#used-by)
- [License](#license)

## Install

Copy `addons/pack_rat/` into your Godot project.

Use PackRat scripts by class name:

```gdscript
var options: PackRatOptions = PackRatOptions.new()
var result: PackRatResult = await PackRat.load_resource_pack("https://example.com/packs/hub.pck", options)
```

You do not need to enable a plugin in Project Settings.

## Requirements

PackRat targets Godot 4 and is currently tested with Godot 4.6.x. It uses
runtime `HTTPRequest` nodes or browser fetch downloads, plus
`ProjectSettings.load_resource_pack()`, so it must run from a live `SceneTree`.

Build downloadable packs with the same Godot version family as your game. Godot
may reject packs produced by a newer incompatible engine version.

## Build and Host Packs

Create downloadable packs with Godot's pack export flow. The official docs cover
exporting `.pck` files and choosing between `.pck` and `.zip` pack formats:

- [Exporting packs, patches, and mods](https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html)
- [PCK versus ZIP pack file formats](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html#pck-versus-zip-pack-file-formats)

Host the exported files as ordinary static files on your VPS, CDN, GitHub
Release, or GitHub Pages site:

```text
https://cdn.example.com/world_packs/hub.pck
https://cdn.example.com/world_packs/arena.zip
```

For Web exports, keep downloadable packs out of the initial game export when
they are meant to be fetched later. PackRat should download those packs from
your static host at runtime, not from files already bundled into the Web export.

## Quick Start

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.entry_path = "res://worlds/hub/main.tscn"

var result: PackRatResult = await PackRat.load_resource_pack("https://example.com/packs/hub.pck", options)
if not result.ok:
	push_error(result.error)
	return

var error: Error = result.change_scene_to_entry()
if error != OK:
	push_error("Could not change to pack scene: %d" % error)
```

PackRat mounts the pack; your game can then load resources from the paths inside
that pack. Set an ID when the URL filename is not stable enough to be your cache
identity:

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.id = "hub"
options.entry_path = "res://worlds/hub/main.tscn"

var result: PackRatResult = await PackRat.load_resource_pack("https://example.com/packs/hub.pck", options)
if not result.ok:
	push_error(result.error)
	return

var error: Error = result.change_scene_to_entry()
if error != OK:
	push_error("Could not change to pack scene: %d" % error)
```

## What PackRat Does

- Sends `HEAD` when a cached file exists and update checking is enabled.
- Compares `ETag`, `Last-Modified`, then reliable `Content-Length` when available.
- Can reuse cache by expected file metadata without a `HEAD` request.
- Can read local file size and modified time with `PackRat.file_metadata(path)`.
- Can run offline-first, using matching cache immediately and downloading only
  on cache miss.
- Downloads missing or stale packs to `user://pack_rat/tmp/*.part`.
- Moves successful downloads into flat versioned paths such as
  `user://pack_rat/<id>-<token>.pck`.
- Stores cache metadata in `user://pack_rat/cache.json`.
- Mounts `.pck` and `.zip` files with `replace_files=true` by default.
- Supports progress and cancellation through `PackRatRequest`.
- Can clear one cached pack or the full cache.
- Builds GitHub Pages and GitHub Release URLs without calling the GitHub API.
- Reports when direct GitHub Release downloads are unsuitable for Web clients.
- Keeps concurrent loads independent; duplicate simultaneous calls may each download.

## What PackRat Does Not Do

- No SHA-256 or signature validation.
- No manifests/catalogs.
- No GitHub API/provider integrations.
- No custom source resolver/cache/installer/validator classes.
- No unload/reload solution for already mounted same-path resources.
- No request de-duplication registry.

## API

### `PackRat.load_resource_pack(url, options := PackRatOptions.new()) -> PackRatResult`

Downloads a remote pack when needed, caches the file, and mounts the `.pck` or
`.zip`. Alternatively handles local packs for rapid development testing. Returns
a completed `PackRatResult`.

### `PackRat.load_resource_pack_async(url, options := PackRatOptions.new()) -> PackRatRequest`

Starts the same load and immediately returns a cancelable `PackRatRequest` with
progress and completion signals.

### `PackRat.clear_cached_resource_pack(value, options := PackRatOptions.new()) -> Error`

Deletes one cached pack by URL, ID, cached filename, or cached path. Already
mounted packs remain mounted until the app exits because Godot has no unload API.

### `PackRat.clear_cache(options := PackRatOptions.new()) -> Error`

Deletes all removable PackRat cache files, temporary downloads, and cache
metadata in the selected cache directory.

### `PackRat.file_metadata(path) -> PackRatFileMetadata`

Reads local file size and modified time for server-side metadata flows.
Use `metadata.apply_to_options(options)` when you want to copy those values into
`expected_size` and `expected_modified_time`.

### `PackRat.github_pages_url(owner, repo, path := "") -> String`

Builds a GitHub Pages project URL such as
`https://owner.github.io/repo/packs/hub.pck`.

### `PackRat.github_release_url(owner, repo, filename, tag := "latest") -> String`

Builds a direct GitHub Release asset URL without calling the GitHub API.

### `PackRat.can_download_github_releases() -> bool`

Returns `false` in Web exports because GitHub Release asset redirects are not
CORS-friendly for browser downloads. Native/editor clients can use Release URLs.

### `PackRat.versioned_url(url, query_version, query_version_key := "v", replace_existing_query_version := true) -> String`

Sets a stable content-version query value, such as `?v=42`, so browser/CDN
caches fetch a fresh file when your remote pack changes. If the URL already has
the same version key, PackRat replaces it by default.

### `PackRat.join_url(base_url, path) -> String`

Joins a static host base URL and relative path with slash cleanup only.

## PackRatOptions

`PackRatOptions` is the optional settings object passed to
`PackRat.load_resource_pack()` and `PackRat.load_resource_pack_async()`. PackRat
copies it when a request starts, so later mutations do not affect in-flight
loads.

### Public Properties

| Option | Default | Purpose |
| --- | --- | --- |
| `id` | `""` | Cache identity and filename prefix. Empty derives one from the URL filename. |
| `cache_dir` | `"user://pack_rat"` | Directory for `cache.json`, `.part` downloads, and cached packs. Must be a non-root `user://` path without `..` segments. |
| `replace_files` | `true` | Passed to `ProjectSettings.load_resource_pack()`. Allows the pack to override existing `res://` paths. |
| `offset` | `0` | Byte offset for embedded PCK files. ZIP packs must use `0`. |
| `entry_path` | `""` | Optional `res://` scene path copied into the result for caller convenience. PackRat only uses it when you call result entry-scene helpers. |
| `editor_pack_export_preset` | `""` | Editor-only local testing helper. When set in an editor run, PackRat builds this Godot export preset with `--export-pack`, then loads the generated local pack instead of downloading the URL. Exported games ignore it and use the URL normally. |
| `editor_simulated_local_load_seconds` | `0.0` | Editor-only minimum duration for uncached local pack copy progress. Use this to dogfood loading screens, progress bars, cancellation, and transfer timing with local packs. Exported games ignore it. |
| `expected_size` | `0` | If greater than `0`, becomes part of cache identity and is checked against downloaded bytes. |
| `expected_modified_time` | `0` | If greater than `0`, becomes part of cache identity and is compared to `Last-Modified` when available. |
| `progress_total_size` | `0` | Optional non-validating byte total for progress bars when a platform cannot report a reliable HTTP body size. |
| `offline_first` | `false` | Uses a matching cached file immediately; downloads only on cache miss. |
| `query_version` | `application/config/version` or `""` | Stable request URL query value. PackRat appends it to remote requests when `query_version_key` is missing from the URL. Set to `""` to disable this. This only affects the outbound request URL, not PackRat cache identity. |
| `query_version_key` | `"v"` | Query key used by `query_version`. |
| `request_headers` | `[]` | Extra headers for `HEAD` and `GET`. |
| `accept_gzip` | `true` | Lets native Godot `HTTPRequest` request gzip/deflate transfer compression. Web browsers already decode fetch bodies, so PackRat avoids a second Web `HTTPRequest` decode while still receiving browser-managed compression. |
| `timeout_seconds` | `120.0` | Total HTTP request deadline in seconds. Large packs on slow links may need a higher value. |
| `download_chunk_size` | `8 * 1024 * 1024` | Bytes per native `HTTPRequest` read or Web `fetch()` write chunk. Defaults to a balanced 8 MiB chunk for DLC-sized files. Try 4 MiB or 16 MiB only after profiling your own host/device mix. PackRat clamps larger values to Godot's 16 MiB maximum. |
| `use_threads` | `false` | Lets native `HTTPRequest` use its worker thread when supported. Leave this off unless your own target benefits from it; PackRat's Windows/GitHub Pages benchmarks found the threaded path was usually slower or neutral. PackRat does not pass this through to Web `HTTPRequest`; Web exports use browser `fetch()` by default. |
| `use_web_fetch` | `true` | Uses PackRat's browser `fetch()` downloader for Web exports when available. Set `false` to force Godot `HTTPRequest`. |
| `capture_timings` | `false` | Fills `PackRatResult.timings_msec` for profiling. Leave off for the leanest production path. |
| `max_redirects` | `8` | Redirect limit for `HTTPRequest`. On Web `fetch()`, `0` disables redirects and positive values use the browser redirect behavior. |
| `always_download` | `false` | Forces a fresh download instead of using a matching cache file. |

### Constants

| Constant | Value | Purpose |
| --- | --- | --- |
| `MIN_DOWNLOAD_CHUNK_SIZE` | `256` | Smallest supported `download_chunk_size`. |
| `MAX_DOWNLOAD_CHUNK_SIZE` | `16 * 1024 * 1024` | Largest supported `download_chunk_size`; matches Godot's `HTTPRequest` maximum. |
| `DEFAULT_DOWNLOAD_CHUNK_SIZE` | `8 * 1024 * 1024` | Balanced default chunk size for DLC-sized files. |

### Helpers

Create options from server-provided file metadata:

```gdscript
var options: PackRatOptions = PackRatOptions.from_expected_metadata(expected_modified_time, expected_size)
var result: PackRatResult = await PackRat.load_resource_pack(url, options)
```

The argument order is `expected_modified_time`, then `expected_size`.

## Results

`PackRatResult.ok` is `true` when the pack is mounted and ready.

Useful fields:

| Field | Meaning |
| --- | --- |
| `id` | Cache ID used for this pack. |
| `status` | `"downloaded"`, `"cache_hit"`, or `"failed"`. |
| `from_cache` | `true` when no download was needed for this request. |
| `mounted` | `true` when Godot accepted the `.pck` or `.zip`. |
| `source_url` | URL or local source path used for this request. |
| `local_path` | Cached file path under `user://`. |
| `entry_path` | Copied from `PackRatOptions.entry_path`. |
| `etag` | Remote `ETag` freshness header, when available. |
| `last_modified` | Remote `Last-Modified` freshness header, when available. |
| `content_length` | Remote or downloaded byte size, when available. |
| `response_code` | Last HTTP response code observed during download. |
| `warnings` | Non-fatal notes, such as missing comparable freshness headers. |
| `timings_msec` | Profiling timings when `capture_timings` is enabled. |
| `error` | Failure message when `ok == false`. |

Entry-scene helpers:

```gdscript
if result.entry_scene_exists():
	var scene: PackedScene = result.load_entry_scene()

var error: Error = result.change_scene_to_entry()
```

These helpers only use `PackRatOptions.entry_path`. PackRat does not discover
an unknown main scene from the mounted pack.

## Progress And Cancellation

```gdscript
var request: PackRatRequest = PackRat.load_resource_pack_async("https://example.com/packs/hub.pck")
request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
	if total_bytes > 0:
		print("%d / %d" % [downloaded_bytes, total_bytes])
	else:
		print("%d bytes" % downloaded_bytes)
)

# request.cancel()

await request.completed
if request.result.ok:
	print("Mounted: %s" % request.result.local_path)
elif request.result.was_canceled():
	print("Canceled")
```

Canceling a request completes it with a failed result. On Web fetch downloads it
aborts the browser request; on Godot HTTP downloads it cancels the active
`HTTPRequest`.

## Web Fetch Helper

For Web exports, PackRat also includes `PackRatWebFetch`: a small static helper
that downloads any URL straight to a `user://` file with browser-native
`fetch()`.

```gdscript
var result: PackRatWebFetchResult = await PackRatWebFetch.download_file(
	"https://example.com/large-file.bin",
	"user://large-file.bin"
)
```

Use `PackRat.load_resource_pack()` for PCK/ZIP packs. Use `PackRatWebFetch`
only when you want PackRat's fast Web download path for a non-pack file. The
helper writes to a temporary file first and replaces `download_path` only after
the request succeeds.

## Server Metadata Without Manifests

Server-authoritative projects can pass expected file metadata instead of
creating a manifest or sidecar file.

On the server, read only file stats and send the compact values your game needs.
For a VPS or dedicated server, this is usually a real filesystem path:

```gdscript
var world_id: String = "hub"
var pack_path: String = "/srv/virtucade/world_packs/%s.pck" % world_id
var metadata: PackRatFileMetadata = PackRat.file_metadata(pack_path)
if not metadata.ok:
	push_error(metadata.error)
	return

rpc_id(peer_id, "prepare_world_transfer", world_id, metadata.modified_time, metadata.size)
```

On the client, derive URL and scene path by your own project convention:

```gdscript
@rpc("authority", "reliable")
func prepare_world_transfer(world_id: String, expected_modified_time: int, expected_size: int) -> void:
	var url: String = PackRat.join_url(world_pack_base_url, "%s.pck" % world_id)
	var options: PackRatOptions = PackRatOptions.from_expected_metadata(expected_modified_time, expected_size)
	options.entry_path = "res://server/worlds/%s/%s.tscn" % [world_id, world_id]

	var result: PackRatResult = await PackRat.load_resource_pack(url, options)
	if not result.ok:
		push_error(result.error)
		return

	var error: Error = result.change_scene_to_entry()
	if error != OK:
		push_error("World scene was not found after mounting pack: %s" % result.entry_path)
```

For example, your game can define this convention:

```text
world_id "hub" -> https://cdn.example.com/world_packs/hub.pck
```

When expected metadata is set, PackRat derives cache identity from the pack ID,
size, and modified time. A matching cached file is used immediately. Otherwise
the URL is downloaded and provided fields are checked independently.

For canonical URLs, `id` is optional because PackRat derives it from the
filename:

```text
https://cdn.example.com/worlds/hub.pck -> id "hub"
```

Set `options.id` for non-canonical URLs:

```gdscript
var options: PackRatOptions = PackRatOptions.from_expected_metadata(expected_modified_time, expected_size)
options.id = "hub"
var result: PackRatResult = await PackRat.load_resource_pack("https://cdn.example.com/download?id=hub", options)
```

```text
https://cdn.example.com/download?id=hub
https://cdn.example.com/latest.pck
```

Size is checked against the downloaded file bytes. Modified time is checked
against the server's `Last-Modified` header when it is available. If
`Last-Modified` is missing but expected size matches, the download is allowed
with a warning. If you only provide `expected_modified_time`, the server must
return a comparable `Last-Modified` header or PackRat cannot validate the
download.

## Offline-First Loads

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.offline_first = true
```

`offline_first` means a cache hit uses the cached file immediately and skips
remote update checks. A cache miss still downloads. This is not the same as
network-disabled mode.

## Cache Behavior Matrix

| Mode | Cache hit behavior | Cache miss behavior | Network check |
| --- | --- | --- | --- |
| Default | Sends `HEAD`, compares freshness, then uses cache if fresh or unknown. | Downloads. | `HEAD` on hit, `GET` on miss/stale. |
| `expected_size` or `expected_modified_time` | Uses matching cache identity immediately. | Downloads and validates provided fields. | No `HEAD`; `GET` only on miss. |
| `offline_first` | Uses cache immediately. | Downloads. | No `HEAD`; `GET` only on miss. |
| `always_download` | Ignores cache for the fresh request. | Downloads. | `GET`. |

## Web Export And CORS

For Godot Web exports, the pack server must allow browser downloads. If you want
HTTP freshness checks, expose the freshness headers too:

```text
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: ETag, Last-Modified, Content-Length, Content-Type
Cache-Control: no-cache
ETag: "..."
Last-Modified: Wed, 10 Jun 2026 20:15:00 GMT
Content-Length: 123456
Content-Type: application/octet-stream
```

If the browser cannot read `ETag` or `Last-Modified`, PackRat may treat
freshness as unknown and reuse the cached pack with a warning. Browser
`Content-Length` can describe compressed transfer bytes instead of decoded pack
bytes, so Web exports should use `expected_size` and/or `progress_total_size`
when they need exact byte totals.

In Web exports, `user://` cache lives in browser-managed storage. Browsers can
evict it, so treat PackRat's cache as a performance cache, not durable game
state. Your server or master-server metadata should remain the source of truth.

## GitHub URL Helpers

```gdscript
var pages_url: String = PackRat.github_pages_url("owner", "repo", "packs/hub.pck")
var latest_url: String = PackRat.github_release_url("owner", "repo", "hub.pck")
var tagged_url: String = PackRat.github_release_url("owner", "repo", "hub.pck", "v1.2.0")
```

These helpers only build URLs. They do not call the GitHub API.

Use GitHub Pages for browser-friendly static downloads:

```gdscript
var url: String = PackRat.github_pages_url("owner", "repo", "packs/hub.pck")
```

Use GitHub Releases for native/editor downloads:

```gdscript
if PackRat.can_download_github_releases():
	var url: String = PackRat.github_release_url("owner", "repo", "hub.pck")
```

Direct GitHub Release asset downloads are not recommended for Web exports
because browsers require CORS headers across the redirect chain and GitHub's
release asset storage is not designed as a game CDN. Mirror release assets to
GitHub Pages, a CDN, or your own static host for Web builds.

For ordinary static hosts or CDNs:

```gdscript
var url: String = PackRat.join_url("https://cdn.example.com/worlds/", "/hub.pck")
var versioned: String = PackRat.versioned_url(url, server_pack_version)
```

`join_url()` only handles slash cleanup. `versioned_url()` is optional when your
server/master payload already knows the current content version and you want to
build the full URL yourself. Neither helper fetches catalogs, lists directories,
or encodes provider-specific rules.

By default, `PackRatOptions.query_version` is copied from
`ProjectSettings.get_setting("application/config/version")`. If that value is
set, PackRat appends it to remote requests as `?v=<version>` unless the URL
already contains `v`:

```gdscript
var options: PackRatOptions = PackRatOptions.new()

var result: PackRatResult = await PackRat.load_resource_pack(
	"https://cdn.example.com/world_packs/hub.pck",
	options
)
```

Override `options.query_version` for a different stable token, set
`options.query_version_key` for a different query key, or set
`options.query_version = ""` to disable request URL versioning. This does not
change PackRat's cache identity, cache filenames, or expected-metadata
validation.

## Cache Cleanup

```gdscript
PackRat.clear_cached_resource_pack("hub")
PackRat.clear_cached_resource_pack("https://example.com/packs/hub.pck")
PackRat.clear_cached_resource_pack("hub-abc123.pck")
PackRat.clear_cache()
```

`clear_cached_resource_pack()` matches by URL, ID, cached filename, or cached
path. Cleanup is limited to non-root `user://` cache directories without `..`
segments.

Clearing cache only removes files from disk. Godot does not expose an API for
unloading a resource pack that is already mounted. PackRat removes matching
cache records but may keep mounted pack files on disk until the process exits.

## Security Notes

Downloaded packs are treated as authoritative content by default. Use trusted
URLs, because mounted packs can replace existing `res://` paths, including
scenes and scripts.

Keep `replace_files=true` for trusted DLC/patch workflows that intentionally
override content. Set `replace_files=false` when a pack should only add
namespaced content and must not shadow existing project paths.

HTTP metadata is useful for freshness, not authenticity. It answers "does this
look changed?" rather than "is this trusted content?"

`entry_path` is also not a validation feature. It is copied into
`PackRatResult` so caller code can keep its intended scene/resource path next to
the load result. Check that path with `ResourceLoader.exists()` or your own game
rules before using it.

## Performance And Stability Notes

- Downloads use a temporary `.part` path and move into cache only after success.
- Cache metadata is saved through a temporary JSON file with backup restore.
- `PackRatOptions` is copied when a request starts, so later option mutations do
  not affect an in-flight load.
- Repeated cache hits for the same ID, path, replace mode, and offset skip a
  duplicate mount call.
- Repeated expected-metadata or `offline_first` cache hits can use an exact
  in-process fast path after the first successful mount.
- Concurrent calls are independent by design. If two identical calls start at
  the same time, both may download.
- Native HTTPRequest progress polling happens once per frame while a GET is active.
- PackRat raises `HTTPRequest.download_chunk_size` above Godot's 64 KiB default
  because resource packs are DLC-sized files, not small API responses. It
  defaults to a balanced 8 MiB chunk and clamps larger values to Godot's 16 MiB
  engine maximum. In repeated tests, 8 MiB was the best default because 16 MiB
  can reduce callback overhead but may lose that gain to larger memory copies or
  longer single-step stalls. Treat 4 MiB and 16 MiB as opt-in profiling knobs.
- PackRat exposes native `HTTPRequest` worker threads through
  `PackRatOptions.use_threads`, but leaves them off by default. In repeated
  Windows/GitHub Pages tests, the threaded path was usually slower or neutral
  compared with the default native path.
- Native desktop/mobile exports still use Godot's built-in HTTP stack. PackRat
  tunes the path for large resource-pack downloads with bigger chunks, gzip, and
  direct-to-file caching. Recent Windows/GitHub Pages tests put native downloads
  close to the Web fetch path for the demo packs, but pure GDScript still cannot
  bypass Godot's native `HTTPRequest` behavior. A future optional GDExtension
  downloader using a native HTTP library may be useful for very large native
  downloads, but that is intentionally outside the lightweight core addon for now.
- PackRat keeps gzip/deflate transfer compression enabled for native
  `HTTPRequest`. Web browsers decode fetch bodies before Godot reads them, so
  PackRat disables Web `HTTPRequest`'s extra decode step and still caches normal
  raw PCK/ZIP bytes.
- Web exports use a browser `fetch()` fast path for file downloads because
  Godot's Web HTTP client cannot progress more than once per frame. This is on
  by default through `PackRatOptions.use_web_fetch`, and can be disabled to
  compare against Godot `HTTPRequest`. This mainly avoids the Web
  `HTTPRequest` frame-polling bottleneck; native Windows downloads can already
  be close in practice with PackRat's tuned `HTTPRequest` path. It still uses
  browser and WebAssembly memory while chunks are handed to Godot.
  Web `fetch()` writes chunks using `download_chunk_size`, so the normal
  `.part` download path is shared with native `HTTPRequest`. Progress UI
  callbacks are rate-limited to 2 FPS to avoid bridge spam without slowing the
  actual browser download. The final progress callback still reports the exact
  completed byte count.
- `capture_timings` is opt-in so normal loads avoid profiling dictionary and
  timestamp overhead.
- `timeout_seconds` is finite by default so failed or extremely slow downloads
  do not hang forever. It is a total request deadline, not an idle-only timeout,
  so raise it for very large packs or slow links.
- If a fresh download would target an already-mounted cache path, PackRat keeps
  the mounted file and stores the new download at a unique cache path. It warns
  when a different pack is mounted for the same ID.
- Load packs before loading or preloading resources they are meant to replace.
  Godot may keep already-loaded scenes, scripts, and resources in memory, so a
  late-mounted pack does not behave like a clean restart.

## Demo Scene

```powershell
godot --path . --scene "res://demo/demo.tscn"
```

PackRat ships with a Web-friendly showcase scene called PackRat Portal. It uses
a tiny base scene and two editor-authored remote packs:

- `packrat-demo-warehouse.pck`, about 10 MiB.
- `packrat-demo-gallery.zip`, about 16 MiB.

In Web builds, the demo includes a `Downloader` selector to compare the default
browser `fetch()` path against Godot's `HTTPRequest` path. Native/editor runs
hide this selector because they always use Godot `HTTPRequest`.

The demo intentionally leaves `expected_size` and `expected_modified_time`
unset, but enables `offline_first` so repeated loads reuse the matching cached
pack immediately without a `HEAD` check. That keeps the showcase snappy while
still demonstrating the normal download, cache, mount, progress, cancel, and
clear-cache APIs.

Export the demo packs locally:

```powershell
godot --headless --path . --export-pack "Warehouse DLC" "build/packs/packrat-demo-warehouse.pck"
godot --headless --path . --export-pack "Gallery DLC" "build/packs/packrat-demo-gallery.zip"
godot --headless --path . --script "tools/demo_pack_catalog.gd" -- --output-dir=build/packs
```

This writes local demo packs to `build/packs/` using the `Warehouse DLC` and
`Gallery DLC` export presets, then updates the committed demo catalog size and
version tokens. The pack source scenes live in `demo/packs/` so they are
visible in the Godot editor. The Web export excludes `demo/packs/*`, then
PackRat mounts those paths back at runtime.

## Local Pack Testing

PackRat is designed around remote HTTP(S) packs, but it can also load local
`.pck` and `.zip` files through the same cache and mount pipeline:

```gdscript
await PackRat.load_resource_pack("user://local_packs/hub.pck")
await PackRat.load_resource_pack("res://local_packs/hub.pck")
await PackRat.load_resource_pack("file:///C:/projects/game/local_packs/hub.pck")
```

Local packs work in editor and exported builds when Godot can read the path. For
example, native exports can use accessible absolute paths, `user://`, and
included `res://` files. Web exports are limited by the browser sandbox, so
arbitrary `file:///C:/...` paths are not available there.

Local packs are copied into the PackRat cache with `.part` files, progress
signals, cancellation checks, metadata validation, and the normal final
`ProjectSettings.load_resource_pack()` mount. This is mostly useful for rapid
development testing; production distribution should usually use HTTP(S).

For the lowest-friction editor workflow, point an option at a Godot export
preset:

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.id = "hub"
options.entry_path = "res://server/worlds/hub/hub.tscn"
options.editor_pack_export_preset = "Hub DLC"

var result: PackRatResult = await PackRat.load_resource_pack(
	"https://cdn.example.com/worlds/hub.pck",
	options
)
```

Only `editor_pack_export_preset` is editor-only. In editor runs, PackRat calls
Godot's own `--export-pack` pipeline for `Hub DLC` and loads that generated
pack. Exporting is synchronous, so very large presets can briefly pause the
editor while Godot builds the pack. In exported games, the option has no effect
and the remote URL is used normally.

PackRat reuses the generated pack across sessions until `export_presets.cfg` or
a project resource has a newer filesystem modified time. That keeps normal
play-button tests fresh without manually rebuilding PCKs.

To test game-side loading UI without waiting on a real network, set
`editor_simulated_local_load_seconds`:

```gdscript
options.editor_simulated_local_load_seconds = 1.5
```

This only affects editor runs and only when a local/editor-generated pack is
being copied into cache. Cache hits stay instant, and exported games ignore the
setting.

The demo pack presets enable both desktop and mobile Web VRAM texture
compression targets. This makes the PCK/ZIP exports larger when they contain
VRAM-compressed textures, but better demonstrates one universal Web pack that
can run on desktop and mobile browsers.

The demo DLC presets use Godot's `Export as dedicated server` resource mode only
to access per-folder `Keep` and `Remove` export behavior. The presets keep
`dedicated_server=false` and do not use `Strip Visuals`, so the exported packs
remain normal runtime content packs.

CI uses the same export presets, syncs the demo catalog to the exported
artifacts, and passes that exported pack directory into the demo smoke test.
This keeps Web deployments aligned even when ZIP metadata differs slightly
between operating systems:

```powershell
godot --headless --path . --script "tools/demo_pack_catalog.gd" -- --output-dir=build/packs
godot --headless --path . --scene "res://tests/pack_rat_demo_smoke.tscn" -- --pack-dir=build/packs
```

When exported for Web, the demo resolves pack URLs against the current page's
same-origin `packs/` folder. Native/editor runs default to the canonical GitHub
Pages mirror. For local manual testing against freshly built packs, start a
static server:

```powershell
python -m http.server 18924 --directory build
```

Then pass a pack base URL:

```powershell
godot --path . --scene "res://demo/demo.tscn" -- --pack-base-url=http://127.0.0.1:18924/packs --auto-load=warehouse,gallery --quit-when-done
```

Useful demo CLI args:

| Arg | Purpose |
| --- | --- |
| `--pack-base-url=...` | Static URL base for mirrored demo packs. |
| `--source=pages` | Use same-origin/static-host URLs. |
| `--source=github_release` | Use GitHub Release asset URLs for native/editor testing. Browser Web exports disable this source because GitHub release redirects do not provide game-friendly CORS headers. |
| `--source=editor_export` | Editor-only mode that builds each demo pack from its Godot export preset, then loads it through PackRat with simulated local progress. |
| `--release-tag=...` | GitHub Release tag for demo packs. |
| `--auto-load=warehouse,gallery` | Load one or more packs after startup. |
| `--quit-when-done` | Exit after auto-load finishes. |

## Smoke Tests

```powershell
godot --headless --path . --scene "res://tests/pack_rat_component_smoke.tscn"
godot --headless --path . --scene "res://tests/pack_rat_local_file_smoke.tscn"
godot --headless --path . --scene "res://tests/pack_rat_editor_export_preset_smoke.tscn"
godot --headless --path . --scene "res://tests/pack_rat_http_pck_smoke.tscn"
godot --headless --path . --scene "res://tests/pack_rat_http_zip_smoke.tscn"
godot --headless --path . --scene "res://tests/pack_rat_pck_hot_update_probe.tscn"
godot --headless --path . --scene "res://tests/pack_rat_demo_smoke.tscn"
```

These smokes cover local metadata reads, `file://`, `user://`, `res://`,
editor export presets, simulated editor-local progress, `expected_size`,
`expected_modified_time`, cache hits without `HEAD`/`GET`, changed metadata
redownloads, missing `Last-Modified` warnings, offline-first cache reuse,
independent concurrent loads, progress/cancel signals, fast-cache cancellation,
request headers, redirects, timeouts, `replace_files=false`, cache clearing,
PCK mounting, ZIP mounting, demo pack exporting, extensionless PCK URLs,
MMO-style scene existence, and Godot's same-path hot-update/resource-cache
behavior.

## Explicit Benchmarks

Benchmarks are intentionally not part of the automatic CI smoke path because
download timing depends on the runner, CDN edge, OS file cache, browser, and
frame rate. Run them explicitly when changing download code or tuning pack
hosting:

```powershell
godot --headless --path . --scene "res://tests/pack_rat_performance_smoke.tscn"
```

Native thread comparison is also explicit and hits the live GitHub Pages demo
pack URLs. Use it when deciding whether `PackRatOptions.use_threads`
should be enabled for a real native target:

```powershell
godot --headless --path . --scene "res://tests/pack_rat_native_thread_benchmark.tscn" -- --samples=24
```

Optional benchmark-only args include `--max-fps=60`, `--max-fps=0`, and
`--vsync-mode=0`. These are for profiling engine behavior, not recommended
PackRat defaults.

The Web download benchmark is also explicit. Export a Web build that starts
`res://tests/pack_rat_web_download_benchmark.tscn`, serve it over HTTP, and pass
`?url=<pack-url>&samples=<count>` to compare Web `fetch()` and Godot
`HTTPRequest` chunk sizes.

Before a release that changes `PackRatWebFetch`, run a browser build and verify
both Web download paths:

- `use_web_fetch=true` downloads, reports progress, cancels, and mounts.
- `use_web_fetch=false` still works through Godot `HTTPRequest`.
- Progress reaches the expected total when `expected_size` or
  `progress_total_size` is set.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `PackRat only accepts HTTP(S) URLs, local .pck/.zip files, or editor export presets.` | The URL is not HTTP(S), not a local `.pck`/`.zip`, and no editor export preset was provided. | Use an HTTP(S) URL, a local pack path, or `options.editor_pack_export_preset`. |
| `PackRat could not build editor export preset` | The preset name is wrong, export templates are missing, or Godot's `--export-pack` failed. | Check `export_presets.cfg`, install export templates for that preset's platform, and try the same `godot --headless --path . --export-pack "Preset Name" output.pck` command manually. |
| Freshness is always unknown. | Server or browser CORS is hiding `ETag`/`Last-Modified`, or the host cannot provide reliable freshness. | Expose freshness headers or use expected metadata. |
| `.zip` URL fails with nonzero offset. | Godot only supports offsets for PCK packs. | Keep `offset = 0` for ZIP packs. |
| Cache cleanup returns `ERR_INVALID_PARAMETER`. | `cache_dir` is root `user://`, outside `user://`, or contains `..`. | Use a dedicated directory such as `user://pack_rat`. |
| Web console prints `Failed to save IDB file system`. | Godot Web is syncing `user://` cache files to browser IndexedDB. DevTools may show a very large minified engine stack trace for one storage sync message. | Treat browser cache as a performance cache, keep using same-origin pack URLs, and clear the site's browser storage if IndexedDB gets wedged during testing. |
| Godot cannot mount the downloaded pack. | The pack may be invalid or built with an incompatible Godot version. | Rebuild the pack with the same Godot version family as the client. |
| Updated resources do not behave like a clean restart. | Godot cannot unload an already mounted pack. | Use versioned internal resource paths or restart between incompatible pack versions. |

## Maintainer: publish the addon branch

The public subtree branch is always named `addon`. After changing files under
`addons/pack_rat` on `main`, the GitHub workflow publishes that directory as the
root of `addon` automatically.

To create or repair the branch manually from the PackRat repo root, publish the
addon directory tree with `git commit-tree`:

```powershell
$addonDir = "addons/pack_rat"
git fetch origin "+refs/heads/addon:refs/remotes/origin/addon" 2>$null
$addonTree = git rev-parse "main:$addonDir"
$currentTree = git rev-parse "origin/addon^{tree}" 2>$null

if ($LASTEXITCODE -eq 0 -and $addonTree -eq $currentTree) {
  "addon branch already up to date"
} else {
  $parent = git rev-parse --verify origin/addon 2>$null
  if ($LASTEXITCODE -eq 0) {
    $newCommit = git commit-tree $addonTree -p $parent -m "chore: sync addon branch from $(git rev-parse --short main)"
  } else {
    $newCommit = git commit-tree $addonTree -m "chore: sync addon branch from $(git rev-parse --short main)"
  }
  git push origin "${newCommit}:refs/heads/addon"
}
```

The `addon` branch contains only the files that belong inside a dependent
project's `addons/pack_rat` directory. It is a generated one-way publish branch,
so make source changes under `addons/pack_rat` on `main` instead of editing
`addon` directly.

The `.github/workflows/sync-addon-branch.yml` workflow uses the same
`git commit-tree` publish flow whenever `main` receives changes under
`addons/pack_rat`, or when the workflow itself changes and needs to seed or
repair the generated branch.

## Using PackRat as a subtree dependency

Dependent Godot projects should keep PackRat at:

```text
addons/pack_rat
```

Git subtree is useful here because the dependent repo gets real committed files
instead of a submodule pointer. That means the project opens normally in Godot,
CI jobs do not need a recursive checkout step, and monorepos can treat PackRat
like ordinary source.

The tradeoff is that subtree is a vendoring workflow, not a package manager.
Updates are explicit merge commits, local edits can create conflicts, and the
`addon` branch follows the latest `main` addon snapshot. For a frozen release,
prefer a tagged release zip; for discoverability, a Godot Asset Library listing
would complement this branch rather than replace it.

This repository is a full Godot demo project. The reusable addon files live in
`addons/pack_rat`, so subtree consumers should use the generated `addon` branch.

### Initialize the subtree

From the root of the repo that depends on PackRat:

```powershell
git subtree add --prefix=addons/pack_rat https://github.com/Shilo/pack-rat.git addon --squash
```

This adds the shared PackRat files into `addons/pack_rat` and records enough
subtree history for future updates.

### Update to the latest PackRat commit

From the dependent repo root:

```powershell
git subtree pull --prefix=addons/pack_rat https://github.com/Shilo/pack-rat.git addon --squash
```

If Git reports conflicts, resolve them like a normal merge, then commit the
result.

## VS Code task for updating without typing the CLI command

In any dependent repo, create `.vscode/tasks.json` with this task:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Update PackRat subtree",
      "type": "shell",
      "command": "git",
      "args": [
        "subtree",
        "pull",
        "--prefix=addons/pack_rat",
        "https://github.com/Shilo/pack-rat.git",
        "addon",
        "--squash"
      ],
      "problemMatcher": []
    }
  ]
}
```

Then run it from VS Code:

1. Open the Command Palette with `Ctrl+Shift+P`.
2. Choose `Tasks: Run Task`.
3. Choose `Update PackRat subtree`.

Optional keyboard shortcut in VS Code `keybindings.json`:

```json
{
  "key": "ctrl+alt+u",
  "command": "workbench.action.tasks.runTask",
  "args": "Update PackRat subtree"
}
```

The task still runs Git under the hood, but you can trigger it from VS Code
without retyping the subtree command.

## Used By

- [Shilo/multi-server-test](https://github.com/Shilo/multi-server-test) - uses
  PackRat for downloadable world/content pack loading.

## License

PackRat is released under the MIT License. See [LICENSE](LICENSE).
