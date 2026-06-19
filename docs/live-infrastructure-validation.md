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

Latest local 10-client run after hosted-burst hardening:

| Role | Avg Core % | Max Core % | Max Working Set |
| --- | ---: | ---: | ---: |
| master | 5.72 | 12.09 | 94.01 MB |
| all worlds | 10.50 | 45.02 | 381.74 MB |
| server total | 15.58 | 49.76 | 471.38 MB |
| all Godot processes | 134.18 | 503.74 | 741.22 MB |

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
- The smoke client load is heavier than real idle players because each client rapidly transfers through every world and sends chat probes.

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
- Memory is already high enough that heavier stress may expose slow startups, delayed replication, failed handshakes, or service restarts.
- Failed stress runs on this plan are useful signals, but they should not be attributed to capacity alone without Caddy logs, systemd/journal data, and per-phase server telemetry.

## Hosted Validation

Release `v1.9` deployed successfully on June 19, 2026:

| Check | Result |
| --- | --- |
| GitHub Actions manual release deploy | Passed, `v1.9` |
| Hosted Pages verification | Passed, `HOSTED_PAGES_VERIFY_OK version=1.9` |
| VPS deploy | Passed, `VPS_DEPLOY_DONE` |
| `https://virtucade.xyz/` | Served by GitHub Pages |
| `https://virtucade.xyz/world_packs/hub.pck` | Served by GitHub Pages |
| `wss://server.virtucade.xyz/` | Browser smoke connected through Caddy to master |
| `wss://server.virtucade.xyz/{world_key}` | Browser smoke connected through Caddy to every world |
| Hosted single-client browser smoke | Passed, `WEB_SMOKE_PASS` |
| Hosted post-stress recovery smoke | Passed after failed burst tests |

The hosted smoke transferred through:

- `hub`
- `left_world`
- `top_world`
- `right_world`
- repeated cached revisits

The previously observed `right_world` handoff failure did not reproduce after the
ACK-before-approval and full handoff retry changes.

## Hosted Stress Ladder

All hosted stress runs used real GitHub Pages files, real PackRat downloads, real
Caddy WSS routing, and the smallest DigitalOcean droplet.

| Run | Result | Notes |
| --- | --- | --- |
| 1 hosted browser client | Passed | Full world traversal and cache hits worked. |
| 5 simultaneous hosted browser clients | Passed | All clients completed `WEB_SMOKE_PASS`. |
| 6 simultaneous hosted browser clients | Passed | All clients completed `WEB_SMOKE_PASS`. |
| 8 simultaneous hosted browser clients | Failed 3/8 | One initial master WSS connect failure; two first-transfer failures. Fresh smoke passed afterward. |
| 10 simultaneous hosted browser clients | Failed 6/10 | Several initial master WSS connect failures; one first-transfer failure. Fresh smoke passed afterward. |

Interpretation:

- The live architecture works end to end for the tested 1/5/6-client hosted browser smoke runs.
- The smallest 512 MB / 1 vCPU droplet is a harsh boundary test, not a production target.
- The 8/10-client failures are unresolved burst failure modes, not proven pure capacity failures:
  - failed clients included initial master websocket connection failures;
  - some first-transfer failures appear consistent with smoke-test portal-position replication timing;
  - successful clients continued transferring through worlds;
  - a fresh hosted smoke passed immediately after the failed bursts;
  - no self-RPC telemetry errors appeared after the `v1.9` guard.
- The observed hosted smoke threshold on this droplet is currently 6 simultaneous full browser smoke clients. This is one test result, not a guaranteed capacity claim.
- For VirtuCade, the next serious capacity test should use a larger droplet before drawing conclusions about 100-200 CCU.
- Before claiming production capacity, add hosted Caddy/access logs, systemd/OOM checks, and a concurrent hosted smoke runner that classifies each failed client by phase.

## Conclusion So Far

The architecture is behaving correctly locally and live at the tested successful levels: PackRat loading, world transfers, chat continuity, export isolation, Caddy URL generation, ACK-before-approval, hosted WSS routing, and telemetry all pass for single-client and 5/6-client hosted smoke.

The tiny DigitalOcean droplet exposes unresolved burst failures around 8-10 simultaneous hosted smoke clients. The important result is narrower but still useful: post-burst service recovery passed, and the original right-world transfer race did not reproduce after the ordering fix. Production capacity is not established by this run.

Next release hardening adds:

- retry around the initial hosted master route bootstrap;
- retry for transient join-ticket acquisition failures;
- stale join-confirmation rejection on the master;
- a public hosted smoke gate before release tagging;
- a slightly longer smoke-only portal replication settle time.
