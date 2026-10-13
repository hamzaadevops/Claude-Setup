# CONTEXT — history and how we got here

Narrative background. For how the system works now, read `ARCHITECTURE.md`. All `[doc]` from `Documentations/Migration/MIGRATION_HISTORY.md`
(the full record), `HANDOVER.md` and saved notes.

## 1. Two projects
| | Dealerships | DealerPulse |
|---|---|---|
| What | Multi-tenant Nissan dealership websites + CMS + leads + chatbot + admin | Separate product (calls, voice agents, SMS) |
| Where | AWS `409289617504` `us-west-2` (migrated from DigitalOcean) | DigitalOcean droplet + DO Managed Postgres |
| Our role | Built and operate it | Inspected; changes need approval |
Dealerships was recorded as "DealerPulse" until 2026-09-17; prose was corrected, resource names were deliberately not.

## 2. Timeline
| When | What |
|---|---|
| Aug 2026 | AWS build with raw AWS CLI (no Terraform): VPC, nodes, S3, IAM, SSM, ECR, DLM snapshots, alerts to Slack. Pivot to merged frontend+backend on two nodes behind an ALB. |
| 2026-09-01 | ALB live, shared Postgres on the integration VM, origin locked to Cloudflare. |
| 2026-09-03/04 | Five-service ECR CI/CD; Cloudflare caching, WAF and country allow-list; CSP enforcing. |
| 2026-09-09/10 | puentehillsnissan.com cut over; team VPN built. |
| 2026-09-11/12 | Surf City on its own branch pipeline; inventory cache bug fixed; `_rsc` connection-limit fix. |
| 2026-09-14/15 | Rightsizing; netdata removed (it was the CPU burn); ALB re-weighted; memory metrics live. |
| 2026-09-16/17 | Chunk-404 incident closed with atomic two-node deploys + automatic purge; latency alarm explained (cache stampede). |
| 2026-09-18/25 | Uptime Kuma, fleet audit, incident review, domain-expiry monitors. |
| 2026-10-01 | SSR empty-content incident (428 bootstrap); fixed by restarting frontends. |
| 2026-10-02/03 | Chatbot outage (OpenRouter credits); cost cleanup; ECR lifecycle policies; nodes on t3.large. |
| ~2026-10-03 | San Bernardino frontend live on both nodes. |
| 2026-10-05 | Weekend sweep: all alarms OK. |
| 2026-10-06 | Graviton trial rolled back (images are amd64-only). |
| ~2026-10-12 | Corona migrated [told]. |
| 2026-10-13 | Knowledge consolidated into this pack; stance set to stability first. |

## 3. Where the detail lives
| Path (under `Documents\Documentations\`) | Contents |
|---|---|
| `HANDOVER.md` | Operational handover |
| `Migration/MIGRATION_HISTORY.md` | Every session: evidence, root causes, decisions |
| `Migration/COMMAND_LOG.md` | Verbatim AWS commands and resulting IDs |
| `Migration/OCTOBER_CAPACITY_PLAN.md`, dashboards JSON, `ecr-lifecycle/`, `scripts/` | Capacity, dashboards, policies, scripts |
| `TENANTS_PUENTE_HILLS_SURF_CITY.md` | Tenant-level configuration |
| `Monitoring/`, `TeamVPN/` | Kuma and VPN setup and history |
| `DealerPulse/` | The DigitalOcean product: architecture, incidents, backend fixes, probes |
| `pre-migration/` | Original DigitalOcean architecture and migration plan (historical) |
| `TODO.md` | Optional improvement ideas (2026-09-17) |
Application repos (Bitbucket `nxpt`): `ocean`, `website_frontend`, `integrations_service`, `chat_back`, `framework_frontend`, `backend_v2.1`, `dp_frontend_v2`, `starfish`.
