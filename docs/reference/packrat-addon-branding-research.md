# PackRat Addon + Branding Handoff

## Project Name

**PackRat**

## Core Concept

PackRat is a lightweight Godot addon for runtime downloadable content packs.

The goal is to make DLC/content-pack loading simple, universal, and friendly. It should not be VirtuCade-specific, even though VirtuCade world packs are the first target use case.

PackRat should handle the boring runtime work:

* fetch remote content
* validate it
* cache it
* mount/install it
* return a useful result object

The game should still decide what scene, resource, file, or world to load after the pack is ready.

## Brand Description

**PackRat is your helpful little companion to fetch, stash, and mount your cheesy content.**

Short tagline:

**Fetch. Stash. Mount.**

Longer description:

**PackRat is a lightweight Godot addon that downloads, verifies, caches, and mounts DLC/content packs at runtime. Use it for worlds, mods, patches, skins, episodes, asset bundles, or standalone downloadable files.**

## Why “PackRat”

The name works as a joke and a product metaphor:

* “Pack” = content pack, PCK file, DLC pack
* “Rat” = friendly little mascot
* “Pack rat” slang = someone who hoards/stashes things
* Addon behavior = downloads and stashes content in cache

The mascot/icon should lean into this without becoming too detailed.

## Addon Goal

PackRat should expose a simple API that hides cache paths, download paths, validation, and mount details.

Preferred API shape:

```gdscript
var result := await PackRat.load_resource_pack("hub")
```

Descriptor mode should also be first-class:

```gdscript
var result := await PackRat.load_resource_pack({
	"id": "hub",
	"url": "https://example.com/world_packs/hub.pck",
	"sha256": "...",
	"size": 1234567,
	"version": "2026.06.10.1",
	"install": "resource_pack",
	"replace_files": false,
	"entry": "res://server/worlds/hub/hub.tscn"
})
```

Direct URL mode can exist for demos/tests:

```gdscript
var result := await PackRat.load_resource_pack("https://example.com/dlc/hub.pck", {
	"id": "hub",
	"sha256_url": "https://example.com/dlc/hub.pck.sha256",
	"install": "resource_pack"
})
```

## Core API Principle

The public mental model should be:

```text
source -> cache -> validate -> install/mount -> result
```

Use `load_resource_pack()` as the primary verb.

Avoid names like `ensure_*` because they hide what may happen internally: cache lookup, freshness check, download, validation, install, pack mount, or failure.

## Runtime Behavior

`PackRat.load_resource_pack()` should:

1. Resolve the source:

   * configured ID
   * server-provided descriptor
   * direct URL
   * future provider, such as GitHub Release

2. Infer defaults:

   * cache dir: `user://pack_rat`
   * install mode: `resource_pack` for `.pck`/`.zip`
   * `replace_files=false`
   * cache key from ID/filename

3. Find integrity:

   * inline `sha256`
   * hash in immutable filename
   * `.sha256` sidecar
   * provider digest
   * unsafe/dev mode only if no hash exists

4. Check cache:

   * cache record exists
   * local file exists
   * hash/version token matches

5. Download if missing/stale:

   * write to `.part`
   * never overwrite stable cache directly

6. Validate:

   * SHA-256 required for production remote packs
   * optional file size check

7. Commit:

   * move `.part` to stable hash-addressed path
   * update `cache.json`

8. Mount/install:

   * use `ProjectSettings.load_resource_pack(local_path, replace_files)`

9. Return a structured result.

## Cache Strategy

Default cache location:

```text
user://pack_rat/cache.json
user://pack_rat/<id>/<sha256>.pck
user://pack_rat/tmp/<id>.pck.part
```

Do not cache downloads under `res://addons/pack_rat/`.

The addon code can live under:

```text
res://addons/pack_rat/
```

But downloaded runtime content belongs in:

```text
user://pack_rat/
```

## Result Object

Use a result object, not a boolean.

Suggested shape:

```gdscript
class_name PackRatResult
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
var error: String
var response_code: int
```

## Runtime Service Design

Use a static facade plus a service node.

Suggested structure:

```gdscript
class_name PackRat extends RefCounted

static func load_resource_pack(content: Variant, options: Dictionary = {}) -> PackRatResult:
	var request := load_resource_pack_async(content, options)
	await request.completed
	return request.result
```

A `PackRatRequest` handle should expose:

* `progress_changed`
* `completed`
* `canceled`
* `cancel()`
* in-flight deduplication
* test injection

Concurrent calls for the same content/cache key should share the same in-flight request.

## No-Manifest Philosophy

Avoid requiring a full catalog manifest for the basic case.

Good no-manifest layouts:

```text
hub.pck
hub.pck.sha256
arena.pck
arena.pck.sha256
```

or immutable hash-named files:

```text
hub-39882095cc2b59579a7c2d2179fc881808848a25febd1d8beffce8812ef35186.pck
arena-a713d9....pck
```

A `.sha256` sidecar is not a manifest. It is just an integrity/freshness token.

A manifest becomes useful later for:

* content discovery
* new packs appearing without a client update
* compatibility ranges
* channels
* dependencies
* rollback
* display name/description
* server-controlled catalogs

## VirtuCade Integration

For VirtuCade, the master server should own world routing and pack metadata.

Recommended flow:

```text
1. Client asks to travel to a world.
2. Master validates route/travel.
3. Master starts target world server if needed.
4. Master returns:
   - world key
   - world websocket URL
   - scene path
   - pack URL
   - pack SHA-256
   - pack size
   - pack version
5. Client calls PackRat.load_resource_pack(route.pack).
6. Client reports assets ready.
7. Master issues fresh short-lived join ticket.
8. Client loads the scene and connects to the world server.
```

Use a two-phase flow so a short-lived join ticket does not expire while the client downloads a large first-time PCK.

## Hosting Recommendation

Recommended first production setup:

```text
Private GitHub repo
  -> GitHub Actions builds artifacts
  -> CI exports client/server/world packs
  -> CI computes SHA-256 values
  -> CI generates worlds.json
  -> CI deploys static files to Hetzner VPS
  -> Caddy/nginx serves /client and /world_packs
  -> optional CDN later
  -> Godot master server reads generated worlds.json
```

This is the best fit because:

* source remains private
* builds are automated
* PCKs are served as simple static files
* no public client needs GitHub auth tokens
* same VPS can serve Web client, world packs, and WebSocket reverse proxy
* CDN/object storage can be added later

Avoid having the master server build PCKs on startup. Use Godot export/CI to generate PCKs ahead of time.

## CI/CD Shape

Initial GitHub Actions pipeline:

```text
on push/tag/manual:
  1. Install/use pinned Godot version.
  2. Export Web Client Base without worlds.
  3. Export dedicated server build with worlds.
  4. Export one PCK per world.
  5. Compute SHA-256 and file size for each PCK.
  6. Rename PCKs to hash-addressed filenames.
  7. Generate worlds.json.
  8. Run smoke checks.
  9. Deploy:
     - /client/*
     - /world_packs/*
     - worlds.json
  10. Restart/reload master if needed.
```

## MVP Scope

Start with:

```text
Addon:
  res://addons/pack_rat/
  PackRat.load_resource_pack()
  HTTP source only
  .pck resource-pack installer
  sha256 / sha256_url / hash-in-filename
  user://pack_rat cache
  temporary .part downloads
  in-flight load dedupe
  replace_files=false by default

VirtuCade:
  master sends pack descriptor
  CI exports hub.pck first
  VPS serves /world_packs/hub-<sha>.pck
  client calls PackRat.load_resource_pack(route.pack)
  client loads route.scene
```

Defer:

```text
GitHub Release provider
GitHub Pages-specific provider
ZIP extraction
catalog discovery UI
editor plugin
cache eviction policy
dependency packs
signed URLs
```

## Icon Direction

The PackRat icon is a cute minimal mascot logo that combines:

```text
rat/mouse face + package/box shape
```

The icon should communicate:

* rat = friendly helper
* package = downloadable content pack
* stash/cache = saves downloaded content
* mount/load = makes content available

The visual pun is:

```text
a pack rat that is also a content pack
```

## Current Icon Description

The current icon is a front-facing rounded square box face with mouse/rat features.

Main elements:

* rounded square package/box face
* large circular mouse ears
* top-center tape strip with jagged bottom edge
* large round eyes
* small rounded nose
* cute rounded smile/mouth
* three whiskers on each side
* whiskers should be fully outside the box face
* whiskers should connect directly to the dark outer border
* warm tan/cream fill
* dark brown outline/details
* flat SVG/vector style
* no text
* no paws
* no body
* no hat
* no extra props

## Icon Style Rules

Keep the icon:

* simple
* scalable
* readable at 16x16, 32x32, 64x64
* two-tone or very limited color
* thick rounded strokes
* friendly and cute
* centered and symmetrical
* suitable for Godot addon/plugin UI

Avoid:

* full body
* paws
* action poses
* hats
* realistic rat details
* detailed fur
* tiny labels like “PCK”
* too many package folds
* whiskers inside the face area

## Current Color Direction

Current color palette:

```text
Dark outline/details: #5B3518
Warm tan fill:        #F4C996
White highlights:     #FFFFFF
```

The current brown/cream direction was chosen because brown is a standard friendly cartoon mouse color. It feels relatable, warm, and playful.

Other possible future palettes:

```text
Classic mouse:
  dark charcoal + pale gray

Friendly sidekick:
  slate blue + pale blue-gray

Heroic white mouse:
  cobalt blue + white

Modern software:
  teal + mint

Playful addon:
  purple + lavender
```

## SVG Notes

The SVG should remain editable and cleanly organized.

Suggested groups/layers:

```text
ears
head / box face
top package flaps
tape strip
whiskers
eyes
eye highlights
nose
mouth
```

Important current fix rule:

```text
Whiskers must be outside the box face only.
They should attach to the dark outer border.
They should not draw over the tan fill area.
```

## Current Files

Current colored SVG:

```text
pack_rat_colored.svg
```

Suggested export names:

```text
pack_rat_icon.svg
pack_rat_icon_preview.png
pack_rat_logo.svg
pack_rat_mascot.svg
pack_rat_icon_monochrome.svg
```

## Next Recommended Design Work

1. Clean up the SVG paths manually.
2. Ensure whiskers are entirely outside the face fill.
3. Create light-mode and dark-mode variants.
4. Create a monochrome Godot editor icon.
5. Test at 16x16, 32x32, and 64x64.
6. Make a README hero version later with more personality, but keep the main icon minimal.

## Final Summary

PackRat is a universal Godot runtime content-pack addon. It should make downloading and mounting DLC/content packs feel like one simple operation:

```gdscript
var result := await PackRat.load_resource_pack("hub")
```

The mascot/icon should be a simple cute mouse-package hybrid: a helpful little pack rat that fetches, stashes, and mounts content for the game.
