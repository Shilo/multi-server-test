# VPS Server Redeploy Strategy

Date: 2026-06-16

## Goal

VirtuCade should support independently updating Web client files and world PCK
files, while keeping the gameplay server stable and secure. The static host can
hot-update downloadable files more freely than the VPS can hot-update live
server processes.

## Deployment Responsibility Split

```text
Static web host:
  website
  Web client export
  Web-targeted world PCK files
  browser/client download bandwidth

VPS/game host:
  master server
  SQLite/database
  world server processes
  gameplay networking bandwidth
```

The static host can redeploy individual PCK files as content changes. The VPS
has a harder problem because the master and world servers currently share the
same exported executable, and active players may be connected to running world
processes.

## Important Constraint

The current server export includes:

```text
master server
world server runner
all server/worlds/* scenes
shared gameplay scripts
database code
network/auth/travel code
```

That means a world source change can require a server rebuild, even if the
browser client only needs one updated PCK. The client-facing PCK and the
server-side world scene must remain logically compatible.

## Recommendation

Use two deploy lanes, but keep production promotion manual until the game has a
real maintenance/drain/reconnect implementation.

### 1. Static Host Lane

This lane can be mostly automatic for development environments, but production
should be manually promoted if the goal is "client, PCKs, and server are always
in sync." Automatically updating only the static host while the live server is
still old creates a version split:

```text
new Web client/PCKs
old master/world server executable
```

That split is fine only when the update is guaranteed content-compatible. For
production simplicity, assume it is not guaranteed.

Trigger examples:

```text
client/* changed          -> rebuild/deploy Web client
server/worlds/hub/*       -> rebuild/deploy hub.pck
server/worlds/top_world/* -> rebuild/deploy top_world.pck
shared/export config      -> rebuild/deploy Web client and all PCKs
removed world folder      -> remove stale world_packs/<world>.pck
```

This is safe because PackRat compares expected metadata before using a pack, and
cached clients redownload only when metadata changes.

### 2. VPS Gameplay Lane

This lane should be gated and graceful, not blindly automatic.

Trigger examples:

```text
server/master/* changed
server/world/* changed
server/worlds/* changed
shared/net/* changed
shared/player/* changed
database schema changed
export_presets.cfg/project.godot changed in server-relevant ways
```

The CI can build and test the new server artifact automatically, but promotion
to the live VPS should require a deploy step that can drain/restart safely.

## Current Production Decision

For the first production-ready VirtuCade path, prefer cold versioned deploys
over live hot updates.

This means:

```text
manual deploy trigger
  -> build/stage updated world PCKs while the old game stays live
  -> build/stage Web client while the old game stays live
  -> build/stage server artifact while the old game stays live
  -> verify/smoke the staged release
  -> enter maintenance / stop gameplay server safely
  -> deploy static host files
  -> deploy server artifact
  -> restart gameplay server
  -> leave maintenance
```

The ordering matters:

1. Build and verify all artifacts before stopping gameplay so a failed export
   does not create avoidable downtime.
2. Generate PCKs before the Web client so the client never points at missing or
   stale pack files.
3. Build the Web client before restarting the server so the browser-facing
   version can be published before the server accepts the new version.
4. Build and smoke the server artifact before maintenance so the final downtime
   window is only backup, deploy, restart, and validation.
5. Enter maintenance only for the final flip. During that window, stop new
   logins/travel, save active players, back up SQLite, deploy static files,
   deploy the server release, restart, then leave maintenance.

Do not shut the gameplay server down before export/build. That sounds simple,
but it turns a failed build into unnecessary downtime. The safe simplicity is:

```text
prepare everything first
then stop/restart once
```

This is less magical than hot updating, but it avoids mixed states:

```text
old client + new PCK
new client + old server
old server + new world scene
new server + missing PCK
```

Those mixed states are where most versioning and security bugs would live.

## Client/Server Version Gate

Every production connection should include a build/version token. The server
should reject incompatible clients before login/world travel.

Implemented first version token:

```text
application/config/version=<MAJOR.MINOR>
```

The exact token can later become a structured value:

```text
client_build_hash
server_build_hash
content_build_hash
protocol_version
```

The first implementation stays simple:

- Godot stores one visible project version in `application/config/version`.
- Client sends that version during master connection.
- Master compares it with its own version.
- If it differs, master rejects the connection with a clear reason.
- Web client shows a modal saying the game was updated and offers a reload.

Do not trust this version for security by itself. It is compatibility gating,
not authentication. Real user identity still needs authenticated sessions.

## Implemented Versioning Shape

Current project behavior:

```text
editor/local version = application/config/version
export/deploy version = application/config/version
```

`tools/project_version.gd` reads, sets, and bumps the project version through
Godot's `ProjectSettings`. Local exports do not bump versions; GitHub's manual
release workflow either sets an exact `MAJOR.MINOR` version or bumps the minor
version once, commits `project.godot`, and then exports every artifact from that
same version.

Runtime checks:

- Client sends `application/config/version` in `request_routes(...)`.
- Master rejects mismatched clients before sending routes.
- Web clients show a reload prompt and append `?v=<server_version>`.
- Export/deploy scripts patch Godot's generated Web shell so `index.js`,
  `index.wasm`, and `index.pck` are requested with the same build query.
- World servers send `application/config/version` during master registration.
- Master rejects stale world server registrations.

Current GitHub Actions release workflow:

```text
manual trigger
  -> set exact project version or bump minor once
  -> commit project.godot when the version changes
  -> export all artifacts with that version
  -> verify exports and world packs
  -> deploy Web client + Web world packs to GitHub Pages
  -> upload server artifact, native world packs, and Web world packs
  -> print VPS deploy reminder
```

The release workflow intentionally publishes every world pack with the Web
client. Partial pack deploys are deferred because this project's production
strategy is a cold, all-artifacts-in-sync release rather than live hot updates.

The VPS stop/upload/start step is intentionally not wired yet. It needs real
host details, a service/supervisor name, a release directory layout, and SQLite
backup/migration commands. Until those exist, uploading the server artifact is
safer than pretending the workflow can restart production.

## Web Reload And Cache Busting

For Web clients hosted on GitHub Pages, cache busting should be explicit.
GitHub Pages commonly serves static files with short cache lifetimes such as
`Cache-Control: max-age=600`, and GitHub Pages does not provide app-level
control over arbitrary response headers. That is usually fine, but it can still
leave users temporarily running an old `index.html` or old `.js/.pck` files.

Sources:

- [GitHub Pages caching discussion](https://github.com/orgs/community/discussions/11884)
- [MDN Cache-Control request header behavior](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control)

Recommended reload behavior:

```text
version mismatch
  -> show "Game updated" modal
  -> reload button navigates to current page with ?v=<server_version>
```

Example:

```text
https://shilo.github.io/multi-server-test/?v=<application/config/version>
```

This makes the browser treat the page URL as new. The export/deploy scripts
also patch Godot's generated Web shell so the same build query is used for
`index.js`, `index.pck`, `index.wasm`, and related loader-side files. Do not add
a service worker/PWA cache until the version/update story is already proven,
because service workers add another cache layer that can keep old clients
alive.

## Why Not Live-Hot-Reload PCKs?

Godot's public API supports mounting resource packs with
`ProjectSettings.load_resource_pack()`, but it does not provide a normal
public API for unmounting a pack and clearing every already-loaded resource in a
running process.

Godot source behavior:

- `ProjectSettings.load_resource_pack()` calls `PackedData::add_pack()`.
- Loaded packs can replace paths for future loads.
- Godot refreshes global class and UID caches after mounting.
- Already-loaded resources/scenes/scripts may still exist in memory.
- The docs warn that `DirAccess` will not show `res://` changes made after
  calling `load_resource_pack()`.

Therefore, "hot update" should mean:

```text
new transfers/processes use new content
```

not:

```text
mutate a running world process in place
```

For production stability, restart the process that owns the authoritative world
logic instead of trying to live-swap its resources.

## Safe VPS Deploy Shape

Use release directories:

```text
/opt/virtucade/releases/<git_sha>/
  server/
    server.exe or server binary
    server-side dependencies
  world_packs/
    native/client world packs if needed
  web/
    world_packs/
      Web-targeted world packs used by the server's default metadata path

/opt/virtucade/current -> /opt/virtucade/releases/<git_sha>
```

Never overwrite the currently running executable in place. Deploy a new release
directory, verify it, then move the `current` symlink or service config.

## Graceful Restart Model

The safest model for the current one-master architecture:

1. CI builds the new server artifact.
2. CI runs smoke tests.
3. Deploy uploads the artifact to a new VPS release directory.
4. Master enters maintenance/drain mode.
5. Master stops accepting new logins/travels.
6. Master saves all connected player state.
7. Master tells clients to reconnect after a short maintenance restart.
8. Master stops old world processes.
9. Systemd/supervisor starts the new master release.
10. Clients reconnect and resume from authenticated saved state.

This is not seamless, but it is stable and secure. For a 100-200 CCU game, a
short maintenance reconnect is safer than trying to live-swap the only master
process.

## Future Rolling World Restart Model

Later, if we want less downtime, the master can support per-world draining:

1. Mark one world as draining.
2. Stop sending new players to that world.
3. Let existing players leave naturally or move them to a safe hub.
4. Stop the old world process.
5. Start the new world process from the new release.
6. Clear draining state.

This requires the master to be able to launch worlds from a selected release
path. It also means old and new world server binaries may briefly coexist.

Do not add this until the simple full-master maintenance restart is proven.

## Reconnect And Security Requirements

Clients must not be trusted to decide who they are or where they resume.

Required production behavior:

- Client reconnects with an authenticated session token.
- Master validates the token server-side.
- Master loads the user's saved world and position from the database.
- Master validates that the target world still exists.
- Master issues a new TravelLease and then a fresh one-use join ticket.
- World servers accept only master-issued join tickets.

Never let the client send "I was user 42 in world hub" as trusted state after a
restart.

## Database Migration Requirements

Before live VPS promotion:

- Back up SQLite.
- Run migrations before starting the new master.
- Fail deployment if migrations fail.
- Avoid destructive schema changes without a tested rollback/recovery path.

For the current MVP, simple name-only login is not production auth. Real
VirtuCade needs authenticated sessions before public deployment.

## What Not To Do

Do not:

- Overwrite the running server executable in place.
- Auto-kill the master immediately after every world PCK update.
- Trust client-provided resume state.
- Deploy server updates without smoke tests.
- Run database migrations without backup.
- Try to unload/reload server PCKs in a long-running process as the primary
  server update mechanism.

Godot resource packs are best treated as process-lifetime mounts. For server
changes, restart the affected process or release, then let clients reconnect
through the master.

## Practical Next Step

For this project:

1. Configure the VPS release directory, systemd/supervisor service, SSH user,
   and backup path.
2. Add a manual workflow step that enters maintenance, backs up SQLite, stops
   the service, uploads the staged server artifact, restarts the service, and
   checks health.
3. Add real authenticated sessions before relying on reconnect/resume.
4. Validate GitHub Pages `Last-Modified` behavior against PackRat metadata; if
   it is inconsistent, move pack freshness to immutable filenames or a static
   manifest before public launch.

This keeps content iteration fast while avoiding the fragile part: automatic
live restart of the authoritative gameplay server.
