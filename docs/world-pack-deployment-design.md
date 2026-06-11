# World Pack Deployment Design

Date: 2026-06-11

## Goal

Deploy per-world PCK files without corrupting live gameplay, without requiring a
full client update, and without forcing the master server to restart just to see
new world pack metadata.

This document is only about the server-side deployment shape for
`multi-server-test` / VirtuCade-style world packs. Client download/cache behavior
is handled separately by PackRat.

## Core Rule

Never upload over the live PCK file in place.

An in-place upload can expose a partially written file to:

- the static file server;
- the master server reading file metadata;
- a client downloading during the upload;
- a world server started during the upload.

Use a staging file first, verify it, then publish it with a final rename or
pointer flip.

## Recommended Production Design

Use immutable pack files plus a tiny current pointer per world.

```text
deploy/
  world_packs/
    hub/
      hub-2026-06-11-001.pck
      hub-2026-06-11-002.pck
      current.json

    arena/
      arena-2026-06-11-001.pck
      current.json
```

Example `current.json`:

```json
{
  "file": "hub-2026-06-11-002.pck"
}
```

The pointer is intentionally tiny. It is not a full content manifest. The master
can read the pointer, then stat the referenced PCK file to get the size and
modified time it sends to the client.

## Deploy Flow

For a new hub build:

```text
1. Build hub PCK locally or in CI.
2. Upload to:
   deploy/world_packs/hub/hub-2026-06-11-003.pck.uploading
3. Verify the uploaded file:
   - file exists;
   - file size is nonzero;
   - optional: open/list it with a pack tool or start a canary world server.
4. Rename:
   hub-2026-06-11-003.pck.uploading
   -> hub-2026-06-11-003.pck
5. Write a new pointer file:
   current.json.tmp
6. Rename:
   current.json.tmp
   -> current.json
7. New transfers use the new file.
8. Existing world servers continue using their started version until drained or restarted.
```

The important property is that clients never download `.uploading`, and the
current pointer only changes after the full PCK exists.

## Why Not Just Replace `hub.pck`?

Stable names are simpler:

```text
world_packs/hub.pck
```

They can work if the deploy flow is careful:

```text
hub.pck.uploading -> hub.pck
```

However, immutable filenames are safer for live games:

- existing clients can finish downloading the old file;
- static servers and CDNs do not have to handle overwritten bytes;
- world servers can report exactly which pack file they started with;
- rollback is changing `current.json` back to an older file;
- stale Godot-mounted client packs are easier to reason about because the local
  cache path can stay versioned.

If we insist on stable server filenames for MVP, the minimum safe rule is still:
upload `hub.pck.uploading`, then publish with a rename. Never stream bytes into
the live `hub.pck`.

## Master Server Runtime Behavior

The master should not cache world pack metadata forever on startup.

Recommended behavior per world-transfer request:

```text
1. Resolve the current PCK file for the requested world.
2. Read filesystem metadata for that file:
   - size;
   - modified time;
   - file name or URL.
3. Return the world route and pack metadata to the client.
4. Client passes URL + expected metadata to PackRat.
5. PackRat uses a matching cached file or downloads the new file.
6. Only after the pack is ready should the master issue/finalize a join ticket.
```

Filesystem stat calls are expected to be cheap enough for normal transfer rates.
If profiling later shows a real issue, add a tiny metadata cache with a short TTL
or invalidation based on `current.json` modified time. Do not add that complexity
until benchmark data says it matters.

## World Server Runtime Behavior

World servers should treat their content version as fixed for their process
lifetime.

Recommended:

- when starting a world server, pass or resolve the current pack file;
- record the file name, size, and modified time in logs;
- do not hot-reload the world scene inside a running world process;
- drain/restart world servers to adopt a new pack version.

This avoids mixing old client resources, new server resources, and already-loaded
Godot resources in the same live instance.

## Local Testing Layout

For local testing, use the same shape under a local deploy directory:

```text
local_deploy/
  world_packs/
    hub/
      hub-dev-001.pck
      hub-dev-002.pck
      current.json
```

A local static file server can expose:

```text
http://127.0.0.1:19100/world_packs/hub/hub-dev-002.pck
```

The master can read:

```text
local_deploy/world_packs/hub/current.json
```

Then stat:

```text
local_deploy/world_packs/hub/hub-dev-002.pck
```

And return:

```json
{
  "world": "hub",
  "scene": "res://server/worlds/hub/hub.tscn",
  "pack": {
    "url": "http://127.0.0.1:19100/world_packs/hub/hub-dev-002.pck",
    "size": 14528,
    "modified_time": 1781152757
  }
}
```

## Client Cache Naming Notes

PackRat's cache ID is not the server filename. It is a client-side cache
namespace.

The useful meanings are:

- `id`: stable content identity, such as `hub`;
- remote filename: human-readable source filename, such as `hub.pck`;
- version token: a freshness-derived token from expected metadata or HTTP
  headers.

That can produce a local cache path like:

```text
user://pack_rat/hub/hub-752672d4f23a.pck
```

This can look redundant because both folder and file say `hub`. The folder is
the stable namespace. The suffix is the version. They solve different problems.

Why keep a version suffix locally?

- avoids overwriting a PCK path that Godot may already have mounted;
- lets PackRat keep the old mounted file around while mounting a new file;
- makes stale mount warnings and cleanup easier;
- supports remote URLs that all end in the same basename;
- supports rollback/debugging because the local filename identifies a specific
  cached revision.

For VirtuCade, if every world has a stable unique filename and expected metadata,
we may choose to simplify PackRat later. But stable filenames alone do not solve
the Godot mounted-pack lifetime problem. Replacing
`user://pack_rat/hub/hub.pck` in place is exactly the risky case.

## Stale Cache Cleanup

Versioned cache files can leave old files behind. That is acceptable for MVP as
a bounded operational concern, but it should be handled deliberately.

Recommended MVP cleanup:

- when a new version of the same cache key succeeds, remove the previous cached
  file if it is not the currently mounted file;
- expose explicit cleanup controls:
  - clear one world/id;
  - clear the full PackRat cache.

Later, if cache growth becomes a real issue:

- keep only the latest N files per id;
- remove files older than a configured age;
- remove files not referenced by `cache.json`;
- never delete the path currently mounted in this process.

## Recommended MVP Decision

Use immutable server PCK filenames plus a tiny `current.json` pointer.

Use size + modified time from filesystem metadata as the first freshness signal.
Do not add required SHA sidecars or full manifests yet.

Do not hot-patch running world servers. Publish new packs for new transfers,
then drain/restart world servers when they should adopt the new content.
