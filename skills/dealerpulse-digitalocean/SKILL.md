---
name: dealerpulse-digitalocean
description: "The DigitalOcean estate: the separate DealerPulse product (droplet Surfcity-Live 146.190.132.236, DO Managed Postgres, blue/green backend, Twilio/Retell/voice), the unrelated callingyounow product on the same droplet, and the legacy pre-migration Dealerships hosts prod and combined. Use whenever DealerPulse means the DigitalOcean product, or for droplet, DO database, voice/SMS/call issues, or legacy host questions."
---

# DigitalOcean estate (DealerPulse + legacy)

Full reference: `Claude-Setup/DEALERPULSE.md` and `Documentations/DealerPulse/` (ARCHITECTURE, BACKEND_FIXES, incidents, scripts).
**Ask before logging in or probing anything here.** Changes need approval.

## DealerPulse
- Droplet `146.190.132.236` (private `10.124.0.3`), hostname `Surfcity-Live`, 2 vCPU / 8 GB / 90 GB, no swap. SSH alias `dealerpulse` (root, key `~/.ssh/digitalocean`).
- `app.dealerpulse.cloud` -> frontend `127.0.0.1:8014`; `app.backend.dealerpulse.cloud` -> backend `127.0.0.1:8004` (Daphne, `web_blue`; plus worker, beat, redis).
  nginx is the only front door. DNS at Hostinger, no CDN/WAF.
- Blue/green is switched automatically by the Bitbucket pipeline (`sed` on the vhost + reload). Only blue runs.
- Database: **DO Managed Postgres** `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com:25060`, `defaultdb`, user `doadmin`, sslmode require.
  Droplet snapshots/backups do not cover app data. Open risk: Trusted Sources not enabled (verified 2026-09-17/22).
- Third parties: Twilio, Retell, XTime, Wassenger, OpenRouter, AssemblyAI, Cox Automotive, S3, SMTP.
- Repos: `nxpt/backend_v2.1` (`Documents/dp_backend_v2`), `nxpt/dp_frontend_v2` (`Documents/dp_frontend_v2`).
- Health probes: `Documentations/DealerPulse/scripts/check-health.sh`, `check-celery.sh`, `check-thirdparty.sh`.
- Reading the backend `.env` on the droplet is blocked for Claude; use the repo's `env.example`.

## Also on that droplet
The `callingyounow` product (backend :8007, frontend :8018; owner unknown) and dead v1 tenant deployments (corona, snb, puentehills, surfcity).
An unused host Postgres 16.9 on 0.0.0.0:5432 (pg_hba restricted). Don't assume everything on the box is DealerPulse.

## Legacy Dealerships hosts
`prod` 143.198.144.174 and `combined` 137.184.45.248 (root, key `~/.ssh/digitalocean`): the pre-AWS stack. Not production for Dealerships. Do not build on them.

## Provenance
Keep `[verified]` / `[told]` / `[doc]` / `[assumed]`. Earlier wrong claims about this host (manual blue/green, exposed droplet Postgres as prod DB) came from skipping verification.
