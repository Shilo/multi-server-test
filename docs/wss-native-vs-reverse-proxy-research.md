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
  - `MULTI_SERVER_BIND_HOST`
  - `MULTI_SERVER_PUBLIC_MASTER_URL`
  - `MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE`
  - `MULTI_SERVER_TLS_CERT`
  - `MULTI_SERVER_TLS_KEY`
  - `MULTI_SERVER_CLIENT_SCHEME`
  - `MULTI_SERVER_CLIENT_HOST`
- The Web client can be pointed at `wss://` by using `master_url` and
  `world_url_template` query parameters. The older `server_host` /
  `server_scheme` fallback still exists for simple port-based testing.

That means native WSS is not theoretical for this codebase. The remaining work
is domain, certificate, permission, firewall, and renewal handling.

## Local Godot Reference: `godot-tiny-mmo`

The local `C:\Programming_Files\Godot\godot-tiny-mmo` project uses a small
project-specific networking helper pattern, not a reusable WSS addon.

Relevant findings:

- `source/common/network/endpoints/base_multiplayer_endpoint.gd` creates a
  `WebSocketMultiplayerPeer`, accepts optional `TLSOptions`, builds
  `ws://host:port` for bare hosts, and preserves full `ws://` or `wss://` URLs
  as-is.
- Its comments explicitly mention full reverse-proxy URLs such as
  `wss://.../world/1` and name Caddy/nginx as the production-style path.
- `source/common/network/utils/tls_options_utils.gd` can build server/client
  `TLSOptions` from certificate/key paths.
- Several config files include certificate/key paths, but the searched runtime
  call sites appear to call the endpoint helper without passing `TLSOptions`.
- The `reverse-proxy` branch adds a project Caddyfile renderer for this repo,
  while `godot-tiny-mmo` keeps proxy support as a URL/config convention.
- Its addons are unrelated to WSS/TLS. The networking code lives under
  `source/common/network`, not `addons/`.

Comparison to this project:

- `shared/net/net_config.gd` already plays the same role: central URL
  construction, environment/query overrides, and TLS server option loading.
- `server/master/master.gd`, `server/world/world.gd`, and `client/client.gd`
  already consume that helper.
- This supports keeping WSS/TLS handling as a tiny project-local helper/config
  pattern for now, not a PackRat-style addon.

Challenge:

PackRat deserves to be an addon because downloadable PCK caching is a reusable
domain with meaningful internal state, file layout, validation, and editor
testing behavior. WSS/TLS setup here is mostly deployment configuration plus a
few Godot primitives. Turning it into an addon now would likely add ceremony
without removing real complexity.

## Godot Official Guidance And Tutorials

Official Godot documentation supports native WSS directly through
`WebSocketMultiplayerPeer` and `TLSOptions`:

- `WebSocketMultiplayerPeer.create_client(url, tls_client_options)` supports
  `wss://` URLs and verifies TLS certificates against the hostname.
- `WebSocketMultiplayerPeer.create_server(port, bind_address,
  tls_server_options)` can start a TLS-backed WebSocket server when passed
  `TLSOptions.server(...)`.
- `TLSOptions.server(key, certificate)` creates the server TLS configuration
  from a `CryptoKey` and `X509Certificate`.
- The certificate should include the full chain up to the signing CA.
- Godot's lower-level WebSocket tutorial describes `wss://` as the secure
  WebSocket scheme and `ws://` as plaintext/insecure.
- Web exports can use WebSocket clients, but browser-side TLS validation is
  enforced. Unsafe client options or custom trust shortcuts are not a real
  production workaround for hosted browser builds.
- Public browser WSS should use a fully qualified domain name that matches the
  certificate. Direct IP-address WSS commonly fails certificate validation.

What Godot does not provide is a full production hosting recipe. The official
API gives the primitives; the server owner is still responsible for:

- acquiring a browser-trusted certificate for the public hostname;
- keeping the private key server-side;
- making certificate/key files readable by the server process without leaking
  them into client exports;
- renewing certificates and restarting/reloading the server if needed;
- deciding whether TLS terminates in Godot, a reverse proxy, or a load
  balancer.

Godot does not appear to officially prefer reverse proxy TLS over native
`TLSOptions` WSS. It documents the native API and browser constraints. Reverse
proxy TLS termination appears mostly in deployment guides because it makes
certificate issuance, renewal, standard `443` hosting, and operational
hardening easier.

Godot community/tutorial material is useful but uneven:

- Godot's official blog post on WebSocket SSL and HTML5 testing is old
  Godot 3-era material, but still useful historically because it demonstrates
  the intended shape: Web exports need secure WebSocket testing, and Godot
  supports SSL/TLS-backed WebSockets.
- Forum answers consistently say browser-hosted Godot games need a trusted
  certificate and `wss://` when the page is served over HTTPS.
- Forum/tutorial examples often show loading Let's Encrypt/certbot certificate
  files into `TLSOptions` for a native Godot WSS server.
- PlayFlow's Godot multiplayer guide uses `WebSocketMultiplayerPeer`,
  `create_client("wss://...")`, and platform-managed TLS. It is useful if using
  PlayFlow, but vendor-specific.
- Harlepengren's browser-compatible Godot multiplayer article shows nginx SSL
  termination, WebSocket upgrade headers, and timeout settings. It is a useful
  deployment example, but community-authored.
- Simon Dalvai's itch.io WebSocket article shows a concise Caddy reverse
  proxy/WSS setup. It is practical, but the author explicitly warns it may not
  be production-best-practice.
- Some older videos/tutorials cover Godot WebSocket multiplayer or generic TLS,
  but they should be treated as implementation references, not deployment
  authority. Official docs and current source should win.

This reinforces the code-architecture recommendation:

```text
Godot supports native WSS.
Godot does not remove the production cert/routing/firewall problem.
Keep our code as a small NET_CONFIG helper unless WSS config becomes a larger
reusable domain with real state and workflow.
```

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

Nakama can also be configured with native SSL certificate/private-key settings,
but its configuration documentation marks direct server SSL as not recommended
for production. That pushes the production default toward edge TLS termination
through a proxy/load balancer or Heroic Cloud.

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

Current Colyseus deployment guidance leans toward nginx/PM2 or Colyseus Cloud,
with the public TLS/WebSocket edge handled outside the room process.

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

Unity Transport can run secure WebSockets directly with certificate/key data,
but Unity also recommends Relay or a reverse proxy when the game server should
not directly manage certificates.

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
| Nakama | WebSocket socket endpoint | Native SSL exists, edge TLS preferred for production | Backend/gateway-style monolith |
| SpacetimeDB | Persistent WebSocket via HTTPS host | nginx + Let's Encrypt in self-host guide | Reverse proxy filters public routes |
| Colyseus | WebSocket | nginx/cloud edge commonly used | Room/match framework |
| Unity WebGL | WSS required from HTTPS page | Native TLS, Relay, or proxy | Browser transport requirement |
| PlayFab sample | Browser WSS | Reverse proxy sample | Proxy compatibility layer |

The common production-friendly browser pattern is:

```text
Use WSS.
Prefer 443 for maximum reachability.
Use native TLS only when the app/server architecture makes that simple.
Use proxy/load balancer/gateway when routing, certs, filtering, or 443 matter.
```

The broader pattern does not make native Godot WSS wrong. It does mean native
WSS on `19080+` should be treated as a deliberate small-scale tradeoff, while
`443` edge termination is the safer default for public Web reachability.

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

Let's Encrypt's current default certificate lifetime is 90 days, and they
recommend renewing those certificates every 60 days. Let's Encrypt has also
announced that certificate lifetimes will be reduced to 45 days by 2028, so
automatic renewal should be treated as mandatory for production.

The restart matters because the current Godot code loads the certificate and key
when the server starts. It does not hot-reload certificate files.

Caddy handles certificate provisioning and renewal automatically and swaps
certificates without requiring the Godot service to restart. This is one of the
strongest operational reasons to use Caddy despite the extra process.

## Recommended Production Path For This Project

For the current one-VPS architecture targeting 100-200 CCU, the standardized
production decision is:

```text
Caddy reverse proxy on public 443.
Godot master/world servers on private localhost ws:// ports.
```

Caddy should be used strictly as the WSS-to-WS edge for gameplay traffic:

```text
Internet -> wss://game.example.com/... -> Caddy :443
         -> ws://127.0.0.1:19080+ -> Godot
```

This is not mainly a latency decision. The same-VPS localhost hop should be
small compared with WAN latency, Godot tick timing, database work, and gameplay
simulation. The decision is mainly about:

- keeping TLS/cert/key handling out of Godot;
- keeping TLS crypto out of Godot's multiplayer polling path;
- using one standard public `443` entrypoint;
- hiding direct world ports from the public internet;
- avoiding Godot restarts for certificate renewal;
- matching the common WebSocket production pattern used by other game/backend
  stacks.

Native Godot WSS remains a valid fallback/diagnostic mode if all of the
following are true:

- The game has one gameplay VPS.
- Master/world server ports are known and controlled.
- We can open a bounded world port range.
- We automate certificate renewal and service restart.
- We accept that some locked-down networks may block nonstandard ports.
- We measure real latency, CPU, memory, disconnects, and connect failures during
  real testing.

This is not "prototype only." It is a valid small-production shape with a clear
tradeoff.

## When To Switch To Proxy Or Gateway

Use Caddy now for the standard production path. Reconsider native WSS only if:

- Caddy causes measured CPU/RAM/latency problems;
- Caddy config/reload behavior becomes more complex than native certbot;
- direct public world ports are acceptable and easier for the final server
  shape;
- profiling shows Godot-native TLS is smoother in the real workload.

Switch to a single public gateway architecture if:

- We want the cleanest long-term MMO shape.
- We want world servers fully private.
- We want all session, auth, and routing through one public WSS endpoint.
- We are ready to design and benchmark gateway forwarding or message routing.

## Reverse Proxy Choice

Use Caddy, not nginx/HAProxy/Traefik/Envoy, for the first production route.

| Option | Verdict |
| --- | --- |
| Caddy | Best default. Automatic HTTPS, simple config, WebSocket reverse proxy support, and direct localhost upstreams. |
| nginx | Very mature and lean, but requires more manual TLS renewal, WebSocket upgrade headers, and timeout config. |
| HAProxy | Excellent for advanced proxying/load balancing, but cert automation is external and the setup is less beginner-friendly. |
| Traefik | Useful for Docker/Kubernetes/service discovery, more machinery than this project needs. |
| Envoy | Powerful service-mesh/proxy tool, overkill for one VPS and a few localhost ports. |

For this project, the reverse proxy is not a web host. It should only do:

```text
public wss:// -> private ws://127.0.0.1:<godot-port>
```

That keeps the proxy's job small and makes resource use easier to reason about.

### Proxy Performance And Process Choice

Do not write a custom reverse proxy for this. It would mean owning TLS,
WebSocket upgrade behavior, reload behavior, abuse handling, security fixes,
and long-lived connection bugs. Existing proxies already solve that problem.

| Option | Implementation | Performance/Resource Notes | Operational Notes | Fit |
| --- | --- | --- | --- | --- |
| Caddy | Go | Efficient enough for 100-200 CCU; likely a little heavier than nginx/HAProxy, but still small for this use case. | Automatic HTTPS/renewal and simple config are the major wins. | Best overall first choice. |
| nginx | C | Very lean, mature, and fast. | Requires explicit WebSocket upgrade headers, certbot or another ACME flow, reload handling, and timeout tuning. | Best if we later want leaner manual ops. |
| HAProxy | C | Excellent for long-lived connections and high-performance proxy/load-balancing. | Cert automation is external; config is more proxy-specialist oriented. | Best pure-performance fallback. |
| Traefik | Go | Fine performance, but aimed at dynamic service discovery. | Useful for Docker/Kubernetes; extra moving parts for one VPS. | Overkill now. |
| Envoy | C++ | High-performance, but built for complex service-mesh/data-plane use. | Large config and operational surface. | Overkill now. |
| Custom Go/Rust proxy | Go/Rust | Could be tailored, but would need benchmarking and hardening. | We would own security, certs, reloads, and WebSocket edge bugs. | Bad tradeoff. |

If everything is perfectly configured, nginx or HAProxy may be leaner than
Caddy. That does not make them the best first choice. At our target scale,
misconfigured certificates, reload behavior, WebSocket timeouts, and deployment
friction are bigger risks than Caddy's small extra overhead.

The decision rule is:

```text
Start with Caddy.
Measure CPU/RAM/latency during real VPS tests.
Switch to nginx or HAProxy only if Caddy is a measured bottleneck or its reload
behavior becomes a real operational problem.
```

Caddy is not overengineering if the Caddyfile stays small and static. Its extra
features do not need to be used. The main operational caveat is that Caddy
config reloads can close long-lived WebSocket streams unless configured and
handled carefully. Use `stream_close_delay` and normal client reconnect logic
if/when reloading Caddy while players are connected.

## Reverse Proxy Endpoint Rules

Use a static endpoint key to deterministic port table. Do not rewrite proxy
routes dynamically when worlds start or stop.

Recommended endpoint shape:

```text
wss://game.example.com/          -> master on 127.0.0.1:19080
wss://game.example.com/hub       -> hub on 127.0.0.1:19081
wss://game.example.com/top_world -> top_world on 127.0.0.1:19082
```

Use `/master` instead of `/` only if the same hostname may later serve normal
HTTP/API traffic. If root is used for master, it must be an exact root match,
not a catch-all fallback that could accidentally swallow world routes.

The important safety rule is:

```text
World key owns a stable port.
Proxy config is static.
Master advertises world keys/URLs, not arbitrary runtime ports.
```

This removes the race where a world starts on a random port, the proxy config
reloads, and the client receives a route while old/new proxy state disagree. If
`/hub` is always `19081`, then a stopped or restarting hub produces a failed
connection or retry window, not a silent route to the wrong world.

Avoid:

- dynamic proxy config rewrites during world lifecycle;
- generic endpoint-by-port paths such as `/19081`, except maybe for private
  diagnostics;
- using proxy reloads as a synchronization primitive.

Even with static routes, keep the existing application-level authority model:
the client should connect with the expected world key and a short-lived
master-issued join ticket, and the world should reject the connection if it is
not the expected world. The proxy stays dumb and static; the master/world
handshake owns correctness.

## Practical Test Plan

Proxy production test:

1. Add a DNS record:

```text
game.example.com -> VPS public IP
```

2. Install Caddy and configure a dedicated WSS hostname.

3. Keep Godot bound to localhost/private ports where possible:

```text
127.0.0.1:19080
127.0.0.1:19081+
```

4. Route public WSS URLs to deterministic backend ports:

```text
wss://game.example.com/          -> ws://127.0.0.1:19080
wss://game.example.com/hub       -> ws://127.0.0.1:19081
wss://game.example.com/top_world -> ws://127.0.0.1:19082
```

5. Update `NET_CONFIG` to support route URLs or route templates, because the
   current code can build `scheme://host:port` but not arbitrary path-based
   endpoints.

6. Open only public `80/443` for gameplay WSS if all client traffic goes
   through Caddy. Keep `19080+` closed publicly.

7. Measure:

- connect success rate;
- master connect latency;
- world connect latency;
- transfer latency;
- disconnects;
- Caddy CPU/RAM;
- Godot CPU/RAM;
- DigitalOcean network metrics;
- Godot `PERF_SAMPLE` logs.

Native WSS fallback test:

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
If Caddy causes measured problems: compare native WSS again.
If native WSS is smoother and operationally acceptable: reconsider.
```

## Implementation Status

The `reverse-proxy` branch implements this recommendation with:

- `MULTI_SERVER_BIND_HOST=127.0.0.1` for private Godot listeners.
- `MULTI_SERVER_PUBLIC_MASTER_URL=wss://<host>/`.
- `MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE=wss://<host>/{world_key}`.
- A generated Caddyfile with exact static routes for every discovered
  `server/worlds/<world_key>/` folder.
- Optional GitHub Actions deployment when `VIRTUCADE_GAME_HOST` is configured.

The proxy config remains static; the master still owns temporary world process
startup, TravelLeases, join tickets, and admission correctness.

## Summary

Native Godot WSS is not a hack. Godot officially supports TLS-backed WebSocket
servers, and this project already wires the needed options. For one VPS and
100-200 CCU, it is production-reasonable as a fallback/diagnostic route.

Caddy reverse proxying is the standardized production recommendation. It is not
mainly a raw latency improvement. It is an operations, security-boundary,
certificate-management, CPU-isolation, and reachability improvement. Its
latency overhead on the same VPS should normally be small at this scale, but it
does add another process and configuration surface.

The best current decision is:

```text
Caddy on public 443.
Static endpoint-to-port routes.
Godot on localhost ws:// ports.
Native Godot WSS kept as fallback/diagnostic mode.
```

The endpoint rule is:

```text
Never mutate proxy routes as worlds start/stop.
Use deterministic world ports and master-issued join tickets.
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
- Godot `WebSocketPeer` docs, including certificate/hostname behavior:
  https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html
- Godot WebSocket tutorial:
  https://docs.godotengine.org/en/stable/tutorials/networking/websocket.html
- Godot Web export docs note browser behavior and Web platform limitations:
  https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_web.html
- Godot blog post on WebSocket SSL testing for HTML5 exports:
  https://godotengine.org/article/websocket-ssl-testing-html5-export/
- Godot forum answer on secure WebSockets for HTTPS web exports:
  https://forum.godotengine.org/t/how-to-secure-websockets-for-https-on-web-exports/73859
- PlayFlow Godot multiplayer guide:
  https://docs.playflowcloud.com/guides/godot-first-multiplayer-game
- Harlepengren browser-compatible Godot multiplayer deployment write-up:
  https://harlepengren.com/from-local-to-online-building-browser-compatible-godot-multiplayer-game/
- Simon Dalvai Godot WebSocket on itch.io with Caddy:
  https://simondalvai.org/blog/godot-websocket-itchio/
- MDN mixed content overview:
  https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content
- Caddy reverse proxy docs:
  https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- Caddy reverse proxy quick-start:
  https://caddyserver.com/docs/quick-starts/reverse-proxy
- Caddy automatic HTTPS docs:
  https://caddyserver.com/docs/automatic-https
- Caddy path matcher docs:
  https://caddyserver.com/docs/caddyfile/matchers
- Caddy reload docs:
  https://caddyserver.com/docs/getting-started#reloading-config
- nginx official WebSocket proxying docs:
  https://nginx.org/en/docs/http/websocket.html
- nginx control/reload docs:
  https://nginx.org/en/docs/control.html
- HAProxy WebSocket docs:
  https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/websocket/
- Traefik docs:
  https://doc.traefik.io/traefik/
- Envoy HTTP upgrade/WebSocket docs:
  https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/upgrades.html
- Let's Encrypt FAQ on 90-day certificates and renewing every 60 days:
  https://letsencrypt.org/docs/faq/
- Let's Encrypt 45-day certificate lifetime announcement:
  https://letsencrypt.org/2025/12/02/from-90-to-45
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
- Nakama JavaScript client SSL/socket options:
  https://heroiclabs.github.io/nakama-js/
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
- Current Colyseus deployment docs:
  https://docs.colyseus.io/deployment
- Current Colyseus scalability docs:
  https://docs.colyseus.io/scalability
- Colyseus Cloud docs:
  https://docs.colyseus.io/cloud
- Unity Transport WebGL secure WebSocket docs:
  https://docs.unity3d.com/Packages/com.unity.transport%402.5/manual/websockets.html
- PlayFab secure WebSocket reverse proxy sample:
  https://github.com/PlayFab/MultiplayerServerSecureWebsocket
- General WebSocket deployment guidance noting that production WebSocket
  servers are usually behind a TLS-terminating reverse proxy:
  https://websockets.readthedocs.io/en/stable/howto/encryption.html
