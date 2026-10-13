---
name: dealerpulse-digitalocean
description: "The DigitalOcean estate: the separate DealerPulse product (droplet Surfcity-Live 146.190.132.236, DO Managed Postgres, blue/green backend, Twilio/Retell voice and SMS, Celery reminders), the unrelated callingyounow product on the same droplet, and the legacy pre-migration Dealerships hosts prod and combined. Use whenever DealerPulse means the DigitalOcean product, or for droplet, DO database, calls, SMS, recordings, reminders, or legacy host questions."
---

# DigitalOcean estate (DealerPulse + legacy)

Full reference with citations: **`knowledge/DEALERPULSE_OPS.md`** (architecture, deploy, issues I-1..I-14, health checks, risks, unknowns).
Records: `records/DealerPulse/`. **Ask before logging in to or probing the droplet.** Every change needs approval and usually the backend team.

## Know first
- **"DealerPulse" means two things.** Here it's the DigitalOcean product. On AWS it's only the resource prefix of the Dealerships platform.
  "Surf City" also means three things: a Dealerships tenant, a dead DealerPulse v1 site, and this droplet's hostname.
- Local files `dealerpulse.dump` and `dealerpulse-infra-diagram.html` belong to **Dealerships**, not this product.
- Droplet `146.190.132.236` (`Surfcity-Live`), 2 vCPU / 8 GB, **no swap**. SSH alias `dealerpulse` (root, key `~/.ssh/digitalocean`).
- `app.dealerpulse.cloud` → frontend 127.0.0.1:8014. `app.backend.dealerpulse.cloud` → backend daphne 127.0.0.1:8004 (blue) or 8006 (green).
  Also running: Celery worker and beat, Redis (broker + websockets), and the unrelated `callingyounow` product (:8007/:8018).
  DNS is at Hostinger (4 h TTL), with no CDN.
- **Database: DO Managed Postgres** `dp2-live` (port 25060, `defaultdb`, user `doadmin`), 1 node, no standby. Droplet snapshots don't cover it.
- Third parties: Twilio, Retell, XTime/Cox, Wassenger, OpenRouter, AssemblyAI, SMTP. `MASTER_ENCRYPTION_KEY` (droplet `.env`) must never be regenerated.

## Health check (tiers)
- **Tier 0, no droplet contact:** Uptime Kuma DealerPulse monitors (backend `/health/ready/`, frontend, beat, worker, threads, error rate, host,
  DB TCP, XTime, Twilio, Wassenger).
- **Tier 1, external, needs the operator's yes:**
  `curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.backend.dealerpulse.cloud/health/ready/` (expect 204), the same for `/health/live/`
  (expect 204), and `https://app.dealerpulse.cloud/` (expect 200).
  - ready 503: the app can't reach the DB.
  - ready hangs while live is fine: the 2026-09-16 outage signature.
  - **The homepage is not proof of health.**
- **Tier 2, on the droplet, read-only, ask first:** commands in `knowledge/DEALERPULSE_OPS.md` §4. Normal backend threads are 9-14; above 30 is an alert.
  Never read `.env`, and never run `docker compose up -d` without a service name and `IMAGE_TAG`.

## Known issues (as of 2026-09-22; verify)
| Report | Cause | Who |
|---|---|---|
| Calls silent, staff can't log in, site "up" but not answering | DB waits with no timeouts → threads pile up (I-1). Ended by a redeploy; prevention not shipped | backend team; infra for DB settings |
| Staff don't get booking or missed-call texts | `TWILIO_FROM_NUMBER` isn't on the Twilio account (I-2). Twilio monitor stays green | backend team (Mudassar) |
| Recording won't play (502) | Twilio recording not ready yet (I-4). Wait and retry | — |
| No confirmation or reminder calls | `RETELL_API_KEY` missing (I-5); state unknown | backend team |
| No transcripts / no follow-up for non-bookers | Features short-circuited in code (I-6). Product decision | backend team / CTO |
| Upload over 1 MB fails (413), slow XTime requests 504 | nginx defaults (I-7). Fix pending approval; timeout only after the DB timeouts | infra with approval |
| Kuma beat/worker down | worker and beat have no restart policy (I-10) | backend team |

## Top risks (don't act alone)
1. The DB is reachable from the internet (Trusted Sources off), the app uses the superuser, and the `doadmin` password appeared in a transcript on
   2026-09-18. **Known and left as-is by user decision (2026-10-13):** explain it if asked, but don't raise it or propose fixes unprompted.
2. Single points of failure: one droplet, one DB node, backups never restore-tested, media only in the droplet snapshot.
3. Unauthenticated webhooks; SSH and the droplet's own Postgres (:5432) open to the world (`pg_hba` restricted).

## Deploy (summary)
Backend `main` → Docker Hub → SSH → start the other colour → health gate 150 s → `sed` the port in the nginx vhost → reload → stop the old colour → recreate
worker and beat. Frontend `main` → recreate (no blue/green). Rollback: re-run the previous good pipeline. Details: `knowledge/DEALERPULSE_OPS.md` §2.
Staging (`staging` branch) deploys to `dp2.back.fluten.xyz` on the legacy `combined` droplet.

## Legacy Dealerships hosts
`prod` 143.198.144.174 and `combined` 137.184.45.248 (root, key `~/.ssh/digitalocean`): the pre-AWS stack plus about 15 other projects on `combined`.
**Legacy pipelines still deploy to them on pushes to `main`/`master`/`staging` branches.** Not Dealerships production. Don't build on them.
