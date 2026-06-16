# Lightweight Orchestration Spike

Historical Nakama-branch note: this document compared a separate local orchestrator
for the Nakama architecture. The current custom Godot branch intentionally uses
`server/master/world_process_manager.gd` instead, so the Godot master owns
small-scale on-demand world process allocation directly.

## Question

What should own the small on-demand world-server lifecycle between Nakama and
Godot headless world processes?

The orchestrator needs to:

- expose a private HTTP API for Nakama runtime RPCs;
- start a Godot headless world process on demand;
- track `pid`, port, readiness, heartbeats, player count, and idle timeout;
- stop worlds after `0` players for `X` seconds;
- work on localhost;
- work in GitHub Actions;
- deploy cleanly to a small Hetzner VPS.

## Recommendation

Use a tiny **Go** orchestrator daemon, run under **systemd** on Linux.

For this branch, the orchestrator uses direct child processes. On Hetzner, run
the Go orchestrator itself as a systemd service. If production needs stronger
per-world accounting later, the same API can swap direct process spawning for
`systemd-run` transient units.

Do not use Godot as the orchestrator beyond throwaway validation. A headless
Godot process is much heavier than the control-plane work requires, and it ties
process supervision to the game runtime.

## Comparison

| Option | Runtime overhead | Operational fit | Local + CI | Verdict |
|---|---:|---|---|---|
| Godot headless orchestrator | High | Easy in this repo, but wasteful | Works where Godot exists | Reject for ongoing use |
| PowerShell/Bash scripts | Lowest startup, poor daemon model | Good for launch profiles, weak API/state | OS-specific unless duplicated | Use only as wrappers |
| Python daemon | Moderate | Fast to write, bigger runtime dependency | Good | Acceptable, not best |
| Node.js daemon | Moderate/high | Good HTTP ergonomics, bigger runtime | Good | Acceptable, not best |
| Rust daemon | Very low | Excellent performance, slower iteration | Good if toolchain installed | Strong, more complexity than needed |
| Go daemon | Low | Single small service, simple HTTP/process code | Good with `setup-go` | Best balance |
| systemd only | Very low | Excellent Linux supervision | Linux only | Use under/behind Go |
| Docker Compose | Moderate | Great fixed stack lifecycle | Poor fit for per-world on-demand processes | Use for Nakama/Postgres, not world allocation |
| Kubernetes/Agones | Higher ops | Standard fleet pattern at scale | Heavy | Overkill for one small VPS |

## Why Go

The orchestrator is mostly boring I/O: HTTP handlers, mutex-protected process
state, subprocess launch, log redirection, and idle timers. Go fits this shape:

- standard library HTTP server;
- `os/exec` process spawning without shell expansion;
- simple binary deployment with `go build`;
- easy GitHub Actions support;
- good enough performance with far less operational weight than Node/Python;
- simpler maintenance than Rust for this small control-plane service.

Rust would likely win on absolute memory floor. The practical difference is not
worth the extra implementation cost for this orchestrator because the Godot
world processes will dominate CPU and memory once players are online.

## Recommended Production Shape

On a Hetzner VPS:

```text
systemd
  nakama.service
  postgresql.service or managed Postgres
  virtucade-orchestrator.service

virtucade-orchestrator
  starts/stops Godot world child processes
  binds private API to 127.0.0.1:19100
  writes world logs to /var/log/virtucade/worlds/
  receives world heartbeats
```

Nakama calls:

```text
POST http://127.0.0.1:19100/worlds/ensure
```

World servers call:

```text
POST http://127.0.0.1:19100/worlds/heartbeat
```

For stricter Linux accounting later:

```text
Go orchestrator -> systemd-run --unit virtucade-world-<id> ...
```

The public API does not need to change.

## Localhost And CI

Localhost:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_nakama_mvp.ps1
```

GitHub Actions:

- use Linux runner;
- install Godot;
- use `actions/setup-go`;
- build `./orchestrator`;
- run Nakama/Postgres as services or via Docker Compose;
- run `tools/run_nakama_smoke.sh`.

Example CI skeleton:

```yaml
jobs:
  nakama-smoke:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
      nakama:
        image: heroiclabs/nakama:latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: stable
      - run: go build -o .logs/virtucade-orchestrator ./orchestrator
      - run: GODOT=/path/to/godot ORCHESTRATOR_EXE=.logs/virtucade-orchestrator tools/run_nakama_smoke.sh
```

That skeleton still needs the project-specific Nakama/Postgres health checks and
Godot install path.

Hetzner CI/deploy:

- GitHub Actions can create/delete Hetzner Cloud servers through the official
  API or the `hcloud` CLI;
- for normal deployment, prefer a persistent small VPS with systemd services;
- use ephemeral Hetzner servers only for heavier integration tests.

This branch includes `deploy/systemd/virtucade-orchestrator.service` as the
starting point for the Hetzner VPS service unit.

## Sources

- Go: https://go.dev/
- Go build tutorial: https://go.dev/doc/tutorial/compile-install
- Go `os/exec`: https://pkg.go.dev/os/exec
- systemd transient units: https://www.freedesktop.org/software/systemd/man/systemd-run.html
- Docker Compose: https://docs.docker.com/compose/
- GitHub Actions service containers: https://docs.github.com/actions/guides/about-service-containers
- Hetzner Cloud API: https://docs.hetzner.cloud/reference/cloud
- Hetzner `hcloud` CLI: https://github.com/hetznercloud/cli
