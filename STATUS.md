# STATUS — watch-list, closed decisions, open questions

**Stance:** the platform is working and accepted. Nothing below is a work queue. Items are **optional** and are raised only when relevant or requested.
Last refreshed 2026-10-13 from documents (no live query). Update with date and provenance when you verify anything.

## 1. Current state (as last recorded) `[doc]`
- All four tenants on AWS: Puente Hills, Surf City, San Bernardino (frontend running since ~2026-10-03), **Corona migrated** [told by the user
  2026-10-13; date given as "12th Agust", probably 12 Oct; hostname not recorded; verify].
- All 7 alarms OK at the 2026-10-05 sweep; 0 ELB 5xx over that weekend; nodes healthy; chatbot healthy after an OpenRouter top-up.
- `chat_back` workers fix (`3ed8deb`, default 2) is on `origin/main-migrated` [verified 2026-10-13]; whether it is deployed is not confirmed.

## 2. Watch-list (risks to be aware of; act only if asked or if they cause trouble)
| Area | Risk | Note |
|---|---|---|
| DealerPulse DB | DO Managed Postgres reachable from any IP (Trusted Sources off), app uses `doadmin` | Highest-severity known risk; fix is a DO panel toggle + app user change |
| Integration VM | Memory pressure / swap; hosts the shared Postgres | Watch swap in sweeps |
| Monitoring gaps | No alarm for 428/empty SSR, chatbot credits, integration memory | Covered by the daily sweep |
| Deploy race | Frontend can cache a failed crypto bootstrap after a deploy | Check the 428 canary after deploys |
| Latency alarm | Fires on the HomeNet cache stampede (~2 h) | Expected; do not retune |
| Vendors | Cloudflare country rule could block Cox/xtime callbacks; Surf City financing IDs were placeholders | Check if a vendor reports problems |
| Certificates | certbot renewal failed silently once | Kuma alerts 21 days before expiry |
| VPN box | ~11 Mbps through the tunnel | Fine for browsing/API |

Optional engineering ideas (health endpoint, image optimizer, `.htm` redirects, Django logging, single Celery beat, etc.) are listed in
`Documentations/TODO.md` (last edited 2026-09-17). Discuss before editing it.

## 3. Closed decisions (do not re-raise)
TIME_ZONE `Asia/Karachi`; Redis per node; ALB stickiness off; no Puente Hills revert pipeline; Graviton/ARM dropped (2026-10-06); no Terraform;
country allow-list US/CA/PK/JP accepted; latency alarm thresholds kept; resource names kept; min TLS 1.2.

## 4. Open questions and doc conflicts (resolve by a read-only check, then fix the losing doc)
- ALB weights: 50/50 (HANDOVER) vs 35/65 (tenant doc, since 2026-09-14).
- Alarm count: 7, and whether `dealerpulse-nginx-fd-exhaustion` exists.
- Corona and San Bernardino hostnames, ports, cert type.
- Owner of the `callingyounow` product on the DealerPulse droplet; who owns `3.43.243.0/30`.
- Purpose of `NEXT_PUBLIC_DSS_REGISTERED_HREF`; whether the 4-rooftop `is_multiple` grouping is intended.

## 5. Read-only refresh (run when picking this up; update this file)
`aws sts get-caller-identity` -> instances and types -> ALB listener weights and target health -> alarms (count, states) -> via SSM on each VM:
`docker ps`, `free -m`, `df -h /`, nginx vhosts, `certbot certificates` -> 428 canary -> chat_back `--workers` -> public HTTPS check of every tenant host.
Commands: `RUNBOOKS.md` §3, skill `dealerships-monitoring`.
