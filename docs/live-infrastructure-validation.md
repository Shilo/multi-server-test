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

### Recovery And Cleanup Hardening

The latest validation pass accepted these reviewer findings and fixed them:

- route-less initial `request_world_join(hub)` now creates an active join request before waiting for world availability;
- stale pending admissions, ready-ticket flags, active join requests, and target leases are cleared immediately when a world deregisters or crashes;
- clients attempt one master-mediated reconnect to the same committed active world after an unexpected world-socket disconnect;
- rejoin requests are validated by the master against session active-world state, so reconnect is not a free teleport path;
- target-world deregistration now notifies source worlds for bare travel leases, preventing long portal locks when a target dies during asset preparation;
- client transfer state is cleared if a world socket disconnects during an in-progress transfer;
- world scene load failure now logs the exact scene path and exits with a distinct code instead of null-instantiating;
- world expected-ticket capacity is aligned with the master admission cap;
- VPS deploys now place SQLite under `/opt/virtucade/data/virtucade.db` through `MULTI_SERVER_DB_PATH`;
- world-pack export waits longer for `.uploading.pck` stability, preventing false failures on slow or loaded disks.

Rejected or deferred review findings:

- SHA-256 PCK validation is useful later, but intentionally deferred because this project currently validates against master-owned file metadata and the PackRat MVP intentionally avoids mandatory hash workflow.
- Full maintenance/drain deploys are deferred; the current release model is manual cold restart with client reconnect prompts.
- Authentication/password hardening is a VirtuCade product feature, not this infrastructure proof. This project remains a private dogfood baseline.
- Caddy trailing-slash support is not added because the generated client URLs are exact-path and endpoints are not user-facing.

## Local Test Results

These tests passed on June 19, 2026:

| Test | Result |
| --- | --- |
| `git diff --check` | Passed |
| `tools/client_ui_smoke.gd` | Passed |
| `tools/net_config_smoke.gd` | Passed |
| `tools/run_smoke.ps1 -UsePackRatWorldPacks -ClientCount 2` | Passed, `SMOKE_PASS clients=2 chat_messages=20` |
| `tools/run_smoke.ps1 -UsePackRatWorldPacks -ClientCount 12` | Passed, `SMOKE_PASS clients=12 chat_messages=120` |
| `tools/run_web_smoke.ps1` | Passed, `WEB_SMOKE_PASS` |
| `tools/run_world_crash_recovery_smoke.ps1` | Passed, transferred to active `left_world`, killed `left_world`, master restarted it, client rejoined and chat passed |
| `tools/run_packrat_version_cache_smoke.ps1` | Passed, unchanged packs cache-hit across app-version bump |
| `tools/run_db_test.ps1` | Passed, SQLite account/world/position persisted across master restart |
| `tools/verify_export_artifacts.py --server-binary server/server.exe` | Passed |
| `tools/run_cpu_profile_smoke.ps1 -ClientCount 12` | Passed, `SMOKE_PASS clients=12 chat_messages=120` |

The web smoke confirms the exported browser client can:

- load from a static host
- download all world packs through PackRat
- cache-hit on repeated world visits
- transfer through all worlds
- keep chat alive across transfers
- emit client-side network stats telemetry
- complete world joins with master ACK telemetry enabled

## Local 12-Client Stress Notes

Latest local 12-client run after world-crash recovery hardening:

| Role | Avg Core % | Max Core % | Max Working Set |
| --- | ---: | ---: | ---: |
| master | 2.77 | 13.30 | 93.58 MB |
| all worlds | 5.70 | 31.61 | 286.56 MB |
| server total | 8.15 | 38.90 | 376.62 MB |
| all Godot processes | 128.76 | 575.29 | 606.97 MB |

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
- The local transfer state machine no longer shows the observed ticket/approval race under 12 concurrent clients.
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

Release `v2.1` deployed successfully on June 19, 2026:

| Check | Result |
| --- | --- |
| GitHub Actions manual release deploy | Passed, `v2.1` |
| Hosted Pages verification | Passed, `HOSTED_PAGES_VERIFY_OK version=2.1` |
| VPS deploy | Passed, `VPS_DEPLOY_DONE` |
| Post-deploy hosted smoke gate | Passed, `WEB_SMOKE_PASS` before release tag publish |
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

The previously observed `right_world` handoff failure did not reproduce after
the ACK-before-approval and full handoff retry changes.

## Hosted Stress Ladder

All hosted stress runs used real GitHub Pages files, real PackRat downloads, real
Caddy WSS routing, and the smallest DigitalOcean droplet.

| Run | Result | Notes |
| --- | --- | --- |
| 1 hosted browser client | Passed | Full world traversal and cache hits worked. |
| 5 simultaneous hosted browser clients | Passed | All clients completed `WEB_SMOKE_PASS`. |
| 6 simultaneous hosted browser clients on `v2.1` | Passed | All clients completed `WEB_SMOKE_PASS`. |
| 8 simultaneous hosted browser clients on `v2.1` | Passed | All clients completed `WEB_SMOKE_PASS`. |
| 10 simultaneous hosted browser clients on `v2.1`, first run | Failed 1/10 | Nine clients completed `WEB_SMOKE_PASS`; one Playwright client timed out waiting for the GitHub Pages document `load` event before any Godot/VPS logs appeared. |
| 10 simultaneous hosted browser clients on `v2.1`, rerun with longer navigation timeout | Passed | All clients completed `WEB_SMOKE_PASS`; several retries occurred and recovered. |

Interpretation:

- The live architecture works end to end for the tested 1/5/6/8-client hosted browser smoke runs.
- The smallest 512 MB / 1 vCPU droplet is a harsh boundary test, not a production target.
- The first 10-client failure did not reach the VPS game path; it timed out during static web page navigation from GitHub Pages. Rerunning with a longer navigation timeout passed all 10 clients.
- Earlier `v1.9` 8/10-client failures included initial master websocket failures and first-transfer failures, but those did not reproduce at 8 clients after the `v2.1` retry/settle hardening.
- Successful clients continued transferring through worlds during the burst tests.
- The observed hosted smoke threshold on this droplet is currently 10 simultaneous full browser smoke clients when navigation timeout is generous enough for GitHub Pages/browser startup. This is one test result, not a guaranteed capacity claim.
- For VirtuCade, the next serious capacity test should use a larger droplet before drawing conclusions about 100-200 CCU.
- Before claiming production capacity, add hosted Caddy/access logs, systemd/OOM checks, a native/headless load harness, and a concurrent hosted smoke runner that classifies each failed client by phase.

## Conclusion So Far

The architecture is behaving correctly locally and live at the tested successful levels: PackRat loading, world transfers, chat continuity, export isolation, Caddy URL generation, ACK-before-approval, hosted WSS routing, and telemetry all pass for single-client and 5/6/8-client hosted smoke.

The tiny DigitalOcean droplet still has little memory headroom, but the latest 10-client hosted smoke rerun passed. The previous remaining 10-client failure was narrower than the original race: one browser client timed out loading the GitHub Pages web app before reaching Godot, while nine clients completed all world transfers. Production capacity is not established by this run.

The current release hardening includes:

- retry around the initial hosted master route bootstrap;
- retry for transient join-ticket acquisition failures;
- stale join-confirmation rejection on the master;
- a public hosted smoke gate before release tagging;
- a slightly longer smoke-only portal replication settle time.
- an explicit hosted stress runner at `tools/run_hosted_stress.ps1`;
- a world-crash recovery smoke at `tools/run_world_crash_recovery_smoke.ps1`.

Recommended next validation before claiming 100-200 CCU:

- test on a larger droplet closer to the intended VirtuCade floor;
- add server-side Caddy access/error log capture to stress reports;
- add systemd journal/OOM checks after each stress run;
- build a cheaper native/headless load harness so browser startup and GitHub Pages page-load behavior do not dominate gameplay capacity results.
