# Uptime monitoring — setup and monitor plan

Written 2026-09-18. Target host: the team VPN VM (`i-0ad5d9743f6c95721`, `t4g.micro`, arm64, EIP `44.225.91.181`, us-west-2). Compose file: `uptime-compose.yml` in this folder.

## Why this host, and what it cannot do

**Chosen: the VPN VM.** It is ours, it sits in its own subnet and security group with zero shared resources, it is otherwise idle, and changing it risks nothing beyond the VPN itself. The alternative — the DigitalOcean `prod` droplet — is a live legacy production box already on the decommission path, so putting monitoring there means doing the work twice and taking risk on a box we do not operationally own.

**The limitation, stated plainly: this monitor lives in the same AWS account and region as everything it watches.** It will not tell you when us-west-2 or the account has a problem, because it will be down too. It catches what actually breaks day to day — containers dying, 5xx, certificate expiry, latency, wrong content — and that is most incidents, but it is not full coverage.

**Therefore pair it with a free external check.** UptimeRobot, Better Stack or similar, free tier, hitting the five or six public hostnames plus the VPN box itself. It costs nothing and covers precisely the gap. Self-hosted for depth, external for independence. **Do not skip this** — without it, an AWS-level event is silent on both layers.

**One consequence to accept knowingly:** this makes the VPN box more important than it was. If it goes down the team loses VPN *and* monitoring at the same time. Acceptable at this size, but it is a reason the external layer is not optional.

## Deploying it

Recorded for reference. The initial deploy was run by the user; subsequent changes (swap, limit raise, DNS) were applied over SSH directly. Note this box has SSH only — no SSM role, that was blocked earlier in the VPN project — so the admin IP rule in `team-vpn-sg` is the only way in.

```bash
# from your machine
scp -i ~/.ssh/team-vpn uptime-compose.yml ubuntu@44.225.91.181:~/uptime-compose.yml
ssh -i ~/.ssh/team-vpn ubuntu@44.225.91.181

# on the box — confirm arm64 support BEFORE pulling
docker manifest inspect louislam/uptime-kuma:2 | grep -i arm64

# then bring it up
docker compose -f uptime-compose.yml up -d
docker compose -f uptime-compose.yml ps
docker stats --no-stream uptime-kuma
```

Check `free -h` afterwards. This box has 1 GiB total and wg-easy is its real job; if memory looks tight, lower `mem_limit` further rather than leaving the VPN exposed.

**Reaching the UI** — same pattern as the wg-easy wizard, since the SG only allows port 22 from the admin IP:

```bash
ssh -i ~/.ssh/team-vpn -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181
# then http://localhost:3001
```

Never publish 3001 on `0.0.0.0`. Kuma stores notification credentials and your full monitor list.

## What to monitor, and why each one earns its place

### 1. Public hostnames — HTTPS, assert status 200

`www.puentehillsnissan.com`, `phn.callingyounow.us`, `surfcity.callingyounow.us`, `api.callingyounow.us`, plus the `admin` / `chat` / `leads` hostnames on the Integrations VM.

**Why this is not redundant with the ALB health check:** both target groups health-check `/` with a `200-499` matcher. A node returning 4xx for every request still reads as healthy. An external check asserting an actual `200` catches exactly the failure the current health check is blind to. Until that matcher is fixed, this is the only thing watching for it.

### 2. Keyword assertions — catch tenant bleed-through

**Use each rooftop's street address, NOT its dealership name.** `surfcity.callingyounow.us` → `17331 Beach Blvd`; `www.puentehillsnissan.com` → `17320 Gale Ave`.

**Why not the dealership name:** the build-time fallback value literally *is* `"Surf City Nissan"`, so a keyword assertion on that string can never fail on that host — it would pass just as happily on a broken build. Proven on 2026-09-18, when `surfcity.callingyounow.us` was found serving Puente Hills' `<title>` and `og:title` while its address and phone numbers were correctly its own. A name-based assertion saw nothing wrong. The address is unique per rooftop and would have caught a wholesale wrong-tenant render.

**Why:** there is a documented, previously-hit failure mode where `website_frontend` fetches branding during `next build`, and if the backend is unreachable at build time it silently bakes in hardcoded fallback content — with `DEFAULT_SITE_NAME = "Surf City Nissan"` as the tell. A build like that returns a perfectly healthy `200`. Only a content assertion catches it. **This becomes more valuable, not less, as Corona and San Bernardino are added**, since each new tenant is another chance to ship the wrong branding.

### 3. TLS certificate expiry

Kuma reports days-to-expiry on every HTTPS monitor; set an alert threshold around 21 days.

**Why:** Let's Encrypt certs on `api` (both nodes) and `admin`/`chat`/`leads` renew on `certbot.timer`, and that renewal was found on 2026-09-07 to have never actually worked despite appearing configured. It was fixed, but "appears configured" was exactly the failure mode once already. This is cheap insurance against a silent repeat.

### 4. Push/heartbeat monitor for the Celery beat scheduler — *after* the single-beat change

The October capacity plan proposes disabling `beat` on Node A so scheduled tasks stop running twice. The accepted trade-off is that cron then depends on one node, and inventory goes stale after its 2-hour TTL if that node is down.

A Kuma **Push** monitor closes that gap: have the HomeNet refresh task hit the push URL on success, and alert if no heartbeat arrives within ~2.5 hours. **Do not make the single-beat change without this.** It is the alarm that makes the trade-off acceptable rather than reckless.

### 5. Deliberately *not* set up yet

**Per-node direct checks** (hitting Node A and Node B individually to distinguish "one node down" from "site down") would be genuinely useful, but the nodes' security group only accepts traffic from the ALB's private IPs, so checks from the VPN box would be blocked. Enabling it needs a security-group change on production — which requires explicit approval, and the VPN project's own standing instruction was "don't touch existing security groups." **Raise it as a request; do not add the rule unilaterally.**

## Notifications

Point Kuma at the same place alerts already go rather than creating a second stream nobody watches. Alarms currently reach `#aws-alerts-dealerpulse` via SNS → AWS Chatbot; add a Slack incoming webhook for that channel as a Kuma notification target.

Set a sensible retry count (2–3 failures before alerting) so a single blip does not page. The lesson from the 14 September alarm rebuild applies here too: an alert set that cries wolf gets muted wholesale, and then nothing is monitored at all.

## Open items

- ~~Confirm arm64 manifest and pin the exact version~~ **DONE 2026-09-18** — arm64 confirmed, running 2.5.5, pinned by tag *and* digest.
- ~~Add the 2 GB swapfile, then apply the 512m limit~~ **DONE 2026-09-18, verified** — see "Applied 2026-09-18" below.
- **Reduce Kuma's request timeout from 48s to 15s** in the UI. Real response time from this box is ~90 ms.
- Stand up the external free-tier check. This is the half of the design that makes the rest trustworthy.
- Chase the `surfcity.callingyounow.us` wrong-`<title>` bug — separate from monitoring, but it is a launch-blocking SEO defect on a site due 5 October.
- Decide whether the status page should be exposed to the wider team, and if so how — that is a separate decision from the admin UI, which should stay tunnel-only.

---

# Troubleshooting: "timeout of 48000ms exceeded" / "socket hang up" / "connect ETIMEDOUT"

**Read this before chasing anything else.** On 2026-09-18, within hours of deployment, Uptime Kuma reported dozens of Down events across every monitor — `socket hang up`, `connect ETIMEDOUT`, `timeout of 48000ms exceeded`, `timeout by AbortSignal (48s)` — while every monitored site was demonstrably fine. Events clustered: unrelated targets on *different* AWS instances going Down within the same two or three minutes, repeatedly (16:06–16:07, 18:05–18:08, 18:52–18:55).

**Root cause: the container's own memory limit, not the network and not the targets.**

The limit was originally set to `mem_limit: 256m` to protect wg-easy on this 904 MiB box. Kuma settled at 231 MiB — 90% of that ceiling. The consequences, all measured:

```
RestartCount  = 12                     # OOM-killed repeatedly
dmesg         → "Memory cgroup out of memory: Killed process uptime-kuma"
                CONSTRAINT_MEMCG       # the cgroup limit, not the host
memory.events → max 1583               # ceiling hit 1,583 times
                sock_throttled 996     # <-- the actual mechanism
```

`sock_throttled` is the one that matters. **Under cgroup memory pressure the kernel throttles socket buffer allocation**, so outbound HTTPS checks stall and get torn down mid-flight. Because the constraint is at the *monitoring host*, it hits every monitor simultaneously regardless of target health — which is exactly the clustering pattern in the event log.

**Fix applied:** `mem_limit` raised to 512m **plus a 2 GB swapfile** (see below — the box had none, and raising the ceiling without swap would let the OOM killer choose wg-easy and drop the team VPN). Also reduce Kuma's request timeout from the 48s default to **15s**: real response time from this box is ~90 ms, and a 48s timeout means each failure holds socket buffers open for 48 seconds, which is what turns one stall into a cascade.

## Two plausible causes that were investigated and ruled out — do not re-chase these

### SNAT / ephemeral port exhaustion

The pinned root cause on [uptime-kuma#275](https://github.com/louislam/uptime-kuma/issues/275) is SNAT exhaustion, and the reporter's symptom string is identical to ours. **It does not apply to this topology.** That issue concerns Azure, where instances share a constrained SNAT port pool behind a platform load balancer. This box is EC2 with its own Elastic IP and the full ephemeral range. Measured here:

```
conntrack        211 / 1,048,576   (0.02%)
TIME-WAIT        1
port range       32768-60999       (~28k free)
conntrack drops  0 in dmesg
```

Nowhere near exhaustion, by four orders of magnitude.

### Cloudflare interference

Reported at [community.cloudflare.com/t/.../805405](https://community.cloudflare.com/t/uptime-kuma-random-timeout-of-48000ms-exceeded-when-cloudflare-enabled/805405/3) (returns 403 to automated fetches; read it in a browser). Every target here is Cloudflare-proxied, so it was a reasonable suspect. **Ruled out empirically**: 16 consecutive requests from this box to `api.` and `leads.callingyounow.us` returned 302/200 with TLS handshake ~43 ms and total ~90 ms, zero failures — through Cloudflare, from the same host, to the same endpoints Kuma claimed were timing out at 48,000 ms. A ~500x margin.

**The general lesson:** the symptom string matched two well-documented external causes, and both were wrong. Direct measurement from the affected host settled it in minutes. Measure the path before believing a matching bug report.

## DNS hardening (added 2026-09-18)

Explicit `dns: [1.1.1.1, 8.8.8.8]` was added to the compose file. The default chain was three hops — container → Docker embedded resolver `127.0.0.11` → host `systemd-resolved` `127.0.0.53` → VPC resolver. `systemd-resolved` is a known source of intermittent resolution stalls inside containers, and a stalled lookup surfaces as `ETIMEDOUT` or `socket hang up`, indistinguishable in the event log from a genuinely down target. This collapses the chain to one hop and removes a whole class of false positive.

This was hardening, not the diagnosed root cause — it was not the source of the 2026-09-18 events, since the path tested clean. It is worth keeping regardless.

## Adding swap — required before raising the memory limit

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=10 && free -h
```

Then apply the compose change. Afterwards confirm `sock_throttled` has stopped climbing and `RestartCount` has stopped rising:

```bash
sudo docker inspect uptime-kuma --format "restarts={{.RestartCount}}"
sudo docker exec uptime-kuma cat /sys/fs/cgroup/memory.events
```

## Applied 2026-09-18 — verified fixed

| | Before | After |
|---|---|---|
| Swap | **0 B** | 2.0 GiB, `vm.swappiness=10`, persisted in `/etc/fstab` |
| `mem_limit` | 256 MiB | 512 MiB |
| Kuma memory | 231 MiB (**90.25%**) | 235 MiB (**46%**) |
| cgroup `max` hits | 1,583 | **0** |
| `sock_throttled` | **996 and climbing** | 19 at startup, then **frozen** across 3 samples 20 s apart |
| `RestartCount` | 12 | **0** |
| Host available RAM | 233 MiB | 272 MiB |
| wg-easy | 89 MiB, healthy | 64 MiB, healthy, uptime unbroken |

Image now pinned `2.5.5@sha256:c74379ac…` (tag verified to resolve before applying). DNS override confirmed live via `HostConfig.Dns=[1.1.1.1 8.8.8.8]`.

**Note on the DNS check:** `/etc/resolv.conf` inside the container still reads `nameserver 127.0.0.11` — that is expected and does **not** mean the override failed. Docker always presents its embedded resolver at that address; the `# Overrides: [nameservers]` line beneath it means the embedded resolver now forwards to 1.1.1.1/8.8.8.8 instead of the host's `systemd-resolved`. Verify with `docker inspect`, not `resolv.conf`.

**Sizing note — Uptime Kuma 2.x ships an embedded MariaDB, not SQLite.** `/app/data` contains a `mariadb/` directory, which is why baseline memory is ~220–235 MiB rather than the tens of MiB a v1/SQLite install would use. Budget accordingly when adding monitors. (Uptime Kuma 1.x *is* genuinely lighter for this reason — but the data here is already in MariaDB format, so a downgrade would mean starting from an empty instance, not a migration.)
