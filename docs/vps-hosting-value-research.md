# VPS Hosting Value Research

Date: 2026-06-17

## Goal

Find a budget-friendly VPS or VPS-like host for `multi-server-test` and the
future VirtuCade server shape:

- one gameplay VPS for master server, SQLite, and temporary world server
  processes;
- static web host/CDN for the Web client and downloadable PackRat PCK files;
- target of roughly 100-200 concurrent players;
- possible 20-50 lightweight Godot world server processes;
- SSD size is not a meaningful constraint yet;
- CPU consistency, RAM, latency, and bandwidth are the real constraints.

The gameplay VPS should not host large public PCK downloads by default. PCKs
and the Web client should live on the static host so player downloads do not
compete with gameplay traffic.

## Hetzner Price Increase

Hetzner's 2026-06-15 adjustment applies to new orders and cloud instance
rescales starting 2026-06-15 at 8:00 CEST. Existing rented servers keep their
old terms. Hetzner's official explanation is standardizing server products plus
increased hardware procurement costs, especially RAM, SSDs, GPUs, and component
replacement costs.

The painful part for us is the USA Regular Performance jump. These are official
USA ASH/HIL cloud prices before IPv4, excluding VAT:

| Plan | Old USD/mo | New USD/mo | Increase |
|---|---:|---:|---:|
| CPX11 | $6.99 | $20.49 | +193% |
| CPX21 | $13.99 | $37.49 | +168% |
| CPX31 | $24.99 | $73.49 | +194% |
| CPX41 | $46.49 | $141.49 | +204% |
| CPX51 | $92.49 | $279.49 | +202% |

CPX12 is listed in the Singapore table at $17.99/mo before IPv4. In the Hetzner
Cloud UI this can show as roughly $18.59/mo after IPv4. That makes even the
smallest realistic US/Singapore Hetzner cloud test feel expensive for the amount
of CPU/RAM provided.

Why it feels worse outside Europe:

- Officially, Hetzner says the increase is about hardware procurement,
  standardization, and operating/replacement costs.
- Officially, Hetzner does not say "non-Europe costs more because of X".
- My inference: Hetzner has much more scale and older optimized infrastructure
  in Germany/Finland than in newer USA/Singapore regions. Regional operations,
  hardware logistics, market scale, transit, staffing, and datacenter economics
  can make non-Europe regions less able to preserve the old bargain pricing.

Bottom line: Hetzner US Regular Performance is no longer the default best-value
choice for this project. It can still be tested, but it should compete against
other providers instead of being assumed.

Sources:

- [Hetzner price adjustment table](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [Hetzner press statement](https://www.hetzner.com/pressroom/standardization-and-price-adjustment-of-our-server-products/)
- [Hetzner FAQ](https://docs.hetzner.com/general/infrastructure-and-availability/faq-standardization-and-price-adjustment/)

## Value Formula

This is a rough game-server value score, not a scientific benchmark:

```text
effective_vcpu = vcpu_count * cpu_reliability_factor

network_score =
  min(public_port_mbps, 1000) / 250
  + 0.3 * min(included_transfer_tb_or_unlimited_cap, 5)

game_server_value =
  (
    5.0 * effective_vcpu
    + 1.5 * ram_gb
    + network_score
  )
  / monthly_price_usd
```

CPU reliability factors:

| CPU type | Factor | Why |
|---|---:|---|
| Dedicated or guaranteed CPU cores | 1.00 | Best for stable world tick timing. |
| High-frequency or premium shared CPU | 0.75 | Better shared host, still not guaranteed. |
| Mainstream shared cloud CPU | 0.65 | Usually fine, but can jitter under noisy neighbors. |
| Budget/fair-share VPS CPU | 0.45 | Great price, but must be load-tested. |

Why this formula weights CPU heavily:

- Godot world processes and the master server need predictable CPU time.
- RAM matters because many world processes can be alive at once.
- Bandwidth matters, but less than CPU/RAM because PCK downloads should live on
  the static host.
- SSD size is intentionally ignored for now.

Use the score to choose test candidates, not to make a final production
decision. The final answer must come from load tests on the same exported
server build.

## Provider Comparison

Prices are a 2026-06-17 snapshot. Currency conversion and VAT can change. For
euro prices, the USD score is approximate. "Unlimited" transfer is capped at
5 TB inside the formula so unlimited marketing does not dominate the score.

## Under-$20 Shortlist

This is the quick comparison for plans cheap enough to test without feeling
like a monthly commitment. Higher cost value is better on paper.

| Provider | Plan | CPU | RAM | Network / transfer | Cost | Cost value |
|---|---|---:|---:|---|---:|---:|
| OVHcloud | VPS-3 | 6 shared vCore | 12 GB | 1 Gbps, unlimited | $12.32 | 3.49 |
| OVHcloud | VPS-2 | 4 shared vCore | 8 GB | 400 Mbps, unlimited | $8.50 | 3.31 |
| netcup | RS 1000 G12 | 4 dedicated cores | 8 GB | up to 2.5 Gbps | ~EUR 12.79 | ~2.5 |
| Contabo | Cloud VPS 20 | 6 shared vCPU | 12 GB | unlimited fair-use | ~EUR 7.50 | high but risky |
| Contabo | Cloud VPS 10 | 4 shared vCPU | 8 GB | unlimited fair-use | ~EUR 5.50 | high but risky |
| OVHcloud | VPS-1 | 2 shared vCore | 4 GB | 200 Mbps, unlimited | $4.54 | ~3.0 |
| Vultr | Regular 2c/2gb | 2 shared vCPU | 2 GB | 3 TB | $15 | ~0.95 |
| Vultr | High Frequency 2c/2gb | 2 shared vCPU | 2 GB | 3 TB | $18 | ~0.9 |
| BuyVM | Slice 4096 | 1 dedicated core | 4 GB | unmetered | $15 | ~0.9 |
| Vultr | High Frequency 1c/2gb | 1 shared vCPU | 2 GB | 2 TB | $12 | ~0.85 |
| Vultr | Regular 1c/2gb | 1 shared vCPU | 2 GB | 2 TB | $10 | ~0.85 |
| DigitalOcean | Basic 2c/2gb | 2 shared vCPU | 2 GB | 3 TB | $18 | ~0.8 |
| Akamai/Linode | Linode 2GB | 1 shared vCPU | 2 GB | 2 TB | $12 | ~0.75 |
| DigitalOcean | Basic 2GB | 1 shared vCPU | 2 GB | 2 TB | $12 | ~0.7 |
| AWS Lightsail | 2GB IPv4 | 2 shared vCPU | 2 GB | 3 TB | $12 | ~0.7 |
| Hetzner | CPX12 | 1 shared vCPU | 2 GB | cloud transfer | ~$18.59 | poor |
| BuyVM | Slice 2048 | 1 fair-share core | 2 GB | unmetered | $7 | decent small-only |
| GreenCloud | Ryzen 2GB | 1 shared core | 2 GB | 10 Gbps, 2 TB | $10 | decent test-only |

For under $20, the best first tests are OVHcloud VPS-3 for raw paper value,
netcup RS 1000 G12 for dedicated-core stability, and Vultr High Frequency
2c/2gb as a mainstream shared-CPU comparison.

## Developer Testing When The Server Is Not 24/7

For private developer testing, hourly-with-monthly-cap billing can be the best
value. The bill is mostly based on how long the server exists, not how many
players connect. With one developer and static PCK hosting elsewhere, bandwidth
should be effectively irrelevant unless a test goes very wrong.

Important rule: on many cloud providers, "stopped" servers can still bill
because disk/IP resources remain reserved. For the lowest bill, destroy/delete
the test server after use and recreate it from scripts, images, or release
artifacts next time.

This table assumes:

- light dev month: 40 server hours;
- heavy dev month: 120 server hours;
- no paid backups/snapshots;
- no transfer overage;
- PCK/Web downloads stay on the static host.

| Rank | Provider / plan | Billing style | CPU | RAM | Monthly cap | 40h estimate | 120h estimate | Dev value | Fit |
|---:|---|---|---:|---:|---:|---:|---:|---:|---|
| 1 | Vultr Regular 2c/4gb | hourly, capped | 2 shared vCPU | 4 GB | $20 | ~$1.19 | ~$3.57 | ~14.6 | Best default dev box. |
| 2 | Vultr High Frequency 2c/4gb | hourly, capped | 2 shared vCPU | 4 GB | $24 | ~$1.43 | ~$4.29 | ~12.9 | Better CPU class, still cheap. |
| 3 | DigitalOcean Basic 2c/4gb | per-second/hourly, capped | 2 shared vCPU | 4 GB | $24 | ~$1.43 | ~$4.29 | ~12.4 | Polished mainstream comparison. |
| 4 | Akamai/Linode 4GB | hourly, capped | 2 shared vCPU | 4 GB | $24 | ~$1.44 | ~$4.32 | ~12.3 | Good mainstream comparison. |
| 5 | Hetzner CPX11 USA | hourly, capped | 2 shared vCPU | 2 GB | ~$21.09 | ~$1.16 | ~$3.47 | ~12.7 | Cheap to sample, RAM is tight. |
| 6 | Vultr Regular 1c/2gb | hourly, capped | 1 shared vCPU | 2 GB | $10 | ~$0.60 | ~$1.79 | ~14.2 | Cheapest smoke-test box. |
| 7 | Akamai/Linode 2GB | hourly, capped | 1 shared vCPU | 2 GB | $12 | ~$0.72 | ~$2.16 | ~12.5 | Simple tiny test box. |
| 8 | DigitalOcean Basic 2GB | per-second/hourly, capped | 1 shared vCPU | 2 GB | $12 | ~$0.71 | ~$2.14 | ~11.9 | Simple tiny test box. |
| 9 | Hetzner CPX12 | hourly, capped | 1 shared vCPU | 2 GB | ~$18.59 | ~$1.02 | ~$3.06 | low | Weak value, but cheap for short tests. |
| 10 | OVHcloud VPS-3 | flat monthly VPS | 6 shared vCore | 12 GB | $12.32 | $12.32 | $12.32 | 3.49 | Great if kept all month, not hourly. |
| 11 | netcup RS 1000 G12 | flat monthly/contract | 4 dedicated cores | 8 GB | EUR 12.79 | EUR 12.79 | EUR 12.79 | ~2.5 | Great stable month-long test host. |
| 12 | OVHcloud VPS-2 | flat monthly VPS | 4 shared vCore | 8 GB | $8.50 | $8.50 | $8.50 | 3.31 | Great if kept all month, not hourly. |

For occasional dev testing, use **Vultr Regular 2c/4gb** first. It has enough
RAM to run the master plus a few Godot world processes, costs only a few dollars
for normal private testing, and has predictable monthly caps. Use **Vultr High
Frequency 2c/4gb** if world tick consistency looks CPU-sensitive.

Use **OVH VPS-3** or **netcup RS 1000 G12** when the goal is a week-long or
month-long burn-in test. They are excellent monthly values, but they lose the
main advantage of destroy-after-use dev testing.

Billing sources:

- [Vultr server billing](https://docs.vultr.com/support/platform/billing/how-am-i-billed-for-my-servers)
- [DigitalOcean Droplet pricing](https://docs.digitalocean.com/products/droplets/details/pricing/)
- [Akamai/Linode billing](https://techdocs.akamai.com/cloud-computing/docs/understanding-how-billing-works)
- [Hetzner Cloud billing FAQ](https://docs.hetzner.com/cloud/billing/faq/)

## Developer Testing Setup Ease

Current project workflow:

- GitHub Actions already builds the Linux server artifact.
- GitHub Actions already deploys the Web client and PCK files to GitHub Pages.
- The workflow intentionally stops at `VPS_DEPLOY_NOT_CONFIGURED`.
- A dev VPS workflow would need to:
  1. create or reuse a temporary Ubuntu VPS;
  2. inject an SSH key and basic cloud-init/startup script;
  3. upload `builds/server/**` and `builds/web/world_packs/**`;
  4. start the server process;
  5. print the public host/IP for browser testing;
  6. destroy the VPS when the test is over.

For this project, a comfortable "cPanel" is less important than a comfortable
cloud console, API token, CLI, SSH keys, cloud-init/startup scripts, and a clean
way to destroy servers after a dev session. Traditional cPanel/Plesk would be
extra software and is not useful for the Godot gameplay server itself.

Ranking by **ease of GitHub Actions dev testing**, filtered toward under-$20 or
near-under-$20 plans with 2+ CPU:

| Rank | Provider / plan | Dev cost style | Specs | Setup comfort | Meaningful difference |
|---:|---|---|---:|---|---|
| 1 | DigitalOcean Basic 2c/2gb | per-second/hourly capped, $18/mo max | 2 shared vCPU, 2 GB | Best | Cleanest panel, official `doctl`, official GitHub Action, easy SSH keys and cloud-init. RAM is tight for many worlds. |
| 2 | Vultr Regular 2c/2gb | hourly capped, $15/mo max | 2 shared vCPU, 2 GB | Very good | Easy panel and API. Less first-party GitHub Actions polish than DigitalOcean. |
| 3 | Vultr High Frequency 2c/2gb | hourly capped, $18/mo max | 2 shared vCPU, 2 GB | Very good | Same workflow as Vultr regular, better CPU class for testing tick stability. |
| 4 | Vultr Regular 2c/4gb | hourly capped, $20/mo max | 2 shared vCPU, 4 GB | Very good | Slightly above the target, but probably the best practical dev spec. |
| 5 | Hetzner CX23 Europe | hourly capped, cheap monthly max | 2 shared vCPU, 4 GB | Good | Best price/spec if Europe latency is acceptable. API/CLI/cloud-init are good, onboarding/account friction can be higher. |
| 6 | OVHcloud VPS-2 | flat monthly, $8.50/mo | 4 shared vCore, 8 GB | Good | Official GitHub Actions SSH deploy guide and easy panel. Not ideal for destroy-after-use because it is monthly VPS billing. |
| 7 | OVHcloud VPS-3 | flat monthly, $12.32/mo | 6 shared vCore, 12 GB | Good | Great specs for a month-long dev server, but not as cost-efficient for short sessions. |
| 8 | netcup RS 1000 G12 | flat monthly/contract, EUR 12.79/mo | 4 dedicated cores, 8 GB | Medium | Best CPU stability for the money, but more contract/account-panel friction and less cloud-native temporary-server flow. |
| 9 | Akamai/Linode 4GB | hourly capped, $24/mo max | 2 shared vCPU, 4 GB | Good | Nice panel/API/CLI, but misses the under-$20 target for 2+ CPU with enough RAM. |
| 10 | AWS Lightsail 2GB | monthly bundle/prorated, $12/mo | 2 shared vCPU, 2 GB | Medium | Friendly console, but IAM/AWS setup is more annoying than DO/Vultr for this project. |
| 11 | Contabo Cloud VPS 10/20 | flat monthly, very cheap | 4-6 shared vCPU, 8-12 GB | Medium | Great specs, API exists, but more performance variability and less polished dev loop. |
| 12 | HostHatch NVMe class | usually monthly, cheap when available | varies | Medium | Good value when in stock, but less documented/standardized than DO/Vultr. |
| 13 | RackNerd / GreenCloud promos | usually annual promo | varies | Low-medium | Cheap, but not ideal for automated create/destroy GitHub testing. |
| 14 | BuyVM under-$20 | monthly | RAM-limited | Low-medium | Good provider culture, but under-$20 plans are not a great fit for 2+ CPU and enough RAM. |

Best workflow pick:

```text
DigitalOcean Basic 2c/2gb
```

Use it when the goal is the easiest GitHub Actions path and the test is mostly:

- master server boots;
- one or a few world processes start;
- Web client connects over public IP;
- PackRat downloads PCKs from GitHub Pages;
- version gate and travel flow work.

Best practical dev spec:

```text
Vultr Regular 2c/4gb
```

It is exactly at the $20 line rather than under it, but 4 GB RAM is much more
comfortable for this project's master plus multiple Godot world processes.

Best short-session value if setup friction is acceptable:

```text
Hetzner CX23 Europe
```

It is cheap, hourly capped, API-friendly, and has 4 GB RAM, but it is not the
same as testing a US player-facing path.

Best month-long burn-in:

```text
netcup RS 1000 G12
```

Dedicated cores matter for stable tick timing. It is less ideal for disposable
hourly dev sessions, but excellent when we want to leave the server up for a
week or month and measure real CPU stability.

Recommended path:

1. Use **DigitalOcean Basic 2c/2gb** first to implement the GitHub Actions VPS
   deploy workflow with minimum friction.
2. If RAM is annoying, switch the same workflow shape to **Vultr Regular
   2c/4gb**.
3. Once the deploy workflow is stable, compare runtime quality on **Hetzner
   CX23 Europe**, **OVH VPS-3**, and **netcup RS 1000 G12**.

For intentionally breaking the smallest possible DigitalOcean box, see
[DigitalOcean 512 MiB Stress Test Plan](digitalocean-512mb-stress-test-plan.md).

Setup sources:

- [DigitalOcean doctl](https://docs.digitalocean.com/reference/doctl/)
- [DigitalOcean GitHub Action for doctl](https://github.com/digitalocean/action-doctl)
- [DigitalOcean Droplet user data](https://docs.digitalocean.com/products/droplets/how-to/provide-user-data/)
- [Vultr API](https://www.vultr.com/api/)
- [Vultr cloud-init user data](https://docs.vultr.com/how-to-deploy-a-vultr-server-with-cloudinit-userdata)
- [Hetzner Cloud API](https://docs.hetzner.cloud/reference/cloud)
- [Hetzner Cloud billing](https://docs.hetzner.com/cloud/billing/faq/)
- [OVHcloud GitHub Actions VPS deployment guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/deploy-website-github-actions)
- [netcup Root Server API](https://www.netcup.com/en/helpcenter/documentation/server/rest-api)

## Dev-To-Production Vertical Scaling Shortlist

This ranking answers a narrower question:

```text
Which host should we start on for private dev testing if we also want to stay
on that same provider for a future 100-200 CCU VirtuCade test?
```

Assumptions:

- "100-200 CPU" means 100-200 CCU.
- Web client and PackRat PCK files stay on GitHub Pages/CDN/static hosting.
- The VPS runs only gameplay: master, SQLite, and temporary world processes.
- We prefer vertical scaling before multi-node orchestration.
- We are ranking provider path, not only the cheapest single plan.
- Providers should have a real reputation as established infrastructure hosts.
  Cheap unknown, promo-driven, or poor-reputation hosts are excluded from the
  main recommendation even when their specs look attractive.

| Rank | Start plan | Dev cost behavior | Future scale path | Why it ranks here |
|---:|---|---|---|---|
| 1 | OVHcloud VPS-3, 6 shared vCore / 12 GB, $12.32/mo | Flat cheap monthly | Same VPS line up to larger vCore/RAM plans | Best blend of low cost now and low cost later. Main risk is shared CPU jitter. |
| 2 | Vultr Regular 2c/4gb, $20/mo cap | Hourly capped; about $1.19 for 40h | Resize to 4c/8gb, 6c/16gb, or higher-performance Vultr lines | Best if dev servers are often destroyed after testing. More expensive than OVH when always-on. |
| 3 | Akamai/Linode 4GB, 2 shared vCPU / 4 GB, $24/mo cap | Hourly capped; about $1.44 for 40h | Resize to larger shared, premium, or dedicated plans | Very established provider and comfortable cloud workflow. Costs more than OVH/Vultr. |
| 4 | DigitalOcean Basic 2c/4gb, $24/mo cap | Per-second/hourly capped; about $1.43 for 40h | Resize Basic or move to dedicated CPU Droplets | Best developer experience and GitHub Actions ergonomics. Scaling gets expensive. |
| 5 | netcup RS 1000 G12, 4 dedicated cores / 8 GB, EUR 12.79/mo | Flat monthly/contract | Larger netcup Root Server plans with dedicated CPU | Best CPU stability per dollar. Reputable, but more European/contract-style and less cloud-native. |

Decision rule:

- Pick **OVHcloud VPS-3** if the goal is cheapest realistic dev-to-production
  path on one provider.
- Pick **Vultr Regular 2c/4gb** if the goal is temporary dev servers that are
  destroyed after each test session, while still having a sane production scale
  path later.
- Pick **netcup RS 1000 G12** if stable tick timing matters more than cloud
  workflow comfort.

Why not top five:

- **Hetzner US Regular Performance**: the 2026 price increase makes the US path
  poor value for this project.
- **Hetzner Europe CX/CAX**: good hourly price/spec if Europe latency is
  acceptable, but not the right default for a USA-focused game test.
- **Contabo**: excellent paper specs, but budget shared/fair-use performance and
  mixed reputation make it too risky as the primary future production path for
  an authoritative game server.
- **RackNerd/GreenCloud/HostHatch promos**: useful for experiments, but stock,
  promo terms, smaller-provider reputation risk, and automation consistency make
  them weaker as the main dev-to-production provider.
- **BuyVM**: good niche reputation, but under-$20 plans are RAM/CPU constrained
  for this specific project and the scale path is less comfortable than the top
  providers.
- **AWS Lightsail**: friendly console, but AWS account/IAM friction and pricing
  are not better than the options above.

Scaling sources:

- [OVHcloud VPS](https://us.ovhcloud.com/vps/)
- [OVHcloud VPS configurator](https://us.ovhcloud.com/vps/configurator/)
- [OVHcloud resize docs](https://support.us.ovhcloud.com/hc/en-us/articles/23533757015827-Modify-or-resize-an-instance-via-the-OVHcloud-Control-Panel)
- [Vultr Cloud Compute](https://www.vultr.com/products/cloud-compute/)
- [Vultr resize docs](https://docs.vultr.com/products/compute/optimized-cloud-compute/management/resize-instance)
- [netcup Root Server](https://www.netcup.com/en/server/root-server)
- [netcup product upgrade docs](https://www.netcup.com/en/helpcenter/documentation/general/instance-upgrade)
- [DigitalOcean resize docs](https://docs.digitalocean.com/products/droplets/how-to/resize/)
- [Akamai/Linode resize docs](https://techdocs.akamai.com/cloud-computing/docs/resize-a-compute-instance)

## Shared vs Dedicated CPU

Shared vCPU/vCore means the virtual CPU can share the same physical CPU time
with other customers. It can be fast when the host node is quiet, but it can
jitter when neighbors are busy.

Dedicated or guaranteed cores means the provider reserves CPU capacity for you.
That usually matters more for game servers than for websites because world
server ticks need consistent timing, not just good average speed.

Hetzner Regular Performance CPX/CX plans are shared CPU. Hetzner Dedicated vCPU
CCX plans are the dedicated-CPU line. After the 2026-06-15 price increase, US
CCX pricing is too expensive to be the budget default for this project.

For this project, 4 dedicated cores can easily beat 6 shared vCores if the
shared host has noisy-neighbor jitter. The OVH VPS-3 may still win if its shared
CPU is quiet enough, but netcup RS 1000 G12 is the cleaner performance bet on
paper because the CPU allocation is guaranteed. The final answer must come from
running the same Godot server load test on both.

| Rank | Provider / plan | CPU | RAM | Network / transfer | Monthly | CPU factor | Value score | Notes |
|---:|---|---:|---:|---|---:|---:|---:|---|
| 1 | OVHcloud VPS-3 | 6 vCore shared | 12 GB | 1 Gbps, unlimited | $12.32 | 0.65 | 3.49 | Best raw paper value. Needs latency/jitter test. |
| 2 | OVHcloud VPS-2 | 4 vCore shared | 8 GB | 400 Mbps, unlimited | $8.50 | 0.65 | 3.31 | Excellent cheap first server if CPU is consistent enough. |
| 3 | netcup RS 2000 G12 | 8 dedicated EPYC cores | 16 GB | up to 2.5 Gbps | ~EUR 21.43 incl. VAT | 1.00 | ~2.8 | Strong dedicated-core value; US location is Manassas. |
| 4 | netcup RS 1000 G12 | 4 dedicated EPYC cores | 8 GB | up to 2.5 Gbps | EUR 12.79 incl. VAT | 1.00 | ~2.5 | Best VPS-like dedicated-core budget pick if routing is good. |
| 5 | Contabo Cloud VPS 20 | 6 vCPU budget | 12 GB | unlimited fair-use | ~EUR 7.50 | 0.45 | high paper, high risk | Very cheap, but fair-use/noisy-neighbor risk makes it test-only. |
| 6 | BuyVM high-volume 8 GB | 2 dedicated cores | 8 GB | 1 Gbps, unmetered | $30 | 1.00 | 0.92 | Honest specs, useful US candidate, stock can be tight. |
| 7 | BuyVM Slice 4096 | 1 dedicated core | 4 GB | unmetered | $15 | 1.00 | 0.9-1.0 | Good small shard/control host, probably not enough for 20-50 worlds. |
| 8 | Vultr Regular 2c/4gb | 2 shared vCPU | 4 GB | 3 TB | $20 | 0.65 | 0.87 | Clean mainstream option. |
| 9 | Vultr High Frequency 2c/4gb | 2 shared vCPU | 4 GB | 3 TB | $24 | 0.75 | 0.77 | Better CPU class than regular, but pricier. |
| 10 | Akamai/Linode 4GB | 2 shared vCPU | 4 GB | 4 TB, 4 Gbps out | $24 | 0.65 | 0.74 | Reliable mainstream candidate. |
| 11 | DigitalOcean Basic 4GB | 2 shared vCPU | 4 GB | 4 TB, up to 2 Gbps | $24 | 0.65 | 0.74 | Simple and polished, not best value. |
| 12 | Hetzner CPX11 USA | 2 shared vCPU | 2 GB | cloud transfer included | ~$21.09 with IPv4 | 0.65 | ~0.7 | After price increase, weak value for this project. |
| 13 | AWS Lightsail 4GB | 2 shared vCPU | 4 GB | 4 TB | $24 | 0.60 | ~0.6 | Easy AWS path, but not compelling for this use. |
| 14 | Akamai/Linode Dedicated 4GB | 2 dedicated vCPU | 4 GB | 4 TB, 4 Gbps out | $36 | 1.00 | 0.59 | Lower value score but safer CPU behavior. |
| 15 | DigitalOcean CPU-Optimized 4GB | 2 dedicated vCPU | 4 GB | 4 TB, premium up to 10 Gbps | $42 | 1.00 | 0.50 | Safe mainstream dedicated CPU, expensive. |
| 16 | Hetzner CPX31 USA | 4 shared vCPU | 8 GB | cloud transfer included | ~$74.09 with IPv4 | 0.65 | ~0.4 | This is the bad new price point we should avoid. |

Secondary budget providers worth testing, but not treating as default
production hosts yet:

| Provider / plan | CPU | RAM | Network / transfer | Monthly | Notes |
|---|---:|---:|---|---:|---|
| GreenCloud Ryzen 4GB | 2 cores | 4 GB | 10 Gbps port, 4 TB | $20 | Good regional test option with LA, Chicago, Utah, San Jose and more. Validate support and jitter. |
| GreenCloud Ryzen 8GB | 4 cores | 8 GB | 10 Gbps port, 8 TB | $40 | Strong paper spec, still needs burn-in before production trust. |
| RackNerd KVM 4GB | 4 vCore | 4 GB | 1 Gbps, 3 TB | $24.59 | Lots of locations and cheap pricing; use as dev/staging or prove with load tests. |
| RackNerd KVM 8GB | 6 vCore | 8 GB | 1 Gbps, 5 TB | $36.59 | Interesting fallback, but CPU consistency is unknown until measured. |
| HostHatch NVMe 16GB | 4 EPYC cores | 16 GB | 4 TB | ~$15 | Strong promo-style value when available; support/availability reputation should be tested before relying on it. |

Sources:

- [OVHcloud VPS](https://us.ovhcloud.com/vps/)
- [netcup Root Server](https://www.netcup.com/en/server/root-server)
- [BuyVM KVM slices](https://buyvm.net/kvm-dedicated-server-slices/)
- [Contabo traffic rules](https://help.contabo.com/en/support/solutions/articles/103000269972-traffic-rules-at-contabo)
- [GreenCloud Ryzen KVM VPS](https://greencloudvps.com/billing/store/ryzen-kvm-vps)
- [RackNerd KVM VPS](https://www.racknerd.com/kvm-vps)
- [HostHatch products](https://hosthatch.com/products)
- [Vultr pricing](https://www.vultr.com/pricing/) and [Vultr plans API](https://api.vultr.com/v2/plans)
- [Akamai cloud pricing](https://www.akamai.com/cloud/pricing) and [Linode types API](https://api.linode.com/v4/linode/types)
- [DigitalOcean Droplet pricing](https://www.digitalocean.com/pricing/droplets)
- [AWS Lightsail pricing](https://aws.amazon.com/lightsail/pricing/)

## Recommendation

Do not start with a $75/month Hetzner CPX31-style plan. It is the wrong value
profile for a game that is not earning money yet.

Recommended test matrix:

1. **OVHcloud VPS-3**: best paper value. Try this first if the target region
   routing is acceptable.
2. **netcup RS 1000 G12**: best budget dedicated-core option. Use it if the
   Manassas, USA location gives good latency for the audience.
3. **Vultr High Frequency 2c/4gb or Akamai/Linode 4GB**: mainstream comparison
   point with cleaner support and easier expectations.
4. **Akamai/Linode Dedicated 4GB**: fallback if shared CPU jitter is visible and
   a stable mainstream provider matters more than lowest price.

Use Contabo/RackNerd/GreenCloud-style discount VPSs only as dev, staging,
overflow experiments, or load-test targets until they prove stable under our
actual server process mix.

## Load-Test Gate Before Choosing

Rent two or three candidates for a short test window. Run the same exported
Linux server build and measure:

- master process CPU and memory;
- total RSS across 20, 30, and 50 world processes;
- CPU steal / noisy-neighbor symptoms;
- world tick/frame time jitter;
- 100 and 200 simulated clients;
- travel between worlds while PackRat downloads are hosted elsewhere;
- SQLite save/load latency;
- chat and route latency;
- disconnects, join ticket failures, and world startup latency;
- public RTT and jitter from expected player regions.

Destroy the losers immediately. The winner is the cheapest plan that survives
the load test with stable tick timing and enough RAM headroom.

## Practical Starting Choice

If choosing today:

- first try **OVHcloud VPS-3** for raw value;
- also try **netcup RS 1000 G12** if Manassas routing is good;
- keep **Akamai/Linode Dedicated 4GB** as the "pay more for safer CPU"
  fallback.

That keeps the first serious hosting experiment around the $12-$36/month range
instead of jumping straight to $75/month.
