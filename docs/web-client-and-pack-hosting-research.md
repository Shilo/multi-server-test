# Web Client And PCK Hosting Research

Date: 2026-06-16

## Goal

VirtuCade should be playable from the browser, and downloadable world PCK files
should not compete with the master/world server processes for bandwidth. The
web client host should also host the downloadable PCK files when practical, so
players load the game and worlds from one public domain.

Think of the deployment as two separate responsibilities:

```text
VPS/game host:
  master server
  database
  world server processes
  gameplay networking bandwidth

Static web host:
  website
  Web client files
  downloadable PCK files
  browser/client download bandwidth
```

The game server VPS should not be the default public file host for PCK
downloads once the project is treated as a showcase product. Separating these
roles keeps heavy one-time downloads from interfering with live gameplay.

## Current Project Shape

The exported Web client expects downloadable packs at:

```text
<web client origin>/world_packs/<world_key>.pck
```

When running in Web, `shared/net/net_config.gd` first derives the world-pack
base URL from the current page URL. For example:

```text
https://shilo.github.io/multi-server-test/index.html
```

derives:

```text
https://shilo.github.io/multi-server-test/world_packs
```

This is the right default because it keeps the Web client and PCK files on the
same public host.

The master server still needs to advertise the same public pack URL to clients
when it sends PackRat metadata. For local or VPS testing, that can be supplied
with:

```text
MULTI_SERVER_WORLD_PACK_BASE_URL=https://<host>/<path>/world_packs
MULTI_SERVER_WORLD_PACK_DIR=<server-readable folder containing matching pcks>
```

`MULTI_SERVER_WORLD_PACK_BASE_URL` is not just test cruft. It lets the server
advertise the current public pack host without rebuilding the game.

`MULTI_SERVER_WORLD_PACK_DIR` lets the master read local file size and modified
time for the same pack version it is advertising. That can be a local mirrored
copy of the deployed PCK files, not necessarily the public web server's storage
folder.

## Hosting Options

### GitHub Pages

GitHub Pages is acceptable for the current low-bandwidth showcase if packs stay
small and cache invalidation is not constant.

Useful facts:

- GitHub Pages supports private repositories on paid GitHub plans, but the
  published site is public.
- Published GitHub Pages sites may be no larger than 1 GB.
- GitHub Pages has a soft bandwidth limit of 100 GB per month.
- Rate limiting can return HTTP 429.
- GitHub may ask high-impact sites to use a CDN or other hosting service.

Source: [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

Bandwidth estimate for 10 MB world packs:

```text
100 GB/month ~= 100,000 MB/month
10 MB per pack ~= 10,000 pack downloads/month
```

Example scenarios:

```text
50 new users/day * 4 packs * 10 MB * 30 days = 60 GB/month
200 new users/day * 4 packs * 10 MB * 30 days = 240 GB/month
```

Because PackRat caches packs, CCU alone is not the bandwidth driver. The real
driver is new users plus updates that force returning users to redownload packs.

GitHub Pages is therefore reasonable for:

- Current public demo/showcase.
- 10 MB-ish packs.
- Low update frequency.
- Modest unique user count.
- Proving that downloadable client files are hosted separately from the
  gameplay VPS.

GitHub Pages is weak for:

- Frequent content updates.
- Many worlds downloaded by every player.
- Large packs.
- A polished production launch where rate limits or soft quota warnings would
  be embarrassing.

Speed is not the main reason to avoid GitHub Pages early. Public static-host
benchmarks generally show GitHub Pages can be fast enough for static files,
though Cloudflare is often faster and more configurable. The practical concerns
are bandwidth limits, published site size, less control over cache/CDN behavior,
and the risk of rate limiting or GitHub support pressure if the project grows.

Sources:

- [Cloudflare Pages vs GitHub Pages performance comparison](https://bejamas.com/compare/cloudflare-pages-vs-github-pages)
- [Static site hosting speed test](https://www.ajnisbet.com/blog/static-site-speedtest)

For this project, GitHub Pages is the recommended current test host. It gives
us the important deployment boundary now:

```text
GitHub Pages:
  website
  Web client
  Web-targeted PCK files

localhost/Hetzner later:
  master server
  database
  world server processes
  gameplay traffic
```

The manual GitHub Actions release workflow exports the Web client and Web world
packs, verifies the export contents, uploads `builds/web/` as a GitHub Pages
artifact, and deploys that artifact with `actions/deploy-pages`.

This should remain **Settings -> Pages -> Build and deployment -> Source:
GitHub Actions**. Do not use **Deploy from a branch** for this project. Branch
deployment is best when the repository already contains the static files to
serve, or when a simple documentation branch is acceptable. This project has a
real release build: Godot Web files, Web-targeted world PCKs, Linux server
artifact, version bump, and release tag all need to be produced and validated by
one workflow.

Do not publish generated Godot Web files by pushing them to a `gh-pages` branch
from CI. GitHub documents that commits pushed by the workflow `GITHUB_TOKEN` do
not trigger a branch-based Pages build, and this project hit that exact failure:
the `gh-pages` branch contained the built files while the public site still
returned 404 until a Pages build was manually triggered.

With the GitHub Actions publishing model, built PCK files are not committed as
repository files. They remain inspectable through the workflow artifact and
through their deployed URLs, such as `/world_packs/hub.pck?v=<version>`.

GitHub Actions Pages does not expose an FTP-like browser for the deployed file
tree. The reliable management model for this project is:

- keep source and release version in git on `main`;
- keep release history as tags such as `v0.6`;
- keep generated binaries out of git history;
- inspect generated release outputs through workflow artifacts;
- inspect the live deployed file list through
  `https://shilo.github.io/multi-server-test/deployment_manifest.json`.

The manifest is generated during export and includes every deployed Web/PCK
file path, size, SHA-256 fingerprint, project version, source commit, and
workflow run id. This keeps the useful visibility of a generated deployment
branch without creating a second mutable branch of generated binaries.

Compared with the `mimic` repository, the same GitHub Actions Pages model is
still correct, but the output is different. `mimic` deploys documentation and a
playable Web example. `multi-server-test` deploys a Web game plus runtime DLC
PCK files, so the world packs must live inside the Pages artifact and be listed
in the deployment manifest.

After deployment, the browser URL is:

```text
https://shilo.github.io/multi-server-test/
```

The default PackRat URL advertised by the master is currently:

```text
https://shilo.github.io/multi-server-test/world_packs
```

The default server-side metadata folder is currently:

```text
builds/web/world_packs
```

That pairing matters. The master must send size/modified-time metadata for the
same Web-targeted PCK files that GitHub Pages serves.

### Cloudflare Pages

Cloudflare Pages is good for hosting the Web client shell. It advertises
unlimited static requests and bandwidth on its public marketing page.

Source: [Cloudflare Pages](https://pages.cloudflare.com/)

However, Cloudflare Pages has a 25 MiB per-file asset limit. Cloudflare's own
docs recommend using R2 for larger files.

Source: [Cloudflare Pages limits](https://developers.cloudflare.com/pages/platform/limits/)

This means Cloudflare Pages alone is fine only while PCK files remain below
25 MiB. If worlds grow, use Cloudflare Pages for the Web client and Cloudflare
R2 for `/world_packs/`.

There is also a Spain-specific availability concern. Spain has had repeated
LaLiga anti-piracy blocks affecting shared Cloudflare IPs, especially during
football match windows. This is not a total permanent Spain-wide Cloudflare
block, but it has caused unrelated legitimate Cloudflare-hosted services to be
unreachable for some Spanish users. If Spain availability matters, Cloudflare
should not be treated as a risk-free default.

Sources:

- [Broadband TV News: Cloudflare legal action over LaLiga blocking](https://www.broadbandtvnews.com/2025/02/19/cloudflare-takes-legal-action-over-laligas-disproportionate-blocking-efforts/)
- [Vercel: update on Spain and LALIGA blocks](https://vercel.com/blog/update-on-spain-and-laliga-blocks-of-the-internet)
- [TechRadar: LaLiga internet disruptions in Spain](https://www.techradar.com/vpn/vpn-privacy-security/la-ligas-war-on-piracy-is-breaking-the-internet-in-spain-and-your-vpn-could-be-the-next-target)

Best Cloudflare architecture:

```text
play.virtucade.com/              -> Cloudflare Pages Web client
play.virtucade.com/world_packs/* -> Cloudflare R2 public bucket or Worker route
```

This keeps one public domain while letting large PCK files live in object
storage.

### Cloudflare R2

Cloudflare R2 is the strongest low-friction option for PCK files if we want
bandwidth not to be the painful part of the architecture.

Useful facts:

- Standard storage is priced per GB-month.
- R2 does not charge egress bandwidth to the Internet.
- Free tier includes 10 GB-month storage and request allowances.

Source: [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)

R2 is a good fit for:

- Large PCKs.
- Cacheable downloadable assets.
- Serving the same files to many users.
- Avoiding game server bandwidth impact.

Tradeoff:

- Slightly more setup than GitHub Pages.
- Need a deployment/upload step for PCK files.
- If serving from a separate subdomain, configure CORS. A same-domain route is
  cleaner.

### Bunny Storage + Bunny CDN

Bunny is a good "simple paid CDN" option. It is attractive if we want predictable
pay-as-you-go pricing and a dashboard that is more directly about files/CDN.

Useful facts:

- Bunny CDN standard tier is about $0.01/GB for Europe/North America traffic.
- Bunny volume tier starts around $0.005/GB for high-bandwidth projects.
- Bunny Storage standard HDD is about $0.01/GB per storage region.
- Bunny has a low monthly minimum.

Sources:

- [Bunny CDN pricing](https://bunny.net/pricing/cdn/)
- [Bunny Storage pricing](https://bunny.net/pricing/storage/)

Bunny is a good fit for:

- Simple static asset hosting.
- Clear bandwidth billing.
- Projects that prefer explicit CDN billing over Cloudflare's broader platform.

Tradeoff:

- Unlike R2, public bandwidth is paid.
- At VirtuCade's expected early scale, the bill should still be tiny.

## Recommendation

Use GitHub Pages for the immediate public showcase while all of this remains
roughly true:

- Web client plus all current PCK files fit comfortably under 1 GB.
- Individual PCKs stay well below GitHub's practical large-file pain points.
- Expected monthly PCK transfer stays below roughly 100 GB.
- Updates are infrequent enough that returning users usually keep cached packs.

This is a useful prototype path because it already exercises the production
boundary: the browser downloads the Web client and PCK files from a static web
host, while the VPS handles only master/world/database gameplay traffic. If
GitHub Pages becomes too limiting, the same public hosting role can move to
Cloudflare, Bunny, or another CDN/static host without changing the core game
server architecture.

For the more production-shaped VirtuCade path, keep the same responsibility
split even if the static host changes:

```text
Static web host:
  /                 Website / Web client
  /world_packs/     PCK files

Hetzner VPS:
  master server
  world server processes
  SQLite/database
  local mirrored PCK metadata folder
```

If PCK files are always under 25 MiB and Spain availability is not a concern,
Cloudflare Pages can host both the Web client and PCK files directly. If PCK
files can exceed 25 MiB, use Cloudflare Pages for the Web client and R2 for
`/world_packs/`. If Spain availability is important, compare Bunny or another
non-Cloudflare static/CDN host before choosing Cloudflare.

The same-origin path is important:

```text
https://play.virtucade.com/index.html
https://play.virtucade.com/world_packs/hub.pck
```

That is better than:

```text
https://play.virtucade.com/index.html
https://packs.virtucade.com/hub.pck
```

because the same-origin shape avoids CORS surprises and lets
`net_config.gd` derive the default pack base URL automatically.

## Deployment Notes

The master server should not guess remote metadata from HTTP during travel. It
should use local file metadata from the exact PCK set intended for deployment:

```text
pack_url
pack_modified_time
pack_size
```

For a remote static host, keep a mirrored PCK folder on the VPS or deployment
machine:

```text
/opt/virtucade/world_packs/hub.pck
/opt/virtucade/world_packs/left_world.pck
/opt/virtucade/world_packs/right_world.pck
/opt/virtucade/world_packs/top_world.pck
```

Then configure:

```text
MULTI_SERVER_WORLD_PACK_BASE_URL=https://play.virtucade.com/world_packs
MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
```

The hosted files and local metadata files must be the same bytes. If they drift,
PackRat can correctly reject the download as stale or wrong.

## Open Questions

- Should production deployment generate a small metadata report after upload and
  compare it against the VPS mirror before the server starts?
- Should we add a smoke test that downloads packs from the real public host and
  compares PackRat metadata with master-advertised metadata?
- Should the public Web host use immutable filenames later, or keep the current
  stable `<world_key>.pck` filenames plus PackRat size/modified-time checks?

For now, keep stable filenames. It matches the current PackRat/VirtuCade design
and avoids a manifest.
