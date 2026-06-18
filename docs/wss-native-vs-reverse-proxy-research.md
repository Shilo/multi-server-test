# Native Godot WSS Vs Reverse Proxy Research

Date: 2026-06-18

## Question

The Web client is served from GitHub Pages over HTTPS. Browser security blocks
plain `ws://` connections from an HTTPS page, so public Web gameplay needs
`wss://`.

The decision is whether VirtuCade-style hosting should use:

1. Native Godot WSS on the master/world server ports.
2. A reverse proxy such as Caddy or nginx in front of Godot.
3. A managed DigitalOcean Load Balancer.
4. A future single public gateway.

The target production scale for this research is a small MMO/showcase with
roughly 100-200 concurrent users and temporary world server processes on one
gameplay VPS.

## Current Project State

This project already has native TLS/WSS hooks:

- `server/master/master.gd` creates the master with:
  `WebSocketMultiplayerPeer.create_server(..., NET_CONFIG.tls_server_options())`.
- `server/world/world.gd` does the same for world servers.
- `shared/net/net_config.gd` reads:
  - `MULTI_SERVER_TLS_CERT`
  - `MULTI_SERVER_TLS_KEY`
  - `MULTI_SERVER_CLIENT_SCHEME`
  - `MULTI_SERVER_CLIENT_HOST`
- The Web client can be pointed at `wss://` by using `server_scheme=wss` or the
  server-side `MULTI_SERVER_CLIENT_SCHEME=wss` environment variable.

That means native WSS is not theoretical for this codebase. The remaining work
is domain, certificate, permission, firewall, and renewal handling.

## Browser Requirement

Browsers treat this as mixed content and block it:

```text
https://shilo.github.io/multi-server-test -> ws://game.example.com:19080
```

Browsers allow this:

```text
https://shilo.github.io/multi-server-test -> wss://game.example.com:19080
```

So the required public transport for the Web client is `wss://`. The open
question is where TLS is terminated.

## Option A: Native Godot WSS

Topology:

```text
Browser
  -> wss://game.example.com:19080
  -> Godot master

Browser
  -> wss://game.example.com:19081+
  -> Godot world servers
```

### Setup

Required VPS configuration:

```text
DNS:
  game.example.com -> VPS public IP

Environment:
  MULTI_SERVER_CLIENT_HOST=game.example.com
  MULTI_SERVER_CLIENT_SCHEME=wss
  MULTI_SERVER_TLS_CERT=/path/to/fullchain.pem
  MULTI_SERVER_TLS_KEY=/path/to/privkey.pem

Firewall:
  19080/tcp for master
  19081-19180/tcp or a tighter current world range for worlds
```

The TLS certificate must be valid for the hostname the browser dials. A raw IP
address is not enough for normal browser-trusted TLS.

### Pros

- No extra proxy process.
- No extra local hop between proxy and Godot.
- No DigitalOcean Load Balancer cost.
- Fewer moving pieces in the runtime path.
- Matches this project already: master and worlds are separate Godot
  `WebSocketMultiplayerPeer` servers on known ports.
- Keeps failure analysis direct: browser connects to Godot, Godot logs the
  connection.

### Cons

- Certificate renewal becomes our responsibility.
- Godot service may need a restart or reload after certificates renew.
- The private key must be readable by the Godot service user, which must be
  handled carefully.
- Each public world port must be opened.
- Some restricted networks allow only outbound `80/443`, so
  `wss://game.example.com:19080` can fail even though it is encrypted.
- Public ports expose every world server directly to internet connection
  attempts.
- If many worlds are added dynamically, firewall ranges need to match the
  maximum world port range.
- The public URL shape is less conventional than normal HTTPS/WSS:
  `wss://game.example.com:19083` instead of `wss://game.example.com/...`.

### Latency And Performance

Native WSS has the shortest path:

```text
Client TCP/TLS/WebSocket -> Godot
```

It avoids a local proxy socket and an extra userspace process. For pure
minimal-latency design, this is the cleanest path.

However, for 100-200 CCU, the expected difference between native WSS and a
same-machine reverse proxy is likely small compared to:

- internet route latency;
- Godot frame/update scheduling;
- game simulation cost;
- database work;
- world process count;
- asset loading and transfer workflow.

The main native WSS advantage is therefore operational simplicity and directness,
not a guaranteed meaningful gameplay latency win.

## Option B: Reverse Proxy On The VPS

Topology:

```text
Browser
  -> wss://game.example.com:443
  -> Caddy/nginx
  -> ws://127.0.0.1:19080
  -> Godot master
```

For worlds, the proxy must route to each world port, for example:

```text
wss://game.example.com/ws/master -> 127.0.0.1:19080
wss://game.example.com/ws/world/hub -> 127.0.0.1:19081
wss://game.example.com/ws/world/left_world -> 127.0.0.1:19082
```

### Pros

- Public traffic can use normal port `443`.
- Better compatibility with schools, workplaces, hotels, and restricted public
  networks.
- Only the proxy needs to be public; Godot can listen on localhost or private
  addresses.
- Certificate automation is much easier, especially with Caddy.
- A proxy can centralize rate limits, access logs, compression controls,
  request filtering, and basic abuse mitigation.
- Cleaner public URLs are possible.
- Easier migration path to multiple backend servers later.
- A proxy can hide direct world server ports from the public internet.

### Cons

- Adds another process to install, configure, update, monitor, and include in
  deployment docs.
- Every WebSocket packet passes through the proxy after the HTTP upgrade.
- Misconfigured WebSocket upgrade headers or timeouts can break connections.
- Path-based routing for dynamic worlds can become awkward if worlds are added
  often and the proxy config must be regenerated.
- If Godot high-level multiplayer expects separate peer URLs per world, the
  application still needs clean routing conventions.
- It can make debugging slightly less direct because failures may live in the
  browser, proxy, or Godot.

### Latency And Performance

The proxy path is:

```text
Client TCP/TLS/WebSocket -> proxy -> local TCP/WebSocket -> Godot
```

This adds:

- one local userspace hop;
- one local socket connection from proxy to Godot;
- proxy bookkeeping for each active connection;
- possible buffering or timeout behavior depending on configuration.

For a same-VPS proxy at 100-200 CCU, this overhead should usually be small. It
is still real, but it is more likely to show up as CPU/configuration overhead
than as player-visible latency. The main reason to use a proxy is not speed. The
main reasons are port `443`, certificate automation, security boundary, and
standard deployment shape.

## Why Not Put Godot Master Directly On Port 443?

This is possible, but it only solves part of the current architecture.

If the master listens on `443`:

```text
Browser -> wss://game.example.com -> Godot master on 443
```

then the initial master connection uses the standard WebSocket TLS port. That
is good for reachability.

However, this project currently has clients connect directly to world servers:

```text
Browser -> wss://game.example.com:19081 -> hub
Browser -> wss://game.example.com:19082 -> left_world
Browser -> wss://game.example.com:19083 -> right_world
```

So putting only the master on `443` still leaves every world on a nonstandard
public port. It helps login/routes, but does not fully solve gameplay
reachability.

There are also operational concerns:

- On Linux, ports below `1024` are privileged. Running Godot as root would be a
  bad security tradeoff. The safer route would be `setcap cap_net_bind_service`
  on the server binary or systemd socket/proxy handling.
- Only one process can own public `443` for a given IP/protocol unless a front
  router/proxy/load balancer is deciding where each connection goes.
- If the future website/API also wants `443`, Godot master owning that port
  becomes a conflict.

Direct Godot on `443` is most reasonable only if the master becomes the single
public gateway and world servers are internal. In the current direct-world
architecture, it is incomplete.

## How A Reverse Proxy Handles Multiple WebSocket Servers

A reverse proxy receives the initial HTTP WebSocket upgrade request, chooses a
backend, and then tunnels the upgraded connection.

It can choose by path:

```text
wss://game.example.com/master      -> 127.0.0.1:19080
wss://game.example.com/world/hub   -> 127.0.0.1:19081
wss://game.example.com/world/top   -> 127.0.0.1:19084
```

Or by subdomain:

```text
wss://master.game.example.com      -> 127.0.0.1:19080
wss://hub.game.example.com         -> 127.0.0.1:19081
wss://top.game.example.com         -> 127.0.0.1:19084
```

Or by public port:

```text
wss://game.example.com:19080       -> 127.0.0.1:19080
wss://game.example.com:19081       -> 127.0.0.1:19081
```

Path and subdomain routing are the useful forms because they can keep public
traffic on port `443`.

For this project, path-based routing would require changing `NET_CONFIG` so
world URLs can be full route URLs, not just `scheme://host:port`. The proxy
uses the path during the handshake; after that, the connection is just a
bidirectional tunnel to the chosen Godot process.

## What Load Balancing Means

Load balancing means distributing incoming connections across multiple backend
servers.

Example:

```text
Client -> load balancer -> server A
                       -> server B
                       -> server C
```

It is useful when there are multiple equivalent servers that can handle the same
kind of request.

For this project today:

- master is unique;
- each world process is unique;
- routing to the right world matters more than spreading clients randomly.

So "load balancing" is mostly irrelevant right now. We need routing, TLS, and
deployment reliability. Load balancing becomes relevant later if there are
multiple gateway/master replicas or multiple equivalent world instances for the
same world.

For WebSocket games, load balancing has an extra complication: connections are
long-lived and stateful. A load balancer must either keep a socket pinned to the
same backend or the backend architecture must be built for shared/distributed
state.

## Option C: DigitalOcean Load Balancer

Topology:

```text
Browser
  -> wss://game.example.com:443
  -> DigitalOcean Load Balancer
  -> Droplet/Godot
```

DigitalOcean documents WebSocket support on Load Balancers and supports SSL
termination. DigitalOcean regional HTTP Load Balancers start at about `$12/mo`
per node.

### Pros

- Managed TLS termination.
- No proxy process to run on the Droplet.
- WebSocket support is built into the managed service.
- Better availability/scaling path if multiple Droplets are added later.
- Keeps port `443` public.

### Cons

- Adds monthly cost.
- Adds provider-managed infrastructure to understand and configure.
- Still needs a routing story for master and multiple world servers.
- Does not automatically solve dynamic per-world routing by itself.
- For a single small VPS, it may cost more than the Droplet or a large fraction
  of the Droplet cost.

### Latency And Performance

A managed load balancer adds an extra network hop through DigitalOcean
infrastructure. It may be highly optimized, but it is still not zero. It is
usually chosen for manageability, standard TLS, and scaling, not because it is
the lowest-latency path for a single Droplet.

## Option D: Single Public Gateway

Topology:

```text
Browser
  -> wss://game.example.com:443
  -> Godot gateway/master
  -> internal world servers
```

This can be done with a reverse proxy or with Godot itself acting as the only
public WSS endpoint.

### Pros

- Best public client compatibility.
- Only one public gameplay port.
- World servers can stay private/internal.
- Simplifies firewall rules.
- Fits a future multi-host architecture better.
- Makes auth/session validation centralized.

### Cons

- Requires architectural work.
- The gateway may need to relay or route gameplay traffic.
- If it relays all gameplay packets, it becomes a new bottleneck and failure
  point.
- If it only hands out tickets and clients still connect directly to worlds,
  the multi-port issue remains.

This is probably the best long-term architecture for a large Web-first MMO, but
it is not the lowest-friction next step for the current codebase.

## Production Reachability

There are two different meanings of "works":

```text
Browser security works:
  HTTPS page -> wss://game.example.com:19080

Network reachability works:
  the user's network allows outbound TCP 19080
```

Native WSS solves browser security. It does not guarantee every user network
allows nonstandard ports.

For home users and normal networks, custom WSS ports are often fine. For
restricted networks, port `443` is the safest public lane because it looks like
normal HTTPS/WSS traffic. That is why many production WebSocket services prefer
WSS on `443`.

This does not mean native Godot WSS is non-production. It means native Godot WSS
on `19080-19180` is a production tradeoff: simpler and direct, but less
universally reachable than one `443` endpoint.

## Backend And Game Platform Patterns

The public documentation for game networking stacks points to a few common
patterns.

### Photon Fusion / Photon Realtime

Photon documents both WebSocket and Secure WebSocket ports. For restricted
networks, Photon specifically recommends secure WebSockets on port `443`.
Photon Cloud can use `443` for WSS, while Photon also documents dedicated WSS
ports such as `19090-19093` for name/master/game server roles.

Pattern:

```text
browser/WebGL -> WSS, preferably 443 for restricted networks
name/master/game server roles may still be distinct internally
```

Takeaway for VirtuCade:

- Photon validates the concern that `443` is best for reachability.
- Photon also validates that separate master/game server roles and distinct
  WebSocket endpoints are normal.
- Photon has infrastructure/client SDK behavior to hide much of that routing
  complexity.

### Nakama

Nakama exposes real-time sockets over WebSockets and rUDP. It is a monolithic
stateful game backend with HTTP/gRPC request APIs and WebSocket real-time APIs.
Heroic Cloud provisions DNS, load balancers with SSL/TLS, Nakama nodes,
database, logs, metrics, and scaling as a managed stack.

Pattern:

```text
client -> Nakama socket endpoint
managed/self-hosted infrastructure handles TLS and routing
Nakama routes realtime features internally
```

Takeaway for VirtuCade:

- Nakama is closer to a gateway/backend model than our current direct world-port
  model.
- Its production story uses a stable public socket endpoint and internal
  routing/message systems.
- For one VPS, our master is currently doing part of this role, but clients
  still connect directly to world processes.

### SpacetimeDB

SpacetimeDB clients use persistent WebSocket connections. The official
self-hosting guide runs SpacetimeDB on localhost and puts nginx in front with
Let's Encrypt. The guide explicitly proxies only selected public routes, such
as the database subscribe WebSocket route, while blocking other routes.

Pattern:

```text
client -> HTTPS/WSS nginx -> localhost SpacetimeDB
public routes are intentionally filtered
```

Takeaway for VirtuCade:

- SpacetimeDB strongly demonstrates the "reverse proxy as security boundary"
  pattern.
- It also shows why proxying is not only about TLS; it can restrict what the
  public internet can call.

### Colyseus

Colyseus is a WebSocket multiplayer framework. Its transport docs include direct
SSL key/certificate options for terminating TLS inside the Node application. Its
deployment docs also discuss SSL helpers and reverse-proxy deployment.

Pattern:

```text
either app terminates TLS directly
or reverse proxy terminates TLS and forwards WebSocket traffic
```

Takeaway for VirtuCade:

- Both native TLS and reverse-proxy TLS are accepted deployment shapes.
- The choice is operational, not purely technical.

### Unity WebGL / Unity Transport / Photon-Style WebGL

Unity Transport documentation says WebGL games distributed over HTTPS must use
WSS to connect to the game server. This matches the browser rule we hit with
GitHub Pages.

Pattern:

```text
HTTPS WebGL page -> WSS game connection
```

Takeaway for VirtuCade:

- The HTTPS to WSS requirement is not Godot-specific.
- Any Web-first build needs this solved before production testing.

### PlayFab Browser Multiplayer Samples

PlayFab has sample code for reverse proxying secure WebSocket browser traffic to
hosted multiplayer servers. The existence of this sample reinforces that browser
WSS often needs an edge/proxy layer when the actual game server is not directly
exposed as a browser-trusted TLS endpoint.

Pattern:

```text
browser WSS -> proxy -> hosted game server
```

Takeaway for VirtuCade:

- Browser multiplayer often needs a small compatibility layer when the server
  hosting model was not designed around browser WSS from the start.

## Industry Pattern Summary

Observed patterns:

| System | Public Web Transport | TLS Handling | Shape |
| --- | --- | --- | --- |
| Photon | WSS, often `443` for restricted networks | Photon Cloud / Photon Server config | Name/master/game roles |
| Nakama | WebSocket socket endpoint | Managed cloud load balancers or self-host config | Backend/gateway-style monolith |
| SpacetimeDB | Persistent WebSocket via HTTPS host | nginx + Let's Encrypt in self-host guide | Reverse proxy filters public routes |
| Colyseus | WebSocket | App TLS or reverse proxy | Room/match framework |
| Unity WebGL | WSS required from HTTPS page | Depends on backend/proxy | Browser transport requirement |
| PlayFab sample | Browser WSS | Reverse proxy sample | Proxy compatibility layer |

The common production-friendly browser pattern is:

```text
Use WSS.
Prefer 443 for maximum reachability.
Use native TLS only when the app/server architecture makes that simple.
Use proxy/load balancer/gateway when routing, certs, filtering, or 443 matter.
```

## Security Considerations

Native Godot WSS:

- Godot owns TLS private key access.
- All public gameplay ports are directly exposed.
- Firewall must be tight and intentional.
- Godot logs are the primary source of connection evidence.
- Rate limiting and abuse controls must be implemented in Godot or at the
  cloud firewall level.

Reverse proxy:

- Proxy owns TLS private key access.
- Godot can bind to `127.0.0.1` or private network.
- Proxy can add connection limits and logging before traffic reaches Godot.
- There is more software to patch and configure.

DigitalOcean Load Balancer:

- Provider owns managed TLS termination behavior.
- Droplet can be less directly exposed.
- Costs more and introduces provider configuration.

## Certificate Renewal

Native WSS needs an explicit renewal story:

```text
certbot renew
copy/read fullchain + privkey permissions
restart virtucade after renewal
```

For example:

```text
certbot deploy hook -> systemctl restart virtucade
```

The restart matters because the current Godot code loads the certificate and key
when the server starts. It does not hot-reload certificate files.

Caddy handles this more automatically. This is the strongest operational reason
to use Caddy despite the extra process.

## Recommended Production Path For This Project

For the current one-VPS architecture targeting 100-200 CCU:

```text
Use native Godot WSS first.
```

This is production-reasonable if all of the following are true:

- The game has one gameplay VPS.
- Master/world server ports are known and controlled.
- We can open a bounded world port range.
- We automate certificate renewal and service restart.
- We accept that some locked-down networks may block nonstandard ports.
- We measure real latency, CPU, memory, disconnects, and connect failures during
  dogfooding.

This is not "prototype only." It is a valid small-production shape with a clear
tradeoff.

## When To Switch To Proxy Or Gateway

Switch to Caddy/nginx or a load balancer if any of these become true:

- Players report connection failures from networks that allow normal HTTPS.
- We want all browser gameplay traffic on `443`.
- We do not want Godot to read private TLS keys.
- Certificate renewal/restart becomes operationally annoying.
- We need centralized rate limiting or better edge logs.
- We need to hide public world ports.
- We move beyond one gameplay VPS.
- We want world routing by path/subdomain instead of public per-world ports.

Switch to a single public gateway architecture if:

- We want the cleanest long-term MMO shape.
- We want world servers fully private.
- We want all session, auth, and routing through one public WSS endpoint.
- We are ready to design and benchmark gateway forwarding or message routing.

## Practical Test Plan

1. Add a DNS record:

```text
game.example.com -> VPS public IP
```

2. Generate a real certificate with Let's Encrypt/Certbot.

3. Configure the VPS service:

```text
MULTI_SERVER_CLIENT_HOST=game.example.com
MULTI_SERVER_CLIENT_SCHEME=wss
MULTI_SERVER_TLS_CERT=/etc/letsencrypt/live/game.example.com/fullchain.pem
MULTI_SERVER_TLS_KEY=/etc/letsencrypt/live/game.example.com/privkey.pem
```

4. Open only the required gameplay ports:

```text
19080/tcp
19081-19084/tcp for the current worlds
```

Use a wider bounded range only when the world count needs it.

5. Test:

```text
https://shilo.github.io/multi-server-test/?server_host=game.example.com&server_scheme=wss
```

6. Measure:

- connect success rate;
- master connect latency;
- world connect latency;
- transfer latency;
- disconnects;
- CPU and memory on the Droplet;
- DigitalOcean network metrics;
- Godot `PERF_SAMPLE` logs.

7. Decide after evidence:

```text
If WSS native ports are stable and reachable: keep native WSS.
If nonstandard ports hurt users: add Caddy or redesign toward a 443 gateway.
```

## Summary

Native Godot WSS is not a hack. Godot officially supports TLS-backed WebSocket
servers, and this project already wires the needed options. For one VPS and
100-200 CCU, it is production-reasonable and has the least runtime overhead.

Reverse proxying is not mainly a performance improvement. It is an operations,
security-boundary, certificate-management, and reachability improvement. Its
latency overhead on the same VPS should normally be small at this scale, but it
does add another process and configuration surface.

The best current decision is:

```text
Start with native Godot WSS for production testing.
Keep Caddy/reverse proxy as the fallback if real users hit nonstandard-port
reachability problems or cert operations become annoying.
Plan a single 443 gateway only when the architecture needs it.
```

After the backend survey, the sharper production recommendation is:

```text
Native WSS on 19080-19180 is acceptable for controlled production testing.
For the most broadly reachable Web production deployment, design toward one
public 443 endpoint, either through a reverse proxy or a gateway.
```

## Sources

- Godot `WebSocketMultiplayerPeer.create_server()` supports
  `tls_server_options`:
  https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html
- Godot `TLSOptions.server()` creates a TLS server config from key and
  certificate:
  https://docs.godotengine.org/en/stable/classes/class_tlsoptions.html
- Godot TLS certificate docs warn that the private key must stay server-side:
  https://docs.godotengine.org/en/stable/tutorials/networking/ssl_certificates.html
- Godot Web export docs note browser behavior and Web platform limitations:
  https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_web.html
- MDN mixed content overview:
  https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content
- Caddy reverse proxy docs:
  https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- Caddy reverse proxy quick-start:
  https://caddyserver.com/docs/quick-starts/reverse-proxy
- nginx official WebSocket proxying docs:
  https://nginx.org/en/docs/http/websocket.html
- DigitalOcean Load Balancer features, including WebSocket support and SSL
  termination:
  https://docs.digitalocean.com/products/networking/load-balancers/details/features/
- DigitalOcean Load Balancer pricing:
  https://docs.digitalocean.com/products/networking/load-balancers/details/pricing/
- DigitalOcean Load Balancer limits:
  https://docs.digitalocean.com/products/networking/load-balancers/details/limits/
- Cloudflare supported proxy ports, useful as evidence that public edge systems
  often restrict which ports can be proxied:
  https://developers.cloudflare.com/fundamentals/reference/network-ports/
- Photon secure network docs recommending WebSocketSecure on port 443:
  https://doc.photonengine.com/realtime/current/connection-and-authentication/secure-networks
- Photon port-number docs showing WSS on 443 and dedicated WSS ports:
  https://doc.photonengine.com/realtime/current/connection-and-authentication/tcp-and-udp-port-numbers
- Photon Server Secure WebSockets setup:
  https://doc.photonengine.com/server/v4/operations/websockets-ssl-setup
- Nakama configuration docs:
  https://heroiclabs.com/docs/nakama/getting-started/configuration/
- Nakama socket docs:
  https://heroiclabs.com/docs/nakama/concepts/sockets/
- Nakama architecture overview:
  https://heroiclabs.com/docs/nakama/getting-started/architecture/
- Heroic Cloud managed stack overview:
  https://heroiclabs.com/docs/heroic-cloud/introduction/
- SpacetimeDB self-hosting with nginx and Let's Encrypt:
  https://spacetimedb.com/docs/how-to/deploy/self-hosting/
- SpacetimeDB connection docs:
  https://spacetimedb.com/docs/clients/connection/
- Colyseus transport docs:
  https://0-14-x.docs.colyseus.io/colyseus/server/transport/
- Colyseus deployment docs:
  https://0-14-x.docs.colyseus.io/colyseus/deployment/
- Unity Transport WebGL secure WebSocket docs:
  https://docs.unity3d.com/Packages/com.unity.transport%402.5/manual/websockets.html
- PlayFab secure WebSocket reverse proxy sample:
  https://github.com/PlayFab/MultiplayerServerSecureWebsocket
