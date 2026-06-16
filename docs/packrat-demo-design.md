# PackRat Demo Design Plan

Status: implemented design note.

Date: 2026-06-11

## Goal

Replace the current `examples/` command-line style scene with one polished,
WebGL-friendly demo that shows PackRat's real value:

- the base export is tiny and only contains the shell UI;
- meaningful scenes/content are absent from the initial export;
- at runtime, PackRat downloads, caches, mounts, and opens remote resource packs;
- users can see progress, cancel an in-flight download, retry, clear cache, and
  observe a fast cached reload;
- the demo uses at least two remote resource packs.

The implementation should rename `examples/` to `demo/` and make the main scene
`demo/demo.tscn`.

## Recommended Concept

Build a single app-style showcase called **PackRat Portal**.

The base project exports only a lightweight portal UI with two or three content
cards. Each card represents downloadable content. Clicking a card starts a
PackRat request, shows progress, allows cancellation, then opens the mounted
scene inside the portal.

This is better than a full game or a generic mod loader for the first demo:

- A pure game hides the API story behind gameplay.
- A mod loader implies catalogs, dependency solving, manifests, and provider
  systems that PackRat intentionally does not provide.
- A portal/gallery makes the product truth obvious: "the shell is here, the
  content arrives later."

## Demo Packs

Use two packs so the demo proves both PCK and ZIP behavior.

| Pack | File | Format | Entry path | Purpose |
| --- | --- | --- | --- | --- |
| Warehouse | `packrat-demo-warehouse.pck` | PCK | `res://demo/packs/warehouse/main.tscn` | A playful physics scene using simple boxes based on the PackRat icon palette. |
| Gallery | `packrat-demo-gallery.zip` | ZIP | `res://demo/packs/gallery/main.tscn` | A UI/content scene with bulky placeholder assets to show app/content-pack use. |

The pack source scenes live under `res://demo/packs/...` so they are visible and
editable in Godot. The base Web export excludes `demo/packs/*`, and the
downloaded PCK/ZIP mounts those same paths back at runtime.

No dedicated artwork is required. Use simple Godot UI, baked scene nodes,
placeholder assets, and the existing PackRat icon palette.

Target payload sizes should be big enough to avoid instant-loading theater:

- Warehouse PCK: roughly 8-12 MiB.
- Gallery ZIP: roughly 12-20 MiB.

Keep bulky placeholder assets inside the demo pack source folders so the export
step packages normal editor-authored content. The UI should also keep the
loading state readable with a brief completion transition, because very fast
connections can still download these sizes quickly.

## User Experience

The demo should open directly to the portal.

Each card should show:

- pack name;
- format, PCK or ZIP;
- source URL type, such as GitHub Release or GitHub Pages mirror;
- current state: not loaded, downloading, mounted, cache hit, failed, canceled;
- progress bar with downloaded bytes and total bytes when known;
- buttons for load, cancel, open, and clear cache.

When a pack finishes:

- show `PackRatResult.status`;
- show whether it came from cache;
- show the local cached path;
- show warnings if present;
- load the entry scene with `result.load_entry_scene()` into an in-app preview
  area or use `result.change_scene_to_entry()` for a full scene transition mode.

The first load should feel like a real download. A repeated load should be
noticeably fast, proving cache behavior.

The clear-cache button should be labeled honestly, for example
`Clear disk cache`. Already mounted packs remain mounted until the process exits
because Godot does not expose per-pack unload. In WebGL, a true fresh-load demo
after clearing cache should be demonstrated by reloading the page.

## PackRat API Surface To Showcase

The demo should intentionally exercise the public API:

```gdscript
var options: PackRatOptions = PackRatOptions.new()
options.id = "warehouse"
options.entry_path = "res://demo/packs/warehouse/main.tscn"
options.expected_size = 12582912

var request: PackRatRequest = PackRat.load_resource_pack_async(url, options)
request.progress_changed.connect(_on_pack_progress_changed)
request.completed.connect(_on_pack_completed)

# Optional cancel button:
request.cancel()
```

Also include small, visible usage of:

- `PackRat.github_release_url(owner, repo, filename, tag)`;
- `PackRat.join_url(base_url, path)`;
- `PackRat.clear_cached_resource_pack(id_or_url, options)`;
- `PackRatResult.load_entry_scene()`;
- `PackRatResult.change_scene_to_entry()`, possibly as an alternate "Open full
  scene" path.

For the WebGL default path, bake `expected_size` and an exported content version
token into the demo catalog after CI builds each pack. Expected size lets PackRat
avoid a HEAD freshness request and keeps the Web path less dependent on
host-specific exposed headers. The content version token must be included in
both the demo URL query and demo cache ID so same-size pack updates cannot reuse
stale browser HTTP cache entries or stale PackRat cache records. If the build can
also provide a host-comparable stable modified time, bake `expected_modified_time`
too.

Do not add new PackRat runtime APIs just for the demo unless implementation
proves the existing public API is awkward.

## Hosting Decision

GitHub Releases should be the canonical artifact location because release assets
are easy for users to inspect and download.

However, the WebGL demo should not assume GitHub Release URLs are a reliable
browser runtime CDN until a real browser smoke test proves it. GitHub release
asset URLs redirect through GitHub-controlled asset hosts, and CORS headers are
not under this project's control.

Recommended first release shape:

1. Build the base Web demo.
2. Build `packrat-demo-warehouse.pck`.
3. Build `packrat-demo-gallery.zip`.
4. Upload the packs to a GitHub Release.
5. Mirror the same packs to GitHub Pages beside the Web demo.
6. Resolve the Web demo's default pack URLs against the current page's
   same-origin `packs/` folder.
7. Include a toggle or code path that demonstrates `PackRat.github_release_url()`
   for native/editor users, or after a browser smoke confirms release URLs work.

This keeps the demo honest: GitHub Releases are used, but WebGL users get the
most reliable browser path.

Decision: the WebGL demo should default to same-origin pack URLs resolved from
the current browser page.
The UI can still show the GitHub Release asset as the canonical artifact/source
link, and native/editor examples can exercise `PackRat.github_release_url()`.
Do not default browser users to GitHub Release asset URLs unless a real browser
smoke test proves they work reliably.

## WebGL Constraints

Godot Web builds use browser networking rules. Cross-origin pack downloads need
CORS headers. Browser storage can also evict `user://`, so the demo must treat
PackRat cache as a performance cache, not durable truth.

For GitHub Pages same-origin hosting, CORS is less painful because the Web demo
and packs can live under the same site origin. GitHub Pages also does not let
this repository set custom response headers, so the default demo path should not
depend on custom CORS or cache headers.

Useful custom CDN/static-host headers:

```http
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, HEAD, OPTIONS
Access-Control-Expose-Headers: ETag, Last-Modified, Content-Length, Content-Type
Content-Type: application/octet-stream
```

For immutable versioned packs, a CDN/static host can use:

```http
Cache-Control: public, max-age=31536000, immutable
```

References:

- [Godot exporting PCK/ZIP packs](https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html)
- [ProjectSettings.load_resource_pack](https://docs.godotengine.org/en/stable/classes/class_projectsettings.html#class-projectsettings-method-load-resource-pack)
- [Godot Web export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [Godot command-line export](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)
- [GitHub release asset links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [gh release upload](https://cli.github.com/manual/gh_release_upload)
- [MDN Access-Control-Expose-Headers](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Expose-Headers)

## Proposed Files

```text
demo/
  demo.tscn
  demo.gd
  demo_card.tscn
  demo_card.gd
  demo_catalog.gd
  demo_pack.gd

tools/
  demo_pack_exporter.gd

.github/workflows/
  demo.yml
```

Demo pack source scenes are committed under `demo/packs/` and hidden from the
main Web export with `exclude_filter`. The exporter only packages those
editor-authored files into PCK/ZIP files. The priority is one good demo, not a
mini framework.

Local exported packs go in `build/packs/`. Exported outputs under `build/` are
hidden from Godot with subfolder `.gdignore` files, while the editable DLC source
folders remain visible.

## Export And CI Plan

Add a committed `export_presets.cfg` with:

- one Web export preset for the base demo;
- one PCK pack preset for the warehouse pack;
- one ZIP pack preset for the gallery pack, if Godot's export preset workflow
  allows the desired output cleanly.

If ZIP export is awkward through presets, use a simple deterministic script to
create the ZIP from a prepared resource folder. The pack still must mount through
`ProjectSettings.load_resource_pack()` in tests and in the demo.

GitHub Actions workflow outline:

1. Trigger on tags and manual dispatch.
2. Install pinned Godot 4.6.x and matching export templates.
3. Import project assets headlessly.
4. Run PackRat smoke tests.
5. Export/build the two packs.
6. Compute pack sizes, and stable modified times if practical.
7. Write the exported demo catalog with URLs, entry paths, IDs, and expected
   metadata.
8. Export the base Web demo after the catalog is refreshed.
9. Upload build artifacts for debugging.
10. Create or update a GitHub Release.
11. Upload release assets:
   - `packrat-demo-web.zip`
   - `packrat-demo-warehouse.pck`
   - `packrat-demo-gallery.zip`
12. Deploy the Web demo and mirrored packs to GitHub Pages.

The workflow needs `permissions: contents: write` for release uploads and Pages
permissions for deployment.

## Testing Plan

Implementation should add automated coverage before the demo is considered done:

- native smoke: load both demo packs from a local HTTP server;
- native smoke: cancel a slowed request and verify `.part` cleanup;
- native smoke: repeated load reports cache hit and avoids extra GET;
- native smoke: `clear_cached_resource_pack()` removes future disk reuse;
- Web smoke: exported Web demo downloads and mounts both packs in a real browser;
- Web smoke: same-origin GitHub Pages pack URLs work;
- optional Web smoke: GitHub Release URLs work or are documented as editor/native
  only if CORS blocks them.

The Web smoke should be part of CI if practical. If CI browser setup is too slow
for first pass, keep a documented manual test checklist and add automation next.

## Non-Goals

Do not add these to the demo:

- client/server flow;
- authentication;
- mod manifests;
- catalogs fetched from a server;
- dependency resolution;
- provider plugins;
- dedicated custom artwork;
- resource-pack unload behavior;
- hot-update or same-path replacement demos.

These would make the showcase look like a different product than PackRat's MVP.

## Implementation Decisions

- default to GitHub Pages mirror URLs for WebGL reliability;
- show GitHub Release URLs as canonical artifact/source links rather than the
  browser default URL;
- use in-portal preview for the main path and one "Open full scene" button to
  demonstrate `change_scene_to_entry()`;
- target roughly 8-12 MiB for the PCK and 12-20 MiB for the ZIP so first loads
  are visibly remote content, while keeping the demo tolerable;
- keep bulky placeholder assets in the demo pack source folders so the exporter
  packages the same files a user would author in Godot.

## Open Questions For Implementation

- Should the demo replace the placeholder payload files with smaller real assets
  once dedicated artwork exists?
- Should CI include a real browser Web smoke immediately, or should the first
  implementation ship with a documented manual browser checklist and add CI
  browser automation next?
