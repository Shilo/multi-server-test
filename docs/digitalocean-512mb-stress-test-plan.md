# DigitalOcean 512 MiB Stress Test Plan

Date: 2026-06-17

## Goal

Use the smallest DigitalOcean Basic Droplet as an intentional worst-case
stress-test host for `multi-server-test`.

Target plan:

```text
DigitalOcean Basic Droplet
slug: s-1vcpu-512mb-10gb
RAM: 512 MiB
CPU: 1 shared vCPU
SSD: 10 GiB
Transfer: 500 GiB outbound/month
Price: $0.00595/hour, $4/month cap
```

This plan is not expected to be comfortable. The point is to discover failure
behavior:

- Does the master boot?
- How many world processes start before RAM pressure?
- Does Linux OOM-kill Godot?
- Does CPU saturation cause travel, heartbeat, or WebSocket timeouts?
- Do logs clearly explain failure?
- Can we deploy, observe, destroy, and repeat cheaply?

## Source Docs

- [DigitalOcean Droplet pricing](https://www.digitalocean.com/pricing/droplets)
- [DigitalOcean Droplets product page](https://www.digitalocean.com/products/droplets)
- [Add SSH keys to Droplets](https://docs.digitalocean.com/products/droplets/how-to/add-ssh-keys/)
- [Connect to Droplets with SSH](https://docs.digitalocean.com/products/droplets/how-to/connect-with-ssh/)
- [Provide user data / cloud-init](https://docs.digitalocean.com/products/droplets/how-to/provide-user-data/)
- [Configure firewall rules](https://docs.digitalocean.com/products/networking/firewalls/how-to/configure-rules/)
- [doctl GitHub Action](https://github.com/digitalocean/action-doctl)
- [doctl Droplet commands](https://docs.digitalocean.com/reference/doctl/reference/compute/droplet/)
- [Resize Droplets](https://docs.digitalocean.com/products/droplets/how-to/resize/)
- [doctl resize command](https://docs.digitalocean.com/reference/doctl/reference/compute/droplet-action/resize/)
- [DigitalOcean Monitoring quickstart](https://docs.digitalocean.com/products/monitoring/getting-started/quickstart/)
- [DigitalOcean Monitoring alerts](https://docs.digitalocean.com/products/monitoring/how-to/manage-alerts/)

## Important Billing Notes

DigitalOcean Droplets are hourly/per-second billed with a monthly cap. If this
Droplet exists for the full month, compute cost should cap at about $4. If it is
created for a few hours and then destroyed, the cost should be cents.

Expected examples:

```text
1 hour:   about $0.00595
10 hours: about $0.0595
40 hours: about $0.238
full month: $4 cap
```

The 500 GiB transfer amount is included outbound transfer, not a hard stop. If
outbound transfer exceeds the included amount, DigitalOcean bills overage. At
the time of this research, DigitalOcean documents outbound transfer overage at
$0.01/GiB. Inbound transfer is free.

For this project, bandwidth should not matter during dev stress testing because:

- Web client files are hosted by GitHub Pages;
- PackRat PCK files are hosted by GitHub Pages;
- the Droplet only carries gameplay WebSocket traffic;
- tests are private and small.

Avoid paid extras for this stress test:

- no backups;
- no snapshots unless explicitly needed;
- no load balancer;
- no managed database;
- no extra volumes;
- no cPanel/Plesk.

## Why No cPanel

Do not install cPanel, Plesk, DirectAdmin, or other hosting panels on the 512 MiB
Droplet.

Reasons:

- they consume RAM we are intentionally trying to reserve for Godot;
- they add services that hide the real stress-test signal;
- they can add license or marketplace costs;
- this project only needs SSH, systemd, logs, and environment variables.

Use the **DigitalOcean Control Panel** for:

- creating the Droplet;
- adding SSH keys;
- viewing console access;
- viewing CPU/bandwidth graphs;
- creating firewall rules;
- destroying the Droplet.

Use SSH/systemd for the actual game server.

## Recommended Region

For US-west dogfooding:

```text
sfo3
```

For a more central/east test:

```text
nyc3
```

Pick one region and keep it consistent during the first tests so performance
differences come from the Droplet size, not geography.

## Manual Purchase Setup

1. Create or log into a DigitalOcean account.
2. Go to **Droplets -> Create Droplet**.
3. Choose an Ubuntu LTS image.
4. Choose region:
   - `sfo3` for west coast testing;
   - `nyc3` for east/central comparison later.
5. Choose **Basic -> Regular**.
6. Choose:

```text
512 MiB / 1 vCPU / 10 GiB SSD / 500 GiB transfer / $4
```

7. Add your SSH key.
8. Add a project name like:

```text
multi-server-test
```

9. Add tags:

```text
multi-server-test
dev-stress
godot
```

10. Enable monitoring if offered.
11. Do not enable backups for this test.
12. Create the Droplet.

## Firewall Plan

Required inbound ports:

```text
22/tcp       SSH
19080/tcp    master WebSocket
19081/tcp    hub world
19082/tcp    left_world
19083/tcp    right_world
19084/tcp    top_world
```

Recommended DigitalOcean Cloud Firewall:

```text
Inbound:
  22/tcp from your IP if stable, otherwise all IPv4/IPv6 during short tests
  19080-19084/tcp from all IPv4/IPv6

Outbound:
  allow all

Apply by tag:
  dev-stress
```

GitHub Actions runners do not have one stable IP. For the first dev test, the
simple path is SSH open to the internet with key-only login. A better later path
is:

1. GitHub Actions detects its public runner IP.
2. Workflow temporarily adds that IP to the SSH firewall rule.
3. Workflow deploys over SSH.
4. Workflow removes the temporary SSH rule.

That is better security but not needed for the first throwaway Droplet.

## Cloud-Init / User Data

DigitalOcean supports user data during Droplet creation through the control
panel, API, and `doctl`.

Use this minimal cloud-init for the first stress test:

```yaml
#cloud-config
package_update: true
packages:
  - unzip
  - rsync
  - htop
  - curl
  - jq

write_files:
  - path: /etc/multi-server-test.env
    permissions: "0600"
    content: |
      MULTI_SERVER_CLIENT_HOST=__DROPLET_PUBLIC_IP__
      MULTI_SERVER_CLIENT_SCHEME=ws
      MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
      MULTI_SERVER_WORLD_PACK_DIR=/opt/multi-server-test/current/world_packs

  - path: /etc/systemd/system/multi-server-test.service
    permissions: "0644"
    content: |
      [Unit]
      Description=multi-server-test Godot master server
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/opt/multi-server-test/current/server
      EnvironmentFile=/etc/multi-server-test.env
      ExecStart=/opt/multi-server-test/current/server/server.x86_64 --headless
      Restart=on-failure
      RestartSec=3
      KillSignal=SIGINT
      TimeoutStopSec=15

      [Install]
      WantedBy=multi-user.target

runcmd:
  - mkdir -p /opt/multi-server-test/releases /opt/multi-server-test/current
  - systemctl daemon-reload
```

Replace `__DROPLET_PUBLIC_IP__` after creation, or let the GitHub workflow write
the env file during deploy. For the first test, it is fine if cloud-init only
installs packages and writes the service file; the workflow can handle the final
env values.

## Swap Policy

For the purest break test:

```text
no swap
```

Expected behavior: if RAM is exceeded, Linux may OOM-kill one of the Godot
processes. That is useful because it proves the failure mode.

For a slightly more forgiving second pass:

```text
512 MiB swap file
```

Expected behavior: fewer immediate kills, but severe stutter under memory
pressure. Swap can make the server look alive while gameplay becomes unusable.

Do both tests eventually:

1. no swap, to see hard failure;
2. 512 MiB swap, to see degraded failure.

## GitHub Secrets

Add these repository secrets before wiring the workflow:

```text
DIGITALOCEAN_ACCESS_TOKEN
DO_DEV_STRESS_SSH_PRIVATE_KEY
DO_DEV_STRESS_SSH_PUBLIC_KEY
DO_DEV_STRESS_KNOWN_HOSTS
```

For the first version, manual Droplet creation is acceptable. Then GitHub
Actions only needs SSH deploy secrets:

```text
DO_DEV_STRESS_HOST
DO_DEV_STRESS_USER=root
DO_DEV_STRESS_SSH_PRIVATE_KEY
```

Provider-specific automation can be added later.

## GitHub Actions Plan

Current workflow already:

- bumps/sets project version;
- exports Linux server;
- exports Web client;
- exports universal world PCKs;
- deploys GitHub Pages;
- verifies hosted files;
- uploads server artifacts;
- stops at `VPS_DEPLOY_NOT_CONFIGURED`.

Add a separate manual workflow first:

```text
.github/workflows/deploy-digitalocean-dev-stress.yml
```

Inputs:

```text
droplet_host: required for manual-first workflow
run_label: optional
start_after_deploy: true/false
```

Steps:

1. Checkout.
2. Download or build release artifacts.
3. Verify exports.
4. SSH into Droplet.
5. Create a timestamped release folder:

```text
/opt/multi-server-test/releases/<version>-<run_id>/
```

6. Upload:

```text
server/**
world_packs/*.pck
```

7. Write:

```text
/opt/multi-server-test/releases/<version>-<run_id>/server/.env
```

or update:

```text
/etc/multi-server-test.env
```

8. Update symlink:

```text
/opt/multi-server-test/current -> /opt/multi-server-test/releases/<version>-<run_id>
```

9. Restart service:

```bash
sudo systemctl restart multi-server-test
```

10. Print:

```bash
systemctl status multi-server-test --no-pager
journalctl -u multi-server-test -n 120 --no-pager
```

11. Print test URL:

```text
https://shilo.github.io/multi-server-test/?server_host=<droplet_ip>&server_scheme=ws
```

Use `ws` for the first cheap test. Add TLS/`wss` later with a domain and cert.

## Optional Fully Automated Droplet Lifecycle

After manual deploy works, add an optional workflow that creates and destroys
the Droplet with `doctl`.

Concept:

```bash
doctl compute droplet create multi-server-test-stress-${GITHUB_RUN_ID} \
  --region sfo3 \
  --image ubuntu-24-04-x64 \
  --size s-1vcpu-512mb-10gb \
  --ssh-keys <ssh-key-id> \
  --tag-names multi-server-test,dev-stress,godot \
  --user-data-file cloud-init/do-dev-stress.yml \
  --wait
```

Then:

```bash
doctl compute droplet get <id> --format PublicIPv4 --no-header
```

Deploy over SSH, run the stress test, then destroy:

```bash
doctl compute droplet delete <id> --force
```

This is the cheapest loop for repeated private testing, but it is more moving
parts than a manual first Droplet.

## Runtime Commands

SSH in:

```bash
ssh root@<droplet_ip>
```

Check service:

```bash
systemctl status multi-server-test --no-pager
journalctl -u multi-server-test -f
```

Watch memory/CPU:

```bash
htop
free -h
ps -eo pid,ppid,comm,%cpu,%mem,rss,args --sort=-rss | head -40
```

Detect OOM kills:

```bash
journalctl -k | grep -i -E "out of memory|oom|killed process"
```

Check listening ports:

```bash
ss -lntp | grep -E "1908[0-4]"
```

Stop/restart:

```bash
systemctl stop multi-server-test
systemctl restart multi-server-test
```

## Built-In Performance Logs

The project emits structured performance samples from the master, every world
server, and every client:

```text
PERF_SAMPLE role=master ...
PERF_SAMPLE role=world instance=hub ...
PERF_SAMPLE role=client ...
```

Each sample is a single log line of `key=value` pairs so it can be grepped from
local smoke logs or `journalctl` on the Droplet.

The monitor uses Godot's built-in/runtime APIs where they exist:

- `Performance.get_monitor(...)` for frame, object, and Godot memory counters;
- `MultiplayerAPI` and `MultiplayerPeer` for peer counts, connection status,
  and available packet queues;
- `WebSocketMultiplayerPeer.get_peer(id)` plus
  `WebSocketPeer.get_current_outbound_buffered_amount()` for WebSocket outbound
  queue pressure;
- ENet `get_statistic(...)` if this project later adds an ENet transport.

Godot's ENet peer statistics expose ping and packet loss, but this project uses
`WebSocketMultiplayerPeer` so the monitor keeps a tiny ping/pong RPC for
client-to-master, client-to-world, and world-to-master latency. This avoids
pretending ENet-only APIs exist for the Web build.

Server-side fields include:

```text
rss_mb / vm_mb              Linux process memory, when /proc is available
static_mb / static_max_mb   Godot static memory
cpu_pct                    process CPU percent
host_net_rx_mb / host_net_tx_mb       Linux host network-interface totals
host_net_rx_kbps / host_net_tx_kbps   recent Linux host network throughput
master_available_packets    Godot multiplayer packets queued for polling
master_ws_outbound_buffered_bytes     WebSocket outbound queued bytes
fps                         Godot frame rate
process_msec               idle frame process time
physics_msec               physics frame process time
master_peers               connected master peers
registered_worlds          world servers registered with master
validated_clients          clients accepted by version/auth gate
world_processes            child world processes owned by master
world_players              total players reported by worlds
connected_players          players inside one world process
pending_transfers          transfers waiting inside one world process
world_master_last_msec      world-to-master ping latency
```

Client-side fields include:

```text
client_master_last_msec       client-to-master ping latency
client_world_last_msec        client-to-world ping latency
master_connect_last_msec      WebSocket connect time to master
world_<key>_connect_last_msec WebSocket connect time to world
world_pack_prepare_last_msec  PackRat prepare/download/mount time
world_pack_cache_hit_total    cached pack uses
world_pack_download_bytes_total downloaded PackRat bytes
transfer_last_msec            portal approval + pack prep + world join time
chat_echo_last_msec           chat round-trip echo latency
```

On the Droplet, use:

```bash
journalctl -u multi-server-test -f | grep PERF_SAMPLE
```

For a concise server-only view:

```bash
journalctl -u multi-server-test -f | grep -E "PERF_SAMPLE role=(master|world)"
```

These logs are intentionally plain text for the first VPS dogfood pass. If the
data proves useful, the next step is exporting the same samples to Prometheus,
Grafana, Loki, or another metrics backend without changing the gameplay code.

## Stress Test Matrix

Run these in order.

### Test 1: Boot Only

Goal: master starts on 512 MiB.

Expected:

```text
MASTER_DB_READY
MASTER_READY port=19080
```

### Test 2: One Browser Client

Goal: GitHub Pages Web client connects to Droplet.

URL:

```text
https://shilo.github.io/multi-server-test/?server_host=<droplet_ip>&server_scheme=ws
```

Expected:

```text
MASTER_WORLD_STARTED key=hub
MASTER_WORLD_REGISTERED key=hub
MASTER_WORLD_PLAYERS key=hub count=1
```

### Test 3: Force All Worlds

Goal: transfer through hub, left, right, top.

Expected:

```text
master + up to 4 world processes
```

Local classified stress result on Windows:

```text
10 clients passed
max server processes: 5
max server working set: ~465 MB
```

That means 512 MiB is expected to be fragile after Linux overhead.

### Test 4: Ten Clients

Goal: intentionally break or prove surprising headroom.

Expected failure modes:

- OOM-killed world process;
- master restart;
- WebSocket disconnects;
- travel timeout;
- visible stutter from CPU saturation;
- delayed world startup;
- SQLite latency spikes.

### Test 5: Resize Up

If 512 MiB fails too fast, resize CPU/RAM only:

```text
1 GiB / 1 vCPU
```

Do not resize disk unless intentionally accepting that disk growth is permanent.

## Resize Plan

DigitalOcean supports two resize types:

```text
CPU and RAM only
Disk, CPU, and RAM
```

Use **CPU and RAM only** for stress testing because it can be reversed. Disk
resize is permanent because disks cannot be shrunk later.

Recommended ladder:

```text
512 MiB / 1 vCPU / $4
1 GiB / 1 vCPU / $6
2 GiB / 1 vCPU / $12
2 GiB / 2 vCPU / $18
4 GiB / 2 vCPU / $24
```

For each step:

1. Stop service.
2. Power off Droplet.
3. Resize CPU/RAM only.
4. Boot Droplet.
5. Start service.
6. Rerun the same stress matrix.

## Success Criteria

This test is successful even if the server breaks, as long as we learn where and
how.

Record:

- smallest plan that boots master;
- smallest plan that handles one browser client;
- smallest plan that handles all worlds;
- smallest plan that handles 10 clients;
- first OOM point;
- first CPU saturation point;
- whether clients recover or fail clearly;
- whether systemd restarts cleanly;
- whether logs identify the failing world/process.

## Expected Outcome

Based on local testing:

```text
master + up to 4 worlds ~= 465 MB working set on Windows
```

On a 512 MiB Linux Droplet, this leaves almost no room for:

- kernel;
- systemd;
- SSH;
- monitoring agent;
- filesystem cache;
- SQLite;
- process startup spikes.

Prediction:

```text
512 MiB may boot master and one world, but all-world or 10-client tests are
likely to hit OOM or severe CPU/RAM pressure.
```

That is useful. The point is to make the system fail loudly now, before
VirtuCade grows real assets and real users.

## Cleanup

When finished:

```bash
doctl compute droplet delete <id> --force
```

Or delete the Droplet from the DigitalOcean Control Panel.

Also delete unused:

- snapshots;
- backups;
- volumes;
- reserved IPs;
- load balancers;
- old firewalls if not reused.

The Droplet must be destroyed, not merely powered off, if the goal is to stop
all compute billing.

## Follow-Up Work

1. Add `.github/workflows/deploy-digitalocean-dev-stress.yml`.
2. Add a small cloud-init file under `deploy/digitalocean/`.
3. Add SQLite query/save timing counters to the existing `PERF_SAMPLE` stream.
4. Add a remote smoke mode that can target:

```text
https://shilo.github.io/multi-server-test/?server_host=<host>&server_scheme=ws
```

5. Run the stress ladder from 512 MiB upward and write results back into this
doc.
