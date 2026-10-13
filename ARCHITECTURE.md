# ARCHITECTURE — how the platform works (the primary reference)

**Operating stance: the system works and the business is happy with it. The goal is to keep it running as it is.**
This document describes the architecture as built. It is not a plan. Improvements listed elsewhere (`STATUS.md`, `Documentations/TODO.md`)
are optional and only happen when someone asks for them. Provenance is `[doc]` (our records, last full review 2026-10-13) unless marked otherwise.

---

## 1. Systems at a glance

| System | Where | Purpose | Skill |
|---|---|---|---|
| **Dealerships** platform | AWS `409289617504`, `us-west-2` | Multi-tenant Nissan dealership websites + CMS + leads + chatbot + admin | `dealerships-architecture` |
| Edge | Cloudflare (`callingyounow.us` ours; `puentehillsnissan.com` third-party account) | DNS, TLS, cache, WAF, country allow-list | `dealerships-edge-cloudflare` |
| Delivery | Bitbucket Pipelines -> ECR -> SSM | Build and deploy | `dealerships-deploy` |
| Observability | CloudWatch + SNS -> Slack; Uptime Kuma | Alarms, dashboards, uptime | `dealerships-monitoring` |
| Team VPN + Kuma box | AWS, same account, isolated subnet/SG | US egress for the team; uptime monitoring | `team-vpn-and-uptime` |
| **DealerPulse** | DigitalOcean droplet + DO Managed Postgres | Separate product (calls / voice agents / SMS) | `dealerpulse-digitalocean` |
| Legacy hosts `prod`, `combined` | DigitalOcean | Pre-migration Dealerships stack | `dealerpulse-digitalocean` |
| Rented RDP box | Third-party Windows host | Browsing from a US IP | `team-vpn-and-uptime` |

**Naming:** the AWS project is "Dealerships", but every AWS resource is named `dealerpulse-*`. That is correct and permanent.

---

## 2. Dealerships: tenants and applications

**Tenants (rooftops):** Puente Hills Nissan (`www.puentehillsnissan.com`, the largest), Surf City Nissan, Corona Nissan (migrated, per the user
on 2026-10-13), Nissan of San Bernardino. One CMS `Dealership` row per tenant. Tenancy is resolved by the `?dealership_id=` query parameter
first, then by the `Domain` table via the Host header.

| App (repo) | Role | Runs on |
|---|---|---|
| `ocean` (ECR `nisanweb-backend`) | Django CMS / inventory API (gunicorn :9000) + Celery worker + Celery beat | nodeA, nodeB |
| `website_frontend` (ECR `website-frontend`) | Next.js site. **One container per tenant**; the tenant is baked in at build time (`NEXT_PUBLIC_DEALERSHIP_ID` and other `NEXT_PUBLIC_*`) | nodeA, nodeB |
| `integrations_service` (ECR `leads-backend`) | Lead delivery to VinSolutions / Cox (:8129) | integration |
| `chat_back` (ECR `chat-backend`) | FastAPI chatbot, WebSocket (:9002), LLM via OpenRouter; Postgres with pgvector | integration |
| `framework_frontend` (ECR `admin-dashboard`) | Admin dashboard (:3003; container named `framework-frontend`) | integration |

Source: Bitbucket workspace `nxpt`. Images are built once in the pipeline and pulled by the nodes.

---

## 3. Request flow

```
Browser
  │ HTTPS
  ▼
Cloudflare  (proxy; SSL mode Full; WAF managed rules; country allow-list US/CA/PK/JP; cache rules)
  │
  ├──► www.puentehillsnissan.com, phn., api., surfcity., corona/SB hosts
  │       ▼
  │    ALB dealerpulse-alb  (HTTPS 443, ACM certs via SNI; SG accepts Cloudflare IP ranges only)
  │       │ weighted forward, no stickiness
  │       ├──► dealerpulse-tg-nodea ──► nodeA nginx :443
  │       └──► dealerpulse-tg-nodeb ──► nodeB nginx :443
  │                                      │ server_name dispatch (every node has every vhost + cert)
  │                     ┌────────────────┴───────────────────┐
  │                     ▼                                    ▼
  │      website_frontend_<tenant> 127.0.0.1:300x     ocean web 127.0.0.1:9000
  │      (SSR calls ocean's /api/* with API crypto)    + celery worker, celery beat, Redis (per node)
  │                                                        │
  │                                                        ▼
  │                                     ocean-shared-postgres (integration VM :5432, private)
  │
  └──► admin. / chat. / leads.callingyounow.us  (Cloudflare-proxied straight to the integration VM's nginx; not behind the ALB)
          ├─► framework-frontend :3003
          ├─► chat_back :9002 (WebSocket) ─► chat_back-postgres (pgvector) ─► OpenRouter
          └─► leads_backend :8129 ─► leads_backend-postgres ─► VinSolutions / Cox
```

---

## 4. Components in detail

### 4.1 Edge (Cloudflare)
Our zone `callingyounow.us`; Puente Hills is in the dealer group's own Cloudflare account (we have access; coordinate changes).
SSL mode **Full** (origin certs need not be publicly trusted). HTML edge cache honouring the Next.js ISR headers, excluding `/api/*`, `/_next/*`
and RSC requests. 30-day static-asset cache (matches by file extension). `/_next/image` cached. A response rule strips `Set-Cookie`, which is
why ALB stickiness cannot work and is off. Full purge after every frontend deploy. Details: skill `dealerships-edge-cloudflare`.

### 4.2 Load balancer
`dealerpulse-alb`, listener 443 default action = weighted forward to two per-node target groups (weights: verify; docs say 35/65 since
2026-09-14 and 50/50 in HANDOVER). Health check `/` with matcher `200-499` (no dedicated health endpoint exists). The detached
`dealerpulse-tg-nginx` is kept as an instant-rollback target group.

### 4.3 Web nodes (nodeA us-west-2a, nodeB us-west-2b, t3.large)
Identical. Host nginx terminates TLS (Let's Encrypt or self-signed per host; renewed by `certbot.timer`), applies `limit_conn 300`
(exempting `?_rsc=` prefetches, status 429), raised fd limits, and proxies by `server_name` to loopback-only containers:
`nisanwebsite-web-1` (gunicorn :9000), `-worker-1`, `-beat-1`, a Redis, and one `website_frontend*` container per tenant
(Puente Hills :3000, Surf City :3001; Corona and San Bernardino ports: read from the vhosts).
**Redis is per node** by design. It holds content-keyed caches only (HomeNet inventory per tenant: db2 Surf City, db6 Puente Hills, db11 Corona,
db12 San Bernardino). Sessions are DB-backed and auth is stateless JWT, so either node can serve any request.

### 4.4 Integration VM (t3.medium, 3.8 GB)
Runs `chat_back`, `integrations_service`, `framework-frontend`, and four data stores: `ocean-shared-postgres` (postgres:15, role `ocean_app`,
DB `nisan_website`, `max_connections` 150), `chat_back-postgres` (pgvector), `leads_backend-postgres`, `website-shared-redis`.
**This is the single point of failure for all tenants** (ocean's database lives here) and the most memory-constrained machine.
Its 5432/6379 accept only the web nodes' SG.

### 4.5 Backend behaviour worth knowing
- **API encryption:** with `API_CRYPTO_MODE=required`, every `/api/*` response is AES-256-GCM encrypted per response. Unsigned clients get
  `428 crypto_key_required`. The frontend bootstraps a crypto session against `/api/crypto/public-key/`. Consequence: API responses are never
  edge-cacheable, and you cannot probe the API with plain curl.
- **Scheduled work (Celery beat, runs on both nodes):** HomeNet inventory warm (twice daily) with a 2-hour cache TTL; JD Power rebates;
  Podium review sync every 2 h at :15. Inventory comes from HomeNet (SOAP + image CDN `content.homenetiol.com`).
- **Build-time data:** the Next.js build fetches site config from the live backend; if the backend is unreachable during a build, fallback
  branding is baked in ("Surf City Nissan" is the tell).
- Django `TIME_ZONE` is `Asia/Karachi` (deliberate). Container logs show +0500; nginx and CloudWatch use UTC.

### 4.6 Security model
- Origin lockdown: nodes accept 80/443 only from the ALB SG; the ALB and the integration VM accept 80/443 only from Cloudflare's managed prefix lists.
  Direct IP access times out by design.
- No SSH on production: SSM Session Manager only (`dealerpulse-ec2-ssm-role`). EBS encrypted by default. S3 media via instance role (no static keys).
- Secrets: SSM Parameter Store `/dealerpulse/shared/*` and per-service `.env` files on the hosts (never in docs).
- WAF managed ruleset (Block) and the country allow-list are zone-wide on `callingyounow.us`.

### 4.7 Delivery
Bitbucket Pipelines per branch (`main-migrated` = Puente Hills and shared services; `main-surfcity`; `main-corona`; `main-sanbernardino`) ->
build image -> ECR (`<sha>`, `latest`, `latest_<tenant>`) -> **one** SSM command to both nodes running `/opt/dealerpulse/deploy.sh <service> <branch>`
-> Cloudflare purge. Details: skill `dealerships-deploy`.

### 4.8 Observability and backups
CloudWatch agent (memory/disk/swap), log groups `/dealerpulse/*`, dashboards `DealerPulse-Fleet-Overview` / `-Logs` / `-Per-VM`, 7 alarms ->
SNS `dealerpulse-alerts` -> AWS Chatbot -> Slack `#aws-alerts-dealerpulse`. Uptime Kuma (`uptime.callingyounow.us`) on the VPN box.
Backups: DLM EBS snapshots targeted by the `Project=dealerpulse` tag; S3 `dealerpulse-backups-409289617504` (versioned, encrypted).

---

## 5. Invariants: do not change these (they hold the system together)

1. Resource names `dealerpulse-*`, the `Project=dealerpulse` tag, `/opt/dealerpulse/*` paths.
2. Both nodes always run the same image; deploys hit both nodes in one SSM call, then purge Cloudflare.
3. Every node has a vhost and a cert for every hostname the ALB can send it.
4. A node carries only `dealerpulse-sg-merged`; origin stays locked to Cloudflare -> ALB.
5. ALB stickiness off; Cloudflare `strip_set_cookie` and the RSC-header cache exclusion stay.
6. App containers bind 127.0.0.1 only; the ALB targets nginx :443, never app ports.
7. Health-check matcher stays `200-499` until a real health endpoint exists.
8. Zone-wide "Cache Everything [Template]" rule stays disabled.
9. Redis per node; TIME_ZONE `Asia/Karachi`; alarm thresholds as calibrated.
10. `.env` changes are applied with `docker compose up -d --no-deps <svc>`; local override files on hosts (e.g. ocean's `docker-compose.override.yml`) must survive deploys.

## 6. Accepted trade-offs (known, deliberately left as they are)
- Shared Postgres on the integration VM is a single point of failure.
- Frontend deploys give a short 502 window; no blue/green on the nodes.
- The country allow-list could block a vendor callback from outside US/CA/PK/JP.
- Celery beat runs on both nodes (duplicate schedules).
- Kuma runs in the same AWS account/region it monitors.
- VPN box is a `t4g.micro` (about 11 Mbps through the tunnel).
