# Dealerships — Open Items

Updated 2026-09-17. Evidence and full context for every item is in
`Documentations/Migration/MIGRATION_HISTORY.md` and `COMMAND_LOG.md`.

**Standing rule:** every write/install/purge/restart on the production VMs
(nodeA `i-061291ea974c4ea1b`, nodeB `i-0c982c44f93bfbc0a`, integration `i-03efb82c808863f84`)
must be approved individually before it is run. Read-only diagnostics do not need approval.

---

## Current status: nothing is down; the latency alarm is now fully root-caused

Site healthy on both tenants, both target groups `healthy`, alarm currently `OK`. But
`dealerpulse-alb-latency-p99` has now fired and recovered **nine times in four days** — four of them on
2026-09-17 alone (19:07 UTC Sep 16, then 03:05, 04:22 and 04:30 UTC Sep 17). As of the 2026-09-17
investigation the cause is no longer open: **it is a Redis cache stampede every 2 hours (item 11), plus
the Next.js image optimizer (item 12).** The alarm is correctly reporting both — do not retune it.

Scale of it: the site is fast for effectively everyone (p50 is **12 ms**). The problem is a 0.7% tail —
~1,000 requests over 5 s per 11 h, of which **83% are `/_next/image`** (item 12) and the most extreme are
inventory API calls at **17-53 s** (item 11). Items 11 and 12 are the only things on this list actively
affecting visitors; everything else is improvement, risk reduction and debt.

Yesterday's item 3a (legacy `.htm` falling through to SSR, worst 350 s) is real and still worth fixing,
but it is **not** what is driving the recurring alarm — only one `.htm` request appears in the slow set
over the last 11 h, against 833 image requests and 44 inventory calls over 15 s.

The one thing that *was* actively degrading performance (Node A starved of CPU credits) is resolving on
its own now that netdata is gone: credit balance has climbed **3 -> 324 -> 358** across three days, while
nodeB sits at its 864 ceiling. Traffic splits ~35/65 nodeA/nodeB by request count, matching the
configured weights.

---

## Time summary

| # | Item | Time | Needs |
|---|---|---|---|
| 1 | Memory + swap alarms | **20 min** | nothing (API only) |
| 2 | Health endpoint + matcher `200` | **2-3 h** | code + deploy |
| 3 | Frontend bugs — **legacy `.htm` (up to 350 s)**, slow VIN pages, `null` slug, assets | **~1 day** | code + deploy |
| 5 | SSR hairpin + alarm retune | **3-5 h** | config + deploy |
| 6 | VPN box IAM instance profile | **15 min** | nothing (API only) |
| 7 | integration reboot + resize | **1-2 h window** | scheduled downtime |
| 8 | Django `LOGGING` (+ Sentry) | **1 h** (+1-2 h Sentry) | code + deploy |
| 9 | nginx hygiene (3 items) | **45 min** | approval + reload |
| 10 | Cleanup (3 items) | **30 min** | approval |
| 11 | **HomeNet cache stampede** — the latency alarm's main cause | **30 min** config / 3-4 h proper | env + deploy |
| 12 | **Next.js image optimizer** — 83% of slow requests | **~1 h** | code + deploy |

Quickest real wins: **item 6 (15 min)** and **item 1 (20 min)** - both pure API, no servers touched.

Highest value for effort: **item 11** - two config lines remove ~12 user-facing stalls a day, and it
is the main driver of the latency alarm. Then **item 12** (83% of all slow requests, a one-line AVIF
change), then **item 3a** (the legacy `.htm` 350 s tail) and **item 5**.

---

## 0. Timezone — CLOSED, not being pursued (user decision 2026-09-16)

`TIME_ZONE` was briefly changed to `'UTC'` in `ocean/server/coresite/settings/base.py:47` and then
**reverted by the user the same day; it is back to `'Asia/Karachi'` and is to be left alone.** Nothing was
ever deployed, so production behaviour never changed at any point.

Consequences to be aware of rather than act on:

- Container/gunicorn log text keeps showing `+0500` while nginx and CloudWatch are UTC. Only the
  human-readable text differs — those events' CloudWatch **timestamps are correct** regardless, because
  the Docker `awslogs` driver stamps them at receipt with no parsing.
- `timezone.localdate()` still resolves on Karachi time, so for the California tenants
  `PublicSpecialListView` stops showing specials whose `expire_date` is today roughly 12-13 hours early,
  and the dashboard analytics window, the CRM lead `requestdate` and `sold_inventory` remain inconsistent
  with each other.

Recorded as accepted, not pending. Do not re-raise as a new finding.

---

## 1. Memory + swap alarms — 20 min

- [ ] Now possible: CWAgent metrics went live 2026-09-15. integration is the one that matters — steady
      **34.7% swap** with zero alarm coverage today.
      Proposed: `swap_used_percent >= 60` and `mem_available < 300 MB`, damped like the existing set so
      they do not flap. Pure CloudWatch change, no VM access needed.

---

## 2. Health check — BLOCKED, do not just change the matcher — 2-3 h

- [ ] **Add a real health endpoint, then set the matcher to `200`.** Attempted 2026-09-16 and
      deliberately stopped. Measured on nodeA with a bare IP Host header (what the ALB sends):

      | path | response |
      |---|---|
      | `/` | 400 |
      | `/healthz` | 400 |
      | `/health` | 400 |
      | `/api/health/` | 428 |

      **No path returns 200, so flipping the matcher today would mark both targets unhealthy and take the
      site down.** No health endpoint exists anywhere in the Django urls.

      The current check is not a pure no-op: `/` with matcher `200-499` does verify nginx is up and the
      upstream answers below 500. Its real faults are that Django's `400` counts as healthy, and it writes
      ~16,000 junk log lines per node per day.

      - **Preferred:** a Django health endpoint returning 200 (ideally touching the DB), then matcher `200`.
      - **Rejected:** a static nginx `location = /healthz { return 200; }` — it would pass with Django
        completely down, which is worse coverage than today.

---

## 3. Frontend bugs — measured cost, need a deploy — ~1 day total

> A message for the frontend developer covering item 3a is drafted in the 2026-09-17 entry of
> `MIGRATION_HISTORY.md` — it can be sent as-is.

- [ ] **Legacy `.htm` URLs falling through to SSR — the worst latency source on the site** — *1-2 h for the
      quick fix.* Found 2026-09-17 after `dealerpulse-alb-latency-p99` fired three times in two days.
      **269 requests exceeded 10 s in 24 hours**; the extreme tail is all `307`s on old `.htm` paths:

      | path | n/24h | avg `rt` | worst |
      |---|---|---|---|
      | `/remote-test-drive-puente-hills.htm` | 11 | **128 s** | 288 s |
      | `/video-gallery/index.htm` | 3 | 54 s | 153 s |
      | `/eprice-form.htm` | 18 | 23 s | 112 s |
      | `/new-inventory/index.htm` | 35 | 22 s | **350 s** |
      | `/edmunds-trade-in.htm` | 18 | 19 s | 208 s |
      | `/all-inventory/index.htm` | 4 | 16 s | 32 s |
      | `/get-pre-approved-in-seconds.htm` | 42 | 12 s | 208 s |
      | `/used-inventory/index.htm` | 136 | 0.9 s | 35 s |

      **Cause, fully traced.** `next.config.ts`'s `LEGACY_REDIRECTS` table works correctly and costs
      **0.027 s** per redirect (`permanent: true` → `308`, matched by the router before any JS runs — its
      own comment explains exactly this). But it lists the **bare** paths (`/new-inventory`,
      `/used-inventory`) while the traffic arriving carries the old `.htm` suffix. Those miss the table,
      miss `proxy.ts` (30 lines, trailing-slash `308`s only, no fetches), and land in the catch-all SSR
      route, which fetches the page **plus its components and galleries** before concluding it does not
      exist and calling `redirect()` → `307`. Legacy `.htm` traffic generated **1,603 CMS API calls in 24
      hours** (1,092 to `/api/public/components/`, 281 to `/api/public/galleries/`) for pages that do not
      exist — and every call hairpins out through Cloudflare and back. Each request holds a worker for its
      full duration on a 2-vCPU box, so a 350 s request degrades legitimate pages at the same time.
      Note most `.htm` `307`s **are** fast (`/financing/application.htm`, `/blog/lead.htm` at 0.01 s) —
      it is these eight paths that reach the expensive route.

      Fixes, easiest first: (a) add the `.htm` / `index.htm` variants to `LEGACY_REDIRECTS`; (b) add a
      catch-all for unmatched `*.htm` so future dead legacy URLs never reach SSR — there is a long tail of
      blog and old VIN pages still arriving from search results; (c) independently, make the catch-all
      route resolve the slug **first** and bail on 404 before fetching components and galleries. (c) is the
      same defect that makes scanner traffic expensive — a single `.php` probe triggered 9 API calls on
      2026-09-14. **Leave the 8 s alarm threshold alone: it is not mis-tuned, it is reporting this.**

- [ ] **Vehicle detail pages ~20 s on cold cache** — *investigation needed.* During the 2026-09-16 19:07
      alarm every slow request was a detail page paired with its own API call at 19-21 s each — e.g.
      `/inventory/2027/Nissan/Kicks/3N8AP6CE1VL314202/` 21.3 s alongside
      `/api/homenet/inventory/3N8AP6CE1VL314202/` 20.9 s. Same VIN, near-identical duration, page blocked
      on its own API call. Likely cold-cache VIN enrichment: `jdpower_enrichment.py` documents an external
      call whose latency is "overlapped by a thread pool", cached with a TTL, so a miss pays full price.
      Options: pre-warm, or a shorter external timeout with a degraded response.

- [ ] **Stop requesting the literal `null` slug** — *1-2 h.* `/api/public/pages/null/` is the single
      biggest 404 source: **242 requests per 30 minutes (~11,600/day)**, each hairpinning out to
      Cloudflare and back through the ALB. Noticed 2026-09-12, quantified 2026-09-16.
- [ ] **Stop routing static assets into the pages API** — *1 h.* `meta.json` (42/30min), `favicon.ico`,
      `apple-touch-icon.png`, `apple-touch-icon-precomposed.png` all requested against
      `/api/public/pages/`.
- [ ] **Check whether `payment-calculator` is genuinely missing from the CMS** — *30 min.* 78 × 404 per
      30 minutes; the only one of these that may be missing content rather than a code bug.

---

## 4. Timezone call sites — reference only, CLOSED with item 0

Not pending work. Kept so the analysis does not have to be redone if item 0 is ever revisited.

The global flip to UTC would narrow the error but not fix it. `timezone.localdate()` /
`timezone.localtime()` are used in four places, and the platform is multi-tenant now, so the correct
design is a timezone field per dealership (`America/Los_Angeles` for both current tenants):

| location | what it affects |
|---|---|
| `apps/cms/views/public_views.py:538` | **Customer-facing** — specials filtered by `expire_date >= today` |
| `apps/dashboard/services.py:314` | Analytics 7-day window bucketing |
| `apps/homenet_inventory/services/vehicle_details_email.py:73` | `requestdate` on outbound CRM lead XML |
| `apps/homenet_inventory/services/sold_inventory.py:96` | Already `timezone.now().date()` (UTC) — inconsistent with the other three |

---

## 5. SSR hairpin — then re-tighten the alarms — 3-5 h

- [ ] **Point the frontend at the backend over the internal network** — *2-4 h.* Every SSR fetch currently
      leaves the VPC, hits Cloudflare and re-enters through the ALB. Confirmed by nodeB's own public IP
      (`35.95.214.123`) appearing as the second-heaviest client in its own logs. Removes roughly half of
      all ALB traffic, the metric pollution, and a full round trip per render.
- [ ] **Re-tighten alarm thresholds afterwards, in that order** — *30 min.* Fixing the hairpin halves the
      alarm denominator, roughly doubling the computed error rate for the same number of real errors.
      Thresholds were deliberately loosened 2026-09-14 (5xx fast 5%→10%, burn 2%→5%, latency 3s→8s,
      credits <30→<10). Doing it in the other order means tuning twice.

---

## 6. team-vpn-box — no access path at all — 15 min

- [ ] **Attach an IAM instance profile** with `AmazonSSMManagedInstanceCore` to `i-0ad5d9743f6c95721`.
      It has **none**, so the SSM agent cannot register and `send-command` fails with
      `InvalidInstanceId`. Its security group also permits SSH only from `223.123.18.138/32`, which is
      stale. **Both management routes are closed at once.** An instance profile is the durable fix — it
      survives a dynamic ISP address change, unlike widening the SSH allowlist. Also unblocks the one
      manual setup step still outstanding on that box. The instance is running and passing both EC2
      status checks; WireGuard is up on 51820/udp and the wg-easy admin UI on 51821 is correctly not
      exposed.

---

## 7. Patching + resize — needs a scheduled window — 1-2 h

- [ ] **integration_node reboot** — *1 h window.* Running kernel `6.17.0-1019-aws` with **both**
      `linux-image-7.0.0-1011-aws` and `linux-image-7.0.0-1012-aws` pending — two versions behind on 19+
      days uptime. It hosts the shared Postgres both frontend nodes depend on, so the box most needing a
      reboot is the one whose reboot is most disruptive. Enable Docker `live-restore` first (*15 min*) so
      containers survive the daemon restart.
- [ ] **integration_node resize** — *1-2 h, same window.* 3.8 GB running **three** Postgres containers
      (ocean-shared 134 MB, chat_back 94 MB, leads_backend 22 MB) plus `chat_back-web-1` at **979 MB —
      26% of the box** — and `dockerd` itself at 298 MB RSS against 115 MB on the frontend nodes. It swaps
      steadily and swapped-out gunicorn workers cause a latency spike on their next request.
- [ ] **nodeA + nodeB reboot** for `libc6` only — *15 min each.* Minor; can ride along with anything else.

---

## 8. Backend observability — 1 h (+1-2 h for Sentry)

- [ ] **Add a `LOGGING` config.** There is none, and no Sentry, so an unhandled Django exception produces
      no traceback in `docker logs`, no file and no external sink — only the gunicorn access line
      recording that a 500 happened. This is why the 11 × 500s from 2026-09-14 are permanently
      unexplainable, and why any future 500 will be too.

---

## 9. nginx hygiene — DONE 2026-09-16

- [x] `limit_conn_status 429;` — added on both nodes, directly after the existing `limit_req_status`.
- [x] `$host` in `log_format` — there was no `log_format` at all (nginx was falling back to built-in
      `combined`). Added `combined_host`, with `host=` and `rt=` **appended** so the prefix stays
      byte-identical to `combined` — that keeps the CloudWatch agent timestamp regex and the Logs
      Insights dashboard queries working. Got `$request_time` for free.
- [x] Stale `puentehillsnissan.com` vhost removed — it was on **both** nodes, not just nodeA.

---

## 10. Cleanup — DONE 2026-09-16

- [x] Exited `chat_backend-postgres-1` removed from integration (`docker rm` without `-v`, so volume
      `chat_backend_postgres_data` survives).
- [x] `apt-get autoremove` run on nodeA/nodeB — removed exactly the 3 expected orphans.
- [x] `/etc/docker/daemon.json` log rotation added on all three nodes (50m x 3). **Takes effect at the
      next docker daemon restart / reboot**, not now — daemon deliberately not restarted.

---

## 11. HomeNet inventory cache stampede — the dominant cause of the latency alarm — 30 min config, 3-4 h proper

**This is the single highest-value item on the list.** Root-caused 2026-09-17 from 24 h of nginx
access logs. It is a two-line config problem with a 12-times-a-day user-facing cost.

### The arithmetic

| Setting | Where | Value |
|---|---|---|
| Inventory cache TTL | `backend.env:68` `HOMENET_CACHE_TTL_SECONDS` | `7200` (2 h) |
| Warm cron schedule | `coresite/settings/celery.py:22` `INVENTORY_WARM_HOURS_UTC` | `1,15,20` (3x/day) |
| TTL the cron writes with | `apps/homenet_inventory/tasks.py:609` | the same `7200` |

Gaps between warms are **14 h / 5 h / 5 h**. The cache lives 2 h. So the warmed cache
*cannot* survive to the next warm — expiry under live traffic is guaranteed, roughly
**every 2 hours, ~12 times a day**.

There is **no single-flight lock** (`inventory.py:335-380` is a plain get -> miss -> fetch -> set),
so every concurrent request that arrives during the gap independently makes the HomeNet SOAP
call (`HOMENET_TIMEOUT=30`) and re-parses ~27 MB / 1,200+ rows. First one to finish repopulates;
the rest have already paid.

### The evidence

Every one of the 44 requests over 15 s in 24 h landed in the first ~6 minutes of a 2-hour cycle:

`05:02, 07:02, 09:03, 11:04, 13:04, 17:00, 19:05, 22:01, 00:01, 03:01` UTC

15:00 and 21:00 are absent exactly because the 15:00 and 20:00 warm crons reset the clock — the
chain is self-consistent end to end. The 03:00 UTC boundary, at 10-minute resolution:

| 10-min bin (UTC) | requests | >5 s | >15 s | max |
|---|---|---|---|---|
| 02:00 - 02:50 (six bins) | 509 | **0** | **0** | 1.72 s |
| **03:00** | 92 | **7** | **5** | **36.9 s** |
| 03:10 | 246 | 0 | 0 | 2.65 s |

Zero slow requests for the full hour before, five over 15 s in the minute the TTL expires. Worst
single observation 52.8 s (`/api/homenet/inventory/3N1AB9DVXVY208380/`), with its SSR page at
52.9 s — the page is slow purely because it is blocked on this API call.

Worst-hit endpoints on a miss: `filter-options` (scans every row), `list_inventory`,
`associate-dealerships`, and per-VIN detail.

### Why this was missed before

`inventory.py:346` already carries the comment *"every ~2 h the db0 copy expired and a real user
request had to make the ~8-30 s HomeNet SOAP call."* That symptom was previously attributed to a
Redis DB-routing mismatch (view read db0, cron wrote db2/6/11/12) and the routing was fixed. The
routing fix was correct but **the TTL-shorter-than-the-warm-gap mechanism was never addressed**, so
the identical symptom survived the fix.

### Fixes, in order

1. **Make the warm cron hourly** — `INVENTORY_WARM_HOURS_UTC = "*"` in `celery.py:22`. With a 2 h
   TTL and a 1 h warm the cache is always refreshed with an hour of headroom, so no user request
   ever pays the SOAP cost. Inventory data also becomes *fresher* than today (1 h vs an effective
   2 h). Cost: 24 HomeNet SOAP calls/day instead of 3 — **confirm the vendor's rate limit first.**
2. **Raise the TTL above the longest gap** — `HOMENET_CACHE_TTL_SECONDS=57600` (16 h > the 14 h
   01:00->15:00 gap). Env-only, no code. Do this *with* fix 1, not instead of it: alone it fixes the
   stampede but makes inventory up to 14 h stale, which is a business call on sold/repriced cars.
3. **Add single-flight + serve-stale-while-revalidate** (~3-4 h, code). The durable fix: one lock
   holder refreshes while everyone else is served the expired blob immediately. Removes the whole
   class of problem independently of any schedule.

**Also found:** `HOMENET_CACHE_REFRESH_SECONDS='3600'` (`backend.env:67`) is **dead config** —
set in the env, referenced nowhere in the codebase. Someone intended this mechanism and it was
never wired up. Delete it or implement it.

---

## 12. Next.js image optimizer — 83% of all slow requests by count — ~1 h

Separate from item 11 and larger by volume. In 11 h: **4,699 `/_next/image` requests, 833 (17.7%)
over 5 s**, 99 of them over 15 s — that is 83% of every slow request on the site. It affects far
more visitors than item 11 does, just less severely each time.

| node | requests | >5 s | >15 s | avg | max |
|---|---|---|---|---|---|
| nodeB | 3,038 | 612 | **99** | 2.87 s | 21.1 s |
| nodeA | 1,661 | 221 | 0 | 1.72 s | 13.6 s |

**Cause — the variant matrix can never stay warm.** Sources are `content.homenetiol.com` at
**1280x960**, and `next.config.ts:112-117` asks for:

- `formats: ["image/avif", "image/webp"]` — AVIF is by far the most CPU-expensive encode there is
- `deviceSizes: [640, 828, 1080, 1200, 1920]` — **1920 upscales a 1280-wide source**, pure waste

~1,200 vehicles x ~10 photos x 5 widths x 3 formats is a six-figure variant count on a 2-vCPU box.
Measured cold cost per single image is only ~1.8-3 s; the 20 s tail is **concurrency**, whole
galleries arriving at once (4 images at 04:19:47 all ~20 s, 3 at 04:27:07 all ~20 s) and queueing.

**Confirmed working, do not "fix" these:** Cloudflare *is* caching optimized images (verified MISS
then HIT at 0.15 s), `minimumCacheTTL` is already 30 days, and the origin disk cache does hit
(`x-nextjs-cache: HIT` on a real URL). The problem is purely how many cold variants exist.

### Fixes

1. **Drop `"image/avif"`**, keep webp — one line, removes the expensive encode and a third of the
   matrix. Largest win for the effort, negligible visual difference at `q=75`.
2. **Remove `1920` from `deviceSizes`** — it cannot add detail to a 1280-wide source.
3. Note `vary: Accept` on the response fragments the Cloudflare cache per browser Accept string.
   This is inherent to Next.js content negotiation; fix 1 reduces the fragmentation.

---

## Operational notes (not tasks — things that will bite you)

- **Container log text is `+0500`, nginx and CloudWatch are UTC.** The CloudWatch *timestamps* on
  container events are correct (the `awslogs` driver stamps at receipt), so correlating inside CloudWatch
  works fine. Only the time printed *inside* a container log message needs a 5-hour offset applied.
- **nginx `access.log` is UTC (`+0000`); container logs are `+0500`.** Mixing the two in one `grep`
  silently returns nothing. This has cost time twice.
- **`describe-log-streams` lags; use `filter-log-events` to confirm log ingestion.** On 2026-09-15 a poll
  loop reported `lastIngestionTime` unchanged across 12 attempts over 4 minutes while `filter-log-events`
  was simultaneously returning 500 current events per stream.
- **Logs Insights bills per GB scanned on every run and refresh.** `/dealerpulse/nginx/access` is ~187 MB
  and growing. Keep dashboard time ranges short; avoid auto-refresh.
- **Stickiness was already non-functional before removal — do not re-enable it "to be safe".** Verified
  2026-09-16: no `Set-Cookie` reaches the browser on the site or the API path, because Cloudflare's
  `strip_set_cookie` rule strips `AWSALB`/`AWSALBCORS`. Nothing needs stickiness anyway — sessions are
  DB-backed in the **shared** Postgres, auth is stateless `simplejwt`, CSRF is cookie-based,
  `request.session` appears nowhere in `apps/`, per-node Redis holds only content-keyed read caches, there
  is no slot-hold flow, and bookings keep all state on a Postgres row.
- **Celery's broker is per-node** (`CELERY_BROKER_URL=redis://localhost:6379/0`). Tasks are queued and
  consumed on the same node and both frontend nodes run a worker, so this is not a stickiness concern —
  but a task queued on nodeA can only ever be run by nodeA's worker. If one node's worker dies, its queued
  tasks sit there rather than failing over.
- **Node A's `/_next/image` concentration (2026-09-12) has no current explanation.** It was blamed on ALB
  stickiness, but stickiness cannot have been the mechanism if the cookie never reached the client. The
  netdata finding (~30% of a core per node, proven 2026-09-15) is a better candidate. Do not re-derive the
  stickiness conclusion.

---

## Done (for context — do not redo)

- 2026-09-14 — alarm set rebuilt: gated-rate 5xx alarms scoped to `LoadBalancer` (survives TG churn),
  per-node health, CPU credits, latency. Calibrated against measured distributions.
- 2026-09-15 — netdata removed from both frontend nodes. Proven cause of ~30% of one core in
  `dockerd`+`containerd` (33%→0% nodeA, 30%→0% nodeB), plus ~209 MB RAM and 1-2 GB disk each. The
  `netdata-edge` apt source went with `netdata-repo-edge`, so it cannot return via unattended-upgrades.
- 2026-09-15 — memory/swap/disk/CPU metrics fixed. The agent was installed and correctly configured all
  along; it lacked `cloudwatch:PutMetricData`. Added as inline policy
  `dealerpulse-cloudwatch-metrics-write`, scoped by condition to the `CWAgent` namespace.
- 2026-09-15/16 — nginx log shipping restored after a 26-hour outage (a metrics-only config had replaced
  the logs config in `.d/`), and `timestamp_format` added so events carry the real request time in UTC.
  Verified 5/5 exact timestamp match on both nodes.
- 2026-09-16 — dashboards: `DealerPulse-Fleet-Overview` (all 3 VMs) and `DealerPulse-Logs` (2 dropdowns
  driving one panel).
- 2026-09-16 — ALB stickiness fully removed at both levels, 35/65 weights preserved.
