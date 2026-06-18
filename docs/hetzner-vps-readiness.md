# Hetzner VPS Readiness

This note is the current deployment reality check for testing `multi-server-test`
on a Hetzner Cloud Regular Performance VPS and using it as the practical shape
for VirtuCade-style server tests.

## Verdict

Important pricing update: after Hetzner's 2026-06-15 price adjustment, Hetzner
US Regular Performance should no longer be treated as the automatic best-value
host for this project. See [VPS Hosting Value Research](vps-hosting-value-research.md)
before renting a test server.

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

- `MULTI_SERVER_BIND_HOST`
- `MULTI_SERVER_PUBLIC_MASTER_URL`
- `MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE`
- Web query overrides:
  - `master_url`
  - `world_url_template`
- direct Godot WebSocket TLS fallback with:
  - `MULTI_SERVER_TLS_CERT`
  - `MULTI_SERVER_TLS_KEY`

That means a GitHub Pages build can be tested against a live VPS through Caddy
without rebuilding the client just to change the gameplay host.

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
MULTI_SERVER_BIND_HOST=127.0.0.1
MULTI_SERVER_PUBLIC_MASTER_URL=wss://game.example.com/
MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE=wss://game.example.com/{world_key}
MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
```

4. Public Web test URL:

```text
https://shilo.github.io/multi-server-test/?master_url=wss://game.example.com/&world_url_template=wss://game.example.com/{world_key}
```

If the hosted packs move to another static host later, also append
`world_pack_base_url=...`.

Important: that query only changes the Web client's own initial connect target.
The master still advertises world URLs from the VPS environment, so
`MULTI_SERVER_PUBLIC_MASTER_URL` / `MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE`
must still be set on the server itself.

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

For the current reverse-proxy production path, open only:

- `22/tcp` for SSH
- `80/tcp` for Caddy HTTP->HTTPS and ACME
- `443/tcp` for public WSS gameplay

No UDP is needed for this project.

Godot still listens on `19080-19084`, but those ports should bind to
`127.0.0.1` and stay closed publicly when Caddy is enabled.

## Why Direct TLS Remains A Fallback

Godot's official docs state that `WebSocketMultiplayerPeer.create_server()`
accepts `tls_server_options`, so the gameplay server can speak `wss://`
directly:

- [WebSocketMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html)
- [TLSOptions.server()](https://docs.godotengine.org/en/stable/classes/class_tlsoptions.html)

That fallback can still be useful for diagnostics or if Caddy becomes a
measured bottleneck, but it is no longer the preferred public Web path because
Caddy gives standard `443`, automatic certificate renewal, and private Godot
backend ports.

Public direct Godot WSS would require opening `19080+`, managing cert/key
permissions for the Godot process, and restarting Godot after certificate
renewal.

## Important Limits Still Present

These are not hidden blockers for the first Hetzner test, but they are still
real:

- Login is still name-only, not production auth.
- Launch tokens are still passed on command line. Fine for owned-host testing,
  not ideal for a shared-host hardening story.
- We still expect the server's local `world_packs/` mirror to match the hosted
  universal pack bytes exactly.

## Practical Recommendation

For the first Hetzner run:

- test the Web client path first
- treat the VPS as gameplay only
- keep GitHub Pages as static host
- let Caddy handle TLS certificates and WSS on `443`
- keep the server-side local pack mirror under `world_packs/` beside the export

That is the simplest path that still respects the real production shape:

- gameplay host separate from static host
- client downloads PackRat DLC before joining worlds
- server advertises live public URLs
- browser uses `wss://`
