---
name: dealerships-architecture
description: "How the Dealerships platform on AWS works: tenants, apps (ocean, website_frontend, integrations_service, chat_back, framework_frontend), request flow Cloudflare -> ALB -> nginx -> containers, nodeA/nodeB/integration VM, shared Postgres, per-node Redis, API encryption, security model, invariants. Use whenever someone asks how something works, where something runs, what talks to what, or before proposing any change to the platform. Also use to decide whether 'DealerPulse' means the AWS resource prefix or the separate DigitalOcean project."
---

# Dealerships architecture

Full reference: `Claude-Setup/ARCHITECTURE.md` (read it). IDs and hostnames: `Claude-Setup/INVENTORY.md`.

## Stance
The platform works and the business is happy with it. **Default is no change.** Explain the system as it is; do not volunteer
redesigns, refactors, upgrades or TODO items unless asked. If a question implies a change, use skill `dealerships-change-control`.

## Mental model (memorise)
- AWS `409289617504`, `us-west-2`. Resource names `dealerpulse-*` (correct; the project is called Dealerships).
- Cloudflare -> ALB `dealerpulse-alb` (Cloudflare IPs only) -> nginx :443 on **nodeA** `i-061291ea974c4ea1b` and **nodeB** `i-0c982c44f93bfbc0a`
  -> loopback containers: `ocean` (Django :9000 + Celery worker/beat + Redis) and one `website_frontend*` per tenant (PHN :3000, Surf City :3001, Corona, SB).
- **integration** `i-03efb82c808863f84`: `ocean-shared-postgres` (database for all tenants), chat_back (:9002 WS, OpenRouter, pgvector),
  leads (:8129, VinSolutions/Cox), admin dashboard (:3003). Reached directly via Cloudflare (`admin.`/`chat.`/`leads.callingyounow.us`), not the ALB.
- Tenancy: `?dealership_id=` first, then Host -> `Domain` table. Frontend tenant is baked into the image at build time.
- `/api/*` is encrypted per response (`API_CRYPTO_MODE=required`); unsigned requests get 428. Not edge-cacheable.
- Reach hosts with SSM only (`aws ssm start-session --target <id>`). No SSH, no public origin access.

## Answering questions
- Say which layer you are describing (edge / ALB / node nginx / container / data / integration).
- Mark provenance: `[doc]` from the pack, `[verified]` only if you checked live in this session.
- If docs disagree (for example ALB weights), say so and offer a read-only check.
- "DealerPulse" + AWS words = this platform's resource prefix. "DealerPulse" + droplet/DigitalOcean/Retell/Twilio = the separate project (skill `dealerpulse-digitalocean`).

## Read-only commands
```bash
aws ec2 describe-instances --filters Name=tag:Project,Values=dealerpulse --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PrivateIpAddress]" --output table
aws elbv2 describe-target-groups --names dealerpulse-tg-nodea dealerpulse-tg-nodeb
aws elbv2 describe-target-health --target-group-arn <arn>
# on a node (SSM): docker ps --format '{{.Names}}\t{{.Status}}'; ls /etc/nginx/sites-enabled; free -m; df -h /
```
On Windows Git Bash set `MSYS_NO_PATHCONV=1`; for `ssm send-command`, put commands in a JSON file and pass `--parameters file://...`.
