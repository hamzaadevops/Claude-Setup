# AWS Migration Plan — Dealerships Platform

**Document owner:** Hamza Khan (DevOps Engineer)
**Date:** 2026-08-24 · **Revised:** 2026-08-26
**Status:** DRAFT — For Management review and approval
**Scope:** Migrate production from DigitalOcean (`143.198.144.174` + `website_frontend` on `Combined`) to AWS

> ## ⚠️ Read `ARCHITECTURE.md` first
>
> This runbook was written against an earlier **single-VM** target. The team has since approved a **three-VM, role-split fleet**, and **`ARCHITECTURE.md` is now the authoritative design document.** Where the two disagree, `ARCHITECTURE.md` wins.
>
> **What changed:**
>
> | | This runbook originally said | Approved design |
> |---|---|---|
> | Fleet | One `t3.large` | **`t3.small` (Frontend) + 2 × `t3.medium` (Backend, Integrations)** |
> | Scope | Four services | **Five applications** — `website_frontend` moves off `Combined` too |
> | Frontend hosting | S3 + CloudFront | **CloudFront in front of a container** — it is Next.js 16, not static |
> | Admin dashboard | On the main VM | **Container on the Integrations VM** |
> | Media files | Move to S3 | **Stay on local disk, backed up** — team decision |
> | Staff access | SSH tunnel over port 22 | **SSM Session Manager — port 22 closed entirely** |
> | Inter-service traffic | Localhost | **Private IPs via a Route 53 private hosted zone** |
>
> §1 (Foundation), §8 (Security), §10 (Decisions) and §12 (Timeline) below have been updated. **Phases 2–7 still read as a single-VM procedure** — the commands are correct, but each has to be run against the right machine. Restructuring them per-VM is outstanding work.

---

## 0. Executive Summary

### What we are doing

Migrating five production applications off a memory-saturated DigitalOcean droplet (plus one frontend from a second box) onto **three AWS EC2 instances split by role**, using a **lift-and-shift** approach: the same Docker Compose stacks, with targeted improvements bundled in because they are effectively free to do during a rebuild:

1. **Role-split across three VMs** — isolates the blast radius; a frontend fault cannot take the API down
2. **CloudFront in front of the public websites** — free HTTPS and a custom domain, neither of which exists today
3. **Container images are built in CI, never on a production VM**
4. **Backups and monitoring** — neither exists today
5. **No inbound SSH** — administrative access via SSM Session Manager

### Why now

| Driver | Evidence |
|---|---|
| **The current box has no memory headroom** | 3.8 GiB total, 3.2 GiB used, **622 MiB available, zero swap** |
| **Deploys are risky** | `nisanweb-backend` builds its Docker image *on the production server* at every deploy — a multi-hundred-MB RAM spike on a box with <650 MB free |
| **No backups exist** | No documented `pg_dump` schedule, no snapshots, no tested restore. We are one disk failure from total data loss. |
| **No monitoring exists** | No metrics, no alerting, no log aggregation. First signal of an outage is a phone call from a dealership. |
| **Production runs `DEBUG=True`** | Confirmed at `server/coresite/settings/base.py:12`. Leaks stack traces, settings, and SQL to any visitor who triggers an error. |

### What it costs

| | Monthly (estimate) |
|---|---|
| Current DigitalOcean droplet (`Nissan-Websites`) | ~$28 |
| **Proposed AWS — three VMs, on-demand** | **~$96** |
| **Proposed AWS — 1-yr Savings Plan** | **~$77** |
| **Proposed AWS — Savings Plan + Graviton** | **~$63** |

**Net increase: roughly $35–68/month.** In exchange: **isolated failure domains** (a frontend fault can no longer take the API down), roughly double the total RAM with swap on every machine, automated and tested backups, a global CDN with free managed TLS, CloudWatch monitoring and alerting, IAM-managed secrets, and **an administrative access model with no open SSH port and a full audit trail.**

`Combined` is **not** being retired — it hosts ~15 unrelated projects — so the Frontend VM is genuinely new spend rather than a transfer, and its cost appears in neither baseline.

> All prices in this document are **estimates for `us-west-2` and must be confirmed in the AWS Pricing Calculator** before sign-off.

### Timeline

**5 working days of execution**, ending in a single planned cutover. No production downtime until that window.

> ⚠️ **The five days are gated by a Day 0 prerequisite of unknown duration.** The binding constraint is confirming whether HomeNet, Cox/VinSolutions, xtime, and J.D. Power **IP-allowlist our current server** — vendor lead times can run to weeks and are entirely outside our control. **These requests must be raised immediately, regardless of when the five days are scheduled.** See §12.1.

### What we need from administration

1. Approval of the ~$96/month AWS spend
2. **Access to the production domain** we will use for testing and cutover
3. Contact details for the **HomeNet, Cox/VinSolutions, xtime, and J.D. Power** account owners — we must confirm whether any of them IP-allowlist our current server *or* have our hostname registered for callbacks (§8, **highest-risk unknown, and the only item on the critical path**)
4. Approval to rotate the exposed secrets immediately (§8)
5. Developer time for seven code changes that cannot be done by DevOps alone (§9)
6. A named list of who should have production shell access, and where alerts should be sent
7. A decision on whether the **staging** droplet also migrates (adds ~$20/month)

---

## 1. Current State (verified 2026-08-24)

### Services in scope

| Service | Stack | Current path | Port | Domain | Deploy model |
|---|---|---|---|---|---|
| **nisanweb-backend** | Django + DRF, Celery, Redis | `/var/www/nisanWebsite` | `127.0.0.1:9000` | `nissan.staging.flutenwebframework.xyz` | Builds **on the server** |
| **leads_backend** | FastAPI, Uvicorn x4 | `/opt/leads/leads_backend` | `0.0.0.0:8129` | `west-cost.ingeg.staging.flutenwebframework.xyz` | DockerHub |
| **chat_backend** | FastAPI, Uvicorn | `/opt/dealerships/chat_backend` | `0.0.0.0:9002` | `chat.staging.flutenwebframework.xyz` | DockerHub |
| **dealerships_frontend** | React SPA on nginx | `/opt/apps/production/dealerships/frontend` | `0.0.0.0:9011` | **none** | DockerHub |

### Host

```
CPU     2 vCPU (DO-Premium-Intel @ 2.0 GHz)   load avg 0.29 / 0.37 / 0.38  ->  ~19% utilised
RAM     3.8 GiB total | 3.2 GiB used | 622 MiB available | 0 B swap
DISK    116 GB total | 6.7 GB used (6%)
UPTIME  45 days | 0 OOM kills | 0 container restarts
```

### Memory breakdown (real, measured)

| Container | Memory | % of box |
|---|---|---|
| `nisanwebsite-web` | **1.161 GiB** | 30.5% |
| `chat_backend-web` | 506 MiB | 12.9% |
| `leads_backend-web` | 358 MiB | 9.2% |
| `nisanwebsite-worker` | 289 MiB | 7.4% |
| `nisanwebsite-beat` | 80 MiB | 2.1% |
| `chat_backend-postgres` | 65 MiB | 1.7% |
| `nisanwebsite-redis` | 58 MiB | 1.5% |
| `nisanwebsite-db` | 53 MiB | 1.4% |
| `leads_backend-postgres` | 35 MiB | 0.9% |
| `dealerships_frontend` | 5 MiB | 0.1% |
| **Containers total** | **2.57 GiB** | |
| Host (dockerd, nginx, systemd) | 0.63 GiB | |

**All three PostgreSQL instances together use 153 MiB.** Databases are not the memory problem. `nisanweb-backend`'s web container is 45% of all container memory.

### Data volumes — small, which makes migration easy

| Item | Size |
|---|---|
| `nisan_website` (nisanweb-backend, PG 15) | 27 MB |
| `dealerpulse` (chat, PG 16) | 11 MB |
| `leads_db` (leads, PG 16) | 8.2 MB |
| nisanweb-backend `media/` | 220 MB (growing ~29 MB/week) |
| Docker volumes total | 223 MB |
| **Total to migrate** | **~270 MB** |

At this size, a full dump/restore takes **minutes**, not hours. The cutover window is bounded by DNS TTL, not data transfer.

### Certificates

All four Let's Encrypt certificates expire **2026-10-08** (~45 days). `certbot.timer` is active; auto-renewal will occur around 2026-09-08. One orphaned certificate (`west-cost.ingeg.staging.omnipulse.cc`) renews for nothing and will not be recreated on AWS.

### 1.x Service rename: `ocean` → `nisanweb-backend`

The Django service has been renamed from `ocean` to `nisanweb-backend`. **A repository rename does not automatically rename anything else**, and this service has its identity spread across at least seven distinct places. The table below records what changes, what does not, and what will break if assumed.

#### What is affected

| # | Identifier | Current value | Renamed? | Breaks if wrong |
|---|---|---|---|---|
| 1 | **Bitbucket repo URL** | `git@bitbucket.org:nxpt/ocean.git` | ✅ Yes | 🔴 **The server does `git pull` — see below** |
| 2 | **Deploy directory** | `/var/www/nisanWebsite` | ❌ **No** | 🔴 Hardcoded in the compose media mount |
| 3 | **Compose project name** | `COMPOSE_PROJECT_NAME=nisanwebsite` | ❌ **No** | 🔴 Determines container names |
| 4 | **Container names** | `nisanwebsite-web-1`, `-worker-1`, `-beat-1`, `-db-1`, `-redis-1` | ❌ **No** | 🔴 Referenced by pipeline health checks |
| 5 | **Local image names** | `nisanwebsite-web`, `nisanwebsite-worker`, `nisanwebsite-beat` | ❌ **No** | 🟠 Replaced by ECR names in Phase 3 |
| 6 | **Database name** | `nisan_website` | ❌ **No** | 🔴 Restore targets this name |
| 7 | **nginx vhost file** | `/etc/nginx/sites-available/nisanwebsite` | ❌ **No** | 🟠 Cosmetic |
| 8 | **Public domain** | `nissan.staging.flutenwebframework.xyz` | ❌ **No** | 🔴 Tenancy resolves on this |
| 9 | **Django project module** | `coresite` | ❌ **No** | 🔴 `coresite.wsgi`, `celery -A coresite` |

> **Only item 1 actually changed.** Items 2 through 9 retain their original names and **must not be "tidied up" as part of the rename** — several are load-bearing.

#### 🔴 The one thing that can break today

`nisanweb-backend` is **the only service that runs `git pull` on the production server.** Its deploy scripts execute:

```bash
cd /var/www/nisanWebsite
git fetch origin main && git checkout main && git pull origin main
```

The server's git remote still points at `git@bitbucket.org:nxpt/ocean.git`. Bitbucket does maintain redirects for renamed repositories, so this **probably** still works — but redirects are a compatibility courtesy, not a guarantee, and they can be broken by creating a new repository under the old name.

**Check this now — read-only, takes five seconds:**

```bash
ssh root@143.198.144.174 'cd /var/www/nisanWebsite && git remote -v && git ls-remote origin HEAD'
```

- If `git ls-remote` succeeds, the redirect is working and there is no immediate problem.
- If it fails, **the next deploy to production will fail.** Fix with:
  ```bash
  git remote set-url origin git@bitbucket.org:nxpt/nisanweb-backend.git
  ```

**This risk disappears entirely in Phase 3.** Once builds move to CI and the VM only pulls images from ECR, **the production server no longer needs git, a repository checkout, or a Bitbucket SSH key at all.** The rename becomes irrelevant to the server.

#### Other places to check

| Location | Check |
|---|---|
| Bitbucket Pipelines variables | Any reference to the old repository name or slug |
| Bitbucket deployment environments | Environment names may embed `ocean` |
| Webhooks / integrations | Slack notifications, issue trackers pointing at the old slug |
| Developer local clones | Each developer must run `git remote set-url` |
| Documentation | The three existing guides all say `ocean` throughout |
| `README.md` / `CONTRIBUTING.md` | Clone instructions with the old URL |

```bash
# Sweep the repository for stale self-references
grep -rn "nxpt/ocean" . --exclude-dir=.git
```

#### Naming decisions for AWS

Since Phase 2 rebuilds everything, choose names deliberately and record them:

| Resource | Recommended | Rationale |
|---|---|---|
| ECR repository | `nisanweb-backend` | Matches the repository |
| Deploy directory | `/var/www/nisanWebsite` **for the 5-day plan** | CC-4 is deferred, so the hardcoded media mount stays. Rename to `/var/www/nisanweb-backend` only *after* media moves to S3. |
| `COMPOSE_PROJECT_NAME` | `nisanwebsite` (unchanged) | Changing it renames every container and breaks pipeline health checks. Not worth the churn during a migration. |
| Database name | `nisan_website` (unchanged) | Renaming a database mid-migration adds risk for no benefit |
| nginx vhost file | `nisanweb-backend` | Free to rename — nothing depends on the filename |
| Cost allocation tag | `Service=nisanweb-backend` | New, so use the new name |

> **Principle: rename the things that are free to rename, and leave the load-bearing ones alone until there is a reason to touch them.** A migration is the wrong moment to change identifiers that other systems depend on.

---

## PHASE 1 — AWS Foundation

**Duration:** 3–4 days | **Owner:** DevOps | **Downtime:** none

### 1.1 Region

| Region | Latency from SoCal | Cost | Verdict |
|---|---|---|---|
| **`us-west-2` (Oregon)** | ~20–25 ms | Baseline | **Recommended** |
| `us-west-1` (N. California) | ~10–15 ms | ~15–20% higher | Not worth the premium |
| `us-east-1` (Virginia) | ~70 ms | Cheapest | Latency penalty |

**Decision: `us-west-2`.** All AWS services are available there, it is the cheapest West Coast region, and a 10 ms latency difference is irrelevant for a dealership web application. All third-party integrations (HomeNet, Cox, xtime, J.D. Power) are internet-facing, so region has no bearing on them.

> **Exception:** CloudFront requires its ACM certificate to live in **`us-east-1`**. That single certificate is the only resource outside `us-west-2`.

### 1.2 Instance type

**Superseded — `ARCHITECTURE.md` §4 is authoritative.** The single-VM sizing below is retained only to record why it was rejected.

### Approved fleet

| | Frontend VM | Backend VM | Integrations VM |
|---|---|---|---|
| Instance | **`t3.small`** | **`t3.medium`** | **`t3.medium`** |
| vCPU / RAM | 2 / 2 GiB | 2 / 4 GiB | 2 / 4 GiB |
| Disk | 40 GB gp3 | 60 GB gp3 | 40 GB gp3 |
| Swap | 2 GB | **4 GB** | 2 GB |
| Est. memory used | ~1.1 GiB (55%) | ~2.1 GiB (53%) | ~1.7 GiB (43%) |
| On-demand | $15.18 | $30.37 | $30.37 |

**Total compute: $75.92/month.**

`t3.small` and `t3.medium` share the **same 0.4 vCPU baseline** — they differ in memory only, so the smaller Frontend VM costs no CPU headroom.

**Upgrade trigger:** Frontend VM → `t3.medium` when the **third tenant** is onboarded (+$15.19/month). **Review trigger:** all three reassessed against real CloudWatch data ~1 month after cutover, downscaling if utilisation matches current baselines.

### Why not a single larger VM (original analysis, rejected)

| Option | vCPU | RAM | ~$/mo | Verdict |
|---|---|---|---|---|
| `t3.medium` | 2 | 4 GiB | ~$30 | Rejected as a single box — no headroom for all five apps |
| `t3.large` | 2 | 8 GiB | ~$61 | **Originally recommended.** Rejected: no blast-radius isolation |
| `t3.xlarge` | 4 | 16 GiB | ~$121 | Overprovisioned |

Three `t3.small`/`t3.medium` machines cost **$76 against `t3.large`'s $61** — a $15 premium that buys isolated failure domains, per-role sizing, and independent deploy/restart cycles. The team judged that worth paying.

**Burstable-credit check (revised against 14-day data):** the `t3` baseline is **0.4 vCPU per instance**. Measured sustained load across the *entire current production box* is **0.16 vCPU (7–9% of 2 vCPU)**, flat across two weeks, with one brief peak of ~1.44 vCPU on 24 Aug consuming roughly 21 surplus credits of a 576 maximum. Split three ways, aggregate baseline becomes 1.2 vCPU — roughly **7.5× headroom**.

> An earlier draft of this section quoted **0.38 vCPU from `load average`**. That metric counts processes in uninterruptible sleep as well as runnable ones and overstates CPU demand. The 14-day `CPUUtilization` graph is what credits are actually consumed against, and it is the figure used here.

**Alarms:** `CPUCreditBalance` below 20% of maximum (early warning) **and** `CPUSurplusCreditsCharged > 0` sustained (now costing money). Escalation path if the Backend VM sustains surplus: `c6i.large` (+~$32/mo) or `m6i.large` (+~$40/mo), both non-burstable.

> **Do not use Graviton (`t4g`) at launch.** All images are prebuilt **amd64**. ARM saves ~$14.60/month but requires rebuilding and verifying every image — `sharp` in the Next.js frontend is the highest-risk dependency. **Fast-follow, not launch.**

**Cost optimisation:** after 30 days of stable operation, purchase a **1-year Compute Savings Plan (no upfront)** for approximately 27–30% off. This keeps flexibility to change instance family later, unlike a Reserved Instance.

### 1.3 Storage type

| Type | $/GB-mo | Baseline IOPS | Baseline throughput | Verdict |
|---|---|---|---|---|
| `gp2` | ~$0.10 | 3 IOPS/GB (min 100) | Tied to size | Costlier and slower at our size |
| **`gp3`** | **~$0.08** | **3,000 (free)** | **125 MB/s (free)** | **Recommended** |
| `io2` | ~$0.125 + IOPS charges | Provisioned | Provisioned | Massively overkill |

**Decision: `gp3`.** It is both **cheaper per GB and faster** than `gp2` at our volume. `gp3` decouples IOPS from capacity: a 60 GB `gp3` volume still receives the full 3,000 IOPS / 125 MB/s baseline, whereas 60 GB of `gp2` would provide only 180 IOPS.

**Do we need provisioned IOPS above baseline?** No. Our largest database is 27 MB and fits entirely in the page cache. Peak I/O occurs during the nightly `pg_dump` (~270 MB) and image pulls. 3,000 IOPS is orders of magnitude beyond requirement.

**Also enable:** account-wide **EBS default encryption** (free, AWS-managed KMS key) before launching anything.

### 1.4 Storage size — what we actually keep on the machine

| Item | Today | On AWS | Notes |
|---|---|---|---|
| OS + packages | ~3.0 GB | ~3.5 GB | Ubuntu 24.04 LTS |
| Docker images | 3.2 GB | ~6 GB | We retain 3 tags per service for rollback |
| Docker volumes (3x PG + Redis) | 223 MB | ~1 GB | Growth allowance |
| Container writable layers | 5 MB | ~100 MB | |
| **nisanweb-backend `media/`** | **220 MB** | **0 MB** | **Moves to S3 (Phase 4)** |
| **Frontend static assets** | 95 MB image | **0 MB** | **Moves to S3 + CloudFront** |
| System + Docker logs | small | ~2 GB | Capped via logrotate + Docker log driver limits |
| Backup staging area | 0 | ~1 GB | Dumps written locally, pushed to S3, then deleted |
| Swap file | 0 | 4 GB | Per Phase 2 |
| **Subtotal** | | **~17.6 GB** | |
| Free headroom (~70%) | | ~42 GB | |
| **Provisioned** | | **60 GB gp3** | **~$4.80/month** |

**Decision: 60 GB gp3.** Storage is cheap and running out of disk on a production box is expensive. `gp3` volumes can be grown online without downtime if needed.

### 1.5 Networking

| Resource | Configuration |
|---|---|
| VPC | Default VPC, single public subnet |
| Public IP | **Elastic IP** — stable target for DNS cutover, free while attached |
| NAT Gateway | **Not used.** A single public-subnet instance avoids approximately $32/month. |
| S3 Gateway VPC Endpoint | **Free.** Keeps S3 traffic (media, backups) off the internet gateway. |
| Security Group `sg-app` | **`22`, `80`, `443` only** — see below |

#### Port strategy: the Security Group is the enforcement boundary

**Adopted approach:** containers publish on whatever host port is convenient (including `0.0.0.0`), and the **Security Group is the single control that decides what reaches the internet**.

| Port | Source | Purpose |
|---|---|---|
| `22/tcp` | Office / admin IPs only | SSH, and the tunnel used for database access |
| `80/tcp` | `0.0.0.0/0` | HTTP, redirects to HTTPS |
| `443/tcp` | `0.0.0.0/0` | HTTPS |
| Everything else | — | **Denied** |

**Why this is sound on AWS but was not on DigitalOcean:** Docker's iptables rules for published ports **bypass `ufw` entirely** — which is why `8129`, `9002`, and `9011` are currently internet-reachable on the DigitalOcean box despite the firewall. **Security Groups sit outside the instance**, at the hypervisor's network layer. Docker cannot bypass them, no matter how a container publishes its ports. This removes an entire class of bug.

**Trade-off to accept knowingly:** this is a single layer of defence. If the Security Group is widened by mistake, every published container port becomes reachable at once. Two cheap mitigations:

1. Keep `ufw` configured identically (22/80/443) as a redundant second layer. It costs nothing and catches Security Group errors for non-Docker services.
2. **Never publish databases or Redis at all.** `postgres` and `redis` should be reachable only over the Docker Compose network — no `ports:` entry whatsoever. This is already the case today and must be preserved.

#### Temporary database access from a local machine

The stated need is occasional direct database connectivity from a developer laptop. **Do not open a database port in the Security Group for this** — a temporary rule that is forgotten becomes a permanent exposure of customer lead data.

**Decided: AWS Systems Manager Session Manager. Port 22 has no inbound rule on any machine.**

This supersedes the SSH-tunnel approach originally proposed here. The SSM Agent opens an **outbound** 443 connection to the SSM service and AWS brokers sessions back down it — so there is no inbound administrative listener at all, no bastion host, and no SSH key material to distribute or revoke.

Publish Postgres on host loopback only, exactly as before:

```yaml
# docker-compose.yml — loopback-only, unreachable from the internet regardless of the SG
services:
  postgres:
    ports:
      - "127.0.0.1:5433:5432"    # nisanweb-backend   (Backend VM)
      # - "127.0.0.1:5434:5432"  # leads_backend      (Integrations VM)
      # - "127.0.0.1:5435:5432"  # chat_backend       (Integrations VM)
```

Distinct host ports avoid collisions between the two database containers that now share the Integrations VM.

Then reach it with **no port open anywhere**:

```bash
# Port-forward straight through SSM — no SSH, no inbound rule, no SG change
aws ssm start-session \
  --target i-0abc123def456 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5433"],"localPortNumber":["15433"]}'

# Then connect any local client to localhost:15433
psql -h 127.0.0.1 -p 15433 -U postgres -d nisan_website
```

**Comparison:**

| | **SSM Session Manager** *(chosen)* | SSH tunnel | Opening port `XXXX` in the SG |
|---|---|---|---|
| Inbound ports open | **None** | 22 | 22 + the database port |
| Security Group change | **Never** | Never | Required each time |
| Risk of being left open | **None** | None | High — the classic exposure |
| Encrypted in transit | Yes | Yes | Only if TLS is set up on Postgres |
| Access control | **IAM, scoped by instance tag** | SSH keys on each host | IP-based only |
| Offboarding | **Revoke one IAM permission** | Remove key from every host | Remove the rule |
| Audit trail | ✅ **Full session transcript to S3** | SSH auth log only | None |
| Works from a new location | ✅ | ✅ | ❌ Needs a rule change |

### Requirements

| Requirement | Detail |
|---|---|
| SSM Agent | **Pre-installed** on Ubuntu 24.04 LTS and Amazon Linux 2023 AMIs |
| IAM instance profile | `AmazonSSMManagedInstanceCore` — **attach at launch**, not afterwards |
| Outbound 443 | Available via the Internet Gateway — **no VPC endpoints needed, saving ~$22/month** |
| Operator tooling | AWS CLI v2 + `session-manager-plugin` |
| Session logging | To S3 or CloudWatch Logs — **enable on day one** |

Because the VMs sit in **public subnets with an Internet Gateway**, the agent reaches SSM directly. A private-subnet design would need three interface VPC endpoints at ~$7.30 each per month.

### SSH-protocol operations (scp, rsync)

Still available, tunnelled over the same SSM channel — `sshd` is reached on the loopback interface from inside the instance, so **port 22 stays closed to the internet**:

```
# ~/.ssh/config
Host i-* mi-*
  ProxyCommand sh -c "aws ssm start-session --target %h \
    --document-name AWS-StartSSHSession --parameters portNumber=%p"
```

### Break-glass

| Fallback | Requires | Notes |
|---|---|---|
| **EC2 Serial Console** | A password on a local OS user | Works with **no networking at all** — the genuine last resort |
| Temporary SG rule for port 22 | Console access | Add, use, **remove**. Never leave standing. |

Set the serial-console password during instance build and store it in Parameter Store as a `SecureString`. **A break-glass path that was never set up is discovered only at the worst possible moment.**

**If a Security Group rule genuinely must be opened:** scope it to a single `/32`, add a description recording who opened it and why, and set a calendar reminder to remove it.

### 1.6 S3 buckets

| Bucket | Purpose | Configuration |
|---|---|---|
| `dealerpulse-prod-media` | nisanweb-backend media files | Versioning ON, SSE-S3, Block Public Access ON, accessed via IAM role |
| `dealerpulse-prod-backups` | Database dumps | Versioning ON, SSE-S3, Block Public Access ON, lifecycle rules (§1.8) |
| `dealerpulse-prod-frontend` | React SPA static assets | Block Public Access ON, served only via CloudFront OAC |

### 1.7 Frontend on S3 + CloudFront — rationale, traffic flow, and cost

#### 1.7.1 Why move the frontend to S3 at all?

`dealerships_frontend` is a **React single-page application**: a folder of static files (`index.html`, hashed JS/CSS bundles, images). It contains no server-side logic. Today it is packaged into a 95 MB Docker image, running an nginx process on the production VM purely to serve those files.

**This is the wrong tool for the job, and it costs us in five concrete ways:**

| Problem today | Consequence |
|---|---|
| A container and an nginx process consume VM resources | Competing for RAM on a box that has none spare |
| Coupled to the VM's lifecycle | If the instance reboots or fails, **the entire customer-facing site goes down** — even though nothing about it needs a server |
| Served from a single point in Oregon | Every asset for every visitor crosses the country |
| Deploys require an image build, push, pull, and container restart | Minutes, with a restart window |
| Served on raw port `9011`, **no domain, no TLS** | Currently unprotected |

**S3 is purpose-built for exactly this:** object storage with 99.999999999% durability, no server to patch, no process to restart, and no capacity to plan.

**What we gain:**

1. **The frontend survives EC2 failure.** If the instance is down for a reboot, patching, or a failed deploy, customers still get the site — it degrades to "API unavailable" instead of a blank connection error. This is the strongest single argument.
2. **One less service on the VM.** Removes 95 MB of images, a container, and a port.
3. **Deploys become atomic and instant** — `aws s3 sync` takes seconds with no restart.
4. **No capacity planning.** A traffic spike that would overwhelm an EC2 instance is invisible to S3.
5. **Free managed TLS**, removing a certbot renewal dependency.

#### 1.7.2 Why add CloudFront on top of S3?

S3 alone would technically work, but CloudFront is **required in practice** for three reasons — and it is the component that makes this free:

| Reason | Detail |
|---|---|
| **1. The S3 bucket must stay private** | Serving directly from S3 requires making the bucket **publicly readable**. CloudFront with Origin Access Control (OAC) keeps Block Public Access enabled and lets only CloudFront read it. |
| **2. Custom domain plus HTTPS** | A raw S3 website endpoint cannot serve a custom domain over HTTPS. CloudFront plus ACM does, free. |
| **3. Cost — CloudFront is cheaper than S3 direct** | S3 egress to the internet is **$0.09/GB after 100 GB**. CloudFront egress is **free up to 1 TB/month, perpetually**. Adding CloudFront *reduces* the bill. |

Plus the obvious benefit: **edge caching at 600+ global locations**. A dealership customer in Los Angeles fetches assets from an LA edge node rather than Oregon — typically 100–300 ms faster on first paint, and near-instant on repeat visits.

#### 1.7.3 Traffic flow — before and after

**Today: everything through one nginx on one VM**

```
Browser
   |
   +--> :9011  ------------------> frontend container (nginx)      [static files]
   |
   +--> :443 nginx --> :9000 ----> nisanweb-backend (Django)       [API]
   +--> :443 nginx --> :8129 ----> leads_backend                   [API]
   +--> :443 nginx --> :9002 ----> chat_backend                    [API + WebSocket]
```

Every byte — static assets and API responses alike — is served by the EC2 instance.

**After: static traffic diverted entirely away from the VM**

```
Browser
   |
   +--> CloudFront (app.<domain>) --> S3 bucket        [static: ~90% of bytes]
   |         ^ cached at the edge; origin hit only on cache miss
   |
   +--> :443 nginx --> :9000 ----> nisanweb-backend    [API: JSON only]
        :443 nginx --> :8129 ----> leads_backend
        :443 nginx --> :9002 ----> chat_backend        [API + WebSocket]
```

**Key point on the API path: it is unchanged.** The browser still calls `https://nissan.staging.flutenwebframework.xyz/api/` directly against nginx on EC2. CloudFront sits only in front of static assets.

**Impact on backend traffic:**

| Effect | Assessment |
|---|---|
| API request volume | **Unchanged.** Same calls, same endpoints. |
| API latency | **Unchanged** — the request path does not go through CloudFront. |
| Bytes served by EC2 | **Reduced by roughly 80–90%.** Static assets dominate page weight; JSON is small. |
| EC2 CPU and memory | **Reduced** — one fewer container, and nginx no longer serves static files. |
| CORS | ⚠️ **Requires attention.** The frontend moves to a new origin (`app.<domain>`), so backends must include it in `CORS_ALLOWED_ORIGINS` / `CSRF_TRUSTED_ORIGINS`. See the note below. |
| WebSocket (chat) | **Unchanged** — still direct to nginx. |
| Blast radius of an EC2 outage | **Reduced** — the site loads; only dynamic data fails. |

> ⚠️ **CORS is the one real integration risk.** Today `nisanweb-backend` runs `CORS_ALLOW_ALL_ORIGINS=True`, so nothing breaks immediately. But `CSRF_TRUSTED_ORIGINS` must include the new frontend origin, and `chat_backend`'s `CORS_ORIGINS` and `leads_backend`'s `CORS_ALLOWED_ORIGINS` must be updated. **This must be verified in Phase 5 testing** — it is the most likely cause of "the site loads but nothing works" after cutover.

#### 1.7.4 Optional later: route the API through CloudFront too

Not recommended for this migration, but worth recording because the economics are counter-intuitive:

**EC2 data transfer to CloudFront is free.** EC2 data transfer directly to the internet is $0.09/GB after the first 100 GB. So if API egress ever exceeds the free allowance, putting CloudFront in front of the API (with caching disabled) would make that egress **free** and bring it under CloudFront's 1 TB allowance.

Reasons to defer: it adds cache-policy complexity, requires careful header and cookie forwarding, and complicates WebSocket. Revisit only if the data transfer line item becomes material.

#### 1.7.5 Cost — S3 and CloudFront, in full

**Free tiers that apply (CloudFront's is perpetual, not 12-month):**

| Allowance | Amount |
|---|---|
| CloudFront data transfer out | **1 TB/month, forever** |
| CloudFront HTTP/HTTPS requests | **10 million/month, forever** |
| CloudFront invalidations | 1,000 paths/month |
| S3 to CloudFront transfer | **Free — always** |
| ACM public certificates | **Free** |

**Frontend hosting:**

| Line item | Volume | Cost |
|---|---|---|
| S3 storage | ~20 MB of built assets | < $0.01 |
| S3 PUT requests (deploys) | ~500/mo | < $0.01 |
| S3 GET (CloudFront origin fetches) | Only on cache miss, ~5,000/mo | < $0.01 |
| S3 → CloudFront transfer | Any | **$0.00** |
| CloudFront transfer out | Under 1 TB | **$0.00** |
| CloudFront requests | Under 10M | **$0.00** |
| CloudFront invalidations | ~30/mo (`index.html` only) | **$0.00** |
| ACM certificate | 1 | **$0.00** |
| **Frontend subtotal** | | **≈ $0.02/month** |

**All S3 usage combined (frontend + media + backups):**

| Bucket | Storage | Monthly cost |
|---|---|---|
| `dealerpulse-prod-frontend` | 20 MB | $0.01 |
| `dealerpulse-prod-media` | 220 MB now, ~1.5 GB after a year | $0.01 → $0.04 |
| `dealerpulse-prod-backups` | ~6 GB rolling (30d Standard + Glacier tail) | $0.15 |
| Requests (all buckets) | | $0.10 |
| **S3 total** | | **≈ $0.30/month** |

> **Break-even sanity check:** CloudFront only starts costing money above **1 TB/month**. At an estimated 3 MB per fresh visit, that is roughly **350,000 uncached visits per month**. For four dealership websites, we are two to three orders of magnitude below that. **Realistically this line stays at $0 indefinitely.**

**Verdict: approximately $0.30/month total for all S3 and CloudFront usage,** while removing a service from the VM, adding a global CDN, eliminating a certbot dependency, and making the customer-facing site independent of EC2 availability.

#### 1.7.6 Implementation requirements

- CloudFront custom error responses: map `403` and `404` to `/index.html` with HTTP `200` (required for React Router client-side routing)
- Cache policy: one-year immutable TTL on hashed asset filenames; **no-cache on `index.html`**
- Origin Access Control (OAC) so the S3 bucket stays private
- ACM certificate issued in **`us-east-1`** (a CloudFront requirement)
- A hostname must be chosen — the frontend currently has **no domain** (§10, Decision 4)
- Backend CORS and CSRF origins updated for the new frontend origin

**Confirmed compatible:** the built bundle calls `https://nissan.staging.flutenwebframework.xyz/api/` — a **domain, not an IP**. DNS cutover carries the frontend automatically. **No rebuild required.**

### 1.8 Backup policy

This is the single largest gap in the current setup — nothing exists today.

#### Targets

| Metric | Target | Rationale |
|---|---|---|
| **RPO** (max acceptable data loss) | **6 hours** | Databases total 46 MB; four dumps per day cost almost nothing |
| **RTO** (max acceptable recovery time) | **2 hours** | Rebuild from snapshot, or redeploy and restore |
| **Retention** | 30 days hot, 90 days cold | |

#### Layer 1 — Logical database dumps (primary)

```
Every 6 hours (00:00, 06:00, 12:00, 18:00 UTC), per database:
  pg_dump -Fc  ->  /var/backups/<service>/<timestamp>.dump
  aws s3 cp    ->  s3://dealerpulse-prod-backups/<service>/<YYYY>/<MM>/<DD>/
  delete local copies older than 48h
```

**S3 lifecycle policy:**

| Age | Action |
|---|---|
| 0–30 days | S3 Standard |
| 31–90 days | Glacier Instant Retrieval |
| > 90 days | Delete |

**Estimated cost:** 4 dumps/day x ~50 MB x 30 days = approximately 6 GB Standard plus a Glacier tail = **under $0.30/month**.

#### Layer 2 — EBS snapshots (whole-machine recovery)

Managed by **Data Lifecycle Manager (DLM)**:

- Daily snapshot at 03:00 UTC, retain 7
- Weekly snapshot on Sunday, retain 4
- Estimated cost: **$1–2/month** (snapshots are incremental)

#### Layer 3 — Media

S3 **versioning** on `dealerpulse-prod-media` *is* the backup. Every overwrite and delete is recoverable. Cost is negligible at 220 MB.

#### Layer 4 — Secrets (CRITICAL)

Two encryption keys must be backed up **separately from the data they protect**:

| Key | Service | Consequence if lost |
|---|---|---|
| `FIELD_ENCRYPTION_KEY` | chat_backend | **Encrypted columns permanently unrecoverable.** A `pg_dump` captures ciphertext; without the key it is noise. **No recovery path exists.** |
| `API_CRYPTO_PRIVATE_KEY_B64` | nisanweb-backend | Recoverable — regenerate the keypair and redistribute the public key. Disruptive: with `API_CRYPTO_MODE='required'`, the API rejects all requests until this is done. |

**Rule: keys live in AWS Secrets Manager / SSM Parameter Store under a different IAM policy than the S3 backup bucket.** Storing the key alongside the ciphertext defeats the encryption entirely.

#### Layer 5 — Automated restore verification

> **An untested backup is a guess, not a backup.**

**Weekly, automatically:**

1. Pull the most recent dump from S3
2. Restore into a throwaway container
3. Compare table row counts against production
4. Emit a CloudWatch metric; alarm on mismatch or job failure

This is the single most valuable item in the entire backup policy. Without it, we will discover a broken backup at exactly the moment we need it.

### 1.9 Secrets management

**Today:** seven hand-maintained `.env` files across five applications, plus `.env.bak` copies sitting inside a git working tree. This model has already caused one documented production incident — a `sed`-based merge silently dropped `JWT_SECRET_KEY`.

**Target:** **AWS SSM Parameter Store** (SecureString) as the source of truth.

```
/dealerpulse/prod/nisanweb-backend/*
/dealerpulse/prod/leads_backend/*
/dealerpulse/prod/chat_backend/*
        |  EC2 instance profile — read-only, scoped per path
        v
  boot-time renderer writes .env  (mode 600)
        v
  docker compose up
```

#### 1.9.1 Option comparison

| | **Keep `.env` files** (today) | **SSM Parameter Store** | **AWS Secrets Manager** |
|---|---|---|---|
| Cost | $0 | **$0** (Standard tier) | $0.40/secret/mo + $0.05/10k API calls |
| Versioning / rollback | None | Yes, automatic | Yes, automatic |
| Encryption at rest | None (plaintext on disk) | KMS (SecureString) | KMS |
| Access audit trail | None | Yes | Yes |
| IAM access control | None (file permissions only) | Yes, per path | Yes, per secret |
| Automatic rotation | No | No | Yes, with Lambda |
| Change a secret without SSH | No | Yes | Yes |
| Cross-instance sharing | Manual copy | Automatic | Automatic |
| Boot-time dependency | None | **Yes — new failure mode** | **Yes — new failure mode** |
| Local development friction | None | Moderate | Moderate |

#### 1.9.2 Real cost impact

| Item | Parameter Store (Standard) | Secrets Manager |
|---|---|---|
| ~120 parameters across three services | **$0.00** (free up to 10,000) | 3 secrets (grouped JSON) = **$1.20/mo** |
| API calls at boot (~120 per deploy, ~50 deploys/mo) | **$0.00** (Standard throughput free) | ~6,000 calls = **$0.03/mo** |
| KMS — using the AWS-managed key | **$0.00** | $0.00 |
| KMS — using a customer-managed key (optional) | $1.00/mo + $0.03/10k requests | Same |
| **Realistic monthly total** | **$0.00** | **~$1.25** |

> **Parameter Store Standard is genuinely free at our scale** — 10,000 parameters, 4 KB each, standard throughput, using the AWS-managed KMS key. The only ways to incur cost are Advanced parameters ($0.05 each per month, needed only above 4 KB or 10,000 parameters) or higher-throughput API mode. Neither applies. **The one parameter that might exceed 4 KB is `API_CRYPTO_PRIVATE_KEY_B64`** — an RSA private key at roughly 2.3 KB base64-encoded, which fits, but should be measured before assuming.

**Verdict: Parameter Store.** Secrets Manager's only meaningful advantage is automatic rotation via Lambda, which we would not use — our secrets are third-party API credentials that must be rotated in the vendor's portal, not by AWS.

#### 1.9.3 Cons and operational impact — stated honestly

This is a real change to how the system boots, not a free win.

| Con | Impact | Mitigation |
|---|---|---|
| **New boot-time dependency** | If SSM is unreachable (IAM misconfiguration, API throttling, regional issue), containers cannot start. Today a `.env` file always works. | Cache the rendered `.env` on disk; fall back to the last known-good copy if SSM fails. Alarm on fallback. |
| **IAM complexity** | An instance profile with a scoped read policy must exist and be correct. A wrong path prefix produces a silent empty value, not an error. | Renderer script must **fail loudly** on any missing parameter, never write a partial `.env` |
| **Local development friction** | Developers cannot read production parameters and need a separate local path | Keep a `.env.example` (scrubbed) and a `/dealerpulse/dev/*` hierarchy |
| **Migration effort** | ~120 parameters to enter, correctly, once | Script it from the existing `.env` files; verify with a key-count check |
| **Debugging is less direct** | `cat .env` no longer shows the source of truth | The renderer writes a real `.env` on disk, so `cat` still works for inspection |
| **Silent truncation risk** | Standard parameters cap at 4 KB | Measure `API_CRYPTO_PRIVATE_KEY_B64` first; use an Advanced parameter ($0.05/mo) if it exceeds the cap |

#### 1.9.4 Recommendation — phase it, do not bundle it

> **Do not adopt Parameter Store during the migration cutover.** A migration already changes the host, the network, the pipelines, and the storage layer. Adding a new boot-time dependency at the same time means that if containers fail to start, we will not know which change caused it.

| Stage | Approach |
|---|---|
| **Migration (Phases 1–6)** | Hand-maintained `.env` files at mode `600`, exactly as today. **One change only:** an encrypted copy is kept in Parameter Store as a *backup*, not as the runtime source. Zero new failure modes. |
| **Post-migration (2–4 weeks after cutover)** | Switch the runtime source to Parameter Store, one service at a time, starting with `chat_backend` (lowest blast radius). Verify, then proceed. |

**Gains once adopted:** versioned with rollback | audit trail on every read | rotation without SSH | no secrets in a git working tree | no more `.env.bak` files | no repeat of the `sed`-merge incident that silently dropped `JWT_SECRET_KEY`.

**Interim benefit available immediately at zero risk:** storing the `.env` files in Parameter Store as an encrypted backup solves the current problem of secrets existing in exactly one place, on one disk, with no versioning — without changing how anything boots.

### 1.10 Cost summary — including full data transfer breakdown

#### 1.10.1 Fixed monthly costs

| Item | On-demand | With 1-yr Savings Plan |
|---|---|---|
| EC2 `t3.small` — Frontend VM | $15.18 | $11.50 |
| EC2 `t3.medium` — Backend VM | $30.37 | $23.00 |
| EC2 `t3.medium` — Integrations VM | $30.37 | $23.00 |
| EBS 140 GB gp3 (40 + 60 + 40) | $11.20 | $11.20 |
| EBS snapshots (incremental, 3 VMs) | $2.00 | $2.00 |
| S3 storage — all buckets | $0.50 | $0.50 |
| CloudFront | $0.00 | $0.00 |
| ECR (~5 GB of images) | $0.50 | $0.50 |
| SSM Parameter Store (Standard) | $0.00 | $0.00 |
| **SSM Session Manager** | **$0.00** | **$0.00** |
| CloudWatch Agent metrics + alarms (3 VMs) | $5.00 | $5.00 |
| Route 53 private hosted zone | $0.50 | $0.50 |
| Elastic IPs (3, attached to running instances) | $0.00 | $0.00 |
| ACM certificates | $0.00 | $0.00 |
| S3 Gateway VPC Endpoint | $0.00 | $0.00 |
| Interface VPC Endpoints for SSM — **not needed** | $0.00 | $0.00 |
| ALB / Auto Scaling — **not used** (§ARCHITECTURE §12) | $0.00 | $0.00 |
| NAT Gateway — **avoided by design** | $0.00 | $0.00 |
| **Fixed subtotal** | **$95.62** | **$77.20** |

With Graviton as a fast-follow, the on-demand figure drops to **$81.02**, and Graviton plus a Savings Plan to roughly **$63**.

**Three line items are $0 only because of specific design choices**, and are worth naming so they are not accidentally reversed later: no NAT Gateway (public subnets, ~$32/mo avoided), no interface VPC endpoints for SSM (same reason, ~$22/mo avoided), and no load balancer (~$22/mo avoided).

#### 1.10.2 Data transfer — itemised

**This was previously a single ~$2.00 line. It is broken out here in full, because data transfer is the most commonly underestimated line on an AWS bill.**

**What is free:**

| Flow | Cost | Note |
|---|---|---|
| **Inbound — internet to AWS** | **$0.00** | All ingress is free, always |
| EC2 → CloudFront | **$0.00** | AWS waives this entirely |
| S3 → CloudFront | **$0.00** | Always free |
| EC2 ↔ S3, same region | **$0.00** | Free, and the Gateway Endpoint keeps it off the IGW |
| EC2 ↔ ECR, same region | **$0.00** | Free |
| CloudFront → internet, first 1 TB/month | **$0.00** | Perpetual free tier |
| EC2/S3 → internet, first 100 GB/month | **$0.00** | Account-wide, perpetual free tier |

**What is charged:**

| Flow | Rate | Applies when |
|---|---|---|
| EC2 → internet, above 100 GB/mo | $0.09/GB | API responses, media served by Django, SSH/rsync out |
| S3 → internet, above 100 GB/mo | $0.09/GB | Shared with the EC2 allowance |
| CloudFront → internet, above 1 TB/mo | ~$0.085/GB | Frontend static assets |
| Inter-AZ traffic | $0.01/GB each way | **N/A** — single AZ |
| NAT Gateway processing | $0.045/GB | **N/A** — not used |

**Three traffic scenarios:**

| | Low | **Expected** | High |
|---|---|---|---|
| Monthly sessions across 4 dealership sites | 5,000 | **15,000** | 60,000 |
| Frontend assets (via CloudFront, ~3 MB/fresh visit, ~60% cached) | 6 GB | **18 GB** | 72 GB |
| API responses from EC2 (JSON, ~400 KB/session) | 2 GB | **6 GB** | 24 GB |
| Media served (once on S3, via signed/public URLs) | 3 GB | **10 GB** | 40 GB |
| Backups, `pg_dump` uploads, SSH, rsync | 2 GB | **2 GB** | 3 GB |
| **CloudFront egress** | 6 GB | **18 GB** | 72 GB |
| — against the 1 TB allowance | 0.6% | **1.8%** | 7.2% |
| **EC2 + S3 egress** | 7 GB | **18 GB** | 67 GB |
| — against the 100 GB allowance | 7% | **18%** | 67% |
| **Data transfer cost** | **$0.00** | **$0.00** | **$0.00** |

> **All three scenarios fall inside the free allowances.** Even the high scenario — a 4x increase over expected traffic — costs nothing. **EC2 and S3 egress would need to exceed 100 GB/month before a single cent is charged**, and at that point the marginal rate is $0.09/GB, so 200 GB/month would cost $9.00.

**Recommended verification before sign-off:** DigitalOcean's control panel shows actual monthly bandwidth for the droplet. Read the real number from the Graphs tab and substitute it into the table above. It replaces my estimate with fact and takes two minutes.

```bash
# Or measure directly on the current box
apt-get install -y vnstat && vnstat -m    # monthly totals per interface
```

#### 1.10.3 Total

| | On-demand | With 1-yr Savings Plan |
|---|---|---|
| Fixed costs | $95.62 | $77.20 |
| Data transfer (expected traffic) | $0.00 | $0.00 |
| Contingency buffer (~5%) | $4.80 | $3.90 |
| **TOTAL** | **≈ $100/month** | **≈ $81/month** |
| *With Graviton as a fast-follow* | *≈ $85/month* | *≈ $67/month* |
| *Current DigitalOcean droplet* | *~$28/month* | |
| **Net increase** | **≈ $72/month** | **≈ $53/month** |

**Two known future movements**, so neither arrives as a surprise:

| Trigger | Change | Effect |
|---|---|---|
| **3rd tenant onboarded** | Frontend VM `t3.small` → `t3.medium` | **+$15.19/month** |
| **~1 month post-migration review** | Downscale any VM the CloudWatch data shows is oversized | **Reduction, amount TBD** |

**If staging also migrates** (`t3.small`, 30 GB gp3): add approximately **$20/month**.

> Verify all figures in the AWS Pricing Calculator before sign-off. Prices are for `us-west-2` and were estimated on 2026-08-24.

#### 1.10.4 Cost controls

- **AWS Budget** at $100/month with alerts at 50% / 80% / 100%
- **Cost Anomaly Detection** enabled (free) — catches a runaway process or misconfigured job
- **Cost allocation tags** on every resource: `Project=DealerPulse`, `Env=Production`, `Service=<name>`
- **Savings Plan** purchased only after 30 days of stable operation, so the commitment matches real usage
- **ECR lifecycle policy** retaining the last 10 images, preventing unbounded registry growth
- **S3 lifecycle policy** transitioning backups to Glacier and expiring them at 90 days

### Phase 1 exit criteria

- [ ] Root account MFA enabled; root credentials stored in a password manager and not used thereafter
- [ ] IAM Identity Center (SSO) configured with MFA-enforced admin access
- [ ] AWS Budget set with alerts at 50% / 80% / 100%
- [ ] Account-wide EBS default encryption enabled
- [ ] VPC, Security Group, and Elastic IP provisioned
- [ ] **Three instances** on Ubuntu 24.04 LTS — `t3.small`/40 GB (Frontend), `t3.medium`/60 GB (Backend), `t3.medium`/40 GB (Integrations)
- [ ] `AmazonSSMManagedInstanceCore` instance profile attached to **all three at launch**; `aws ssm start-session` verified against each
- [ ] Security Groups created with **no port 22 rule at all**
- [ ] Session Manager logging to S3/CloudWatch enabled
- [ ] EC2 Serial Console password set and stored in Parameter Store as a `SecureString`
- [ ] Route 53 private hosted zone created with the three service records
- [ ] T3 **Unlimited** mode confirmed on all three
- [ ] Three S3 buckets created with Block Public Access and versioning
- [ ] DLM snapshot policy active
- [ ] SSM parameter hierarchy created (empty)
- [ ] **Vendor IP-allowlist requests raised** (see R1 — critical path)

---

## PHASE 2 — Build and Deploy All Five Applications

**Duration:** 1 week | **Owner:** DevOps + 1 Developer | **Downtime:** none (nothing live yet)

### 2.0 Service placement — which machine gets what

> ⚠️ **The procedures in Phases 2–7 were written for a single VM.** The commands themselves are correct; what changed is that each now has a target. Use this table to route every step.

| Application | Target VM | Ports | Data on that VM |
|---|---|---|---|
| `nisanweb-backend` (Django + gunicorn) | **Backend** | `127.0.0.1:9000` | — |
| `nisanweb-backend` worker | **Backend** | — | — |
| `nisanweb-backend` beat *(singleton — never replicate)* | **Backend** | — | — |
| PostgreSQL 15 — `nisan_website` | **Backend** | `127.0.0.1:5433` | 27 MB |
| Redis 7 (cache + broker) | **Backend** | internal only | regenerable |
| Media files | **Backend** | — | 220 MB, local disk |
| `leads_backend` (FastAPI) | **Integrations** | `127.0.0.1:8129` | — |
| PostgreSQL 16 — `leads_db` | **Integrations** | `127.0.0.1:5434` | 8 MB |
| `chat_backend` (FastAPI + WebSocket) | **Integrations** | `127.0.0.1:9002` | — |
| PostgreSQL 16 — `dealerpulse` | **Integrations** | `127.0.0.1:5435` | 11 MB |
| `dealerships_frontend` (admin dashboard) | **Integrations** | `127.0.0.1:9011` | — |
| `website_frontend` (Next.js 16, per tenant) | **Frontend** | `127.0.0.1:3000` | — |

**Every application binds to loopback.** nginx on the same VM is the only thing that talks to it, and the Security Group is the only thing that talks to nginx.

**Steps that run on all three machines:** §2.1 base system, §2.2 swap, log rotation, nginx hardening, CloudWatch Agent, certbot.
**Steps that run on one machine only:** everything service-specific, per the table above.

### 2.1 Base system

```bash
# Ubuntu 24.04 LTS

# --- Docker Engine + Compose plugin (official apt repo) ---
apt-get update -y
apt-get install -y ca-certificates curl gnupg git nginx certbot python3-certbot-nginx \
                   awscli fail2ban unattended-upgrades
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Ensure Docker and nginx start on boot ---
systemctl enable --now docker
systemctl enable --now nginx
```

### 2.2 Swap

```bash
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab   # persist across reboot
sysctl -w vm.swappiness=10                         # only swap under real pressure
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
free -h
```

**Rationale:** with 8 GiB of RAM we expect never to touch swap. Its purpose is to convert a hard OOM kill — where the kernel terminates PostgreSQL outright — into graceful degradation, where things simply get slower. `swappiness=10` ensures it is used only under genuine pressure.

### 2.3 Directory standardisation

Today there are **four different conventions**: `/var/www/nisanWebsite`, `/opt/leads/leads_backend`, `/opt/dealerships/chat_backend`, and `/opt/apps/production/dealerships/frontend`.

**Standardising on `/var/www/`:**

```
/var/www/
├── nisanweb-backend/                    docker-compose.yml, .env
├── leads_backend/            docker-compose.yml, .env
└── chat_backend/             docker-compose.yml, .env

(dealerships_frontend has no directory — it lives in S3 + CloudFront)
```

> **Blocker to clear first:** nisanweb-backend's current `docker-compose.yml` contains a **hardcoded absolute path** for the media bind-mount (`/var/www/nisanWebsite/server/coresite/media`). Renaming the directory is only safe **once media has moved to S3** and that mount is removed (Phase 4 / code change CC-4). If the S3 storage change slips, we keep the legacy `nisanWebsite` directory name as a fallback rather than breaking the mount.

Each directory is `chmod 700`, owned by root, with `.env` at mode `600`.

### 2.4 `DEBUG=False` — mandatory gate

**Nothing goes live with `DEBUG=True`.** This is a hard gate, not a recommendation.

Current state: `DEBUG = True` is **hardcoded** at `server/coresite/settings/base.py:12`. It is not environment-driven, so it cannot be changed by configuration alone.

#### 2.4.1 How to verify the claim — before presenting it

Do not take the assertion on trust, and do not present it to administration without evidence. **Three checks, in increasing order of persuasiveness. All are read-only and safe to run against production.**

**Check 1 — read the setting from source** *(already performed; confirmed)*

```bash
docker exec nisanwebsite-web-1 grep -rn '^DEBUG' /app/server/coresite/settings/
# Result: /app/server/coresite/settings/base.py:12:DEBUG = True
```

Necessary but not sufficient — a later settings module could override it.

**Check 2 — read the effective setting at runtime** *(authoritative)*

```bash
docker exec nisanwebsite-web-1 python server/manage.py diffsettings | grep -E '^DEBUG'
```

`diffsettings` reports the **fully resolved** value after every settings module has been imported. This is the definitive answer, and it settles any argument about whether an override exists.

**Check 3 — demonstrate the exposure** *(the one to show administration)*

With `DEBUG=True`, Django returns a **technical 404 page that prints the entire URL routing table** to any anonymous visitor. This requires no authentication, no error, and no special knowledge — just a request to a URL that does not exist.

```bash
curl -s https://nissan.staging.flutenwebframework.xyz/this-path-does-not-exist-98765/ \
  | grep -iE "URLconf|Using the URLconf|Django tried these URL patterns" | head -5
```

If that returns matches, **any member of the public can enumerate every API endpoint in the application.** That is a more compelling demonstration than any description of the risk, and it takes five seconds.

> This test is entirely safe: it is a normal HTTP GET to a non-existent path. It writes nothing, changes nothing, and triggers no application logic.

**What `DEBUG=True` exposes, precisely:**

| Exposure | Trigger | Severity |
|---|---|---|
| Full URL routing table | Any 404 | High — endpoint enumeration |
| Complete Python traceback with source excerpts | Any unhandled 500 | Critical |
| **Local variable values at each stack frame** — can include credentials, tokens, customer data in flight | Any unhandled 500 | **Critical** |
| Settings dump (Django scrubs keys matching `SECRET`/`PASSWORD`/`API`/`TOKEN`, but only by name) | Any unhandled 500 | High |
| Every SQL query executed for the request | Any unhandled 500 | High — reveals schema |
| Retained query log in memory | Continuous | Low — bounded at 9,000 entries |

The middle row is the one that matters most. Django's traceback page renders **local variables for every stack frame**, and its scrubbing is name-based only. A variable holding a decrypted value or a customer record under a name Django does not recognise is printed in full.

#### 2.4.2 Interim defence, if the code change cannot ship immediately

If CC-1 slips, the exposure can be **substantially reduced at the nginx layer without touching application code**. This is a mitigation, not a fix — but it is deployable in minutes and closes the worst of it.

```nginx
# Intercept upstream errors and serve our own page instead of Django's debug traceback
proxy_intercept_errors on;
error_page 500 502 503 504 /50x.html;
error_page 404              /404.html;

location = /50x.html { root /usr/share/nginx/html; internal; }
location = /404.html { root /usr/share/nginx/html; internal; }
```

**What this achieves:** Django's debug traceback is returned with HTTP status `500`, and the technical 404 page with status `404`. `proxy_intercept_errors on` makes nginx discard the upstream response body for those statuses and serve a static page instead. **The traceback, local variables, settings dump, and URL routing table never reach the client.**

**What it does not fix:**

| Residual issue | Why |
|---|---|
| Any debug content returned with a `200` status | nginx only intercepts the statuses listed |
| Django Debug Toolbar, if installed and enabled | Renders inline in normal `200` responses |
| The in-memory query log | Internal, not exposed, but still consumes memory |
| `runserver` remaining unsuitable for production | Unrelated to `DEBUG` |
| The underlying misconfiguration | Still present; still `DEBUG=True` |

**Verify the mitigation works:**

```bash
nginx -t && systemctl reload nginx
curl -s https://<domain>/this-path-does-not-exist-98765/ | grep -ic "URLconf"
# Expect: 0
```

> **Treat this strictly as a stopgap.** It reduces exposure while CC-1 is scheduled; it does not remove the need for it. Recorded here because a plan that says only "this is critical, fix it eventually" is less useful than one that also says what to do this afternoon.

#### 2.4.3 The permanent fix

**Required (see §9 — code changes CC-1, CC-2, CC-3):**

```python
# server/coresite/settings/base.py
DEBUG = os.environ.get('DEBUG', 'False').lower() in ('true', '1', 'yes')
ALLOWED_HOSTS = [h.strip() for h in os.environ.get('ALLOWED_HOSTS', '').split(',') if h.strip()]
```

**Consequential change — `runserver` must go too.** Django's development server is explicitly not intended for production, and with `DEBUG=False` it stops serving static files. Since we are changing this anyway, `nisanweb-backend` moves to **gunicorn**:

```yaml
command: gunicorn coresite.wsgi:application --bind 0.0.0.0:9000 --workers 3 --timeout 120
```

**Memory impact:** three gunicorn workers at approximately 250–300 MB each is around 900 MB — comparable to or less than the current single `runserver` process at 1.16 GiB. Static files are served by nginx or WhiteNoise.

**Verification gate before any traffic is cut over:**

```bash
docker exec nisanweb-backend-web python server/manage.py diffsettings | grep -E '^(DEBUG|ALLOWED_HOSTS)'
# MUST show: DEBUG = False
```

### 2.5 Fresh SSH deploy keys — one per service

Each service gets its own dedicated `ed25519` keypair. A compromise of one service's CI credentials must not grant access on behalf of another.

```bash
for svc in nisanweb-backend leads_backend chat_backend dealerships_frontend; do
  ssh-keygen -t ed25519 -f ./deploy_${svc} -N "" -C "bitbucket-pipelines-prod-${svc}"
  cat deploy_${svc}.pub >> /home/deploy/.ssh/authorized_keys
  echo "=== ${svc} — paste into Bitbucket variable PROD_SSH_KEY_B64 ==="
  base64 -w0 deploy_${svc}
  shred -u deploy_${svc}          # private key exists only in Bitbucket thereafter
done
chmod 600 /home/deploy/.ssh/authorized_keys
```

Additionally, harden the `authorized_keys` entries so a deploy key cannot open an interactive shell beyond what it needs:

```
restrict,pty,command="/usr/local/bin/deploy-wrapper.sh" ssh-ed25519 AAAA...
```

> **Note:** all existing deploy keys become obsolete. `leads_backend`'s current `PROD_SSH_KEY_B64` private half exists **only inside Bitbucket** and is unrecoverable, so fresh keys are required regardless.

### 2.6 Container restart policy

Every service in every `docker-compose.yml`:

```yaml
services:
  web:
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- `restart: unless-stopped` — containers recover from crashes and return after a host reboot, but stay down if an operator deliberately stopped them
- `systemctl enable docker` — the Docker daemon itself starts on boot
- **Log rotation is mandatory.** Uncapped Docker JSON logs are a common cause of disk exhaustion; `10m x 3` per container bounds total log usage.

### 2.7 Health checks for every service

Currently `nisanweb-backend` and the frontend have **no health check**, which is why they also have **no automated rollback**. Every service gets one.

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:9000/health"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 60s
```

`nisanweb-backend` requires a `/health` endpoint to be added (code change **CC-5**). It should verify database connectivity and Redis reachability, and return HTTP 200 with a JSON body.

### 2.8 Server and nginx hardening

Per direction, security is strengthened at the **nginx and server level**. WAF, GuardDuty, and CloudTrail are explicitly **out of scope for now**.

#### SSH

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
AllowUsers deploy admin
```

- A non-root `deploy` user for all CI deploys
- `fail2ban` enabled for `sshd`
- SSH restricted to office/admin IPs at the Security Group level

#### Firewall (defence in depth)

The **Security Group is the primary control** (§1.5). `ufw` is configured identically as a redundant second layer — it costs nothing and catches Security Group mistakes for any non-Docker service.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

> Remember that **`ufw` does not constrain Docker-published ports** — Docker's iptables rules bypass it. That is precisely why the Security Group, which sits outside the instance, is the control we rely on. `ufw` here is belt-and-braces, not the mechanism.

**Application container ports** (`8129`, `9000`, `9002`, `9011`) may be published on `0.0.0.0` as convenient; the Security Group prevents any external reach.

**Databases and Redis are different, and stricter:**

```yaml
# postgres / redis — NO ports: entry at all.
# Reachable only over the Docker Compose network.
services:
  postgres:
    # ports:  <- deliberately absent
    networks: [internal]
```

The single exception is loopback publishing for SSH-tunnelled developer access (§1.5):

```yaml
ports:
  - "127.0.0.1:5433:5432"    # loopback only — unreachable externally regardless of the SG
```

#### nginx

```nginx
# TLS
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_stapling on;

# Do not advertise version
server_tokens off;

# Security headers
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options    "nosniff" always;
add_header X-Frame-Options           "SAMEORIGIN" always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=()" always;

# Rate limiting (zone defined in http{})
limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;
limit_req zone=api burst=40 nodelay;

# Upload cap
client_max_body_size 25m;

# Timeouts
client_body_timeout 15s;
client_header_timeout 15s;
```

#### WebSocket support — required for chat

`chat.staging.flutenwebframework.xyz` uses an nginx `upstream` block with dedicated `/ws` locations. The AWS configuration **must** carry the upgrade headers, or live chat fails silently while plain HTTP appears healthy:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 3600s;
```

#### OS patching

`unattended-upgrades` enabled for security updates only, with automatic reboot disabled — reboots are scheduled manually.

### Phase 2 exit criteria

- [ ] Docker, git, nginx, certbot, and awscli installed; Docker enabled on boot
- [ ] 4 GB swap active and persistent, `swappiness=10`
- [ ] Standardised `/var/www/` layout
- [ ] All five applications running on their assigned VM (not serving public traffic)
- [ ] **`DEBUG=False` verified via `diffsettings`**
- [ ] `nisanweb-backend` running under gunicorn, not `runserver`
- [ ] `restart: unless-stopped` plus log rotation on every container
- [ ] Health checks green on all services
- [ ] Fresh per-service deploy keys installed; private halves only in Bitbucket
- [ ] SSH hardened, `fail2ban` active, `ufw` configured
- [ ] All containers bound to `127.0.0.1`
- [ ] nginx security headers and rate limiting in place
- [ ] Reboot test passed — all services return automatically

---

## PHASE 3 — CI/CD Pipelines (no builds on the VM)

**Duration:** 1 week | **Owner:** DevOps | **Downtime:** none

### 3.1 The core change

| | Today | Target |
|---|---|---|
| nisanweb-backend | `git pull` + `docker build` **on the production server** | Build in CI, push to ECR, VM pulls |
| leads_backend | Build in CI, push to DockerHub | Build in CI, push to **ECR** |
| chat_backend | Build in CI, push to DockerHub | Build in CI, push to **ECR** |
| dealerships_frontend | Build in CI, DockerHub, run as container | Build in CI, **S3 sync + CloudFront invalidation** |

**Why this matters:** nisanweb-backend's on-server build is the single largest memory and CPU spike the production host experiences. Eliminating it removes the main argument for oversizing the instance, makes deploys faster and repeatable, and gives nisanweb-backend the same immutable-artifact rollback story the other services already have.

**Result: the production VM never runs `docker build`, and never needs git, a repository checkout, or a Bitbucket SSH key.**

### 3.2 Registry — ECR over DockerHub

| | DockerHub | **ECR** |
|---|---|---|
| Authentication | Long-lived `DOCKER_TOKEN` in CI | **IAM / OIDC — no static credentials** |
| Pull speed | Public internet | Same region — faster, free transfer |
| Cost | Free tier / paid plan | ~$0.10/GB-mo = **~$0.50/mo** |
| Rate limits | Yes | No |
| Lifecycle policies | Limited | Native (auto-expire old images) |

**Decision: ECR**, one repository per service, with a lifecycle policy retaining the last 10 images.

**Bitbucket Pipelines authenticates to AWS via OIDC** — no long-lived AWS access keys stored in Bitbucket. This is a meaningful improvement over the current static `DOCKER_TOKEN`.

### 3.3 Standard pipeline (all backend services)

```yaml
# Structurally identical for nisanweb-backend / leads_backend / chat_backend
pipelines:
  branches:
    main:
      - step:
          name: Build and push to ECR
          services: [docker]
          oidc: true
          script:
            - export IMAGE=$ECR_REGISTRY/$SERVICE_NAME
            - aws ecr get-login-password | docker login --password-stdin $ECR_REGISTRY
            - docker build -t $IMAGE:$BITBUCKET_COMMIT -t $IMAGE:latest_production .
            - docker push $IMAGE:$BITBUCKET_COMMIT
            - docker push $IMAGE:latest_production
      - step:
          name: Deploy
          deployment: production
          script:
            - echo $PROD_SSH_KEY_B64 | base64 -d > ~/.ssh/pipelines_id
            - chmod 600 ~/.ssh/pipelines_id
            - ssh-keyscan -H $PROD_SSH_HOST >> ~/.ssh/known_hosts
            - scp docker-compose.yml deploy@$PROD_SSH_HOST:/var/www/$SERVICE_NAME/
            - |
              ssh deploy@$PROD_SSH_HOST bash -s <<'REMOTE'
                set -euo pipefail
                cd /var/www/$SERVICE_NAME
                aws ecr get-login-password --region us-west-2 \
                  | docker login --username AWS --password-stdin $ECR_REGISTRY
                docker compose pull web
                docker compose up -d --no-deps web
                # health gate: poll up to 150s
                for i in $(seq 1 30); do
                  S=$(docker inspect --format='{{.State.Health.Status}}' ${SERVICE_NAME}-web-1)
                  echo "Health status: $S (attempt $i/30)"
                  [ "$S" = "healthy" ] && exit 0
                  sleep 5
                done
                echo "Health check FAILED — rolling back"
                docker compose down && docker compose up -d
                exit 1
              REMOTE
```

**Retained from the existing pipeline design** (it is sound): commit-SHA plus floating tag, `scp` of only the compose file, `--no-deps` so databases are never touched, 30 x 5s health polling, and automatic rollback on failure.

### 3.4 Frontend pipeline

```yaml
- step:
    name: Build and deploy SPA
    oidc: true
    script:
      - npm ci && npm run build
      - aws s3 sync dist/ s3://dealerpulse-prod-frontend/ --delete \
          --cache-control "public,max-age=31536000,immutable" \
          --exclude index.html
      - aws s3 cp dist/index.html s3://dealerpulse-prod-frontend/index.html \
          --cache-control "no-cache,no-store,must-revalidate"
      - aws cloudfront create-invalidation --distribution-id $CF_DIST_ID --paths "/index.html"
```

Hashed assets get a one-year immutable cache; `index.html` is never cached. Only `index.html` needs invalidating, which keeps CloudFront invalidation costs at zero.

### 3.5 Branch strategy — standardise across all five repositories

Currently inconsistent: `main` for nisanweb-backend and chat, `master` for leads.

| Branch | Environment |
|---|---|
| `development` | dev (if a staging environment is retained) |
| `staging` | staging |
| `main` | **production** |

> **Known historical failure to avoid repeating:** `leads_backend`'s production pipeline branch key read `main:` while the repository's default branch was `master`. The production pipeline **silently never fired** for an extended period — no deploy, no error, because Bitbucket had no matching definition. Standardising on `main` and validating branch keys against `git branch -a` prevents recurrence.

### 3.6 Required Bitbucket configuration

**Repository variables (per repository):**

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-west-2` |
| `ECR_REGISTRY` | `<account>.dkr.ecr.us-west-2.amazonaws.com` |
| `AWS_OIDC_ROLE_ARN` | IAM role assumed via OIDC (ECR push only) |

**Deployment environment `production`:**

| Variable | Value |
|---|---|
| `PROD_SSH_HOST` | AWS Elastic IP |
| `PROD_SSH_USER` | `deploy` |
| `PROD_SSH_PORT` | `22` |
| `PROD_SSH_KEY_B64` | base64 of the per-service private key |

### Phase 3 exit criteria

- [ ] Four ECR repositories with lifecycle policies
- [ ] Bitbucket-to-AWS OIDC configured; **no static AWS keys in Bitbucket**
- [ ] All five pipelines build in CI and push artifacts
- [ ] **`docker build` never executes on the production VM** — verified
- [ ] Health-gated deploys with automatic rollback on all three backends
- [ ] Frontend deploys via S3 sync plus CloudFront invalidation
- [ ] Branch strategy standardised on `main` = production across all repositories
- [ ] End-to-end test deploy of each service succeeds against AWS
- [ ] Deliberate rollback test performed and verified

---

## PHASE 4 — Data Migration

**Duration:** 3–4 days | **Owner:** DevOps | **Downtime:** none (production stays live)

### 4.1 STEP ZERO — connectivity testing

**This must happen before anything else in this phase, and it is the highest-risk unknown in the entire migration.**

#### 4.1.1 Third-party egress — the potential blocker

Several integrations may **IP-allowlist** our current server. If so, they will reject the new AWS IP and the service will fail after cutover with no obvious cause.

| Service | Endpoint | Allowlist risk | Action |
|---|---|---|---|
| **HomeNet** | `services.homenetiol.com/Gateway.asmx` | **High** — SOAP integration with a token | Contact account owner, register Elastic IP |
| **Cox / VinSolutions** | `COX_API_BASE_URL` | **High** — enterprise OAuth API | Contact account owner, register Elastic IP |
| **xtime** | `XTIME_TOKEN_URL` | **High** — same portal family | Contact account owner, register Elastic IP |
| **J.D. Power** | LenderDesk Rebates API | Medium — Tyk gateway key | Confirm whether the contract is IP-bound |
| **Hostinger SMTP** | `smtp.hostinger.com:587` | Medium — may rate-limit unknown IPs | Test early |
| **OpenRouter AI** | `api.openrouter.ai` | Low — API-key based | Test |
| **ECR / Bitbucket** | AWS / Bitbucket | None | Test |

> **Vendor lead times can be weeks.** Requests to register a new IP with HomeNet, Cox, and xtime must be raised **in Phase 1**, not Phase 4. This is the most likely cause of schedule slippage.

**Test script (run from the AWS instance):**

```bash
# HomeNet
curl -sS -o /dev/null -w "HomeNet: %{http_code} in %{time_total}s\n" \
  https://services.homenetiol.com/Gateway.asmx

# Cox / xtime token endpoints (expect 400/401 — proves reachability, not auth)
curl -sS -o /dev/null -w "Cox:   %{http_code}\n"  "$COX_AUTH_URL"
curl -sS -o /dev/null -w "xtime: %{http_code}\n"  "$XTIME_TOKEN_URL"

# SMTP — note AWS blocks port 25 by default; we use 587
nc -zv smtp.hostinger.com 587

# OpenRouter
curl -sS -o /dev/null -w "OpenRouter: %{http_code}\n" https://openrouter.ai/api/v1/models

# ECR
aws ecr get-login-password --region us-west-2 >/dev/null && echo "ECR: OK"

# S3
aws s3 ls s3://dealerpulse-prod-backups/ >/dev/null && echo "S3: OK"
```

#### 4.1.2 DigitalOcean to AWS connectivity

```bash
# From the AWS instance
nc -zv 143.198.144.174 22            # SSH reachable
ssh root@143.198.144.174 'echo OK'   # key-based auth works
```

#### 4.1.3 Database connectivity

```bash
# On the DigitalOcean box — confirm dump capability before relying on it
docker exec nisanwebsite-db-1        pg_isready -U postgres
docker exec leads_backend-postgres-1 pg_isready -U postgres
docker exec chat_backend-postgres-1  pg_isready -U postgres

docker exec nisanwebsite-db-1 pg_dump -U postgres -d nisan_website --schema-only | head -5
```

### 4.2 Media files to S3 (no longer stored on the VM)

**Current:** 220 MB in `/var/www/nisanWebsite/server/coresite/media/`, bind-mounted into three containers, growing approximately 29 MB per week.

**Target:** `s3://dealerpulse-prod-media/`, accessed via the EC2 instance profile.

**Requires code change CC-4.** Per the existing documentation, `server/coresite/settings/file_storage.py` already contains conditional S3 support gated behind `FILE_UPLOAD_STORAGE=S3`, but **`django-storages` and `boto3` are not installed**. They must be added to `requirements.txt`.

```python
# settings/file_storage.py — S3 branch
if os.environ.get('FILE_UPLOAD_STORAGE') == 'S3':
    DEFAULT_FILE_STORAGE   = 'storages.backends.s3boto3.S3Boto3Storage'
    AWS_STORAGE_BUCKET_NAME = os.environ['AWS_STORAGE_BUCKET_NAME']
    AWS_S3_REGION_NAME      = 'us-west-2'
    AWS_DEFAULT_ACL         = None
    AWS_QUERYSTRING_AUTH    = False
    AWS_S3_FILE_OVERWRITE   = False
    # No keys in .env — the EC2 instance profile supplies credentials
```

**Migration:**

```bash
# From the DigitalOcean box
aws s3 sync /var/www/nisanWebsite/server/coresite/media/ \
            s3://dealerpulse-prod-media/ \
            --storage-class STANDARD

# Verify object count and total size match
aws s3 ls s3://dealerpulse-prod-media/ --recursive --summarize | tail -3
du -sh /var/www/nisanWebsite/server/coresite/media/
find /var/www/nisanWebsite/server/coresite/media/ -type f | wc -l
```

**Gains:** removes 220 MB and all future growth from the VM | S3 durability | versioning as backup | the media bind-mount disappears, unblocking the directory rename in §2.3.

**Fallback:** if CC-4 cannot be delivered in time, retain the bind-mount and the legacy `/var/www/nisanWebsite` directory name. Media-to-S3 then becomes a post-migration task. **This fallback must not block the migration.**

### 4.3 Database migration

Data totals **46 MB** across three databases — this runs in minutes.

> **Use logical dump/restore, never volume copies.** Each PostgreSQL container bakes its password into its data volume at first initialisation. Copying volumes between hosts produces an authentication failure with no useful diagnostic. Creating fresh containers from the same `.env` values and restoring a dump avoids this entirely.

```bash
# ---- nisanweb-backend (PostgreSQL 15) ----
ssh root@143.198.144.174 \
  "docker exec nisanwebsite-db-1 pg_dump -U postgres -d nisan_website -Fc" > nisanweb-backend.dump
scp nisanweb-backend.dump deploy@<AWS_IP>:/tmp/
ssh deploy@<AWS_IP> \
  "docker exec -i nisanweb-backend-db-1 pg_restore -U postgres -d nisan_website \
     --no-owner --clean --if-exists < /tmp/nisanweb-backend.dump"

# ---- leads_backend (PostgreSQL 16) ----
ssh root@143.198.144.174 \
  "docker exec leads_backend-postgres-1 pg_dump -U postgres -d leads_db \
     --clean --if-exists --no-owner --no-acl" > leads.sql
scp leads.sql deploy@<AWS_IP>:/tmp/
ssh deploy@<AWS_IP> \
  "docker exec -i leads_backend-postgres-1 psql -U postgres -d leads_db < /tmp/leads.sql"

# ---- chat_backend (PostgreSQL 16, database name: dealerpulse) ----
ssh root@143.198.144.174 \
  "docker exec chat_backend-postgres-1 pg_dump -U postgres -d dealerpulse \
     --clean --if-exists --no-owner --no-acl" > chat.sql
scp chat.sql deploy@<AWS_IP>:/tmp/
ssh deploy@<AWS_IP> \
  "docker exec -i chat_backend-postgres-1 psql -U postgres -d dealerpulse < /tmp/chat.sql"

# ---- MANDATORY cleanup — dumps contain real customer lead data ----
ssh deploy@<AWS_IP> 'shred -u /tmp/*.dump /tmp/*.sql'
shred -u nisanweb-backend.dump leads.sql chat.sql
```

> **`FIELD_ENCRYPTION_KEY` must be transferred before the chat restore is considered complete.** The `dealerpulse` dump contains ciphertext for encrypted columns. Without the identical key in the AWS environment, that data is permanently unreadable. Confirm the key is present in SSM **before** declaring this step done.

**Redis is not migrated.** It is pure cache and Celery broker; it rebuilds itself.

### 4.4 Verification

#### 4.4.1 Row counts per table

```bash
# Run on BOTH hosts and diff the output
docker exec <container> psql -U postgres -d <db> -t -A -F',' -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  ORDER BY relname;" > counts_<host>_<db>.csv

diff counts_do_nisan_website.csv counts_aws_nisan_website.csv && echo "nisanweb-backend: MATCH"
diff counts_do_leads_db.csv      counts_aws_leads_db.csv      && echo "leads: MATCH"
diff counts_do_dealerpulse.csv   counts_aws_dealerpulse.csv   && echo "chat:  MATCH"
```

> If `n_live_tup` shows drift (it is an estimate updated by autovacuum), run `ANALYZE;` on both sides first, or fall back to an exact `SELECT count(*)` per table.

#### 4.4.2 Alembic — leads_backend and chat_backend

```bash
docker exec leads_backend-web-1 alembic current
docker exec chat_backend-web-1  alembic current
```

**Expected:** an identical revision on both hosts. Documentation records leads at **head 012** — confirm this is still current and that chat's revision matches its source.

#### 4.4.3 Django migrations — nisanweb-backend

```bash
docker exec nisanweb-backend-web python server/manage.py showmigrations > migrations_aws.txt
ssh root@143.198.144.174 \
  "docker exec nisanwebsite-web-1 python server/manage.py showmigrations" > migrations_do.txt
diff migrations_do.txt migrations_aws.txt && echo "nisanweb-backend migrations: MATCH"
```

Every migration must show `[X]`. Any `[ ]` means the restore is incomplete.

#### 4.4.4 Media verification

```bash
find /var/www/nisanWebsite/server/coresite/media/ -type f | wc -l    # on DigitalOcean
aws s3 ls s3://dealerpulse-prod-media/ --recursive | wc -l           # on AWS
```

Object count and byte totals must match.

#### 4.4.5 Multi-tenancy data check

```sql
-- nisanweb-backend: enumerate configured tenant domains
SELECT d.id, d.domain, d.is_active, dl.name AS dealership
FROM   tenancy_domain d
JOIN   dealership dl ON dl.id = d.dealership_id
ORDER  BY d.domain;
```

> Table and column names above are indicative — confirm against `apps/tenancy/models.py`.

Documentation records that as of 2026-07-10 the only `Domain` row was `nissan-downtown-la.omnipulse.cc` mapped to Puente Hills Nissan, and that **`nissan.staging.flutenwebframework.xyz` had no row**. If that is still true, it is a **live production bug**, independent of this migration, and must be resolved before Phase 5 testing can pass.

### Phase 4 exit criteria

- [ ] All third-party endpoints reachable from AWS — **IP allowlisting confirmed with every vendor**
- [ ] Media synced to S3; object count and byte totals match
- [ ] `FILE_UPLOAD_STORAGE=S3` working; uploads land in S3 (or the documented fallback is in effect)
- [ ] All three databases restored
- [ ] Row counts match per table on all three databases
- [ ] `alembic current` matches on leads and chat
- [ ] `showmigrations` identical for nisanweb-backend; no unapplied migrations
- [ ] `FIELD_ENCRYPTION_KEY` and `API_CRYPTO_PRIVATE_KEY_B64` present in SSM and verified decrypting
- [ ] All dump files securely deleted from both hosts
- [ ] Backup jobs running against the AWS databases; **one successful restore test completed**

---

## PHASE 5 — Testing (production DNS untouched)

**Duration:** 1 week | **Owner:** DevOps + QA + Developers | **Downtime:** none

### 5.1 Parallel-run hazard controls — configure BEFORE any testing

A full parallel copy of production, running production credentials, **will take real actions in the real world**: duplicate customer emails, duplicate CRM writes, and duplicate billed API calls.

| Variable | Test value | Reason |
|---|---|---|
| `JDPOWER_ENABLED` | `false` | Live, **billed per VIN, no caching**. The `.env` states *"every VIN hits JD Power fresh"*. Parallel running doubles spend. |
| `LEAD_DISTRIBUTION_EMAIL` | test inbox | Prevents duplicate real leads reaching dealerships |
| `ALERTS_EMAIL` | test inbox | |
| `EMAIL_HOST` | catch-all (Mailtrap / MailHog) | Blocks all outbound customer email |
| nisanweb-backend `beat` | scaled to `0` | Prevents duplicate scheduled HomeNet refreshes |
| `COX_API_BASE_URL` | sandbox | Prevents duplicate CRM writes and bookings |
| `API_CRYPTO_MODE` | `required` with a **test keypair** | Exercises the real code path without exposing the production key |

**A written "flip to live values" checklist is a mandatory cutover artifact.** Every row above must be explicitly reverted and signed off.

### 5.2 Testing without touching DNS

```bash
# Backend services — correct Host header, routed to the AWS IP
curl --resolve nissan.staging.flutenwebframework.xyz:443:<AWS_IP> \
     https://nissan.staging.flutenwebframework.xyz/health

curl --resolve west-cost.ingeg.staging.flutenwebframework.xyz:443:<AWS_IP> \
     https://west-cost.ingeg.staging.flutenwebframework.xyz/health
# Expect: {"status":"healthy","service":"Cox Automotive Integrations API"}

curl --resolve chat.staging.flutenwebframework.xyz:443:<AWS_IP> \
     https://chat.staging.flutenwebframework.xyz/health
```

**Browser testing** — add to the local hosts file:

```
<AWS_IP>  nissan.staging.flutenwebframework.xyz
<AWS_IP>  west-cost.ingeg.staging.flutenwebframework.xyz
<AWS_IP>  chat.staging.flutenwebframework.xyz
```

**TLS before DNS:** certbot's HTTP-01 challenge requires the domain to already point at the server, which it will not. **Use DNS-01 validation via the Cloudflare API** to obtain real certificates ahead of cutover. This gives a zero-downtime cutover with valid TLS from the first request.

```bash
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d nissan.staging.flutenwebframework.xyz \
  -d west-cost.ingeg.staging.flutenwebframework.xyz \
  -d chat.staging.flutenwebframework.xyz
```

### 5.3 How to test multi-tenancy

This is the subtlest part of the test plan and deserves specific attention.

**How it works:** `nisanweb-backend` is multi-tenant. `apps/tenancy/middleware.py` (`DealershipFromHostMiddleware`) resolves the tenant **per request, from the HTTP `Host` header**, by looking up an active `Domain` row in the database. This is entirely application-level and unrelated to nginx vhosts.

**Why it is easy to get wrong:** if the `Host` header does not exactly match a `Domain` row, the middleware cannot resolve a tenant and the request fails — which looks identical to a broken migration.

#### Step 1 — enumerate what exists

```sql
SELECT d.domain, d.is_active, dl.name
FROM   tenancy_domain d JOIN dealership dl ON dl.id = d.dealership_id;
```

#### Step 2 — `curl --resolve` sends the correct Host header

This is the key technique. `--resolve` overrides DNS **without** altering the `Host` header, so the middleware sees exactly what it would in production:

```bash
curl -v --resolve nissan.staging.flutenwebframework.xyz:443:<AWS_IP> \
     https://nissan.staging.flutenwebframework.xyz/api/dealership/
# Expect: HTTP 200, correct dealership in the response body
```

#### Step 3 — per-tenant matrix

For every `Domain` row, confirm the correct dealership resolves:

| Host header | Expected dealership | Result |
|---|---|---|
| `nissan-downtown-la.omnipulse.cc` | Puente Hills Nissan | |
| `nissan.staging.flutenwebframework.xyz` | *(row must exist — see §4.4.5)* | |
| *(each additional Domain row)* | | |

#### Step 4 — negative tests (equally important)

| Host header | Expected behaviour |
|---|---|
| `unknown-host.example.com` | Rejected / 404 — **must not** silently fall back to a default tenant |
| Raw IP `<AWS_IP>` | Rejected — no Host match |
| A domain with `is_active = false` | Rejected |

#### Step 5 — tenant data isolation

Confirm that a request for dealership A never returns dealership B's inventory, leads, or settings. Compare API responses across two tenants and verify there is no overlap in returned record IDs.

#### Step 6 — `API_CRYPTO_MODE='required'` interaction

Every in-scope `/api/` request is **rejected without a valid `X-Crypto-Key`**. A plain `curl` will return an error that looks like a migration failure but is not. Tenant tests must be run through a client that performs the crypto handshake, or against endpoints outside the middleware's scope.

#### Step 7 — chat_backend is deliberately single-tenant

Per product decision, `chat_backend` serves exactly one dealership per deployment, configured via `DEALERSHIP_ID`, `DEALERSHIP_NAME`, `SALES_PHONE`, and related variables. **This is intentional and is not a defect.** Test that the configured dealership's details appear correctly.

*Forward note: onboarding dealerships 2–4 means three additional container stacks, each with its own `.env` and database. Worth designing the AWS layout so that is cheap to do.*

### 5.4 CloudWatch monitoring and alarms

Currently there is **no monitoring of any kind**. This closes that gap.

> **Memory and disk are not default EC2 metrics.** They require the **CloudWatch Agent** to be installed. This is the single most commonly missed step, and memory is precisely the metric that would have flagged the current situation.

```bash
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb
# configure: mem_used_percent, disk_used_percent, swap_used_percent
systemctl enable --now amazon-cloudwatch-agent
```

#### Alarms to an SNS topic, delivered by email (and optionally SMS)

| Alarm | Threshold | Severity |
|---|---|---|
| `mem_used_percent` | > 85% for 10 min | Critical |
| `swap_used_percent` | > 25% for 10 min | Warning — memory pressure is real |
| `CPUUtilization` | > 80% for 15 min | Warning |
| `CPUCreditBalance` | < 50 | Warning — burst exhaustion |
| `disk_used_percent` (`/`) | > 80% | Warning |
| `StatusCheckFailed` | >= 1 | Critical — instance or host failure |
| Backup job failure (custom metric) | >= 1 | Critical |
| Weekly restore-test failure (custom metric) | >= 1 | Critical |

#### Uptime checks

CloudWatch Synthetics canaries (or an external uptime service) polling each `/health` endpoint every 5 minutes, alarming after two consecutive failures.

**Estimated cost:** approximately $3/month for custom metrics and alarms.

### 5.5 Functional test matrix

| # | Test | Owner | Pass criteria |
|---|---|---|---|
| 1 | All `/health` endpoints | DevOps | HTTP 200 |
| 2 | Multi-tenancy resolution (§5.3) | DevOps | Every Domain row resolves correctly; negative tests rejected |
| 3 | HomeNet inventory populates | Dev | Vehicles appear; no read timeouts |
| 4 | XTime booking end-to-end | QA | **nisanweb-backend to leads_backend** cross-service path succeeds |
| 5 | Chat responses via OpenRouter | QA | Coherent replies returned |
| 6 | Chat WebSocket `/ws` | QA | Connection upgrades and holds |
| 7 | chat_backend to nisanweb-backend (inventory + FAQ APIs) | Dev | Data returned |
| 8 | ADF lead email | QA | Arrives **in the test inbox** |
| 9 | Frontend loads from CloudFront | QA | SPA renders; API calls succeed |
| 10 | Frontend deep-link refresh | QA | `/some/route` returns the app, not a 404 |
| 11 | Celery beat schedule | DevOps | Tasks fire on schedule (test window only) |
| 12 | Media upload to S3 | Dev | File lands in S3 and is retrievable |
| 13 | `API_CRYPTO_MODE=required` | Dev | Valid key succeeds; missing key rejected |
| 14 | `DEBUG=False` verified | DevOps | `diffsettings` shows `False`; error pages leak nothing |
| 15 | Reboot recovery | DevOps | All services return automatically |
| 16 | Deploy plus rollback | DevOps | Health gate triggers rollback on a deliberately bad image |
| 17 | Backup plus restore | DevOps | Restore into a scratch container; row counts match |
| 18 | Load test | DevOps | 2x expected peak; memory stays below 70% |

### Phase 5 exit criteria

- [ ] All 18 test-matrix items pass
- [ ] Multi-tenancy verified for every Domain row, including negative cases
- [ ] CloudWatch Agent installed; memory, swap, and disk metrics reporting
- [ ] All alarms configured and test-fired
- [ ] Real TLS certificates in place via DNS-01
- [ ] Load test shows memory below 70% at 2x peak
- [ ] Backup and restore verified end to end
- [ ] "Flip to live values" checklist written and reviewed

---

## PHASE 6 — Cutover

**Duration:** 1 day (2-hour window) | **Owner:** DevOps | **Downtime:** target zero, worst case ~5 min

### T-minus 48 hours

- [ ] Lower Cloudflare TTLs to **60 seconds** on all records — this is the single biggest lever on rollback speed
- [ ] Confirm all records remain **"DNS only" (grey cloud)**
- [ ] Freeze deploys on both environments
- [ ] Circulate the rollback plan; confirm who has authority to invoke it

> **Why grey cloud matters:** Cloudflare's free Universal SSL covers only the apex and **one** level of subdomain. Proxying a three-or-more-level hostname such as `west-cost.ingeg.staging.flutenwebframework.xyz` **fails TLS at Cloudflare's edge** before any certificate is presented, even with a perfectly valid origin certificate. Diagnostic: `curl --resolve <domain>:443:<origin-ip>` succeeds while a plain `curl` fails.

### Cutover window

1. Announce the maintenance window
2. Stop writes on DigitalOcean (scale `web` to 0; leave databases running)
3. **Final delta dump and restore** for all three databases — minutes at 46 MB
4. **Final media sync** to S3
5. Verify row counts match one final time
6. **Flip `.env` from test to live values** — every row of the §5.1 table, signed off
7. Bring nisanweb-backend's `beat` container up
8. Restart all AWS services; confirm health checks are green
9. **Switch Cloudflare A records** to the AWS Elastic IP
10. Add the frontend's CNAME to the CloudFront distribution
11. Verify from multiple external networks and resolvers
12. Monitor CloudWatch dashboards for 60 minutes

### Rollback

Point the A records back to `143.198.144.174`. With a 60-second TTL, recovery is under two minutes. **The DigitalOcean box stays running and untouched throughout.**

### Post-cutover

- [ ] Raise TTLs back to normal after 48 hours of stability
- [ ] **Soak for a minimum of 2 weeks** before decommissioning anything
- [ ] Daily backup verification for the first week

---

## PHASE 7 — Decommission

**Duration:** 1 day, **at least 2 weeks after cutover**

- [ ] Final full backup of the DigitalOcean box, archived to S3
- [ ] Confirm the migrated services are the **only** thing being removed — the box also hosts unrelated projects
- [ ] Stop and remove only our four service stacks
- [ ] Remove our three nginx vhosts
- [ ] Remove the orphaned `west-cost.ingeg.staging.omnipulse.cc` certificate
- [ ] Revoke old Bitbucket deploy keys and DockerHub tokens
- [ ] **Confirm rotation of every secret exposed during this project** (§8)
- [ ] Update documentation; retire the superseded guides
- [ ] Hand back or resize the droplet

> The DigitalOcean boxes host **approximately 15 unrelated projects and 30 other domains**. **Do not delete the droplet.** Decommissioning means removing our services only.

---

## 8. Security — required actions

### 8.1 Secret rotation (required regardless of migration)

Production credentials were exposed during discovery. These must be rotated **before or during cutover**:

| Secret | Service | Priority |
|---|---|---|
| `API_CRYPTO_PRIVATE_KEY_B64` | nisanweb-backend | Immediate — RSA private key protecting all API responses |
| `JDPOWER_API_KEY` + `JDPOWER_SECRET` | nisanweb-backend | Immediate — live, billed API |
| `XTIME_CLIENT_SECRET` | nisanweb-backend | High |
| `HOMENET_INTEGRATION_TOKEN` | nisanweb-backend | High |
| `EMAIL_HOST_PASSWORD` | nisanweb-backend | High |
| `SECRET_KEY` | nisanweb-backend | High — currently a weak keyboard-mash value |
| `PASSWORD` (Postgres) | nisanweb-backend | Currently `'123'`. Not network-exposed, but must be strong on AWS. |

**Rotation of `API_CRYPTO_PRIVATE_KEY_B64` requires redistributing the public key to the frontend.** With `API_CRYPTO_MODE='required'`, the API rejects requests until this is done. Coordinate with the frontend team.

Documented regeneration path:
`docker compose exec web python server/manage.py generate_api_crypto_keypair`

### 8.2 Additional items

- **Move `.env.bak` files out of git working trees.** Two exist in nisanweb-backend's repository directory (dated 2026-07-17 and 2026-08-11). They are untracked, but a single `git add -A` would commit secrets to history.
- **Audit `.env.example`** in the leads repository — documentation records two suspected real secrets and a real personal email in tracked history. Needs rotating and scrubbing.
- **Verify `COX_API_BASE_URL`** points at the production VinSolutions endpoint rather than `sandbox.api.vinsolutions.com`. Documentation records that this was never confirmed. If production has been running against sandbox, that is a live functional bug.
- **Generate strong per-service PostgreSQL passwords** on AWS (`openssl rand -base64 32`).

### 8.3 Explicitly out of scope (per direction)

- AWS WAF
- GuardDuty / Security Hub
- CloudTrail organisation trails and Config guardrails
- Network firewall appliances

Security is addressed at the **nginx and operating-system level** (§2.8) plus Security Groups. These services can be added later without rework.

---

## 9. Code changes required (developer time, not DevOps)

| # | Change | Repository | Phase | Effort | Blocking? |
|---|---|---|---|---|---|
| **CC-1** | `DEBUG` env-driven, default `False` | nisanweb-backend | 2 | 1h | **Yes** |
| **CC-2** | `ALLOWED_HOSTS` env-driven | nisanweb-backend | 2 | 1h | **Yes** |
| **CC-3** | `runserver` to gunicorn; static via nginx/WhiteNoise | nisanweb-backend | 2 | 4h | **Yes** (follows CC-1) |
| **CC-4** | Add `django-storages` + `boto3`; enable S3 storage | nisanweb-backend | 4 | 3h | Has a fallback |
| **CC-5** | Add `/health` endpoint (DB + Redis check) | nisanweb-backend | 2 | 2h | Needed for rollback gating |
| **CC-6** | Rebuild `bitbucket-pipelines.yml` — CI build, ECR push, no VM build | all 4 | 3 | 8h | **Yes** |
| **CC-7** | Frontend pipeline to S3 sync + CloudFront invalidation | frontend | 3 | 3h | Only if S3+CF is approved |

**Total: approximately 22 developer-hours.** CC-1, CC-2, CC-3, and CC-6 are hard blockers.

---

## 10. Decisions required from administration

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **1** | Approve AWS spend | **~$96/mo on-demand**, ~$77/mo with a 1-yr Savings Plan, ~$63/mo with Graviton as well | Approve on-demand now; buy a Savings Plan after 30 days of stable operation |
| **2** | **Access to the production domain** | — | 🔴 **Blocking.** Needed for DNS-01 certificates before cutover and for the cutover itself. `dealerpulse.cloud` is inferred from configuration and unconfirmed. |
| **3** | Provide vendor contacts (HomeNet, Cox, xtime, J.D. Power) | — | 🔴 **Highest-risk unknown, and the only item on the critical path.** If Cox or xtime have our current hostname registered for callbacks, renaming without telling them causes **silent lead loss**. Vendor lead times can be weeks. |
| **4** | Approve immediate secret rotation | — | 🔴 Required regardless of migration — see §8 |
| **5** | Allocate approximately 22 developer-hours | — | Blocks Phase 2 and Phase 3 |
| **6** | Who gets production shell access? | Named list | Session Manager permissions are IAM-scoped per person; the list has to exist before it can be written |
| **7** | Where should alerts be sent? | Email / SMS / Slack | Monitoring is inert without a destination |
| **8** | Approve the cutover window | — | Recommend a low-traffic window; target zero downtime |
| **9** | Does **staging** also migrate? | Production only / both | **Both eventually.** Production first. A `t3.small` staging box adds approximately $20/mo. Testing on DigitalOcean while deploying to AWS is a real risk. |

### Already decided — no longer open

| Item | Decision | Where |
|---|---|---|
| Region and AZ | `us-west-2`, single AZ | `ARCHITECTURE.md` §5 |
| Fleet | `t3.small` + 2 × `t3.medium` | §1.2 |
| Load balancer / autoscaling | **Neither** — blocked by shared state | `ARCHITECTURE.md` §12 |
| Staff access | SSM Session Manager, **port 22 closed** | §1.5 |
| Public websites hosting | **CloudFront in front of a container** — Next.js 16 cannot be static-exported without losing on-demand CMS publishing | `MIGRATION_CHANGES.md` §2 |
| Admin dashboard | Container on the Integrations VM | `ARCHITECTURE.md` §7 |
| Media files | **Stay on local disk**, backed up | `MIGRATION_CHANGES.md` §3 |
| Graviton | Fast-follow, not launch | §1.2 |

---

## 11. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Third parties IP-allowlist the old server** | High | Critical | Raise vendor requests in **Phase 1**, not Phase 4. Test from AWS per §4.1. |
| R2 | `FIELD_ENCRYPTION_KEY` lost or mismatched | Low | Critical — **permanent data loss** | Transfer to SSM first; verify decryption before declaring Phase 4 complete |
| R3 | Parallel run sends duplicate leads, CRM writes, or billed API calls | Medium | High | §5.1 hazard controls; written flip-to-live checklist |
| R4 | Developer time unavailable | Medium | High | Secure the ~22 hours before Phase 2 begins |
| R5 | `DEBUG=False` surfaces latent bugs (missing `ALLOWED_HOSTS`, static files) | Medium | Medium | Test thoroughly in Phase 5 — this is precisely why we test before cutover |
| R6 | `API_CRYPTO_MODE=required` blocks testing | Medium | Medium | Generate a separate test keypair (§5.1) |
| R7 | Missing `Domain` row breaks tenancy after cutover | Medium | High | Verify per §4.4.5 — may already be a live production bug |
| R8 | Cloudflare deep-subdomain TLS failure | Low | Medium | Records stay "DNS only". Documented and understood. |
| R9 | Cutover DNS propagation delays | Low | Medium | 60-second TTLs set 48h in advance |
| R10 | Cost overrun | Low | Low | AWS Budget with alerts at 50/80/100% |
| R11 | `t3` CPU credits exhaust | Low | Medium | Alarms on `CPUCreditBalance` **and** `CPUSurplusCreditsCharged`; escalate the affected VM to `c6i.large`. 14-day data shows 7.5× headroom. |
| R12 | Frontend VM memory pressure at 2 GiB | Medium | Medium | Estimated 55% used — the tightest in the fleet. Memory alarm at 80%; **upgrade to `t3.medium` at the third tenant**. Resize is a stop/start. |
| R13 | SSM Agent fails, locking out all access | Low | High | **EC2 Serial Console** as break-glass — password set at build, stored in Parameter Store. Verify it works **before** cutover, not after. |
| R12 | S3 media change (CC-4) slips | Medium | Low | Documented fallback: retain the bind-mount and legacy directory name |

---

## 12. Timeline — 5-day execution plan

**Target: 5 working days of execution, ending in cutover.**

This is achievable. It is not achievable *from a standing start*. The data is small (270 MB), the architecture is unchanged, and four of five applications already deploy from a registry. What makes five days realistic is that **the work is well-understood**; what makes it fail is starting before the prerequisites are cleared.

### 12.1 Day 0 — prerequisites (NOT part of the five days)

**Nothing on Day 1 can begin until every item below is complete.** Day 0 is elapsed calendar time, not effort, and it is gated by third parties.

| # | Prerequisite | Owner | Typical lead time |
|---|---|---|---|
| P1 | **Vendor IP allowlisting confirmed** — HomeNet, Cox/VinSolutions, xtime, J.D. Power | Account owners | **Days to weeks — the binding constraint** |
| P2 | AWS account: root MFA, IAM Identity Center, budget alarms | DevOps | 2 hours |
| P3 | Elastic IP allocated (needed for P1 — vendors must be given the address) | DevOps | 15 minutes |
| P4 | **Developer allocated full-time for Days 1–3** (~22 hours, §9) | Administration | Scheduling |
| P5 | Code changes CC-1, CC-2, CC-3, CC-5 merged and tested locally | Developer | 8 hours |
| P6 | Cloudflare API token created for DNS-01 validation | DevOps | 15 minutes |
| P7 | Frontend hostname decided (§10, Decision 4) | Administration | Decision |
| P8 | Cutover window agreed and communicated | Administration | Decision |
| P9 | Test inbox provisioned for parallel-run email capture | DevOps | 15 minutes |

> ⚠️ **P1 cannot be compressed and is entirely outside our control.** If HomeNet or Cox require a change-request process, that alone can take two to three weeks. **Raise these requests immediately — today — regardless of when the five days are scheduled.** Every other prerequisite is a matter of hours.

### 12.2 The five days

| Day | Focus | Deliverables |
|---|---|---|
| **1** | **Foundation + base build** (Phase 1, Phase 2.1–2.3) | **Three EC2 instances** provisioned — `t3.small`/40 GB (Frontend), `t3.medium`/60 GB (Backend), `t3.medium`/40 GB (Integrations) — each with an Elastic IP and the SSM instance profile. Docker, nginx, certbot, awscli, CloudWatch Agent installed on all three. Swap active (4 GB Backend, 2 GB others). `/var/www/` layout created. S3 buckets and IAM roles. **Security Groups locked to 80/443 only — no port 22.** Route 53 private hosted zone created. `aws ssm start-session` verified against each instance. **Connectivity test suite run (§4.1) — this is the go/no-go gate.** |
| **2** | **Deploy all five applications** (Phase 2.4–2.8) | All services running on AWS. `DEBUG=False` verified via `diffsettings`. gunicorn replacing `runserver`. Health checks green. Restart policies and log rotation. nginx hardening and WebSocket config. Fresh deploy keys. **DNS-01 certificates issued.** |
| **3** | **CI/CD + data migration** (Phase 3, Phase 4) | ECR repositories, Bitbucket OIDC, four rebuilt pipelines. **No builds on the VM — verified.** Test deploy and deliberate rollback of each service. Databases dumped, restored, and verified (row counts, `alembic current`, `showmigrations`). Media synced to S3. Backup jobs scheduled. |
| **4** | **Testing** (Phase 5) | Parallel-run hazard controls applied. Full 18-item test matrix. Multi-tenancy verified per Domain row, including negative cases. CloudWatch Agent, metrics, and alarms live. Load test at 2x peak. One successful backup restore. **Go/no-go decision at end of day.** |
| **5** | **Cutover** (Phase 6) | Final delta sync. Flip-to-live checklist signed off. `beat` container started. DNS switched. Verified from multiple resolvers. 60-minute monitoring window. Rollback held ready. |

**TTL reduction to 60 seconds must happen on Day 3**, so it has propagated 48 hours before the Day 5 cutover.

### 12.3 What a 5-day schedule sacrifices

Honest accounting of what is compressed relative to the 5–7 week plan:

| Item | 5-week plan | 5-day plan | Risk introduced |
|---|---|---|---|
| Soak time before cutover | 1 week | **0 days** | Slow-burn issues (memory growth, a weekly cron, a scheduled task) go undetected until after cutover |
| Test matrix execution | 5 days | **1 day** | Less exploratory testing; only the scripted matrix runs |
| Pipeline hardening | 5 days | **1 day** | Rollback tested once per service, not repeatedly |
| CC-4 (media to S3) | Included | **Deferred** | Media bind-mount and the legacy `nisanWebsite` directory name are retained; S3 media becomes post-migration work |
| Secrets to Parameter Store | Post-migration | **Post-migration** | Unchanged — was always deferred |
| Contingency for surprises | ~1 week | **0 days** | **Any single unexpected problem pushes the cutover** |

**Deliberately dropped from the five days:**
- **CC-4 / media to S3.** Media stays on the EBS volume, bind-mounted as today. This also means **the directory rename in §2.3 does not happen** — we keep `/var/www/nisanWebsite` to avoid breaking the hardcoded compose path. Schedule as a post-migration task.
- **CC-7 / frontend to S3 + CloudFront**, *if* the hostname decision (P7) is not made in time. Fallback: keep the frontend as a container on the VM exactly as today, and migrate it to CloudFront afterwards. **This must not block cutover.**

### 12.4 Conditions under which five days holds

All of the following must be true. If any is false, the schedule extends.

- [ ] All Day 0 prerequisites complete **before** Day 1 begins
- [ ] Vendor IP allowlisting confirmed, or confirmed to be unnecessary
- [ ] A developer is available and responsive throughout Days 1–3
- [ ] The four `docker-compose.yml` files have been reviewed in advance (still outstanding)
- [ ] No undiscovered service or dependency emerges — three have already surfaced during discovery
- [ ] `DEBUG=False` does not reveal latent application bugs (R5 — a genuine unknown until tested)
- [ ] DigitalOcean bandwidth and the current database state remain stable

### 12.5 Recommendation

**Run the five days, but present it to administration as "5 days of execution after a Day 0 gate of unknown duration."** Committing to a calendar date before P1 is resolved would be committing to something outside our control.

**A safer variant that costs one extra day:** insert a **48-hour soak between Day 4 and cutover** — a 7-day elapsed schedule with two days of parallel running under real observation. It catches exactly the class of problem that a compressed test window misses, and it is the single highest-value day that could be added.

### 12.6 Post-cutover (beyond the five days)

| When | Activity |
|---|---|
| Days 6–12 | Daily backup verification. Monitor memory, CPU credits, and alarms. Keep the DigitalOcean box running and untouched. |
| Week 3 | CC-4: media to S3. Directory standardisation. CloudFront for the frontend if deferred. |
| Week 4 | Purchase the 1-year Savings Plan. Begin Parameter Store migration, one service at a time. |
| Week 5+ | Phase 7 — decommission DigitalOcean services (**minimum 2 weeks after cutover**). |

**Critical path throughout: vendor IP-allowlist confirmation (R1) and developer availability (R4).**

---

## 13. Out of scope

Deliberately excluded to keep this migration bounded:

- The approximately 15 unrelated projects and 30 other domains on the DigitalOcean boxes
- AWS WAF, GuardDuty, Security Hub, CloudTrail organisation trails
- Migration to ECS / EKS / Fargate (a future option once lift-and-shift is stable)
- RDS (containerised PostgreSQL is retained; at 46 MB total, RDS is not yet justified)
- Multi-AZ or high availability
- Multi-tenant expansion of `chat_backend` to dealerships 2–4
- Centralised log aggregation beyond CloudWatch

---

## 14. Future roadmap (post-migration)

| Priority | Item | Value |
|---|---|---|
| 1 | Migrate staging to AWS | Environment parity |
| 2 | Centralised logging (CloudWatch Logs / OpenSearch) | Currently `docker compose logs` only |
| 3 | Error tracking (Sentry) | No error visibility exists today |
| 4 | RDS for PostgreSQL | Managed backups, PITR, automated patching |
| 5 | Terraform / IaC for the whole estate | Reproducibility, review, disaster recovery |
| 6 | Multi-tenant `chat_backend` | Removes per-dealership container sprawl |
| 7 | Auto-scaling / high availability | Once traffic justifies it |
| 8 | Staging environment parity with production | |

---

## 15. Additional real-world considerations

Items that routinely cause problems in migrations of this shape and are not covered elsewhere. Each is cheap to handle in advance and expensive to discover at cutover.

### 15.1 Pin Docker image tags before migrating

**Current compose files use floating tags: `postgres:15`, `postgres:16-alpine`, `redis:7-alpine`.**

When new containers are created on AWS, Docker pulls whatever those tags point to **today** — which is a newer minor version than what has been running for six weeks. Usually harmless. Occasionally not.

```yaml
# Before                After — pin explicitly
postgres:15        ->   postgres:15.14
postgres:16-alpine ->   postgres:16.10-alpine
redis:7-alpine     ->   redis:7.4.6-alpine
```

**Read the exact running versions first, and pin to those:**

```bash
docker exec nisanwebsite-db-1        postgres --version
docker exec leads_backend-postgres-1 postgres --version
docker exec chat_backend-postgres-1  postgres --version
docker exec nisanwebsite-redis-1     redis-server --version
```

### 15.2 🔴 Database locale and collation must match

The `\l+` output shows all three databases using `en_US.utf8` with the `libc` locale provider. **A restore into a container with a different locale can silently change text ordering and corrupt collation-dependent indexes** — `ORDER BY` returns different results, and unique indexes on text columns can behave unexpectedly.

The risk is real here because the stack mixes image bases: `postgres:15` is Debian-based (glibc) while `postgres:16-alpine` is Alpine-based (musl). **Provided we use identical image tags on AWS, the locale carries over correctly.** Verify after restore:

```bash
docker exec <container> psql -U postgres -c "SHOW lc_collate; SHOW lc_ctype;"
# Must match the source exactly: en_US.utf8
```

### 15.3 🔴 Let's Encrypt rate limits during testing

Let's Encrypt enforces **5 duplicate certificates per exact hostname set per week.** Re-issuing certificates for the same three hostnames during Phase 5 testing can exhaust this quickly, and there is **no way to lift it** — only to wait seven days.

**Mitigations:**
- Use `--dry-run` for every test issuance; it does not count against the limit
- Use the staging ACME directory while iterating: `--server https://acme-staging-v02.api.letsencrypt.org/directory`
- Issue the real certificate **once**, on Day 2, and back up `/etc/letsencrypt/` immediately
- Related limit: 50 certificates per registered domain per week

### 15.4 Separate EBS volume for Docker data

Consider a **second gp3 volume mounted at `/var/lib/docker`** with `DeleteOnTermination=false`.

| Benefit | Detail |
|---|---|
| Instance replacement without data loss | Detach and reattach to a new instance; databases and volumes survive |
| Independent snapshot schedules | Root volume weekly, data volume every 6 hours |
| Independent resizing | Grow data storage without touching the root volume |
| Accidental-termination protection | The data volume persists even if the instance is terminated |

Suggested split: 30 GB root + 40 GB data. Same total cost (~$5.60/month at $0.08/GB). Also enable **termination protection** on the instance itself.

### 15.5 Email sending — a non-issue worth confirming

New cloud IPs commonly have poor email reputation, and **AWS blocks outbound port 25 by default**. Neither applies here:

- Mail is relayed through **Hostinger SMTP on port 587**, so the sending IP is Hostinger's, not ours — reputation is unaffected by the move
- Port 587 is not blocked

**But confirm two things:** that Hostinger does not IP-restrict SMTP authentication (§4.1), and that SPF/DKIM records for `dealerpulse.cloud` reference Hostinger rather than the DigitalOcean IP.

```bash
dig +short TXT dealerpulse.cloud | grep -i spf
```

### 15.6 System timezone and clock

Set the instance to **UTC** and verify NTP is synchronising. `chat_backend` has a `DEALERSHIP_TIMEZONE_OFFSET` variable that presumably assumes a UTC base; a host in a different timezone would shift every displayed dealership opening hour.

```bash
timedatectl set-timezone UTC
timedatectl status        # confirm "System clock synchronized: yes"
```

> Also worth resolving: discovery output suggested the string `[11:26 AM] DEALERSHIP_TIMEZONE_OFFSET` may appear in `chat_backend`'s `.env`. If that is literally in the file rather than a paste artifact, **the variable name is corrupted and is not being read at all** — the application is silently running on a default offset. Confirm with `grep -n 'TIMEZONE' /opt/dealerships/chat_backend/.env` and fix during the rebuild.

### 15.7 OpenRouter costs during parallel running

§5.1 covers J.D. Power, but **`chat_backend` uses OpenRouter, which bills per token.** Parallel chat testing spends real money and is easy to overlook because the amounts are small per request.

**Add to the hazard controls:** use a separate OpenRouter API key with a spend cap for the test environment, or a cheaper model via `OPENROUTER_PRIMARY_MODEL` during Phase 5.

### 15.8 Snapshot the DigitalOcean droplet before starting

Before any migration work begins, take a **full DigitalOcean snapshot** of `143.198.144.174`. It is inexpensive, takes minutes, and provides a whole-machine recovery point that the (currently non-existent) backup system does not.

> Note: the droplet also hosts unrelated projects. A snapshot captures all of them, which is fine — but the same fact is why the droplet **must not be deleted** at decommission.

### 15.9 Staging will point at the old production after cutover

`nisanweb-backend` on **staging** has `XTIME_BASE_URL` pointing at `https://west-cost.integ.omnipulse.cc`, and other cross-environment references may exist. Once production DNS moves to AWS, verify that staging is not inadvertently calling production — or worse, that production is not calling staging.

```bash
grep -E 'XTIME_BASE_URL|INVENTORY_API_URL|FAQ_API_URL|CSRF_TRUSTED_ORIGINS' \
  /var/www/nisanWebsite/.env /opt/dealerships/chat_backend/.env
```

Run this on **both** boxes and confirm every URL points within its own environment.

### 15.10 CloudWatch Logs cost, if adopted later

CloudWatch Logs charges approximately **$0.50/GB ingested** plus $0.03/GB-month stored. Verbose Docker logs from five applications across three VMs can reach several GB per month, so what looks like a free improvement can become $10–20/month.

**If adopting centralised logging:** ship only application logs, not access logs; set a 14–30 day retention policy; and keep the Docker `json-file` driver with `max-size: 10m` as the local buffer.

### 15.11 Define the rollback decision-maker before cutover

A technical rollback plan without a named decision-maker fails under pressure. Agree in advance:

- **Who** can call a rollback (name one person, plus one deputy)
- **What** triggers it — e.g. any Critical alarm, or health checks failing for more than 10 minutes
- **How long** we attempt to fix forward before rolling back (recommend 30 minutes)
- **Who** notifies the dealerships

### 15.12 Post-cutover on-call

For the first 72 hours after cutover, someone must be reachable and able to act. There is no on-call rotation today. At minimum: a named person with SSH access, AWS console access, and Cloudflare access, with alarms routed to a phone rather than only to email.

### 15.13 Make the build reproducible

Everything in Phase 2 should be captured as a **user-data script or Ansible playbook**, not performed by hand. If the instance is lost, rebuilding from a documented script takes 20 minutes; rebuilding from memory takes a day.

Full infrastructure-as-code (Terraform) is out of scope for a five-day plan, but a single shell script that provisions the box from a bare Ubuntu AMI captures most of the value at almost no cost.

### 15.14 Capture a performance baseline before cutover

Record response times from the current production box so post-cutover comparisons are grounded in data rather than impressions:

```bash
for url in https://nissan.staging.flutenwebframework.xyz/ \
           https://west-cost.ingeg.staging.flutenwebframework.xyz/health \
           https://chat.staging.flutenwebframework.xyz/health; do
  echo -n "$url  "
  curl -s -o /dev/null -w "%{time_total}s (TTFB %{time_starttransfer}s)\n" "$url"
done
```

Run the same set against AWS in Phase 5. Any regression greater than ~20% warrants investigation before cutover.

---

## Appendix A — Reference data

### Domains and upstreams (current)

| Domain | Upstream | Service |
|---|---|---|
| `nissan.staging.flutenwebframework.xyz` | `127.0.0.1:9000` | nisanweb-backend |
| `west-cost.ingeg.staging.flutenwebframework.xyz` | `127.0.0.1:8129` | leads_backend |
| `chat.staging.flutenwebframework.xyz` | `chatbot_backend` upstream + `/ws` | chat_backend |
| *(none)* | `0.0.0.0:9011` | dealerships_frontend |

> All production hostnames contain the word **"staging"**. They are production. Do not judge an environment by its hostname.

### Service dependency graph

```
                 Dealership website visitor
                            |
        +-------------------+--------------------+
        v                   v                    v
 dealerships_frontend    nisanweb-backend (Django)     chat_backend
   (S3 + CloudFront)        |                    |
                            |                    |
        +-------------------+                    |
        v                   v                    |
    HomeNet SOAP      leads_backend  <-----------+
    J.D. Power        (Cox / xtime)
                            |
                            v
                  Cox VinSolutions | xtime
                  Hostinger SMTP (ADF leads)
```

**Cross-service dependencies to preserve at cutover:**

1. `nisanweb-backend` to `leads_backend` via `XTIME_BASE_URL`
2. `chat_backend` to `nisanweb-backend` via `INVENTORY_API_URL` and `FAQ_API_URL`

### Known naming traps

| Trap | Detail |
|---|---|
| One service, three names | "Cox Automotive Integrations API" = `leads_backend` = nisanweb-backend's "XTime proxy" |
| Production hostnames say "staging" | All `*.staging.flutenwebframework.xyz` records are **production** |
| `nisanWebsite` is misspelled | Legacy, and load-bearing — hardcoded in nisanweb-backend's compose media mount |
| Two files named `DEPLOYMENT_GUIDE` | The `.md` covers nisanweb-backend; the `.docx` covers leads_backend |
| chat's database is `dealerpulse` | Not `chat_db` |

### Documentation status

| Document | Covers | Currency |
|---|---|---|
| `DEPLOYMENT_GUIDE.md` | nisanweb-backend | Written 2026-07-10 — partly outdated |
| `DEPLOYMENT_GUIDE.docx` | leads_backend | Written approximately 2026-07-10 — the most reliable of the three |
| `Backend Infrastructure & Deployment Guides.docx` | Summaries of three services | Shallow |

**Undocumented, and discovered during this exercise:** `dealerships_frontend` | the J.D. Power integration | `API_CRYPTO_*` response encryption | chat_backend's `FIELD_ENCRYPTION_KEY` | chat_backend's port (9002) | the `chat_backend` to `nisanweb-backend` dependency.

**This plan supersedes all three documents where they conflict.**

---

*End of document.*
