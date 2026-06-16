# Hetzner VPS Readiness

This note is the current deployment reality check for testing `multi-server-test`
on a Hetzner Cloud Regular Performance VPS and using it as the practical shape
for VirtuCade-style server tests.

## Verdict

The project is now ready for a first real Hetzner test with this shape:

- Hetzner Cloud VPS runs the exported Godot gameplay server.
- GitHub Pages continues serving the Web client and downloadable world packs.
- The Web client connects to the VPS over `wss://`.
- The master server reads world-pack metadata from a local mirror of the exact
  hosted Web world packs.

That is good enough for the first public infrastructure test.

## What Changed

The repo previously had one real deployment blocker:

- public client URLs were effectively hardcoded to `127.0.0.1` / `ws`

It now supports:

- `MULTI_SERVER_CLIENT_HOST`
- `MULTI_SERVER_CLIENT_SCHEME`
- Web query overrides:
  - `server_host`
  - `server_scheme`
- direct Godot WebSocket TLS with:
  - `MULTI_SERVER_TLS_CERT`
  - `MULTI_SERVER_TLS_KEY`

That means a GitHub Pages build can be tested against a live VPS without
rebuilding the client just to change the gameplay host.

## Recommended First Hetzner Shape

1. Static host:
   - GitHub Pages hosts:
     - `index.html`
     - `index.js`
     - `index.wasm`
     - `index.pck`
     - `world_packs/*.pck`

2. Gameplay host:
   - one Hetzner Cloud VPS
   - one exported server binary
   - one local directory containing the same Web world packs the static host serves

3. Runtime configuration on the VPS:

```text
MULTI_SERVER_CLIENT_HOST=game.example.com
MULTI_SERVER_CLIENT_SCHEME=wss
MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
MULTI_SERVER_WORLD_PACK_DIR=/srv/multi-server-test/world_packs
MULTI_SERVER_TLS_CERT=/etc/letsencrypt/live/game.example.com/fullchain.pem
MULTI_SERVER_TLS_KEY=/etc/letsencrypt/live/game.example.com/privkey.pem
```

4. Public Web test URL:

```text
https://shilo.github.io/multi-server-test/?server_host=game.example.com&server_scheme=wss
```

If the hosted packs move to another static host later, also append
`world_pack_base_url=...`.

Important: that query only changes the Web client's own initial connect target.
The master still advertises world URLs from the VPS environment, so
`MULTI_SERVER_CLIENT_HOST` / `MULTI_SERVER_CLIENT_SCHEME` must still be set on
the server itself.

## Firewall / Traffic Notes

Relevant current Hetzner docs:

- Regular Performance Cloud is intended for web applications, small databases,
  and dev/test workloads:
  [Hetzner Regular Performance](https://www.hetzner.com/cloud/regular-performance)
- Hetzner Cloud Firewalls are stateful and block all inbound traffic not
  explicitly allowed:
  [Hetzner Cloud Firewalls FAQ](https://docs.hetzner.com/cloud/firewalls/faq/)
- Cloud traffic billing counts outgoing traffic; incoming and internal traffic
  are free:
  [Hetzner Cloud billing FAQ](https://docs.hetzner.com/cloud/billing/faq/)

For the first test, open only:

- `22/tcp` for SSH
- `19080-19084/tcp` for master + four world WebSocket ports

No UDP is needed for this project.

## Why Direct TLS Is Acceptable Here

Godot's official docs state that `WebSocketMultiplayerPeer.create_server()`
accepts `tls_server_options`, so the gameplay server can speak `wss://`
directly:

- [WebSocketMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html)
- [TLSOptions.server()](https://docs.godotengine.org/en/stable/classes/class_tlsoptions.html)

That keeps the first VPS test simpler:

- no mandatory reverse-proxy rewrite
- no path-based socket routing redesign
- no extra port translation layer

## Important Limits Still Present

These are not hidden blockers for the first Hetzner test, but they are still
real:

- Login is still name-only, not production auth.
- Launch tokens are still passed on command line. Fine for owned-host testing,
  not ideal for a shared-host hardening story.
- The master currently serves one pack-metadata set at a time. In practice that
  means one deployment is either Web-pack metadata or native-pack metadata, not
  both simultaneously.
- We still expect the server's local `world_packs/` mirror to match the hosted
  Web pack bytes exactly.

## Practical Recommendation

For the first Hetzner run:

- test the Web client path first
- treat the VPS as gameplay only
- keep GitHub Pages as static host
- use real TLS certs
- keep the server-side local pack mirror under `world_packs/` beside the export

That is the simplest path that still respects the real production shape:

- gameplay host separate from static host
- client downloads PackRat DLC before joining worlds
- server advertises live public URLs
- browser uses `wss://`
