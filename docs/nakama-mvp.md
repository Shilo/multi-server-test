# Nakama MVP Glue

This branch replaces the old master/chat control path with:

```text
Godot client -> Nakama guest auth/RPC/socket chat
Godot client -> active Godot headless world WebSocket
Nakama Lua RPC -> local Go orchestrator HTTP API
Go orchestrator -> on-demand Godot headless world processes
Godot world -> Nakama validate_ticket RPC
```

The world scenes and player replication layout are unchanged. Movement is still
client-authority through `Player.tscn` and its `MultiplayerSynchronizer`.

## What Is Implemented

- Vendored Nakama Godot SDK at `addons/com.heroiclabs.nakama`.
- `Nakama` autoload in `project.godot`.
- Guest-only device auth in the Godot client.
- Nakama room chat through the Godot SDK socket.
- Nakama client RPCs:
  - `join_world`
  - `transfer_world`
- Nakama server-to-server RPC:
  - `validate_ticket`
- Local Go orchestrator:
  - `POST /worlds/ensure`
  - `POST /worlds/heartbeat`
  - `GET /worlds`
  - `POST /worlds/{world_id}/stop`
- On-demand startup/shutdown for all worlds, including world 1.

## Files

- `client/client_main.gd`: Nakama guest auth, socket chat, world join/transfer.
- `orchestrator/main.go`: small localhost process supervisor.
- `server/world/world_server.gd`: ticket validation before player spawn.
- `shared/world_endpoint.gd`: client sends ticket with world-state request.
- `nakama/modules/virtucade.lua`: Nakama Lua runtime RPC glue.
- `nakama/local.yml`: local Nakama config example.
- `tools/run_nakama_mvp.ps1`: starts the orchestrator and a visible client.
- `tools/run_nakama_smoke.ps1`: starts orchestrator and smoke-test clients.

## Local Run Shape

Start Nakama separately. This repo does not install or run Nakama for you.

Mount:

```text
nakama/modules -> /nakama/data/modules
nakama/local.yml -> Nakama config
```

The local config points Nakama at:

```text
http://host.docker.internal:19100
```

Then run:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_nakama_mvp.ps1
```

The Nakama scripts run a quick headless editor import first so Godot refreshes
the vendored SDK class metadata. They also build the Go orchestrator with
`go build`; install Go locally or pass `-OrchestratorExe` to use a prebuilt
binary.

For automated validation after Nakama is running:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_nakama_smoke.ps1
```

On Linux/GitHub Actions:

```bash
GODOT=/path/to/godot tools/run_nakama_smoke.sh
```

## Expected Flow

1. Client authenticates as a Nakama guest with `authenticate_device_async`.
2. Client opens a Nakama realtime socket.
3. Client joins Nakama room chat named `global`.
4. Client calls `join_world` for world 1.
5. Nakama asks the local orchestrator to ensure world 1 is running.
6. Orchestrator starts a Godot headless world process if needed.
7. Nakama returns the world WebSocket endpoint and a short-lived ticket.
8. Client connects directly to the Godot world.
9. Client sends the ticket through `request_world_state`.
10. World validates the ticket with Nakama before spawning the player.
11. Portals call `transfer_world`, which repeats the same ensure/ticket flow.

## Verification Done

Local verification without installing/running Nakama:

- Godot editor import pass generated Nakama SDK class metadata.
- Client script loads and reaches Nakama guest auth.
- Earlier Godot orchestrator role booted and listened on `127.0.0.1:19100`.
- That has been replaced by the lighter Go orchestrator design in
  `docs/orchestration-language-spike.md`.
- World role boots and reaches `WORLD_READY` on a spare test port.
- The old `POST /worlds/ensure` behavior was verified with the Godot
  orchestrator; the Go replacement could not be compiled in this local
  environment because Go is not installed here.

Full chat/join/transfer smoke requires a running Nakama server.
