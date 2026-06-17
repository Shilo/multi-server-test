# Runtime Loop Rate Settings

This project uses role-specific runtime loop settings for server processes only.
The client keeps the normal project settings / Godot defaults.

## Current Settings

| Role | Physics TPS | Max FPS | Reason |
|---|---:|---:|---|
| Master server | 1 | 20 | The master has no gameplay or physics. Its important loop is the process frame because Godot polls multiplayer there. `20 FPS` is the current tested floor before local latency starts trending worse. |
| World server | 20 | 20 | Chosen default for the prototype and VirtuCade baseline. It is the best tested CPU/latency tradeoff and avoids spending `30` by default. |
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

For that reason, `20 TPS / 20 FPS` is the chosen default for the current
project and the VirtuCade baseline. It is not a permanent rule for every
minigame, but the burden of proof is on a world to justify raising its own rate.

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
| 20 | 40.0 ms | 35.6 ms | 128.9 ms | 651.0 ms | 1246.8 ms | 61.9 ms | Chosen default. Best low-CPU/default tradeoff for the current prototype. |
| 30 | 27.0 ms | 31.3 ms | 134.0 ms | 562.8 ms | 1145.2 ms | 54.8 ms | Better responsiveness, but not enough to justify the default loop cost. Use only for worlds that prove they need it. |
| 60 | 22.5 ms | 22.1 ms | 137.9 ms | 536.1 ms | 1094.9 ms | 55.5 ms | Best latency, highest loop churn. Reserve for twitch/action worlds. |

The local Windows smoke cannot currently report reliable OS-level CPU/RAM
percentages (`cpu_pct` and `rss_mb` report `0` in this environment), so CPU is
inferred from loop frequency and Godot timing rather than treated as a precise
host measurement. A Linux VPS run should be used for final CPU/RAM confirmation.

## CPU And RAM Interpretation

The most reliable CPU signal from this local sweep is the configured loop count
itself. Godot cannot process more automatic multiplayer polls, synchronizer
frames, `_process()` callbacks, or world physics ticks than the configured
server rates allow.

Using `20` as the chosen baseline:

| Rate | Process frames vs `20` | World physics ticks vs `20` | CPU interpretation |
|---:|---:|---:|---|
| 10 | 50% as many | 50% as many | Cheapest loop cost, but the latency table shows too much slowdown. |
| 20 | Baseline | Baseline | Chosen balance. |
| 30 | 150% as many | 150% as many | Costs about 50% more scheduled loop/physics work than `20`. Not worth it globally for the current latency gain. |
| 60 | 300% as many | 300% as many | Costs about 3x the scheduled loop/physics work of `20`. Reserve for special worlds only. |

The master does not run world physics, so its `physics_ticks_per_second` stays
at `1`. For the master, the relevant CPU difference is process frames:

| Master FPS | Process frames vs `20` | Interpretation |
|---:|---:|---|
| 10 | 50% as many | Lower CPU, but noticeably worse routing/chat/transfer timing. |
| 20 | Baseline | Chosen master default. |
| 30 | 150% as many | 50% more process loop work for better latency, but not enough benefit to spend by default. |
| 60 | 300% as many | 3x process loop work. Useful as a responsiveness reference, not a default. |

The smoke also recorded a rough master `process_msec * fps` proxy, but it should
not be treated as precise CPU because local Windows process CPU/RAM metrics were
unreliable and each smoke run had slightly different timing. The proxy still
supports the main conclusion that `60` is much more expensive, while `10` is
cheap but too laggy:

| Rate | Master process-time/sec proxy | Note |
|---:|---:|---|
| 10 | 160.7 ms/sec | Lowest observed proxy, but worst latency. |
| 20 | 363.8 ms/sec | Accepted baseline. |
| 30 | 238.3 ms/sec | Noisy local result; do not overfit this below `20`. The hard loop count is still 50% higher than `20`. |
| 60 | 1439.6 ms/sec | Clearly much more expensive. |

RAM should not materially change with FPS/TPS. Tick rate changes how often
existing objects update, not how many objects, resources, or packs are loaded.
The local static memory readings stayed in the same range across profiles.

The ratio decision is:

- `10` is too low: it saves the most loop work but clearly worsens route,
  transfer, world-ready, and chat timing.
- `20` is the lowest tested value that keeps timings reasonable, so it is the
  project default.
- `30` is smoother, but it is not the default. It is reserved for
  server-authoritative platformer or collision-sensitive worlds that show a real
  gameplay problem at `20`.
- `60` should be per-world opt-in, not the global default.

Conclusion: stay on `20`. `20 FPS/TPS` is the current practical floor for both
master network polling and lightweight world synchronizer updates. It keeps
loop churn low while avoiding the obvious local latency regression from `10 FPS`
and avoids paying the extra default cost of `30 FPS/TPS`.

## Recommended Policy

Start low, measure, then raise only when gameplay proves it needs it:

| World Type | Physics TPS | Max FPS / Sync Ceiling |
|---|---:|---:|
| Social / lobby / lightweight world | 20 | 20 |
| Current client-authoritative prototype | 20 | 20 |
| Casual realtime minigame | 20 | 20 |
| Platformer with server-authoritative gravity/collision | 20 by default, raise to 30 only if needed | 20 by default, raise to 30 only if needed |
| Twitch/action game | 45-60 | 30-60 |

For platformer worlds that use server-authoritative `CharacterBody2D`, gravity,
moving platforms, or collision-sensitive gameplay, start at `20 TPS` and only
raise that world to `30 TPS` if testing shows movement, collision, or portal
behavior is visibly worse at `20`. This keeps the global server fleet cheaper
while still leaving an escape hatch for individual worlds.

## Why Not Lower Everything?

Lower rates reduce CPU and bandwidth pressure, but they also increase latency
and reduce update granularity:

- `20 Hz` = one update every `50 ms`.
- `30 Hz` = one update every `33 ms`.
- `60 Hz` = one update every `16.7 ms`.

For the master, low physics TPS is safe because gameplay is absent. For the
world server, low FPS/TPS is a tradeoff because it limits both simulation
frequency and default synchronizer frequency.

The master and worlds use `20` instead of `30` because local smoke tests did
not show enough benefit from `30` to justify making every server process run 50%
more process frames by default. The project should spend that budget only when
a specific world demonstrates a gameplay need.

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
