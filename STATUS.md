# STATUS — watch-list, closed decisions, open questions

**Stance:** the platform is working and accepted. Nothing below is a work queue. Items are **optional** and raised only when relevant or requested,
except section 2a, which has dates or security exposure that someone with authority should decide on.
Last refreshed 2026-10-13 from documents (latest record 2026-10-06; no live query). Update with date and provenance when you verify anything.

## 1. Current state (as last recorded) `[doc]`
- All four tenants on AWS:
  - Puente Hills
  - Surf City
  - San Bernardino (frontend on both nodes since about 2026-10-03)
  - **Corona migrated** [told by the user 2026-10-13, "12th Agust", probably 12 Oct; its pipeline and cache-purge environment exist since 2026-10-10]
- All 7 alarms OK at the 2026-10-05 sweep. 0 ELB 5xx over that weekend. Nodes healthy. Chatbot healthy after the OpenRouter top-up.
  The latency alarm has been quiet since the 2026-09-21 cache fix, apart from one flap on 09-27.
- The `chat_back` workers fix (`3ed8deb`, default 2) is on `origin/main-migrated` [verified 2026-10-13]. Whether it's deployed is unconfirmed.

## 2a. Needs a decision by someone with authority (dates / security)
| Item | Why it matters | Who |
|---|---|---|
| **Dealership domain registrations** | surfcitynissan.com expires **2026-11-12**, coronanissan.com 2026-11-21, puentehillsnissan.com 2026-12-11. We don't own them; auto-renew unknown | CTO / dealers |
| **DealerPulse DB exposed** | Managed Postgres reachable from any IP (Trusted Sources off); app uses `doadmin`; that password was printed into a transcript on 2026-09-18 → **rotate** | DO account holder, backend team, CTO |
| Previous engineer's access | Their AWS access keys, SSH keys and WireGuard peers should be rotated or revoked per company policy after handover | lead / CTO |

## 2b. Watch-list (act only if asked or if they cause trouble)
| Area | Risk | Note |
|---|---|---|
| Integration VM | Memory pressure/swap; hosts the shared Postgres for all tenants | Watch in sweeps; resize was deferred, not rejected |
| Monitoring gaps | No alarm for empty SSR (428), chatbot credits, integration memory; nothing monitors from outside AWS | Covered by the daily sweep |
| Deploy race | Frontend can cache a failed crypto bootstrap after a deploy | Check the 428 canary after deploys |
| ocean deploys | Node B is a manual click; nodes can run different backends | Click Node B promptly |
| Legacy pipelines | Pushes to `main`/`master`/`staging` still deploy to old DigitalOcean hosts | Don't push there by accident |
| Leads | SMTP 535 (confirmation emails), occasional VinSolutions 422 | Developer / credential owner |
| Vendors | Country rule could block Cox/xtime callbacks; Surf City financing IDs were placeholders | Check if a vendor reports problems |
| Certificates | certbot renewal failed silently once | Kuma alerts 21 days before expiry |
| VPN | ~11 Mbps; client configs may carry the stale Endpoint 44.242.4.12; no SSM on the box | Fix the Endpoint per client |
| Kuma origin | `44.225.91.181:443` reachable directly, bypassing Cloudflare | Hardening idea, not done |
| Reboots | All three VMs have pending security reboots; rebooting integration is a full outage | Needs a window and approval |
| DealerPulse | Staff SMS failing, Retell key, Celery fragility, no DB timeouts | Backend team |

Optional engineering ideas are listed in `records/TODO.md` (last edited 2026-09-17, partly superseded by the history): health endpoint, image
optimizer (fix on branch `perf/next-image-optimizer-2026-09-22`), `.htm` redirects, Django logging, single Celery beat. Discuss before editing it.

## 3. Closed decisions (do not re-raise)
- **Runtime:** TIME_ZONE `Asia/Karachi`; Redis per node; HomeNet warms 3×/day.
- **Load balancer and edge:** ALB stickiness off; keep `dealerpulse-tg-nginx`; Cloudflare SSL Full with self-signed origins; country allow-list US/CA/PK/JP; min TLS 1.2.
- **Delivery:** no Puente Hills revert pipeline; frontend blue/green not built; legacy DigitalOcean pipelines stay until decommission.
- **Platform and process:** Graviton/ARM dropped (2026-10-06); no Terraform; latency alarm thresholds kept; resource names kept.

## 4. Open questions and doc conflicts (resolve by a read-only check, then fix the losing doc)
- ALB weights: 35/65 (history 2026-09-14 and 09-21) vs 50/50 (`records/HANDOVER.md`).
- Alarm count (7?) and whether an fd-exhaustion alarm should be recreated (it was deleted on purpose on 09-14).
- Corona and San Bernardino: public hostnames, San Bernardino port, Kuma monitors present?
- `max_connections` 150 (most sources) vs 100 (one history line).
- Owner of the `callingyounow` product on the DealerPulse droplet; who owns `3.43.243.0/30`.
- Purpose of `NEXT_PUBLIC_DSS_REGISTERED_HREF`; whether the 4-rooftop `is_multiple` grouping is intended.
- Escalation contact for the operator (`START_HERE.md` §5).

## 5. Read-only refresh (run when picking this up; update this file)
1. `aws sts get-caller-identity`
2. Instances and types.
3. ALB listener weights and target health.
4. Alarms: count and states.
5. Via SSM on each VM: `docker ps`, `free -m`, `df -h /`, the nginx vhost list, `certbot certificates`, the live `deploy.sh` cases.
6. The 428 canary.
7. chat_back `--workers`.
8. HomeNet warm log line.
9. Public HTTPS check of every tenant host.
10. Kuma state.

Commands: skill `dealerships-monitoring`, `knowledge/ISSUES_AWS_B.md` section (a).
