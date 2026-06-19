# Live Infrastructure Validation

## Purpose

This document tracks the final multi-server-test validation pass before using the design as the baseline for VirtuCade.

The goal is a small-scale production-ready MMO stack:

- GitHub Pages hosts the web client and world PCK files.
- DigitalOcean hosts the Godot master server, SQLite database, temporary world server processes, and Caddy WSS edge.
- Clients download world PCKs through PackRat before joining each world.
- Master/world transfer order remains strict enough to avoid stale world, idle shutdown, and join-ticket races.

## Current Runtime Fixes

### Client Network Stats

The client now displays a lightweight network stats label in the running UI. It reports:

- master ping
- world ping
- WebSocket outbound buffered bytes
- active world
- route count
- chat status
- last PackRat pack status, bytes, and prepare time
- last transfer time
- FPS

The same data is mirrored into `PERF_SAMPLE` logs so local and hosted smoke tests can assert that the UI path exists.

### Join Approval Ordering

The master now waits for the target world server to acknowledge the exact join ticket before approving the client join.

Old risky order:

1. Client requested join.
2. Master generated ticket.
3. Master approved the client.
4. Target world received ticket slightly later.

Observed failure:

- the browser client was approved for `right_world`
- the world socket closed before the connection was established
- another client still appeared to have `right_world` running, which made the failure ambiguous

New order:

1. Client requests join.
2. Master starts or reserves target world.
3. Master creates pending admission ticket.
4. Target world receives and stores ticket.
5. Target world ACKs that exact ticket back to master.
6. Master approves client.
7. Client connects to the target world.

The client also has a short bounded retry for the full world handoff. A retry requests a fresh world join ticket under the same travel lease, connects to the target world, sends the ticket, and waits for world-state confirmation. This keeps world tickets one-use while still surviving transient WSS/Caddy handoff timing.

Accepted review fixes:

- ACK wait now matches the 10-second world join reservation instead of using a brittle 2-second window.
- Travel leases survive failed ticket attempts and are consumed only by successful world confirmation or explicit release.
- Worlds replay ACKs for stored tickets when registration acknowledgement arrives, covering ticket-before-registration ordering.
- Master `PERF_SAMPLE` logs now include join-ticket ACK success/timeout counters and last ACK wait time.

## Local Test Results

These tests passed on June 19, 2026:

| Test | Result |
| --- | --- |
| `git diff --check` | Passed |
| `tools/client_ui_smoke.gd` | Passed |
| `tools/net_config_smoke.gd` | Passed |
| `tools/run_smoke.ps1 -UsePackRatWorldPacks -ClientCount 2` | Passed, `SMOKE_PASS clients=2 chat_messages=20` |
| `tools/run_web_smoke.ps1` | Passed, `WEB_SMOKE_PASS` |
| `tools/verify_export_artifacts.py --server-binary server/server.exe` | Passed |
| `tools/run_cpu_profile_smoke.ps1 -ClientCount 10` | Passed, `SMOKE_PASS clients=10 chat_messages=100` |

The web smoke confirms the exported browser client can:

- load from a static host
- download all world packs through PackRat
- cache-hit on repeated world visits
- transfer through all worlds
- keep chat alive across transfers
- emit client-side network stats telemetry
- complete world joins with master ACK telemetry enabled

## Local 10-Client Stress Notes

Final local 10-client run:

| Role | Avg Core % | Max Core % | Max Working Set |
| --- | ---: | ---: | ---: |
| master | 5.05 | 10.77 | 89.90 MB |
| all worlds | 8.47 | 17.34 | 380.58 MB |
| server total | 12.79 | 22.29 | 470.46 MB |
| all Godot processes | 131.47 | 377.17 | 913.19 MB |

Final 10-client ticket ACK telemetry:

| Metric | Observed |
| --- | ---: |
| `join_ticket_ack_success_total` | 100 |
| `join_ticket_ack_timeout_total` | 0 |
| `join_ticket_ack_last_msec` | 91 ms |

Interpretation:

- CPU is not the first bottleneck for the current tiny worlds.
- Memory is the real constraint.
- A 512 MB DigitalOcean droplet is useful as a harsh dogfood/stress boundary, but it is not a safe production target for many concurrent world processes.
- The local transfer state machine no longer shows the observed ticket/approval race under 10 concurrent clients.

## DigitalOcean 512 MB Observations

From a live 1-2 client browser test on the smallest DigitalOcean droplet:

| Metric | Observed |
| --- | ---: |
| CPU peak | about 8% |
| 1-minute load peak | about 0.23 |
| memory | about 58.8% |
| disk usage | about 27.1% |
| public inbound bandwidth during test | about 1.24 MB/s |
| disk I/O spikes | under about 1 MB/s |

Interpretation:

- These numbers are good for a tiny test.
- CPU/load are comfortably low.
- Memory is already high enough that heavier stress may crash or restart services on the 512 MB plan.
- Crashes or failed stress runs on this plan should be treated as capacity findings unless logs show logic errors.

## Hosted Validation

Pending after the next deploy:

- GitHub Actions manual release deploy succeeds.
- `https://virtucade.xyz/` serves the updated web client.
- `https://virtucade.xyz/world_packs/*.pck` serves current world packs.
- `wss://server.virtucade.xyz/` connects through Caddy to the master.
- `wss://server.virtucade.xyz/{world_key}` connects through Caddy to each world.
- Hosted browser smoke transfers through all worlds without the previous `WebSocket is closed before the connection is established` race.
- Live stress documents the maximum stable client count on the 512 MB droplet.

## Conclusion So Far

The architecture is behaving correctly locally: PackRat loading, world transfers, chat continuity, export isolation, Caddy URL generation, ACK-before-approval, and telemetry all pass. The remaining question is live capacity on the smallest droplet and whether the new full-handoff retry removes the hosted race under real WSS/Caddy timing.
