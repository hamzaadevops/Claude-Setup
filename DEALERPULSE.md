# DEALERPULSE — the separate project (DigitalOcean)

Not the AWS-migrated Dealerships stack. Not migrated by us. **Ask before logging in or probing.** Full source: `Documentations/DealerPulse/ARCHITECTURE.md` (verified 2026-09-17 by read-only ssh), `ASK_SENIOR_DEV.md`, `BACKEND_FIXES.md` (17 items), `INCIDENT_2026-09-16.md`, `INCIDENT_REPORT_CTO.md`, `MONITORING.md`, `PRE_MOVE_CHECKLIST.md`, `THIRD_PARTY_STATUS.md`, `SMS_ISSUE_MUDASSAR.md`, `scripts/`.

## 1. Host `[verified 2026-09-17]`
DigitalOcean droplet `146.190.132.236` (private `10.124.0.3`), hostname **`Surfcity-Live`**, 2 vCPU / 8 GB / 90 GB, $54.60/mo (incl. backups,
never restored), no swap, 202 days uptime. `app.dealerpulse.cloud` (frontend :8014) and `app.backend.dealerpulse.cloud` (backend :8004). DNS at
Hostinger, 4 h TTL, no CDN/WAF. `corona.dealerpulse.cloud` is NXDOMAIN; only `surfcity.dealerpulse.cloud` resolves.

## 2. What runs there
DealerPulse backend (web_blue, worker, beat, redis) + frontend; the unrelated **callingyounow** product (backend :8007, frontend :8018; owner unknown);
four dead v1 tenant deployments (corona, snb, puentehills, surfcity); netdata; host Postgres 16.9 on 0.0.0.0:5432 (unused, `pg_hba` restricts to
localhost, `3.43.243.0/30`, stale WrenAI) and a host redis; nginx; 15 Let's Encrypt certs. Blue/green is switched by `sed` on the vhost in
`bitbucket-pipelines.yml` (automated). Only blue runs.

## 3. Database and the top finding
App DB = **DO Managed Postgres** `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com:25060`, db `defaultdb`, user `doadmin` (superuser), sslmode require.
Droplet snapshots are not an app-data backup. **Trusted Sources disabled** (verified reachable from an unrelated machine, 2026-09-22): fix = enable
Trusted Sources + stop using doadmin. Needs approval. Outranks the load-balancer request. Reading `/opt/dealerpulse/backend/.env` on the droplet is
blocked by the tooling classifier; use the repo's `env.example`.

## 4. What the team actually wants
A "load balancer" is really deploy safety: nginx hardcodes `proxy_pass 127.0.0.1:8004`. An nginx `upstream` block fixes it on-host; a DO LB cannot
reach loopback-bound ports. CTO agenda item: "Digital Ocean server needs LBs at urgent bases for DealerPulse".

## 5. Third parties (about 9)
Twilio, Retell (4 agent IDs), XTime, Wassenger (WhatsApp), OpenRouter, AssemblyAI, Cox Automotive, AWS S3, SMTP; plus `vapi.py`/`tony.py` in settings.
A 502 on `/api/calls/<id>/get-recording/` was a **Twilio** recording download failing, not a missing Retell key.

## 6. Repos and tools
`bitbucket.org/nxpt/backend_v2.1` -> `Documents/dp_backend_v2`; `bitbucket.org/nxpt/dp_frontend_v2` -> `Documents/dp_frontend_v2`. Probes:
`Documentations/DealerPulse/scripts/` (`check-health.sh`, `check-celery.sh`, `check-thirdparty.sh`, `thirdparty-probe*.py`). Backups: `Documents/dealerpulse.dump`.
Infra diagram: `Documents/dealerpulse-infra-diagram.html`.

## 7. Provenance rule for this project
`[verified]` checked, `[told]` backend team said, `[doc]` their README, `[assumed]` our inference. Keep using it.
