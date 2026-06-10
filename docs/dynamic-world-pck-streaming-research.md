# Dynamic World PCK Streaming Research

Date: 2026-06-10

This research note covers dynamic, per-world content delivery for the current
multi-server Godot spike:

```text
one exported Web client
one persistent master server
one temporary world server process per active mini-game/world
```

The goal is Roblox-like world travel without shipping every mini-game in the
initial Web client bundle. The client should start with only the shell, shared
runtime code, and the main/hub flow needed to connect to the master. When the
player enters a world, the client should download that world's resource pack,
mount it, then load the world scene.

## Research Inputs

Local code reviewed:

- `project.godot`
- `export_presets.cfg`
- `shared/main/main.gd`
- `shared/net/net_config.gd`
- `shared/net/master_endpoint.gd`
- `client/client.gd`
- `server/master/master.gd`
- `server/master/world_process_manager.gd`
- `server/world/world.gd`
- `server/worlds/*/*.tscn`
- `tools/export_all.ps1`
- `tools/run_smoke.ps1`

Godot documentation reviewed:

- [Exporting packs, patches, and mods](https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html)
- [ProjectSettings.load_resource_pack](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-method-load-resource-pack)
- [PCKPacker](https://docs.godotengine.org/en/stable/classes/class_pckpacker.html)
- [Runtime file loading and saving](https://docs.godotengine.org/en/stable/tutorials/io/runtime_file_loading_and_saving.html)
- [HTTPRequest](https://docs.godotengine.org/en/stable/classes/class_httprequest.html)
- [Making HTTP requests](https://docs.godotengine.org/en/stable/tutorials/networking/http_request_class.html)
- [ResourceLoader](https://docs.godotengine.org/en/stable/classes/class_resourceloader.html)
- [File paths in Godot projects](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)
- [Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [Exporting from the command line](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html#exporting)

Godot source reviewed:

- `C:/Programming_Files/Godot/godot-master/core/config/project_settings.cpp`
- `C:/Programming_Files/Godot/godot-master/core/io/file_access_pack.cpp`
- `C:/Programming_Files/Godot/godot-master/core/io/file_access_pack.h`
- `C:/Programming_Files/Godot/godot-master/core/io/file_access.cpp`
- `C:/Programming_Files/Godot/godot-master/platform/web/os_web.cpp`
- `C:/Programming_Files/Godot/godot-master/platform/web/js/engine/engine.js`
- `C:/Programming_Files/Godot/godot-master/platform/web/js/libs/library_godot_os.js`

## Current Implementation

The project currently uses one Godot project and chooses the runtime role from
feature tags plus command-line user arguments:

```text
client build, no server feature -> res://client/client.tscn
server build, no user args      -> res://server/master/master.tscn
server build, world key arg     -> res://server/world/world.tscn
```

The master server listens on `MASTER_PORT`, owns `WorldProcessManager`, starts
world processes on demand with `OS.create_instance()`, and expects a launch token
back from each world before registering it.

Each world server loads one keyed world scene and listens on that world's socket.
The client keeps the master/chat connection alive while replacing the active
world socket during travel.

Before this spike, the world location was hard-coded through `NET_CONFIG`.
The implementation spike moved that root to:

```gdscript
const WORLD_SCENE_DIR := "res://server/worlds"
```

`world_keys()` now combines the manifest with local world folders, and
`world_port()` still derives ports from the sorted world list. Exported clients
should rely on the master-provided route/catalog data instead of local world
folder discovery.

Before this spike, the client also loaded the world scene before connecting to
the world server with a ticket that had already been issued:

```gdscript
_load_world_scene(world_key)
var ok := await _connect_api(world_api, endpoint["url"], "world-%s" % world_key)
```

That is the correct insertion point for dynamic content:

```text
ensure world pack installed -> load world scene -> connect world socket
```

## Recommendation

Use ahead-of-time exported per-world PCKs, downloaded by the Web client and
mounted at runtime.

Do not build PCKs dynamically inside the running production server. `PCKPacker`
exists, but it is a low-level pack writer. It does not replace the editor export
pipeline: it does not import source assets, produce platform-specific imported
formats, apply export remaps, or validate a complete Godot content dependency
graph. For shippable mini-games, use Godot's export pipeline and automate it.

The recommended client-side flow is:

```text
receive world route/pack metadata
check local cache manifest
download PCK to user:// when missing or stale
verify size/hash/version
ProjectSettings.load_resource_pack("user://world_packs/<key>-<hash>.pck", true)
load("res://server/worlds/<key>/<key>.tscn")
connect to the world server with a fresh join ticket
```

## Runtime PCK Facts

`ProjectSettings.load_resource_pack(pack, replace_files := true, offset := 0)`
mounts a `.pck` or `.zip` into the virtual `res://` resource filesystem and
returns `true` on success.

Important behavior:

- The pack path is a local Godot-readable file path, not an HTTP URL.
- Download first, then call `load_resource_pack()` on the downloaded file.
- Pack contents are loaded by their internal `res://` paths after mounting.
- If a mounted pack contains a file with the same internal path as an existing
  resource, the pack wins when `replace_files` is `true`.
- If `replace_files` is `false`, already registered paths remain mapped to the
  old file.
- `DirAccess` should not be used as the source of truth after dynamic pack
  mounting; keep authoritative manifests and load exact paths.
- Resource cache matters. Avoid loading or preloading a world scene before its
  pack is mounted. For replacement/patch testing, use explicit
  `ResourceLoader` cache modes or restart the affected content.

Godot source confirms this path:

```text
ProjectSettings.load_resource_pack()
  -> ProjectSettings::_load_resource_pack()
  -> PackedData::add_pack()
  -> PackedSourcePCK::try_open_pack()
  -> PackedData::add_path()
```

Regular `FileAccess` reads check `PackedData` first for non-write resource
paths, so mounted PCK files become normal resource inputs for `load()` and
`ResourceLoader.load()`.

## Web Constraints

The Web client should download world PCKs with `HTTPRequest`.

Use `download_file` so large PCKs are written to disk instead of held entirely
in memory:

```gdscript
var request := HTTPRequest.new()
request.download_file = "user://world_packs/hub-<sha>.pck"
request.timeout = 0.0
request.accept_gzip = false
request.request(pack_url)
```

`user://` is the correct storage location because exported `res://` content is
read-only. On HTML5 exports, `user://` maps to an IndexedDB-backed virtual
filesystem. That storage is useful but not guaranteed permanent:

- private/incognito mode can prevent persistence;
- iframe/third-party contexts can interfere with storage;
- browsers can evict cached data under storage pressure;
- `OS.is_userfs_persistent()` helps but can report false positives.

Therefore, downloaded PCKs are a cache, not durable truth. The master or static
asset host must always be able to provide a fresh copy.

Production Web hosting must also account for:

- HTTPS secure context for modern browser behavior;
- same-origin or correct CORS headers for PCK downloads;
- correct MIME types for main Web export files;
- server-side gzip/Brotli for `.wasm` and `.pck` files where appropriate;
- `wss://` world/master WebSocket URLs if the page is served over HTTPS.

Godot 4 C# projects currently cannot be exported to Web. This project is
GDScript, which is the straightforward path for Web PCK loading.

## Recommended Resource Layout

Use `res://server/worlds/` for the current spike.

This is a developer-facing convention, not a player-facing runtime detail. In
this project, `server/` and `client/` mean "source that is bundled into this
executable or artifact." That is where the concern ends. Godot does not care
whether the mounted client scene path is `res://worlds/hub` or
`res://server/worlds/hub`; after a PCK is mounted, either path is just a virtual
`res://` resource path. The important project rule is that export automation
must know which folders go into which artifacts.

The working convention is:

```text
res://shared/main/          bootstrap scene and role selection
res://shared/net/           shared endpoint/config code
res://shared/world/         base world runtime shared by client and server
res://shared/player/        shared player runtime
res://client/               client shell and UI
res://server/               server export source
res://server/worlds/<key>/  mini-game source, included in server export and
                            packed separately for client download
res://addons/               all exports when needed
```

`res://shared/world/` should remain in the base client export if downloaded
world scenes instance shared base scenes, portals, spawn helpers, or common
actors from it. The per-world PCK should contain only the standalone mini-game
folder and any dependencies not already in the base client.

If a world needs unique client-safe scripts, art, scenes, audio, shaders, or
resources, keep them under:

```text
res://server/worlds/<world_key>/
```

The tradeoff is semantic: a Web client will load a mounted resource path that
begins with `res://server/`. That is acceptable for this spike because the path
is not user-facing. The export boundary is what matters: `server/worlds/<key>/`
is bundled into the server export and also emitted as a public client-downloadable
world pack; other `server/` folders are bundled only into the server executable.

## Export And Build Workflow

The current export presets use `export_filter="all_resources"` for both client
and server. That must change.

Recommended export outputs:

```text
builds/web/client/index.html
builds/web/client/client.js
builds/web/client/client.wasm
builds/web/client/client.pck        # base client only; no worlds

builds/server/server.exe            # or Linux server binary/PCK; includes all worlds

builds/world_packs/hub.pck
builds/world_packs/left_world.pck
builds/world_packs/right_world.pck
builds/world_packs/top_world.pck
builds/world_packs/worlds.json
```

Suggested presets:

```text
Web Client Base
  includes: client/**, shared/main/**, shared/net/**, shared/world/**,
            shared/player/**, icon/project basics
  excludes: server/**

Server
  includes: server/**, shared/**
  dedicated server export

World Pack <key>
  includes: server/worlds/<key>/** plus required imported dependencies
  excludes: other server-only paths under server/**
```

Godot supports command-line PCK export with `--export-pack`. For per-world PCKs,
there are two practical automation options:

1. Maintain one export preset per world. This is simple and explicit for the
   first batch of worlds.
2. Generate temporary export presets or temporarily rewrite include/exclude
   filters in a build script, then run `--export-pack` for each world. This is
   better once world count grows.

The build script should compute a manifest after each PCK is written:

```json
{
  "schema_version": 1,
  "client_build": "2026.06.10-dev",
  "engine_version": "4.6",
  "worlds": {
    "hub": {
      "display_name": "Hub",
      "scene": "res://server/worlds/hub/hub.tscn",
      "pack_url": "https://example.com/world_packs/hub-4b1f.pck",
      "pack_sha256": "4b1f...",
      "pack_size": 1234567,
      "version": "2026.06.10.1",
      "compat": {
        "min_client_build": "2026.06.10-dev",
        "engine_major": 4,
        "engine_minor": 6
      }
    }
  }
}
```

For local testing, `pack_url` can be an HTTP URL served by a tiny local static
server. For production, it should be served by nginx/Caddy/Apache or object
storage/CDN in front of the VPS.

## Runtime Manifest Contract

World identity should no longer come from local resource scanning. The master
should own the world catalog used for routing and validation.

Move `NET_CONFIG.world_keys()` away from `ResourceLoader.list_directory()` and
toward one of these:

```text
authoritative server-side world manifest
static JSON generated at build time and loaded by the server
master-owned dictionary produced by the build/deploy pipeline
```

Endpoint data sent to the client should include asset metadata:

```gdscript
{
  "key": "hub",
  "name": "Hub",
  "url": "wss://game.example.com/worlds/hub",
  "port": 19081,
  "scene": "res://server/worlds/hub/hub.tscn",
  "pack": {
    "url": "https://game.example.com/world_packs/hub-4b1f.pck",
    "sha256": "4b1f...",
    "size": 1234567,
    "version": "2026.06.10.1"
  }
}
```

This avoids three current problems:

- a Web client without local worlds cannot discover valid world keys;
- local client resource availability should not determine server port mapping;
- route approval currently lacks enough information to install the target world.

## Transfer Flow Change

The current flow issues a join ticket before the client loads and connects to
the world. With dynamic PCK downloads, that can race against large downloads.

Recommended two-phase transfer:

```text
1. Client asks current world to use portal.
2. Current world validates portal/player proximity.
3. Current world asks master to prepare transfer.
4. Master starts target world if needed.
5. Master replies with target endpoint plus pack metadata, but no final join
   ticket yet, or with a long-lived asset-prep reservation.
6. Client downloads/verifies/mounts target world pack.
7. Client tells master "assets ready for <world_key>".
8. Master issues fresh short-lived one-use join ticket.
9. Client disconnects old world socket, loads target scene, connects target
   world socket, and presents ticket.
```

This keeps short-lived join tickets short-lived while still allowing slow or
first-time PCK downloads.

If a quicker MVP is desired, keep the current join ticket behavior but extend
the pending join reservation while downloading. That is workable for local
testing, but the two-phase shape is cleaner for production.

## Client Cache Model

Use a client cache manifest in `user://world_packs/cache.json`:

```json
{
  "schema_version": 1,
  "packs": {
    "hub": {
      "version": "2026.06.10.1",
      "sha256": "4b1f...",
      "size": 1234567,
      "path": "user://world_packs/hub-4b1f.pck",
      "mounted": true,
      "last_used_unix": 1781130000
    }
  }
}
```

Install logic:

```text
if cache has same sha256 and file exists:
  mount cached pack
else:
  download to temporary user://world_packs/<key>.download
  verify size and sha256
  rename/copy to user://world_packs/<key>-<sha>.pck
  update cache manifest
  mount pack
```

Use hash-based filenames so older mounted packs remain distinguishable from new
versions. Godot does not provide an unload operation for mounted packs, so avoid
trying to replace an active world in place. Prefer:

- unload/free current world scene;
- download/mount the new hash-named PCK;
- load the new scene path after mounting;
- rely on browser/page restart to fully clear old mounted pack mappings if a
  same-path replacement becomes confusing during development.

For production, world updates should usually happen between visits, not while a
player is inside the same world.

## Local Testing Plan

Local testing should prove the full Web path, not just native editor behavior.

Suggested flow:

```text
1. Export Web Client Base without worlds.
2. Export Server with worlds.
3. Export per-world PCKs.
4. Generate worlds.json.
5. Start local HTTP static server for Web export and world_packs/.
6. Start local master/server process.
7. Open Web client in browser.
8. Confirm first world downloads, mounts, loads, and connects.
9. Refresh browser and confirm cached pack mounts without redownload.
10. Change a world, rebuild only that PCK, update manifest, confirm redownload.
```

The current smoke test discovers local `server/worlds` folders directly. It will
need a Web/client-pack smoke path that validates:

- base client export does not contain world scenes;
- world route includes pack metadata;
- download progress reaches completion;
- hash mismatch rejects a pack;
- cached matching hash skips network download;
- transfer after slow download gets a fresh valid join ticket.

## Production VPS Shape

For a simple VPS deployment:

```text
nginx or Caddy
  /client/       -> Web export
  /world_packs/  -> static PCKs + worlds.json
  /ws/master     -> reverse proxy to master WebSocket
  /ws/world/...  -> reverse proxy or direct world socket routing

Godot master server
  owns world manifest
  starts/stops world server processes
  issues world pack metadata and join tickets

Godot world server processes
  load local server-side world scenes
  register/heartbeat with master
```

If serving the page over HTTPS, use `wss://` for WebSocket endpoints. Browsers
will reject mixed-content patterns where an HTTPS page opens insecure `ws://`
connections.

The server export can keep all worlds embedded or keep world PCKs/files next to
the server, depending on deployment preference. The important part is that the
client-facing packs are separate artifacts with public, hash-addressed URLs.

## Security And Compatibility Notes

- Do not include server-only scripts, launch-token handling, database code, or
  service credentials in downloadable world packs.
- Treat all client pack metadata as untrusted from a security perspective; the
  server still validates travel, tickets, identity, and gameplay authority.
- Use HTTPS and same-origin hosting where possible to avoid CORS complexity.
- Hash world PCKs and reject mismatches before mounting.
- Keep pack internal paths namespaced under `res://server/worlds/<key>/` to
  avoid accidental override behavior.
- Use `replace_files=true` only when intentional. Namespacing should make
  replacement mostly irrelevant for normal world packs.
- Do not rely on pack encryption as a security boundary for gameplay secrets.
  Anything the Web client can load should be considered client-visible.
- Godot's PCK loader rejects packs made by a newer major/minor engine version
  than the runtime, so build packs with the same Godot version as the client.

## Migration Steps

Recommended implementation order:

1. Move `shared/worlds/<key>/` to `server/worlds/<key>/` and update scene paths. Done in the first implementation spike.
2. Keep `shared/world/` and `shared/player/` in the base client/server export.
3. Replace `NET_CONFIG.world_keys()` filesystem discovery with manifest-driven
   world keys.
4. Stop deriving ports from the client-visible local resource list. Let the
   master manifest or process manager own ports.
5. Add `pack` metadata to route and transfer endpoint dictionaries.
6. Add a client `WorldPackManager` responsible for cache manifest, download,
   hash verification, and `load_resource_pack()`.
7. Change `_connect_world()` to await `WorldPackManager.ensure_world_installed()`
   before `_load_world_scene()`.
8. Split transfer into asset-prep and fresh-ticket phases.
9. Add export automation for base Web client, server, per-world PCKs, and
   generated `worlds.json`.
10. Add smoke coverage for missing/stale/hash-mismatched world packs.

## Open Questions

- Should the hub world be included in the base Web client for faster first load,
  or should every world including hub be dynamically downloaded? The purest
  architecture downloads every world; the friendliest first-user experience may
  embed a minimal lobby/hub.
- Should world PCKs be one file per world, or split into world-code plus large
  optional art/audio packs later? One PCK per world is the right first step.
- Should old cached packs be garbage-collected by count, total size, or
  last-used time? Start with hash-based cache correctness, then add size limits.
- Should the master serve pack metadata directly, or should it only return a
  versioned manifest URL? Direct metadata is simpler now.

## Bottom Line

The design is viable with Godot's existing runtime pack system. The critical
changes are not in the PCK API itself; they are in project organization,
manifest ownership, export automation, and transfer timing.

Build PCKs ahead of time, serve them as static artifacts, cache them in
`user://`, mount them into `res://`, and make the master authoritative for world
identity and fresh join tickets.
