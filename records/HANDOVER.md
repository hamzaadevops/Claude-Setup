# DevOps Handover — Dealerships (AWS) and adjacent systems

---

## 0. Read this first (the rules that prevent most damage)

1. **The project is called "Dealerships", but every AWS resource is still named `dealerpulse-*`. Do not rename anything.** Renaming would break live infrastructure. **DealerPulse is a different, separate project** on DigitalOcean (§6.3). When someone says "DealerPulse", work out which one they mean before acting.
2. **Verify before you state.** Don't report an inference as a fact. Run the command, read the file, then say what you saw. Mark anything you couldn't check as an assumption. Several past reports were wrong because they skipped this (e.g. the "exposed Postgres" that turned out not to be the production DB). The owner relays your reports to a CTO and a senior developer.

---

## 1. What this system is

A **multi-tenant Nissan dealership website platform**, migrated from DigitalOcean to AWS in Aug–Sep 2026. Four rooftops (tenants):

| Tenant | Public host | Note on Migration |
|---|---|---|
| Puente Hills Nissan | `www.puentehillsnissan.com` (third-party DNS zone) | First and largest; ~99% of traffic historically |
| Surf City Nissan | `www.surfcitynissan.com` at time of last audit; launch domain separate | Own pipeline branch `main-surfcity` |
| Corona Nissan | container `website_frontend_corona` running since ~2026-09-26 | Update the Variables in the deployment NEXT_PUBLIC_IMAGE_ALLOWED_DOMAINS/NEXT_PUBLIC_SITE_URL and cutover the Domains to the ALB URL |
| Nissan of San Bernardino | container `website_frontend_sanbernardino`, up since ~2026-10-03 | Update the Variables in the deployment NEXT_PUBLIC_IMAGE_ALLOWED_DOMAINS/NEXT_PUBLIC_SITE_URL and cutover the Domains to the ALB URL |

Working domain for our own hostnames: **`callingyounow.us`** (our Cloudflare account).

Five applications:

| App (repo) | Role | Runs on |
|---|---|---|
| `ocean` (`nisanweb-backend`) | Django backend + Celery worker + Celery beat + Redis. The CMS/inventory API. | nodeA, nodeB |
| `website_frontend` | Next.js site. **One container per tenant** (tenant is fixed at build time via `NEXT_PUBLIC_DEALERSHIP_ID`) | nodeA, nodeB |
| `integrations_service` (`leads_backend`) | Lead delivery to Cox/VinSolutions etc. | integration |
| `chat_back` (`chat_backend`) | FastAPI chatbot, WebSocket, calls OpenRouter | integration |
| `framework_frontend` | Admin dashboard (container is misnamed `framework-frontend`) | integration |

Source is in Bitbucket (workspace repos include `nxpt/ocean`). Images are built by Bitbucket Pipelines and pushed to **ECR**; nodes pull from ECR.

---

## 2. Architecture in one picture

```
Browser ──▶ Cloudflare (proxy, cache rules, WAF country rules)
              │
              ▼
        ALB  dealerpulse-alb   (SG sg-alb: Cloudflare IPs only)
         │ weighted 50 / 50
         ├──▶ dealerpulse-tg-nodea ─▶ nodeA nginx :443 ─┐
         └──▶ dealerpulse-tg-nodeb ─▶ nodeB nginx :443 ─┤
                                                         │ nginx dispatches by server_name
                              ┌──────────────────────────┴────────────────────────┐
                              ▼                                                   ▼
        website_frontend(_surfcity/_corona/_sanbernardino) :3000-300x      ocean web (gunicorn) :9000
                                                                           + celery worker, beat, redis (per node)
                                                                                  │
                                                          shared Postgres (ocean-shared-postgres) on integration :5432

integration VM (not behind the ALB; Cloudflare-proxied nginx direct):
   admin.* → framework-frontend :3003    chat.* → chat_back :9002 (WS)    leads.* → leads_backend :8129
   containers: chat_back-postgres (pgvector), leads_backend-postgres, ocean-shared-postgres, website-shared-redis
```

Key facts that are easy to get wrong:

- **The ALB forwards to nginx on :443 of each node, not to app ports.** App containers bind `127.0.0.1` only. nginx does hostname routing, so **every node must have a vhost and a valid cert for every hostname the ALB can send it.**
- **Two certs per hostname:** an ACM cert on the ALB, and a separate Let's Encrypt cert on each node (ACM certs can't be exported). Renewal is `certbot.timer`; it was once found silently broken, so watch expiry.
- **Postgres for ocean is shared** and lives on the integration VM. It is the single point of failure for all four tenants.
- **ALB stickiness is OFF and must stay off.** It was never working (Cloudflare strips the `AWSALB` cookie) and nothing needs it.
- **Origin lockdown:** nodes accept 80/443 only from `sg-alb`; `sg-alb` only from Cloudflare prefix lists. Direct access to a node IP from the internet *times out by design*. Use SSM, not SSH, to reach nodes.

---

## 3. Inventory (AWS account `409289617504`, region `us-west-2`)

| Resource | ID | Notes |
|---|---|---|
| **nodeA** | `i-061291ea974c4ea1b` | us-west-2a, `10.0.1.94`, EIP `184.32.92.25`. `t3.large` as of 2026-10-03 [log] |
| **nodeB** | `i-0c982c44f93bfbc0a` | us-west-2b, `10.0.2.129`, EIP `35.95.214.123`. `t3.large` |
| **integration** | `i-03efb82c808863f84` | us-west-2a, `10.0.1.92`, EIP `52.12.241.229`. `t3.medium`, 3.8 GB RAM — the most constrained box |
| team VPN + uptime box | `i-0ad5d9743f6c95721` | `t4g.micro`, EIP `44.225.91.181`, **not production Dealerships** (§6.1) |
| VPC | `vpc-04362594fced3c6f0` | `10.0.0.0/16`; subnets `subnet-067d90425d81116e3` (2a), `subnet-02464b852778c1e06` (2b) |
| SG: ALB | `sg-034a06fe048939fc5` | Cloudflare prefix lists `pl-0dc48316ba9fa95bd` (v4), `pl-0a7981fd8cec1fa9a` (v6) |
| SG: nodes | `sg-0587ebfd9dd3a52a7` (`dealerpulse-sg-merged`) | 80/443 from `sg-alb` only. **A node must carry only this SG** — a stale second SG once silently re-opened it |
| SG: integration | `sg-097c63c5851f32550` | 80/443 Cloudflare only; 5432/6379 from `sg-merged` only |
| ALB | `dealerpulse-alb` | DNS `dealerpulse-alb-158980700.us-west-2.elb.amazonaws.com`; target groups `dealerpulse-tg-nodea` / `-nodeb`. (`dealerpulse-tg-nginx` is detached/unused — instant rollback path) |
| ECR repos | `nisanweb-backend`, `leads-backend`, `chat-backend`, `website-frontend`, `admin-dashboard` | Lifecycle policies applied 2026-10-03 (JSON in `Migration/ecr-lifecycle/`) |
| S3 | `dealerpulse-media-409289617504`, `dealerpulse-backups-409289617504` | Media is read/written via the EC2 role, no static keys |
| Alerts | SNS `dealerpulse-alerts` → AWS Chatbot → Slack `#aws-alerts-dealerpulse` (workspace "Nexrupt Tech") | Don't recreate the Chatbot config casually; it took a delete+recreate to make it work once |

Cloudflare: zone `callingyounow.us` (Free plan; Zone ID `283d6090889e4fdd64e23e6790cfa50a`). The `puentehillsnissan.com` zone belongs to a **third party's account** (zone ID `d68d738c1d15ec0cd770a9533e16d5ae`); changes there need coordination. Every Cloudflare change made and the symptom each could cause is in the memory note `project_dealerships_cloudflare_config` — read it before debugging 5xx/522/525/stale-asset reports.

### How to reach things

- **Nodes / integration:** SSM only. `aws ssm start-session --target <id>` for a shell; `aws ssm send-command --document-name AWS-RunShellScript` for scripted checks. There is no SSH key on them.
- **SSH config hosts** (in `~/.ssh/config`): `combined`, `prod` (legacy DigitalOcean), `dealerpulse` (DigitalOcean droplet, §6.3), `node_vpn`, `kuma`, `wg-ui`, `vpn-box`, `kuma-vpn`, `wg-ui-vpn`. Keys: `~/.ssh/team-vpn`, `~/.ssh/digitalocean`.

---

## 4. Deploying

**Normal path:** merge to the right branch in Bitbucket → pipeline builds the image → pushes to ECR → deploys by one `aws ssm send-command` to **both** nodes at once → then purges Cloudflare cache.

| Branch | Deploys |
|---|---|
| `main-migrated` | Puente Hills (and shared services) — **the production branch** |
| `main-surfcity` | Surf City — separate pipeline stream. |
| `main-corona` | Corona Nissan — separate pipeline stream |
| `main-sanbernardino` | Nissan Of SB — separate pipeline stream. |

On the nodes: `/opt/dealerpulse/deploy.sh <service> <branch>`. 
`ocean`, `integrations_service`, `chat_back` use `docker compose`;
`website_frontend*` and `framework_frontend` use plain `docker pull` / `docker rm -f` / `docker run`.

Rules learned the hard way:

- **A new `.env` variable needs `docker compose up -d --no-deps`, never a plain `restart`.** `deploy.sh` never touches `.env`, so env edits persist across deploys.
- **Stopping a Bitbucket run does not cancel an SSM command already dispatched** — it keeps running on the node.
- **Frontend deploys cause a brief 502 window**. Bundle changes; avoid deploying during peak. A proper fix (blue/green per node, flip the nginx upstream) is not built because of cost complexity.
- **Next.js rebuild trap:** use `docker build --pull --no-cache` when proving a content fix; a cached `npm run build` layer has silently reused stale output before.

---

## 5. Monitoring and alerts

- **CloudWatch alarms** (7 as of 10-05, all `OK`): ALB 5xx (gated-rate, scoped to the LoadBalancer), per-node target health, CPU credits, `dealerpulse-alb-latency-p99`, nginx fd-exhaustion (verify it exists — it was deleted once and the metric filter survived). Thresholds were deliberately loosened 2026-09-14 and calibrated on measured distributions. **Don't retune them to silence noise** — the latency alarm correctly reported a real cache stampede; it's been quiet since that was fixed.
- **Uptime Kuma** on the VPN box (`uptime.callingyounow.us`, nginx-fronted; setup in `Monitoring/UPTIME_MONITORING_SETUP.md`, checklist in `MONITOR_CHECKLIST.md`). 16 monitors at last check. Keyword checks use each rooftop's **street address** (Puente Hills `17320 Gale Ave`, Surf City `17331 Beach Blvd`), *not* its name, because the broken-build fallback text contains the name. Kuma runs in the same account/region as what it watches — pair it with a free external checker (not yet confirmed done).
- **Known blind spots** (nothing alarms on these; each has already caused a real incident):
  1. SSR returning HTTP 200 with no data (the `428` incident).
  2. Chatbot answering "temporarily unavailable" to everyone (OpenRouter credits).
  3. Memory/swap on integration — no alarm yet (TODO item 1).
- **Daily routine** (read-only, ~15 min): alarm states; ALB 5xx and target health; `docker ps` restart counts and `free -m` on all three VMs; `428` count on `nisanwebsite-web-1` over the last hour; integration swap; cert expiry; CloudWatch dashboards over a short window. Previous sweeps are good templates: `MIGRATION_HISTORY.md` entries 2026-09-25, 10-01, 10-05.

---

## 6. Adjacent systems you will also be asked about

### 6.1 Team VPN (WireGuard via wg-easy)
Purpose: team in Pakistan needs a US exit IP because dealership sites behind Cloudflare are removing Pakistan from allow-lists. Box: `i-0ad5d9743f6c95721`, EIP **`44.225.91.181`** (an older recorded EIP is gone), `t4g.micro`, SG `team-vpn-sg` `sg-020165aeddafe5322`, key `~/.ssh/team-vpn`.

### 6.2 Fluten RDP box
Rented US Windows RDP `93.127.140.109`, RDP port **10025** (not 3389), SSH on 22. Network is excellent; **CPU is ~27× slower than a laptop** (1 core, 2.8 GB RAM, host contention). Slow browsing there is a CPU problem, not network, not the site, not our origin (all measured). Real fix is a bigger box (≥4 vCPU, ≥8 GB). Don't re-diagnose.

### 6.3 DealerPulse (separate project, DigitalOcean)
Not migrated, not ours to change without asking. Droplet `146.190.132.236` (hostname `Surfcity-Live`, 2 vCPU/8 GB, no swap), SSH alias `dealerpulse` — **ask before logging in or probing**. It also hosts the unrelated `callingyounow` product and four dead v1 tenant deployments. DB is a **DigitalOcean Managed Postgres** (`dp2-live-do-user-13151402-0.g.db.ondigitalocean.com:25060`) used as `doadmin`; droplet snapshots are *not* an app-data backup.
- 🔴 **Highest-severity open finding across everything:** the managed Postgres had **Trusted Sources disabled** (reachable from any IP) as of 2026-09-22. Fix = enable Trusted Sources in the DO panel (fast) and stop using `doadmin` (app change). Re-test with a plain TCP connect.
- DNS is at Hostinger; no CDN/WAF. Docs: `Documentations/DealerPulse/` (`ARCHITECTURE.md`, `BACKEND_FIXES.md` with 17 items for the backend team, `INCIDENT_2026-09-16.md`, `MONITORING.md`, scripts in `DealerPulse/scripts/`).

### 6.4 Legacy DigitalOcean `prod` / `combined`
The old Dealerships hosts (SSH aliases `prod`, `combined`) are on the decommission path. Don't build on them.

---

## 7. Quick command reference (read-only unless noted)

```bash
# Who am I / session alive?
aws sts get-caller-identity
# Alarm state
aws cloudwatch describe-alarms --query "MetricAlarms[].[AlarmName,StateValue]" --output table
# Target health
aws elbv2 describe-target-health --target-group-arn <tg-arn>
# Instances
aws ec2 describe-instances --filters "Name=tag:Project,Values=dealerpulse" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PrivateIpAddress]" --output table
# Shell on a node (SSM)
aws ssm start-session --target i-0c982c44f93bfbc0a
# On a node: containers, memory, disk, recent errors
docker ps --format '{{.Names}}\t{{.Status}}'; free -m; df -h /; docker stats --no-stream
# 428 canary (SSR bootstrap failure) — run on a node
sudo grep -c ' 428 ' /var/log/nginx/access.log   # then compare windows; container logs are +0500, nginx is UTC
# Is the origin really locked down? (from outside AWS this should time out)
curl -m 5 -sS https://184.32.92.25/ -k
```
