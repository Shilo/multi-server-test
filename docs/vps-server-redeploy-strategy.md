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

Use two deploy lanes:

### 1. Static Host Lane

This lane can be mostly automatic.

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

## Safe VPS Deploy Shape

Use release directories:

```text
/opt/virtucade/releases/<git_sha>/
  server.exe or server binary
  world_packs/ mirror for metadata if needed

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

This is not seamless, but it is stable and secure. For a 100-200 CCU showcase,
a short maintenance reconnect is safer than trying to live-swap the only master
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

1. Add smart GitHub Pages deploy for Web client and per-world PCK updates.
2. Keep VPS gameplay deployment manual/gated for now.
3. Add a future server deploy workflow that builds the server artifact and
   uploads a versioned release directory.
4. Add master maintenance mode before automated live VPS restarts.
5. Add real authenticated sessions before relying on reconnect/resume.

This keeps content iteration fast while avoiding the fragile part: automatic
live restart of the authoritative gameplay server.
