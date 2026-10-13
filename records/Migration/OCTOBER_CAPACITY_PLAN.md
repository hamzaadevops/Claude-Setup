# October Capacity Plan — 4 tenants live by 31 Oct, Surf City + Corona by 5 Oct

**Status: DRAFT — awaiting approval. Nothing in this document has been executed.**
Written 2026-09-15. Source data: `MIGRATION_HISTORY.md` and project memory; the AWS CLI session was expired at time of writing, so no figure here comes from a live query. Re-verify anything marked ⚠️ before acting.

## Planning assumptions (confirmed with user 2026-09-15)

| Assumption | Value |
|---|---|
| Traffic per new rooftop | Comparable to Puente Hills → plan for ~2x current total frontend load |
| Downtime tolerance | 3–5 min per box acceptable, one box at a time |
| Budget | Modest increase acceptable (~+15–30%/mo) |
| Approval model | Plan reviewed and confirmed first, then implement item by item |

## The core finding

The backend already runs at 4-tenant scale. The HomeNet cron already refreshes all four dealerships, Redis db2/6/11/12 are warmed on both nodes, per-VIN keys exist for all four (db2=255, db6=356, db11=290, db12=331), and the Postgres data is in place. **Launching Corona and San Bernardino does not double backend load — that load is already being carried today for two rooftops nobody can visit yet.**

What changes is the frontend tier. Tenant identity is bound at build time via `NEXT_PUBLIC_DEALERSHIP_ID`, so each rooftop needs its own container: Node A and Node B go from 6 containers to 8 (`web`/`worker`/`beat`/`redis` + 4× `website_frontend`). That delta is almost entirely CPU, and it lands on boxes that have no CPU headroom left.

---

# Phase 0 — Today. Unblock measurement.

Nothing else in this plan should be sized without this. We currently have **no memory metrics at all**, and the sizing decision in Phase 2 depends on knowing how Node A's CPU splits between the Next.js containers and the Django stack.

### 0.1 Attach `CloudWatchAgentServerPolicy` to `dealerpulse-ec2-ssm-role` — USER ACTION

The CloudWatch agent is already installed and correctly configured on all three boxes; it has simply never been permitted to publish. The role holds only `AmazonSSMManagedInstanceCore`. Attaching this one AWS-managed policy in the IAM console starts metrics flowing immediately with no further action.

This cannot be done from here — IAM permission grants are categorically blocked by the auto-mode permission classifier (the same wall hit on the team VPN role).

**Verify:** the `CWAgent` namespace returns `mem_used_percent` and `swap_used_percent` for all three instance IDs within ~5 minutes.
**Risk:** none. Read-only telemetry permission.

### 0.2 Baseline measurement, read-only

Per-container CPU and memory on Node A and Node B across a representative traffic window, via SSM:

- `docker stats --no-stream` sampled repeatedly — not a single snapshot, since one reading of a Next.js container tells you nothing
- per-cgroup `memory.stat` `anon` vs `file`, for true RAM versus reclaimable cache. `systemd-cgtop`'s single figure conflates the two and misleads; this already produced a wrong conclusion on the Integrations VM, where `cron.service` appeared to use 482 MB but was 495 MB of page cache and 0.25 MB of actual RAM.
- 7-day `CPUUtilization` and `CPUCreditBalance` for both nodes
- `df -h` and `docker system df`, for disk headroom before two more images land

**The question this answers:** what fraction of Node A's CPU is the two `website_frontend` containers? If it is most of it, doubling them roughly doubles node CPU and Phase 2 must size accordingly. If the Django stack dominates, the frontend delta is smaller and `m7i.large` is comfortable.

**Risk:** none, entirely read-only.
**Blocker:** ⚠️ AWS CLI session expired — `aws login` needed first.

---

# Phase 1 — This week. Protect what exists. No resize, no traffic impact.

These are cheap, reversible, and each removes a failure mode that gets worse with two more tenants. None require a maintenance window.

### 1.1 Bound Redis memory on both app nodes

Both nodes run Redis with `maxmemory=0` and `maxmemory-policy=noeviction`. The note written when this was first found states it plainly: it "will OOM the box rather than evict as dealerships are added." That is the event now scheduled for 5 October. Current usage is only ~63 MB, so this is not about size today — it is that nothing bounds it, and the failure mode is the whole box dying rather than the cache degrading.

**The nuance that must not be got wrong:** this same Redis instance is the Celery broker as well as the Django cache and the inventory store. `allkeys-lru` would silently evict queued Celery tasks. The correct policy is **`volatile-lru`**, which evicts only keys carrying a TTL — the inventory blobs (`HOMENET_CACHE_TTL_SECONDS=7200`), per-VIN keys and CMS entries all have one; broker keys do not.

Proposed: `maxmemory 512mb`, `maxmemory-policy volatile-lru`. That is ~8x current usage — generous enough never to evict in normal operation, small enough to be a real backstop on an 8 GiB box.

**Apply:** `CONFIG SET` for immediate effect, plus the equivalent persisted in the Redis config so it survives a container recreate. Verify with `CONFIG GET maxmemory maxmemory-policy` on both nodes.
**Rollback:** `CONFIG SET maxmemory 0` — instant.
**Risk:** low. The worst realistic case under sustained pressure is a cache miss, which now costs ~20–50 ms rather than the 26–60 s it cost before the inventory fixes landed.

### 1.2 Stop `beat` running on both nodes

`nisanwebsite-beat-1` is up on Node A and Node B, so every scheduled task fires twice per cycle. `refresh_homenet_inventory_cache` takes 31.9 s for four dealerships and runs twice; `warm_jdpower_incentive_cache` likewise. Pure waste today. At four launched tenants it doubles a vendor call volume that already covers all four rooftops, and vendor rate limits become a real consideration.

Proposed: disable `beat` on Node A (the credit-starved node), leave it running on Node B.

**Caveat to resolve before acting:** this makes cron execution dependent on a single node. If Node B is down, scheduled refreshes stop and inventory goes stale after its 2 h TTL. Options: (a) accept it, with an alarm on cache freshness; (b) a proper lock (`celery-singleton`, or a Redis lock in the task) so both can run safely — a dev change. **Recommend (a) plus an alarm now, (b) later.** This is a decision needed, not a foregone conclusion.
**Rollback:** start the container again. Trivially reversible.
**Risk:** low, provided the caveat above is accepted explicitly rather than by omission.

### 1.3 Recreate the fd-exhaustion alarm

`dealerpulse-nginx-fd-exhaustion` was deleted, but its metric filter on `/dealerpulse/nginx/error` survives and still publishes `DealerPulse/nginx/NginxFdExhaustion`. So the signal exists and nothing consumes it. fd exhaustion would not reliably surface as either latency or 5xx, which means it would currently go unnoticed entirely.

One `put-metric-alarm` against the existing metric, wired to `dealerpulse-alerts`.
**Risk:** none.

### 1.4 Add memory and swap alarms — *after* 0.1 lands

Once `CWAgent` publishes: `mem_used_percent` and `swap_used_percent` on all three boxes. The Integrations VM matters most — it has been swapping 764 MB–1 GB persistently for weeks with nothing watching it.

Set thresholds from the 0.2 baseline, not from instinct. Yesterday's alarm set had to be loosened wholesale precisely because it was tuned on estimates rather than distributions; that mistake is worth not repeating.

---

# Phase 2 — By ~25 Sep. Resize. One box at a time.

**This must complete before Corona's containers are deployed, not after.** Landing two more Next.js containers on a node already at its sustainable CPU ceiling is the single most likely way 5 October goes badly.

## 2.1 Why the app nodes must leave the t3 family

Node A is `t3.large`: 2 vCPU, 8 GiB, burstable baseline **30% — meaning 0.6 vCPU sustained** — earning 36 credits/hour against a 576 cap. It averages ~30% CPU. That is not "30% utilised with headroom"; it is sitting exactly on its sustainable ceiling with an empty burst bucket. Which is why its credit balance bottoms at 8 and spends 16.7% of the day under 30, and why yesterday's credit alarm had to be loosened to `<10` over 30 minutes to stop it firing continuously.

Doubling the frontend container count pushes average utilisation permanently past baseline. To illustrate the shape rather than predict a number: at 45% average the node consumes 54 credits/hour against 36 earned — an 18/hour deficit that drains a *full* bucket inside a day and then hard-throttles the instance to 0.6 vCPU. **Available CPU falls by a third at the moment load doubles.** It is a cliff, not a slope, and the site gets slower precisely when more people are looking at it.

Node B currently holds a healthy balance (737–864), but only because the ALB sends it 65% of traffic while Node A starves. Both nodes need to be the same size and both need to leave the credit model.

## 2.2 Instance recommendation

| Option | vCPU / RAM | ~$/hr ⚠️ | vs t3.large | Notes |
|---|---|---|---|---|
| **`m7i.large` (recommended)** | 2 / 8 GiB | ~0.1008 | ~+21% | Fully non-burstable. Sustained CPU 0.6 → **2.0 vCPU**: 3.3x the guaranteed capacity for about a fifth more cost. |
| `m6i.large` | 2 / 8 GiB | ~0.096 | ~+15% | Same shape, previous generation, marginally cheaper. Fine if m7i is constrained. |
| `m7i-flex.large` | 2 / 8 GiB | ~0.0983 | ~+18% | ~7% cheaper than m7i, but sustains full CPU only ~95% of a 24 h period. Not worth the asterisk for that saving. |
| `m7i.xlarge` | 4 / 16 GiB | ~0.2016 | ~+142% | Only if 0.2 shows memory is tight with 8 containers. Decide from data, not comfort. |
| `m7g.large` (Graviton) | 2 / 8 GiB | ~0.0816 | **−2%** | Genuinely cheaper than what we run today, but needs arm64 rebuilds of every image. **Not before 5 October.** Revisit in November — it is the real long-term cost answer. |

**Recommendation: `m7i.large` for Node A and Node B.** ⚠️ All prices are approximate us-west-2 on-demand and must be confirmed against live pricing before sign-off. No Savings Plan is currently applied to any of these instances; worth revisiting once October's shape is known.

## 2.3 Integrations VM — the severity risk, not the likelihood risk

`t3.medium`, 3.8 GB. **Persistently swapping 764 MB–1 GB with ~1.5 GB available for weeks**, has hit zero CPU credits, and hosts `ocean-shared-postgres` — the single database behind *both* app nodes — alongside `chat_back`, `leads_backend`, `framework_frontend` and the unused `website-shared-redis`.

`vm.swappiness` is already 10, so that swap is genuine memory pressure, not kernel eagerness — do not "tune" it. `swapoff -a && swapon -a` was explicitly rejected earlier for good reason: forcing ~1 GB back into a box with ~1.6 GB available risks the OOM killer taking shared Postgres and both production sites with it.

**This is a single point of failure for all four tenants and the most constrained box in the fleet.** It needs resizing regardless of what the app nodes do.

**Recommend `m7i.large` (2 vCPU / 8 GiB)** — doubles memory, removes the credit ceiling. `r7i.large` (2 / 16 GiB, ~$0.1323/hr) if the baseline shows Postgres wants more headroom. Also fix `effective_cache_size`, currently set to 5 GB on a 3.8 GB box and therefore actively misleading the query planner; set it from whatever the new size actually is.

## 2.4 Execution order and verification

Proven procedure, unchanged from Node B's `t3.medium` → `t3.large` resize on 2026-09-10: stop → `modify-instance-attribute` → start, ~2–3 minutes, all containers return on their own via Docker's restart policy.

1. **Node B first.** It carries 65% of traffic, so do it while Node A can still absorb 100% — and if something unexpected happens, the node we have *not* touched is the healthy one. Confirm both targets healthy before starting.
2. Verify: AWS status checks, both ALB targets `healthy`, live `200`/`301` on `www.puentehillsnissan.com`, `phn`, `surfcity`, `api`, `admin`. All 6 containers up with `restarts=0`.
3. **Node A second**, same checks.
4. **Reset ALB weights to 50/50.** The 35/65 split exists solely to relieve Node A's credit starvation; once both nodes are identical and non-burstable it is no longer justified and simply wastes Node A.
5. **Reduce listener stickiness from 86,400 s.** At 24 hours, weights govern only new session assignment and load can never rebalance — the realized split has been running nearer 23/77 than the configured 35/65. Stickiness is needed to avoid the cross-node Next.js chunk-hash 404 bug, but that needs minutes, not a day. **Propose 3,600 s.** ⚠️ Verify against a real deploy first: the chunk-mismatch window is the gap between Node A and Node B deploying, and Node B's deploy step is manual-trigger, so the true requirement is however long that gap is allowed to be.
6. **Integrations VM last**, in a scheduled window — this one *is* a real outage for all sites, since shared Postgres lives on it. ~3 minutes.

**Rollback for every step:** `modify-instance-attribute` back to the previous type, same 3 minutes. `dealerpulse-tg-nginx` also remains registered-but-unreferenced as an instant listener rollback path.

## 2.5 While the boxes are down anyway

Two things worth folding into the same windows rather than scheduling separately:

- **Raise gunicorn concurrency.** 3 workers × 4 threads = 12 concurrent request slots per node, and that ceiling has to serve four sites' SSR fan-out (8–10 API calls per page render) plus real API traffic. Env-overridable via `GUNICORN_WORKERS`/`GUNICORN_THREADS`, so it is a `.env` change — but note the standing rule: a new `.env` variable needs `docker compose up -d --no-deps` to take effect, **never** a plain `restart`. Size from the 0.2 baseline.
- **Fix the health-check matcher.** Both `dealerpulse-tg-nodea` and `dealerpulse-tg-nodeb` use a `200-499` matcher against `/`, so a node returning 4xx for everything still reads as healthy. This no-op check was documented on 2026-09-12 and then carried unchanged into the new per-node topology. It should hit a real endpoint with a `200`-only matcher. With four tenants sharing two nodes, a health check that cannot detect an unhealthy node is worth considerably less.

---

# Phase 3 — Late Sep / early Oct. Build out Corona (and San Bernardino).

Only after Phase 2. The standing pattern is already documented in project memory and was proven by Surf City; the steps are not the risk. **The risk is entirely in the inputs**, and these need chasing now rather than on 4 October:

1. **Real production hostnames for Surf City and Corona, and who controls each DNS zone.** Surf City is currently live only on `surfcity.callingyounow.us`, which is our own zone and not a launch hostname. Precedent: with `puentehillsnissan.com` the third-party DNS coordination was the long pole, not the infra work. **If either domain is third-party managed, this dominates the schedule and nothing else on this list matters as much.**
2. **Which pipeline pattern Corona uses** — the original single-branch-multiple-dealership arrangement, or the decoupled per-dealership branch (`main-surfcity`). Both exist deliberately in this repo's history, and the earlier note says explicitly to ask rather than assume a default.
3. **The three per-location vendor IDs** still carrying Puente Hills' placeholder values on Surf City today: `NEXT_PUBLIC_CAPITAL_ONE_DEALER_ID`, `NEXT_PUBLIC_DEALER700_QUICK_QUALIFY_ID`, `NEXT_PUBLIC_DSS_REGISTERED_HREF`. Launching a rooftop with another rooftop's financing IDs is a real-money defect, not a cosmetic one. Corona needs its own set as well.
4. **Whether Cox/xtime hold the new hostnames for callbacks.** Oldest open blocker in the project, vendor lead times run to weeks, and the failure mode is silent lead loss. Given the CTO's fourth point was specifically that lead volume is below expectation, a lead-routing gap discovered after launch would be a bad conversation.

Mechanically, per rooftop: second git clone on both nodes, ACM cert + SNI attach, nginx vhost on a new local port reusing the existing self-signed cert, Cloudflare DNS plus a full-replace cache-rules PUT, `ocean`'s `ALLOWED_HOSTS`/`CORS_ALLOWED_ORIGINS` on both nodes, a new `deploy.sh` case with its own container name/port/ECR tag — **never reuse an existing case**, that landmine nearly took Puente Hills down once — and new pipeline steps.

Disk is not expected to be a constraint: nodes sit at ~20% of ~60 GB, images are built in CI and only pulled here, and the nightly prune covers images and build cache. Confirm in 0.2 regardless.

---

# Phase 4 — October, after launch stabilises.

### 4.1 Kill the SSR hairpin — the biggest structural win

The frontend reaches the backend over the public hostname, so every server-side fetch leaves the VPC, crosses Cloudflare, and re-enters through the ALB. It is roughly **half of all ALB `RequestCount`**, it consumes the same 12 gunicorn slots that serve real users, it is billed and rate-limited as public edge traffic, and it puts SSR errors into the same 5xx metric that fronts customer traffic. It scales directly with page renders, so two more tenants multiply it.

Needs a dev change: a separate server-side API base URL pointing at the internal address, since `NEXT_PUBLIC_*` is baked at build time *and* used by the browser, so it cannot simply be repointed.

**Note for whoever does it:** removing the hairpin halves ALB `RequestCount`, which halves the denominator of both error-rate alarms and therefore roughly doubles the computed error rate for the same number of real user errors. Both thresholds need retuning in the same change.

### 4.2 Move `ocean` Postgres to RDS

Removes the all-tenant single point of failure, and brings backups, failover and metrics we do not currently have. A real migration with a maintenance window — worth doing properly rather than squeezing in before 5 October.

### 4.3 Shared ISR cache handler

`website-shared-redis` already exists on the Integrations VM and is completely unused. Today each node keeps its own filesystem ISR cache and a CMS revalidation only ever reaches one of them — confirmed by code and by cross-referencing both nodes' access logs. At four tenants across two nodes that becomes **eight independent caches**, with every content edit landing on one. Editorial confusion scales linearly with rooftops.

### 4.4 Fix `pages/null`

`getCmsPageFetcher` guards `DEADERSHIP_ID` but never the slug, so a null slug still builds `/public/pages/null`. Currently 6,281 on Node A and 7,264 on Node B — about **4% of all traffic** wasted, and it multiplies per tenant.

---

# The structural point for the CTO

One container per rooftop exists **only** because tenant identity is bound at build time through `NEXT_PUBLIC_DEALERSHIP_ID`. The platform already resolves tenants at runtime — by `?dealership_id=` and by the `Domain` table — so if that binding moved from build time to request time, a single image would serve every rooftop and the frontend tier would stop growing linearly with tenant count.

At four tenants on `m7i.large` boxes the current model is entirely affordable. **It is what makes rooftop number eight expensive** — in instance size, deploy time, pipeline count and blast radius. It is an application change rather than an infrastructure one, and it is the highest-leverage item in this document.

---

# Cost summary ⚠️

| Box | From | To | ~$/mo before | ~$/mo after |
|---|---|---|---|---|
| Node A | t3.large | m7i.large | ~61 | ~74 |
| Node B | t3.large | m7i.large | ~61 | ~74 |
| Integrations | t3.medium | m7i.large | ~30 | ~74 |
| **Total** | | | **~152** | **~222** |

**≈ +$70/month (+46%) on the compute line**, of which roughly $44 is the Integrations VM alone — the box that is the single point of failure for all four tenants and has been swapping for weeks. Compute only; excludes ALB, data transfer, EBS, ECR and Cloudflare. All figures approximate and pending confirmation against live pricing.

Graviton (`m7g.large`) would bring the app nodes in *below* today's cost, but needs arm64 rebuilds and should not be attempted before 5 October.

---

# Open decisions needed before implementation starts

1. Approve the `m7i.large` sizing, or run the 0.2 baseline first and decide from data.
2. Single-`beat` trade-off: accept the single point of failure plus a freshness alarm, or ask the dev team for a proper lock.
3. Stickiness reduction to 3,600 s — needs the real deploy-gap requirement confirmed.
4. Maintenance window for the Integrations VM resize, which is a genuine all-sites outage.
5. Everything in Phase 3's input list — not infra decisions, but they gate the launch date.
