# Nakama MVP Runtime

This folder contains the server-side Nakama files for the `nakama` branch MVP.
It does not install Nakama or Docker.

The Lua module provides:

- guest-session world entry through `join_world`
- guest transfers through `transfer_world`
- short-lived world admission tickets through `validate_ticket`
- orchestration calls to `POST /worlds/ensure`

Run Nakama with `nakama/modules` mounted to `/nakama/data/modules` and
`nakama/local.yml` mounted as the server config. The config points Nakama at the
local Go orchestrator on `http://host.docker.internal:19100`.
