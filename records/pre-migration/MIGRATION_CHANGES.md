# Planned Changes — Dealerships AWS Migration

## Overview

This is a **lift-and-shift** migration — the application architecture does not change. We are moving the same Docker Compose stacks from DigitalOcean droplets onto AWS EC2.

Alongside the move we are making **eight changes**. Three are the headline items (a three-machine split with more memory, CDN delivery, and all builds moved into CI). Five are things that simply do not exist today and are cheap to add while we are rebuilding anyway.

**Every change other than the machines is either free or costs under $5/month.** The cost increase is almost entirely the machines themselves.

### What is in scope

**Five applications**, split across **three AWS instances** by role:

| Application | Today | Moves to | Role |
|---|---|---|---|
| `nisanweb-backend` | `Nissan-Websites` | **Backend VM** | Django API, Celery, PostgreSQL, Redis |
| `leads_backend` | `Nissan-Websites` | **Integrations VM** | Cox / xtime lead and appointment integration |
| `chat_backend` | `Nissan-Websites` | **Integrations VM** | AI chat |
| `dealerships_frontend` | `Nissan-Websites` | **Integrations VM** | **Admin dashboard** — static single-page app |
| `website_frontend` | **`Combined` (a different box)** | **Frontend VM** | **Public dealership websites** — Next.js 16 |

**Why three machines and not one.** Splitting by role isolates the blast radius: a frontend problem cannot take the API down, and an integration service crashing cannot take down a dealership website. It also lets each machine be sized for its actual job rather than for the sum of everything.

---

## Change register at a glance

| # | Change | Today | After | Monthly cost | Teams involved |
|---|---|---|---|---|---|
| 1 | **Three right-sized machines** | 1 box, 2 vCPU / 3.8 GiB, no swap | 3 VMs, role-split, swap on all | $76 (vs $28) | DevOps |
| 2 | **CDN for the public websites** | No domain, no HTTPS, no caching | CloudFront in front of the container | **$0.00** | DevOps |
| 3 | **Media files backed up** | 220 MB on disk, **no backup** | Snapshot + 6-hourly sync to S3 | **$0.05** | DevOps |
| 4 | **All builds in CI** | One service builds on the VM | All build in CI, VMs only pull | **$0.50** | DevOps + all repo owners |
| 5 | **Automated backups** | ❌ **None** | 6-hourly dumps + snapshots + restore test | **$2.20** | DevOps |
| 6 | **Monitoring & alerts** | ❌ **None** | CloudWatch metrics + alarms | **$5.00** | DevOps |
| 7 | **Turn off DEBUG mode** | `DEBUG=True` in production | `DEBUG=False`, production web server | **$0.00** | **Backend** |
| 8 | **Firewall and access model** | Bypassable by Docker; SSH open | Security Groups; **no inbound SSH at all** | **$0.00** | DevOps |

**Total new inclusions: ~$8.25/month.** The remaining increase is the machines.

---

## 1. Three right-sized machines

The current server is effectively full:

```
RAM   3.8 GiB total  |  3.2 GiB used  |  622 MiB available  |  0 B swap
CPU   2 vCPU         |  7–9% sustained over 14 days
Disk  116 GB         |  6.7 GB used (6%)
```
![alt text](memory.png)
![alt text](disk.png)
![alt text](nproc.png)

**Memory is the constraint — not CPU, not disk.** With no swap, there is no graceful degradation: if the box runs out of memory, the kernel terminates a process outright — most likely a database. It has not happened yet (45 days uptime), but there is no margin, and one service spikes memory every time it deploys (see Change 4).

CPU tells the opposite story: **7–9% sustained across two full weeks**, with one brief peak. We are not short of processing power and never have been.

### The fleet

| | Frontend VM | Backend VM | Integrations VM |
|---|---|---|---|
| Instance | **`t3.small`** | **`t3.medium`** | **`t3.medium`** |
| vCPU / RAM | 2 / 2 GiB | 2 / 4 GiB | 2 / 4 GiB |
| Swap | 2 GB | **4 GB** | 2 GB |
| Disk | 40 GB gp3 | 60 GB gp3 | 40 GB gp3 |
| Expected memory use | ~1.1 GiB (55%) | ~2.1 GiB (53%) | ~1.7 GiB (43%) |
| Monthly | $15.18 | $30.37 | $30.37 |

**`t3.small` and `t3.medium` have the same CPU allowance** — the difference between them is memory alone. Sizing the Frontend VM smaller therefore costs no processing headroom, and saves $15.19/month.

### Two planned reviews

| When | Action |
|---|---|
| **Third tenant onboarded** | Frontend VM `t3.small` → `t3.medium` (**+$15.19/month**). One tenant fits comfortably in 2 GiB; three will not. |
| **~1 month after migration** | Review all three against real CloudWatch data. If utilisation is as low as today's figures suggest, **downscale.** |

Resizing is a stop, resize, start — minutes, no rebuild. We size conservatively now and reduce on evidence, because reducing on evidence is safe and discovering an undersized machine during a traffic peak is not.

> ⚠️ **Note on `Combined`:** `website_frontend` moves off it, but `Combined` also hosts roughly 15 unrelated projects and is **not being retired**. The Frontend VM is therefore genuinely new spend, not a transfer.

---

## 2. Public websites get a CDN

`website_frontend` has **no domain and no HTTPS today.** It is a **Next.js 16 application, not a static website** — it requires a running Node.js server for edge middleware (`proxy.ts`), an API route for on-demand CMS cache invalidation (`app/api/revalidate`), ISR content fetching, and `next/image` optimisation.

**Forcing this into static hosting would mean losing on-demand content publishing** — the marketing team's CMS edits would no longer appear until an engineer triggered a rebuild. That is a product regression traded for an infrastructure convenience, and not a good trade.

**So: keep it running as a container, and put CloudFront in front of it.**

| Feature | vs today |
|---|---|
| Edge caching, faster loads | ✅ **New** |
| Free HTTPS + custom domain | ✅ **New** — it has neither today |
| Data served by the server | ✅ **~70–80% less** |
| Middleware, CMS publishing, image optimisation | ✅ **Unchanged — all keep working** |
| Application code changes required | ✅ **None** |
| Site survives a server outage | ❌ **Not delivered** — would need a different hosting model |

**Cost: $0.00.** CloudFront delivery is free to 1 TB/month and 10M requests/month, permanently; HTTPS certificates are free. For scale, 1 TB is roughly 350,000 fresh visits.

### Admin dashboard — stays a container

The admin dashboard (`dealerships_frontend`) **is** genuinely a static single-page app, so S3 + CloudFront would work. **We are keeping it as a container on the Integrations VM instead.** It uses 4.6 MiB, so co-locating costs nothing, and it keeps the cutover to one deployment pattern rather than two.

Moving it to S3 remains available as a fast-follow if independence from the VM becomes worth having.

---

## 3. Media files — backed up, but staying on disk

220 MB of uploaded images sit on the server's disk, growing about **29 MB per week**, **backed up by nothing.** If the disk fails today, they are gone.

**Team decision: media stays on local disk for now.** The volume is small and stable, and moving it means an application change during a migration that otherwise changes no application code.

What does change is that it stops being unprotected:

| | Today | After |
|---|---|---|
| Copy of the files exists anywhere | ❌ **No** | ✅ Daily disk snapshot + 6-hourly sync to S3 |
| Recoverable after accidental deletion | ❌ No | ✅ Yes |
| Application change required | — | **None** |

**Cost: ≈ $0.05/month** for the backup copy. **Teams: DevOps only.**

> Moving media to S3 properly remains on the roadmap, for one reason beyond durability: it is a **prerequisite for ever running more than one backend server.** Deferring it defers that too — see *Why no load balancer* below. The application already contains the code; it needs two libraries and a setting.

---

## 4. All builds move into CI

Four of our five applications build their container image on a **build server**, then the production machine downloads the finished result. That is the correct pattern.

**`nisanweb-backend` does not.** It downloads source code onto the production server and **compiles the image there**, at every deployment — consuming several hundred MB of memory on a machine with 622 MB free, occupying both CPU cores while serving live traffic, producing a slightly different result each time, with no previous version kept to roll back to.

**Benefits:** removes the largest memory spike from production · faster, more predictable deploys · **rollback becomes possible** · one identical pattern for all five applications · source code and repository credentials leave the production servers · deployments verify health automatically and roll back if unhealthy.

**Cost: ≈ $0.50/month** for the image registry (Amazon ECR). We are also moving the other applications from Docker Hub to ECR — faster (same data centre), no download rate limits, and one fewer stored password.

**Teams: DevOps, with each repository owner reviewing their own pipeline.** All five deployment pipelines are rewritten.

---

## 5. Automated backups — new capability

**There are no backups.** No scheduled database exports, no server snapshots, no tested recovery procedure. A disk failure, accidental deletion, or bad migration would mean permanent loss of dealership and customer lead data. **This is the single largest gap in the current setup.**

| Layer | What it does |
|---|---|
| Database exports every 6 hours | All three databases copied to S3, retained 30 days |
| Daily server snapshots | Whole-machine recovery point per VM, retained 7 days |
| Media file versioning | Every version of every uploaded file recoverable |
| **Weekly automated restore test** | A backup is restored and verified automatically, every week |

That last item matters most. **An untested backup is a guess.** The weekly test means we find out a backup is broken on a Tuesday morning, not during an emergency.

**Recovery targets:** maximum data loss **6 hours**; maximum time to restore **2 hours**.

**Cost: ≈ $2.20/month.** The databases total only 46 MB; the increase over a single-box design is the third set of snapshots.

> 🔴 **One dependency:** `chat_backend` encrypts its stored data with a key held in its configuration. **Without that key, its backups are permanently unreadable.** The key must be stored in AWS Parameter Store as part of this work — not left only in a file on a server.

---

## 6. Monitoring and alerting — new capability

**There is no monitoring.** No metrics, no alerts, no dashboards. Today the first indication of a problem is a phone call from a dealership — and the memory pressure in Change 1 went unnoticed until manually investigated.

Automated alerts by email or SMS when memory exceeds 85%, disk exceeds 80%, CPU is sustained above 80%, a server fails a health check, any service stops responding, **a backup job fails**, or **a weekly restore test fails**.

Two alarms are specific to the new machines: **CPU credit balance** (early warning that a machine is working harder than its baseline) and **surplus credits charged** (that headroom is now costing money).

**Cost: ≈ $5.00/month** across three instances.

---

## 7. Turn off DEBUG mode

The main application runs with **developer diagnostic mode enabled in production**. When an error occurs it returns a diagnostic page **to whoever triggered it** — internal file paths, database queries, configuration values, and the contents of variables in memory at that moment, which can include customer data being processed.

Two changes, which have to happen together:

1. **Diagnostic mode is turned off** — `DEBUG` and `ALLOWED_HOSTS` become environment-driven rather than hardcoded
2. **The application moves to gunicorn**, a production web server, replacing Django's built-in development server — which Django's own documentation states is not for production use

**These are not separable.** With diagnostic mode off, the development server stops serving static files altogether, so turning off `DEBUG` without also moving to gunicorn would break the site's styling and assets.

**Cost: $0.00** — configuration and code only. **This is a hard requirement: the migration will not go live without it.**

---

## 8. Firewall and access model

### The firewall

Three services are currently reachable directly from the internet, bypassing the secure entry point — **despite the firewall being configured to block them.** Docker writes its own network rules that take precedence over the server's firewall, so the firewall appears correctly configured and is silently ineffective.

On AWS the firewall (a **Security Group**) sits **outside the machine**, at the network layer. Docker cannot override it.

| Port | Access |
|---|---|
| 443 (HTTPS) | Public |
| 80 (HTTP) | Public, redirects to HTTPS |
| Everything else | **Blocked** |

Databases are not exposed at all, and traffic between our own services travels over private internal addresses that are unreachable from the internet.

### Staff access — no SSH port at all

Today, administrative access means an open SSH port and private keys distributed to individuals. On AWS we are using **AWS Systems Manager Session Manager** instead, and **port 22 will have no inbound rule on any machine.**

The agent on each server opens an **outbound** connection to AWS; sessions are brokered back down it. There is nothing listening for administrative traffic, so there is no port to scan and no bastion server to maintain.

| | Today | After |
|---|---|---|
| Inbound SSH port | Open to listed addresses | **None — closed entirely** |
| Credentials | SSH private keys per person | **AWS identity — no keys exist** |
| Removing someone's access | Delete their key from every server | **Revoke one permission** |
| Working from a new location | Firewall change required | Works anywhere |
| Record of who did what | ❌ None | ✅ **Full session transcript, retained** |
| Extra infrastructure | — | **None** |

Engineers still get a normal shell, and can still reach a database from their laptop through a temporary encrypted tunnel — **without any firewall rule being changed, ever.**

The session audit trail is worth calling out on its own: it is the **first administrative access log this environment has ever had.**

**Cost: $0.00.**

---

## Why no load balancer and no autoscaling

Worth stating explicitly, because it is the obvious question. **The blocker is shared state, not cost.**

| Component | Why a second copy breaks it |
|---|---|
| **Scheduled-job service** | Must be a singleton. A second copy fires every hourly inventory sync twice — **double the supplier API calls and duplicate leads.** |
| **Media files** | On local disk. A second server would not see uploads written by the first. Needs shared storage (S3/EFS) before scaling is even correct — see Change 3. |
| **Database and cache** | Run on the Backend VM with local storage. Would have to move to managed services first. |

The dealership websites add a fourth reason: **they are not interchangeable copies.** A load balancer spreads traffic across identical instances of one application; ours is one container per dealership, isolated by design, so each address has exactly one correct destination.

Cost reinforces this but does not drive it — a load balancer is ~$22/month and an autoscaling group only means anything at a minimum of two instances, roughly +$30/month per tier. And with CPU flat at 7–9% for two weeks, autoscaling would have no signal to react to and would sit permanently at its minimum.

**Blast-radius isolation, the usual reason to want this, is already achieved** by splitting into three machines.

**Not a one-way door.** Adding a load balancer later is a DNS change and a configuration entry. We would do it once media is on shared storage and there is a real reason.

---

## Also planned, deliberately deferred

| Change | Why deferred |
|---|---|
| **Centralised secrets management** (AWS Parameter Store) | Free and a clear improvement — but it changes how services start up. If something failed to start during the migration, we would not know which change caused it. Scheduled 2–4 weeks after the move. *(The one exception is the chat encryption key in Change 5, which goes in immediately.)* |
| **Graviton (ARM) processors** | Same performance, **~15% cheaper**. Requires every container image to be rebuilt and verified. Fast-follow. |
| **1-year commitment pricing** | **~24% cheaper.** Purchased only after 30 days of real usage data. |
| **Media files served from S3** | Team decision — volume is small and stable, and it means an application change mid-migration. Backed up either way (Change 3). Becomes necessary before any horizontal scaling. |
| **Admin dashboard to S3** | Works, but adds a second deployment pattern during cutover. Optional later. |
| **Migrating the staging environment** | Recommended, but production first. |

---

## Cost summary

| | Monthly |
|---|---|
| Current DigitalOcean (`Nissan-Websites`) | **$28** |
| AWS — first 30 days, on-demand | **$96** |
| AWS — after Graviton and a 1-year plan | **$63** |

`Combined` is not being retired, so its cost is unchanged either way and is excluded from both columns.

**Where the money goes:**

| | Monthly |
|---|---|
| The three machines | $75.92 |
| Storage (140 GB) | $11.20 |
| **Everything else combined** — CDN, S3, backups, monitoring, registry, private DNS | **$8.50** |
| Data transfer | **$0.00** |
| Load balancer / autoscaling | **$0.00 — not used** |
| NAT Gateway | **$0.00 — avoided by design** |

> **Backups and monitoring together cost about $7/month**, and neither exists today.

### Data transfer

Amazon provides **two separate free allowances**, and which one a flow falls into determines how much headroom we have:

| Path | Free each month | Rate above it |
|---|---|---|
| **Through CloudFront** | **1 TB** | ~$0.085/GB |
| **Direct from a server or S3** | **100 GB** (shared) | $0.09/GB |

Inbound traffic is always free, as is traffic from our servers or S3 *into* CloudFront — so routing through the CDN costs nothing and gets the ten-times-larger allowance.

Measured from DigitalOcean's 14-day graph, current outbound is **~49 GB/month**. At the projected 6,000 visits/day per tenant:

| | Volume | Allowance used |
|---|---|---|
| **Via CloudFront** — site assets, images, pages | ~270 GB | **27% of 1 TB** |
| **Direct** — API responses, backups | ~22 GB | **22% of 100 GB** |
| **Cost** | | **$0.00** |

> **One optimisation worth taking:** serve **media images through CloudFront** as well. It costs nothing and moves traffic from the 100 GB allowance to the 1 TB one.

**Cost controls:** monthly budget alarm at $120 with alerts at 50/80/100%, anomaly detection enabled, and the 1-year commitment purchased only after 30 days of real usage data.

---

### Risk

Low. The application architecture does not change, the data is small (270 MB total), and rollback is a DNS change taking under two minutes. The existing servers stay running and untouched for two weeks afterwards.

The one item **not** on the DevOps critical path is external: **if Cox or xtime have our current hostname registered for callbacks, it must be updated with them before cutover** — otherwise leads stop arriving with no error message. Vendor turnaround can take weeks, so this needs answering early.

---

## Recommendation

Proceed with all eight changes. Six of the eight cost under $3/month each, and two of them — backups and monitoring — address gaps that currently represent genuine business risk.

---

*Full technical detail, procedures, and risk register: `AWS_MIGRATION_PLAN.md`*
*Target architecture and network design: `ARCHITECTURE.md`*
