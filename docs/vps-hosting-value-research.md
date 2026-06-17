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
