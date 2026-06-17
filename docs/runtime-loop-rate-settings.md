# Runtime Loop Rate Settings

This project uses role-specific runtime loop settings for server processes only.
The client keeps the normal project settings / Godot defaults.

## Current Settings

| Role | Physics TPS | Max FPS | Reason |
|---|---:|---:|---|
| Master server | 1 | 30 | The master has no gameplay or physics. Its important loop is the process frame because Godot polls multiplayer there. |
| World server | 20 | 20 | Stress-test baseline for lightweight client-authoritative worlds. This intentionally tests the low end before raising rates. |
| Client | Project default | Project default | Client feel and rendering belong in project/export settings, not server runtime code. |

## Source Findings

- Godot defaults to `physics/common/physics_ticks_per_second = 60` and
  `application/run/max_fps = 0` (`0` means uncapped).
- `Engine.physics_ticks_per_second` must be greater than `0`, so the master
  cannot use `0` TPS. `1` is the lowest valid value.
- Godot automatically polls `MultiplayerAPI` from `SceneTree.process()`, not
  from the physics loop. This means `max_fps` can affect RPC responsiveness,
  while physics TPS does not directly control RPC polling.
- `MultiplayerSynchronizer` defaults to `replication_interval = 0.0` and
  `delta_interval = 0.0`, which means synchronization happens every network
  process frame. This means world-server `max_fps` is also the default
  synchronizer update ceiling unless explicit intervals are configured.
- Low Processor Mode is not used here. It mostly adds sleep between frames and
  is less explicit than `Engine.max_fps` for server networking behavior.

## Current Project Behavior

`shared/player/player.gd` uses client authority for player movement. On the
world server, client-owned player nodes return early from `_physics_process()`.
That means world TPS is not currently simulating player movement.

The world server still has fixed-step work:

- NPC `_physics_process()` movement.
- Physics/area state used by world content.
- Future server-authoritative minigames.

For that reason, `20 TPS / 20 FPS` is a reasonable stress-test baseline for the
current project, but it is not a permanent rule for every VirtuCade minigame.

## Recommended Policy

Start low, measure, then raise only when gameplay proves it needs it:

| World Type | Physics TPS | Max FPS / Sync Ceiling |
|---|---:|---:|
| Social / lobby / lightweight world | 10-20 | 10-20 |
| Current client-authoritative prototype | 20 | 20 |
| Casual realtime minigame | 30 | 20-30 |
| Platformer with server-authoritative gravity/collision | 30-60 | 30-60 |
| Twitch/action game | 45-60 | 30-60 |

For platformer worlds that use server-authoritative `CharacterBody2D`, gravity,
moving platforms, or collision-sensitive gameplay, prefer `30 TPS` as the
minimum normal setting. Use `20 TPS` only if testing shows movement, collision,
and portal behavior still feel correct under latency.

## Why Not Lower Everything?

Lower rates reduce CPU and bandwidth pressure, but they also increase latency
and reduce update granularity:

- `20 Hz` = one update every `50 ms`.
- `30 Hz` = one update every `33 ms`.
- `60 Hz` = one update every `16.7 ms`.

For the master, low physics TPS is safe because gameplay is absent. For the
world server, low FPS/TPS is a tradeoff because it limits both simulation
frequency and default synchronizer frequency.

## References

- Godot source: `SceneTree::process()` polls multiplayer APIs during process
  frames.
- Godot source: `Engine::set_physics_ticks_per_second()` requires a value above
  `0`.
- Godot docs: `MultiplayerAPI.poll()` is normally called by `SceneTree`.
- Godot docs: `MultiplayerSynchronizer` with interval `0.0` synchronizes every
  network process frame.
- Nakama authoritative multiplayer docs recommend selecting the lowest tick rate
  that provides an acceptable player experience, because lower tick rates allow
  more concurrent matches per CPU core.
