# Runtime Loop Rate Settings

This project uses role-specific runtime loop settings for server processes only.
The client keeps the normal project settings / Godot defaults.

## Current Settings

| Role | Physics TPS | Max FPS | Reason |
|---|---:|---:|---|
| Master server | 1 | 20 | The master has no gameplay or physics. Its important loop is the process frame because Godot polls multiplayer there. `20 FPS` is the current tested floor before local latency starts trending worse. |
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

## External Reference Points

Photon Fusion Godot/Fusion uses a similar separation between simulation tick
and send rate. Fusion's Godot documentation says Shared Mode tick and send rate
settings are capped at `32`, and Fusion 2.1 allows tick rates from `8` to `256`.
Fusion's optimization docs explicitly recommend reducing send rate to every
`1/2`, `1/4`, or `1/8` tick to reduce bandwidth without lowering simulation
quality. This supports the idea that VirtuCade should eventually separate
simulation TPS from network snapshot rate instead of treating one number as
everything.

Nakama authoritative matches are also explicit tick loops. Nakama recommends
choosing the lowest tick rate that gives acceptable feel, because lower tick
rates allow more concurrent matches per CPU core. Nakama non-authoritative
relayed matches have no tick rate at all; messages are relayed as received. That
maps closely to this project: the master behaves more like event relay/control
than an authoritative simulation, while world servers are the only processes
that need gameplay tick tuning.

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

The master and world rates were tested at `60`, `30`, `20`, and `10` with a
10-client smoke. The swept value means:

- master `max_fps`;
- world `max_fps`;
- world `physics_ticks_per_second`.

Master `physics_ticks_per_second` stayed at `1` for every profile because the
master has no gameplay simulation.

| Rate | Client -> master avg | Client -> world avg | Join ticket avg | World ready avg | Transfer avg | Chat echo avg | Result |
|---:|---:|---:|---:|---:|---:|---:|---|
| 10 | 50.8 ms | 62.4 ms | 169.4 ms | 864.2 ms | 1521.7 ms | 90.1 ms | Passes, but visibly worse timing. Too low for default. |
| 20 | 40.0 ms | 35.6 ms | 128.9 ms | 651.0 ms | 1246.8 ms | 61.9 ms | Best low-CPU/default tradeoff for the current prototype. |
| 30 | 27.0 ms | 31.3 ms | 134.0 ms | 562.8 ms | 1145.2 ms | 54.8 ms | Better responsiveness; likely default for server-authoritative minigames. |
| 60 | 22.5 ms | 22.1 ms | 137.9 ms | 536.1 ms | 1094.9 ms | 55.5 ms | Best latency, highest loop churn. Reserve for twitch/action worlds. |

The local Windows smoke cannot currently report reliable OS-level CPU/RAM
percentages (`cpu_pct` and `rss_mb` report `0` in this environment), so CPU is
inferred from loop frequency and Godot timing rather than treated as a precise
host measurement. A Linux VPS run should be used for final CPU/RAM confirmation.

The ratio decision is:

- `10` is too low: it saves the most loop work but clearly worsens route,
  transfer, world-ready, and chat timing.
- `20` is the lowest tested value that keeps timings reasonable.
- `30` feels like the safer production baseline for authoritative platformer or
  collision-sensitive worlds.
- `60` should be per-world opt-in, not the global default.

So `20 FPS` is the current practical floor for both master network polling and
lightweight world synchronizer updates. It keeps loop churn low while avoiding
the obvious local latency regression from `10 FPS`.

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

The master uses `20 FPS` instead of `30 FPS` because it does not run gameplay
and local smoke tests did not show a meaningful benefit from `30 FPS`. It does
not use `15 FPS` because latency started trending worse even though tests still
passed.

## References

- Godot source: `SceneTree::process()` polls multiplayer APIs during process
  frames.
- Godot source: `Engine::set_physics_ticks_per_second()` requires a value above
  `0`.
- Godot docs: `MultiplayerAPI.poll()` is normally called by `SceneTree`.
- Godot docs: `MultiplayerSynchronizer` with interval `0.0` synchronizes every
  network process frame.
- Photon Fusion docs: Shared Mode tick/send rates are capped at `32`, Fusion
  2.1 supports tick rates from `8` to `256`, and send rate can be reduced to
  every `1/2`, `1/4`, or `1/8` tick.
- Nakama authoritative multiplayer docs recommend selecting the lowest tick rate
  that provides an acceptable player experience, because lower tick rates allow
  more concurrent matches per CPU core.
- Nakama non-authoritative relayed matches have no tick rate because messages
  are relayed as received.
