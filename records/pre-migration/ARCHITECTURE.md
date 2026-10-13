# Target Architecture — Dealerships on AWS

---

## 1. Decisions locked

| Decision | Consequence |
|---|---|
| **Three VMs — no Auto Scaling Group, no load balancer** | Blocked by shared state, not cost — see §12 |
| **Frontends isolated per tenant** | One container per tenant. **One tenant today**, headroom for ~6 |
| **`nisanweb-backend` must be reliable** | Own VM, own database, cache and scheduled jobs. |
| **`leads_backend` / `chat_backend` are integration microservices** | Share one VM. Brief outages tolerable. |
| **Admin dashboard on the Integrations VM** | Negligible footprint (4.6 MiB). S3 + CloudFront remains an option — §7 |
| **All VMs in public subnets, protected by security groups** | **No NAT Gateway — saves ~$32/month.** |
| **Inter-service traffic over private IPs** | No hairpin, lower latency, no transfer charges. |

### Fleet as approved

| | Instance | Rationale |
|---|---|---|
| Frontend VM | **`t3.small`** | One tenant today. **Upgrade to `t3.medium` at the third tenant.** |
| Backend VM | **`t3.medium`** | Shared by every tenant — the reliable one |
| Integrations VM | **`t3.medium`** | Two services, two databases, plus the admin dashboard |

**Review after one month of production metrics.** If utilisation stays as low as the current data suggests, downscale then — sizing down on evidence is safe; sizing up under load is not.


---

## 2. Traffic basis

**6,000 visits/day, one tenant** ≈ 180,000/month.

| | Estimate |
|---|---|
| Peak hour (~15% of daily) | ~900 sessions |
| Peak page requests | ~1/second (SSR, mostly ISR cache hits) |
| Peak API requests | ~2/second |
| Concurrent users at peak | ~30–50 |

Modest. Sizing below is driven by **memory headroom, not CPU**.

| Data transfer | Volume/month | Free allowance | Cost |
|---|---|---|---|
| Via CloudFront | ~270 GB | 1 TB | **$0.00** |
| Direct from EC2 (API) | ~22 GB | 100 GB | **$0.00** |

---

## 3. Architecture

```
                         Cloudflare DNS  (public zone)
                                 │
         ┌───────────────────────┴───────────────────────┐
         │                                               │
   CloudFront                                            │
  (tenant site)                                          │
         │                                               │
         ▼                                               ▼
┌──────────────────────┐                    ┌───────────────────────────┐
│  FRONTEND VM         │                    │  INTEGRATIONS VM          │
│  t3.small            │                    │  t3.medium                │
│  nginx + certbot     │                    │  nginx + certbot          │
│    └ Next.js :3000   │                    │    ├ leads_backend :8129  │
│      (tenant 1)      │                    │    │   └ PostgreSQL 16    │
│                      │                    │    ├ chat_backend  :9002  │
│  room for ~6 tenants │                    │    │   └ PostgreSQL 16    │
│  → t3.medium at      │                    │    └ admin dashboard      │
│    the 3rd tenant    │                    │        (static SPA)       │
└──────────┬───────────┘                    └─────────┬─────────────────┘
           │                                          │
           │   private IPs — Route53 private zone     │
           ▼                                          ▼
┌────────────────────────────────────────────────────────────────┐
│  BACKEND VM  —  "the reliable one"   ·   t3.medium             │
│  nginx + certbot                                               │
│    ├ Django + gunicorn  :9000      ├ PostgreSQL 15             │
│    ├ celery worker                 ├ Redis 7  (hourly cache)   │
│    └ celery beat  (singleton)      └ media/  (local disk)      │
└────────────────────────────────────────────────────────────────┘
            │
            └──► HomeNet · J.D. Power · SMTP      (outbound via IGW)
```

| From | To | Path |
|---|---|---|
| Visitor browser | Tenant site | CloudFront → Frontend VM |
| Admin browser | Admin dashboard | Direct to Integrations VM (public HTTPS) |
| Admin browser | API | Direct to Backend VM (public HTTPS) |
| Chat widget | `chat_backend` WebSocket | Direct to Integrations VM |
| Next.js server-side | API | **Private IP** |
| `chat_backend` | API (inventory, FAQ) | **Private IP** |
| `nisanweb-backend` | `leads_backend` (XTime) | **Private IP** |
| Any VM | HomeNet, Cox, OpenRouter, SMTP, ECR | Internet Gateway (free) |

---

## 4. Instance sizing — and the Graviton question

**Chosen: `t3.medium` × 2 (Backend, Integrations) + `t3.small` × 1 (Frontend).**

The Frontend VM is smaller deliberately: it serves one tenant today, and a Next.js container in `standalone` mode is the lightest workload in the fleet. **It moves to `t3.medium` when the third tenant is onboarded** — that is the trigger, not a date.

### CPU baseline — measured, not estimated

`t3.medium` provides **0.4 vCPU sustained** (20% per vCPU, 24 credits/hour, 576-credit maximum balance); beyond that it draws on burst credits.

**Measured from DigitalOcean's 14-day CPU graph for `Nissan-Websites` (12–25 Aug 2026):**

| | Reading | As vCPU | vs one `t3.medium` baseline |
|---|---|---|---|
| **Sustained** | **7–9%**, flat across two weeks | **0.16 vCPU** | **40%** |
| Peak (24 Aug) | ≥72%, brief | 1.44 vCPU | ~21 surplus credits — of 576 |
| `sys` time | ~0% throughout | — | Not I/O bound |

**That is the entire current production workload on one box.** Split across three VMs the aggregate baseline becomes 1.2 vCPU, giving roughly **7.5× headroom**.

> **On measurement:** an earlier draft quoted 0.38 vCPU from `load average`. That metric counts processes in uninterruptible sleep as well as runnable ones, so it overstates CPU demand; a `docker stats` snapshot understates it by sampling instantaneously. The 14-day `CPUUtilization` graph is the figure credits are actually consumed against, and it is the one used here.

**Frontend VM sizing is not yet grounded in data.** `Nissan-Websites` serves JSON APIs; the page assets that dominate a visitor session are served by `website_frontend` on `Combined`. **Pull the same 14-day graph from `137.184.45.248` before finalising the Frontend VM.** Note that `Combined` also hosts ~15 unrelated projects, so its graph is an upper bound rather than our share.

### Burst credits and alarms

T3 instances default to **Unlimited** mode, so they never throttle — surplus bills at $0.05/vCPU-hour only when consumed. **Confirm Unlimited is enabled** at launch rather than assuming it.

Two alarms, not one:

| Metric | Threshold | Means |
|---|---|---|
| `CPUCreditBalance` | Below 20% of maximum | Early warning — baseline is being exceeded |
| `CPUSurplusCreditsCharged` | `> 0` sustained | **This is now costing money** |

If the Backend VM sustains surplus, escalate to a non-burstable instance with guaranteed CPU: **`c6i.large`** (same 2 vCPU / 4 GiB, ~+$32/month) or **`m6i.large`** (2 vCPU / 8 GiB, ~+$40/month).

### Fleet specification

| | Frontend VM | Backend VM | Integrations VM |
|---|---|---|---|
| Instance | **`t3.small`** | **`t3.medium`** | **`t3.medium`** |
| vCPU / RAM | 2 / **2 GiB** | 2 / 4 GiB | 2 / 4 GiB |
| CPU baseline | 0.4 vCPU (20%) | 0.4 vCPU (20%) | 0.4 vCPU (20%) |
| Disk | 40 GB gp3 | 60 GB gp3 | 40 GB gp3 |
| Swap | 2 GB | **4 GB** | 2 GB |
| Est. memory used | ~1.1 GiB (**55%**) | **~2.1 GiB (53%)** | ~1.7 GiB (43%) |
| Graviton equivalent | `t4g.small` | `t4g.medium` | `t4g.medium` |
| Upgrade trigger | **3rd tenant → `t3.medium`** | Sustained surplus credits | 4th integration service |

`t3.small` and `t3.medium` share the same **0.4 vCPU baseline** — the difference is memory, not CPU. Downsizing the Frontend VM therefore costs no compute headroom at all.

All instances run **T3 Unlimited** so they never throttle; surplus credits bill at $0.05/vCPU-hour only if used. Expect $0 at this load.

> **Frontend VM headroom is the tightest number in the fleet at 55%.** That is comfortable for one tenant and untenable for three — which is exactly why the third tenant is the upgrade trigger. Set a CloudWatch memory alarm at 80% so the trigger fires on evidence rather than on a count.

### Post-migration review

Sizing above is deliberately conservative. **After roughly one month of production CloudWatch data, review all three.** If utilisation matches the current baseline, downscale — reducing an instance on evidence is a five-minute stop/start; discovering it was undersized during a traffic peak is not.

---

## 5. Network design

### Region — `us-west-2` (Oregon)

| | `us-west-2` *(chosen)* | `us-west-1` (N. California) |
|---|---|---|
| `t3.medium` on-demand | **$0.0416/hr** | $0.0464/hr — **~11% more** |
| Availability Zones | **4** | 2 |
| Service coverage | Full — every service, earliest | Reduced; some services absent |
| Latency from Los Angeles | ~20–25 ms | ~10–15 ms |

`us-west-1` is physically closer to the dealerships, but the **10–15 ms difference is invisible** for this workload. It does not justify a permanent ~11% premium on every instance, a smaller service catalogue, or half the zones to grow into.

### Availability Zones — single

**One AZ, deliberately.** Multi-AZ only produces availability when each tier has redundancy *across* those zones. We run **one VM per role**, so distributing the three machines across three zones would make nothing survive a zone failure — it would add **$0.01/GB each way** on every internal call between our own services, plus a few milliseconds of latency, for zero availability gain.

| | Cost | Availability gained |
|---|---|---|
| Three VMs, one AZ *(chosen)* | $0 inter-AZ | — |
| Three VMs, three AZs | Inter-AZ charges on all private traffic | **None** — still one VM per role |
| Six VMs, two AZs + ALB | ~2× compute + $22 ALB | Real, but blocked by §12 |

**The trade-off, stated plainly: an AZ failure is a full outage.** Mitigation is daily EBS snapshots, which are **region-scoped, not zone-scoped** — the fleet can be relaunched in a different AZ in roughly 20–30 minutes. That is the correct cost/benefit at current scale, and it is revisitable once there is redundancy worth distributing.

```
Region  us-west-2
VPC  10.0.0.0/16
└── Public subnet  10.0.1.0/24      (single AZ — inter-AZ traffic is $0.01/GB each way)
      Frontend VM      10.0.1.10  + Elastic IP
      Backend VM       10.0.1.20  + Elastic IP
      Integrations VM  10.0.1.30  + Elastic IP
```

**Public subnets, no NAT Gateway.** Every VM needs outbound access to HomeNet, Cox, OpenRouter, SMTP and ECR. From a public subnet that goes out via the Internet Gateway at **no charge**. Private subnets would need a NAT Gateway at ~$32/month plus $0.045/GB — and the NAT would itself become a new single point of failure.

> **A public IP is not public access.** Inbound is governed entirely by security groups.

### Security groups

| Group | Port | Source |
|---|---|---|
| `sg-frontend` | 443, 80 | `0.0.0.0/0` |
| `sg-backend` | 443, 80 | `0.0.0.0/0` — browsers call the API directly |
| | 9000 | `sg-frontend`, `sg-integrations` |
| `sg-integrations` | 443, 80 | `0.0.0.0/0` — chat WebSocket from browsers |
| | 8129 | `sg-backend` |

Rules **reference other security groups, not IP addresses** — this survives instance replacement.

**Never opened — including SSH.** PostgreSQL (5432), Redis (6379) and **port 22** have no inbound rule at all on any of the three groups. Staff access is via **SSM Session Manager**, below.

---

## 5a. Staff access — no inbound ports at all

**AWS Systems Manager Session Manager.** The SSM Agent on each instance opens an **outbound** connection to the SSM service on 443; AWS brokers the session back down that existing connection. Nothing listens for inbound administrative traffic, so there is no SSH port to scan, no bastion host to patch, and no key material to distribute or revoke.

| | **Session Manager** *(chosen)* | Bastion host | Port 22 to office IPs |
|---|---|---|---|
| Inbound ports open | **None** | 22 on the bastion | 22 on all three VMs |
| Extra infrastructure | **None** | A VM to run, patch, monitor | None |
| Cost | **$0** | ~$15/month | $0 |
| Credentials | **IAM — no keys exist** | SSH private keys per person | SSH private keys per person |
| Offboarding | **Remove IAM permission** | Remove key from every host | Remove key from every host |
| Remote / travelling staff | ✅ Works anywhere | ✅ | ❌ Breaks on every IP change |
| Session audit trail | ✅ **Every keystroke to S3/CloudWatch** | Only if configured on the bastion | ❌ None |
| Single point of failure | None | ✅ The bastion | None |

### What it requires

| Requirement | Detail |
|---|---|
| SSM Agent on the instance | **Pre-installed** on Amazon Linux 2023 and Ubuntu 22.04/24.04 AMIs |
| IAM instance profile | `AmazonSSMManagedInstanceCore` — attach at launch |
| Outbound 443 | Already available via the Internet Gateway — **no VPC endpoints needed**, saving ~$22/month |
| Staff-side CLI | AWS CLI v2 plus the Session Manager plugin |

Because the VMs sit in **public subnets with an Internet Gateway**, the agent reaches SSM directly. In a private-subnet design this would need three interface VPC endpoints at roughly $7.30 each per month — another cost the public-subnet decision avoids.

### The three things staff actually need to do

**1. A shell on a box** — replaces `ssh root@…`:
```bash
aws ssm start-session --target i-0abc123def456
```

**2. Reach a database from a laptop** — replaces the SSH tunnel, and still opens no port:
```bash
aws ssm start-session \
  --target i-0abc123def456 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5432"],"localPortNumber":["15432"]}'
# then point DBeaver / psql at localhost:15432
```

**3. Copy a file** — SCP and `rsync` still work, tunnelled over the same session, once `ProxyCommand` is configured in `~/.ssh/config`:
```
Host i-* mi-*
  ProxyCommand sh -c "aws ssm start-session --target %h \
    --document-name AWS-StartSSHSession --parameters portNumber=%p"
```
This carries the SSH *protocol* over the SSM channel. **Port 22 stays closed to the internet** — the agent connects to `sshd` on the loopback interface from inside the instance.

### Who gets in, and how it is proved

| Layer | Mechanism |
|---|---|
| Identity | **IAM Identity Center (SSO)** — no long-lived access keys for humans |
| Authorisation | IAM policy on `ssm:StartSession`, scoped by instance tag (e.g. `Environment=production`) |
| Least privilege | Read-only staff get session access to non-production only; production shells restricted to named engineers |
| Audit | Session Manager logs **full session transcripts** to S3 or CloudWatch Logs; `StartSession` calls appear in CloudTrail |
| Revocation | Remove the IAM permission — effective immediately, on every instance at once |

Session logging is the part worth enabling on day one: it is the only administrative audit trail this environment has ever had, and it costs a few cents a month.

### Break-glass

If the SSM Agent itself fails, Session Manager cannot reach the box. Two fallbacks, in order:

| Fallback | Requires | Notes |
|---|---|---|
| **EC2 Serial Console** | A password set on a local OS user | Works with **no networking at all** — the genuine last resort |
| Temporary SG rule for port 22 | Console access to edit the security group | Add, use, **remove**. Never leave it standing. |

Set the serial-console password during instance build and store it in Parameter Store as a `SecureString`. Discovering it was never set is a problem only ever discovered at the worst moment.

### Private DNS — split-horizon

A **Route53 private hosted zone containing the same public hostnames**, resolving to private IPs:

```
Public (Cloudflare)                 Private (Route53, VPC-only)
  api.<domain>    → 54.x.x.x    |     api.<domain>    → 10.0.1.20
  leads.<domain>  → 54.x.x.x    |     leads.<domain>  → 10.0.1.30
  chat.<domain>   → 54.x.x.x    |     chat.<domain>   → 10.0.1.30
```

**Why the names must match:** TLS validates the hostname in the URL, not the IP behind it. Identical names mean certificates **still validate** over private IPs — so `XTIME_BASE_URL`, `INVENTORY_API_URL` and `FAQ_API_URL` work unchanged, with no application code touched.

Inventing internal names such as `leads.internal` would break every certificate and force a private CA or disabled verification — the latter unacceptable for traffic carrying customer leads.

**Cost: $0.50/month.** `/etc/hosts` on each VM is a free alternative, adequate at three machines but manual if an instance is replaced.

---

## 6. Domain scheme — new production names

The current hostnames all contain "staging" while serving production. Moving to unambiguous names.

### Proposed — **for confirmation**

| Service | Proposed hostname | Today |
|---|---|---|
| Backend API | `api.dealerpulse.cloud` | `nissan.staging.flutenwebframework.xyz` |
| `leads_backend` | `leads.dealerpulse.cloud` | `west-cost.ingeg.staging.flutenwebframework.xyz` |
| `chat_backend` | `chat.dealerpulse.cloud` | `chat.staging.flutenwebframework.xyz` |
| Admin dashboard | `admin.dealerpulse.cloud` | *(none)* |
| Tenant site — Puente Hills | `phn.dealerpulse.cloud` | *(none)* |

`dealerpulse.cloud` is inferred from `COMPANY_EMAIL` and `EMAIL_FROM` in the current configuration. **Confirm the registered domain before proceeding.**

### 🔴 What renaming forces

Renaming is the right call, but it is not free:

| Change | Impact |
|---|---|
| `CSRF_TRUSTED_ORIGINS`, `CORS_ALLOWED_ORIGINS`, `CORS_ORIGINS` | Configuration edit on all three backends |
| **Both frontends must be rebuilt** | API URLs are baked into the images at build time — `website_frontend` passes **no environment variables at all** |
| New TLS certificates | Issue via DNS-01 before cutover |
| Tenant `Domain` row | `nisanweb-backend` resolves tenants by hostname from the database — **a row must exist for the new tenant hostname or the site will not resolve** |
| **Cox / xtime callback registrations** | If either has our hostname registered, it must be updated. **Silent lead loss if missed.** |
| Route53 private zone | Uses the new names |

> **Recommendation: run both hostnames in parallel.** Keep the existing names resolving alongside the new ones for two to four weeks after cutover. Costs nothing, and removes the risk of an unknown third party still calling an old address.

---

## 7. Admin dashboard hosting

**Decided: container on the Integrations VM.**

It is genuinely a static SPA and consumes 4.6 MiB, so it costs nothing to co-locate, and it keeps the cutover to one deployment pattern rather than two. It sits with the integration services rather than the tenant frontends so that a tenant-site problem cannot take administrative access down with it.

S3 + CloudFront stays available as a fast-follow if independence from the VM becomes worth having:

| | **Container on Integrations VM** *(chosen)* | **S3 + CloudFront** |
|---|---|---|
| Cost | $0 (shares the VM) | ~$0.02/mo |
| Survives VM outage | ❌ No | ✅ Yes |
| TLS | certbot — same as every other service | ACM, free, auto-renewing |
| Deploy | Image pull + container restart | `aws s3 sync` — seconds, no restart |
| New pattern to build | ❌ No — identical to today | ✅ Yes |
| Best when | Minimising change during cutover | Production-stable, want independence |

Reversible in either direction; it is a small enough component that the decision can be revisited without disruption.

---

## 8. Data layer and backups

| Service | Database | Location | Size |
|---|---|---|---|
| `nisanweb-backend` | `nisan_website` — PostgreSQL 15 | Container, Backend VM | 27 MB |
| `leads_backend` | `leads_db` — PostgreSQL 16 | Container, Integrations VM | 8 MB |
| `chat_backend` | `dealerpulse` — PostgreSQL 16 | Container, Integrations VM | 11 MB |
| Cache / broker | Redis 7 | Container, Backend VM | Regenerable |
| Media | Local disk | Backend VM | 220 MB |

All seeded from DigitalOcean dumps at cutover.

### Backups — still required

"Invalidates daily" is true of the **HomeNet inventory cache**, which rebuilds hourly. It is not true of everything else:

| Data | Regenerable? |
|---|---|
| HomeNet inventory (Redis) | ✅ Rebuilds hourly — **no backup needed** |
| Tenant config and `Domain` rows | ❌ No |
| **`leads_db` — customer leads** | ❌ **No. Business records.** |
| **`dealerpulse` — chat history (encrypted)** | ❌ No |

| Layer | Detail | Cost |
|---|---|---|
| Database dumps every 6 hours | All three → S3, 30-day retention | $0.20 |
| EBS snapshots, daily | Per VM, 7 retained | $2.00 |
| Weekly automated restore test | Restore to a scratch container, compare row counts | $0.00 |
| 🔴 **`FIELD_ENCRYPTION_KEY` in Parameter Store** | Without it, `dealerpulse` backups are permanently unreadable | $0.00 |

---

## 9. Entry point — nginx now, ALB later

Each VM runs **nginx + certbot**, as today. The migration runbook carries over unchanged.

| | **A. nginx per VM** *(chosen)* | **B. ALB fronting all three** | **C. ALB for frontends only** |
|---|---|---|---|
| Cost | **$0** | ~$22/mo | ~$22/mo |
| TLS certificates | certbot × 3, self-renewing | **ACM — free, auto-renews, cannot expire** | Split: ACM + certbot |
| Cert failure modes | 3 renewals to monitor; Let's Encrypt rate limits apply | **None** | Both, different schedules |
| Health checks | ❌ None | ✅ Unhealthy targets removed | ✅ Frontend only |
| Per-tenant routing | nginx `server_name` blocks | ✅ Native host rules | ✅ Native |
| Adding a tenant | Edit nginx, request a certificate | ✅ Add a listener rule | ✅ Add a listener rule |
| Path to redundancy | Rebuild the entry layer | ✅ **Add to a target group** | Partial |
| Access logs / metrics | Per-box nginx logs | ✅ S3 + CloudWatch | Partial |
| WAF later | Not possible | ✅ Attach directly | Frontend only |
| Extra hop | No | ~1–3 ms | ~1–3 ms |
| WebSocket | ✅ Config already proven | ✅ Needs target-group setup | ✅ |
| Matches today | ✅ **Runbook carries over** | ❌ New component | ❌ Two patterns |

**Chosen: A** — free, proven in this stack, no unfamiliar component during cutover.

**Revisit at the second tenant**, when listener rules beat hand-edited nginx and three certbot installations become three things that can silently stop renewing.

---

## 10. Availability

| Failure | Outcome |
|---|---|
| Container crashes | ✅ `restart: unless-stopped` recovers in seconds |
| VM reboot (patching) | ✅ Docker enabled on boot; containers return |
| VM hardware degradation | 🟡 **EC2 Auto Recovery** replaces it, keeping IP and disks. **Free; enable on all three.** |
| VM instance failure | 🔴 That service down until rebuilt (~20–30 min from snapshot) |
| Availability Zone failure | 🔴 Everything down — single AZ by design |
| Bad deploy | 🟡 Health-gated pipeline rolls back automatically |
| Database corruption | 🟡 Restore from the 6-hourly dump |

**Blast radius is isolated** — the main gain over one shared box. A frontend problem cannot take down the API; an integrations problem cannot take down the tenant site.

Enable on all three, free: **EC2 Auto Recovery**, **termination protection**, **`DeleteOnTermination=false`** on data volumes.

---

## 11. Cost

| Item | Spec | `t3` (x86) | `t4g` (Graviton) |
|---|---|---|---|
| Frontend VM | **`small`** | **15.18** | **12.26** |
| Backend VM | `medium` | 30.37 | 24.53 |
| Integrations VM | `medium` | 30.37 | 24.53 |
| EBS | 140 GB gp3 | 11.20 | 11.20 |
| Elastic IPs | 3, attached | 0.00 | 0.00 |
| CloudFront | Within free tier | 0.00 | 0.00 |
| S3 | Backups | 0.50 | 0.50 |
| ECR | Images | 0.50 | 0.50 |
| Route53 private zone | 1 | 0.50 | 0.50 |
| EBS snapshots | Daily, 7 retained | 2.00 | 2.00 |
| CloudWatch | 3 VMs + alarms | 5.00 | 5.00 |
| Data transfer | Within free allowances | 0.00 | 0.00 |
| NAT Gateway | **Not used** | 0.00 | 0.00 |
| ALB / Auto Scaling | **Not used** — see §12 | 0.00 | 0.00 |
| **Total** | | **$95.62** | **$81.02** |

| Scenario | Monthly |
|---|---|
| **As approved, at launch** | **$96** |
| + 1-year Savings Plan | ~$73 |
| Graviton (fast-follow) | $81 |
| **Graviton + Savings Plan** | **~$63** |
| *Current DigitalOcean (two droplets)* | *~$56* |
| *If the Frontend VM were also `t3.medium`* | *$111* |

**Landing point: ~$96/month at launch, ~$63/month once optimised.** Roughly **$7–40/month more than today**, for isolated blast radius, backups, monitoring, and a CDN — none of which exist now.

Sizing the Frontend VM at `t3.small` rather than `t3.medium` takes **$15.19/month** off the launch figure and costs no CPU headroom, since both share the same 0.4 vCPU baseline.

### Levers

| Lever | Saving | Trade-off |
|---|---|---|
| Graviton (`t4g`) | **−$14.60** | Every image rebuilt and verified for ARM64 |
| 1-year Compute Savings Plan | **−$23** | 12-month commitment; buy after 30 days of real usage |
| Post-migration downscale review | TBD | Requires a month of CloudWatch data first — §4 |
| Merge Integrations into Backend VM | −$30 | Loses blast-radius isolation; needs a larger instance, so the net saving is smaller |
| `/etc/hosts` instead of Route53 | −$0.50 | Manual updates on instance replacement |

### Known future increase

| Trigger | Change | Cost |
|---|---|---|
| **3rd tenant onboarded** | Frontend VM `t3.small` → `t3.medium` | **+$15.19/month** |

---

## 12. Why no Auto Scaling Group and no load balancer

**The blocker is shared state, not cost.** Three components cannot be duplicated as they stand today, so adding instances would produce incorrect behaviour rather than more capacity.

| Component | Why a second instance breaks it |
|---|---|
| **Celery beat** | It is a scheduler and must be a singleton. A second copy fires every hourly inventory sync twice — **double the HomeNet API calls and duplicate leads.** |
| **Media files** | Stored on the Backend VM's local disk. A second instance would not see uploads written by the first. Needs shared storage (**EFS or S3**) before scaling is even correct. |
| **PostgreSQL and Redis** | Run as containers on the Backend VM with local volumes. They would have to move to managed services (**RDS / ElastiCache**) before there is anything to scale onto. |

A fourth reason applies specifically to the frontends: **they are not interchangeable.** A load balancer distributes traffic across identical copies of one application; ours is one container per dealership, tenant-isolated by design, so each hostname has exactly one correct destination. There is nothing to balance between them.

**Cost reinforces the conclusion but does not drive it.** An ALB is ~$22/month before traffic charges, and an Auto Scaling Group is only meaningful at a minimum of two healthy instances — roughly +$30/month per tier. Together that approaches the cost of the entire fleet, to solve a problem the data does not show: **CPU has been flat at 7–9% for two weeks with no daily peak**, so an ASG would have no signal to react to and would sit permanently at minimum capacity.

**Blast-radius isolation — the usual reason to reach for a load balancer — is already achieved** by the three-way split. A frontend problem cannot take the API down; an integrations failure cannot take down the tenant site.

### Not a one-way door

Adding an ALB later is a DNS change and a target group — no redesign, no downtime. The prerequisites, in order:

| # | Prerequisite | Unblocks |
|---|---|---|
| 1 | Move media to EFS or S3 | Horizontal scaling of the backend becomes *correct* |
| 2 | Move PostgreSQL to RDS, Redis to ElastiCache | Backend instances become stateless |
| 3 | Split beat into its own single-instance service | Workers become freely replicable |
| 4 | Add the ALB | Health checks, ACM certificates, WAF, per-tenant listener rules |

Steps 1–3 are engineering work that must happen regardless before any autoscaling is possible. **Revisit at the second tenant**, alongside the nginx-vs-ALB decision in §9.

---

## 13. Confirmations needed to mark this FINAL

| # | Item | Why it matters |
|---|---|---|
| 1 | 🔴 **Confirm the registered domain** — is `dealerpulse.cloud` correct and under our control? | Every hostname in §6 depends on it |
| 2 | 🔴 **Approve the §6 hostname scheme** | Drives certificates, CORS, frontend rebuilds, and the private zone |
| 3 | 🔴 **Do Cox or xtime have our hostname registered for callbacks?** | Renaming without updating them causes **silent lead loss** |
| 4 | 🟠 **`website_frontend` passes no environment configuration** — everything is baked in | New domains force a rebuild; per-tenant isolation will need a config mechanism |
| 5 | 🟠 **Pull the 14-day CPU/memory graph from `Combined`** | Frontend VM at `t3.small` is the one size not yet grounded in per-service data — §4 |
| 6 | 🟡 **Who gets production shell access?** | Session Manager is IAM-scoped; the named list has to exist before it can be written — §5a |
| 7 | 🟡 **Where should alerts go?** | Email, SMS, Slack — monitoring is inert without a destination |
| 8 | 🟡 **Are the tenant site's API calls server-side or client-side?** | Determines whether the API's public exposure can be narrowed later |

### Settled

| Item | Decision |
|---|---|
| Region | **`us-west-2`** (Oregon) — §5 |
| Availability Zones | **Single**, deliberately — §5 |
| Instance sizes | `t3.small` + 2 × `t3.medium` — §4 |
| Entry point | nginx per VM, **no ALB** — §9, §12 |
| Scaling | **No Auto Scaling Group** — blocked by shared state, §12 |
| Staff access | **SSM Session Manager, port 22 closed** — §5a |
| Admin dashboard | Container on the Integrations VM — §7 |

**Deferred by decision:** staging environment (production first), Graviton migration (fast-follow), admin dashboard to S3 (optional, §7), ALB adoption (at the second tenant), horizontal scaling prerequisites (§12).
