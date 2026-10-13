# INCIDENTS — symptom -> cause -> fix (and what was wrong in earlier diagnoses)

Source: `Documentations/Migration/MIGRATION_HISTORY.md`, memory notes. `[doc]` re-verify before relying.

| # | Date | Symptom | Root cause | Fix | Still open |
|---|---|---|---|---|---|
| 1 | 2026-10-01 | Pages render shell, no CMS/inventory data; every alarm green | `website_frontend/utilis/apiCrypto.ts` caches a **failed** crypto bootstrap (`null`) for the process lifetime; deploy started frontend before Django -> Django answered 428 forever. 2,275 x 428 in one deploy hour | `docker restart website_frontend website_frontend_surfcity`, nodeA then nodeB (user approved) | Code fix (cache only success, reset on `crypto_key_required`); order the deploy; **alarm on 428 rate**; purge CF |
| 2 | 2026-09-16 and earlier (09-01, 09-11) | ChunkLoadError / JS 404 on puentehillsnissan.com | Nodes on different builds (first: per-node builds; then moving `:latest`; finally deploy skew ~2.5 min between manually-triggered nodes) + CF cached the transient 404 | Single atomic SSM deploy; 4xx/5xx edge TTL 0; auto purge | Optional frontend `ChunkLoadError` reload handler (proposed to Ghulam Ali) |
| 3 | 2026-10-02 | Chatbot "temporarily unavailable" for everyone | OpenRouter credits exhausted | User topped up; after: 5,370 sessions, 0 errors | No alarm covers it (blind spot) |
| 4 | 2026-09-11/17 | `dealerpulse-alb-latency-p99` fires every ~2 h | Inventory Redis **cache stampede** at 2-hour TTL expiry, no single-flight lock; plus Next image optimizer (83% of slow requests); HomeNet SOAP timeouts | Not fixed (ocean not deployed since 09-14 at last check). Alarm is correct, do not retune | TODO items 11, 12 |
| 5 | 2026-09-11/12 | Inventory slow | Redis inventory cache written to one place, read from another (confirmed); an earlier cost claim was wrong, real hot spot differed | Fixes landed 09-15 (mostly) | Frontend part |
| 6 | 2026-09-12 | Repeating "site down" 503 storms | `limit_conn` hit by Next.js `?_rsc=` prefetch | nginx `map` exempting `_rsc`; `limit_conn 300`; status 429 | None |
| 7 | 2026-09-15 | nodeA slow, CPU credits at 3 | netdata container-runtime CPU burn | netdata removed (approved after a mis-scoped purge); ALB weighted toward nodeB | Verify weights |
| 8 | 2026-09-16/19 | Postgres `too many clients` (83, then 24 events) | JD Power 15-thread fan-out after the 20:00 UTC warm | Non-fatal (audit-log writes) | Open |
| 9 | 2026-09-20 | 29 image 500/504 in 1 s on nodeB | HomeNet image CDN stall | Self-resolved | Hypothesis only: CPU starvation after stampede |
| 10 | 2026-10-05 | integration swap 51%, 279 MB available | `chat_back` reverted to `--workers 4` by a clean pull/deploy | Fix commit `3ed8deb` (`UVICORN_WORKERS` default 2) **local only, unpushed** at the time | Push + deploy |
| 11 | 2026-09-16 | **DealerPulse** backend degraded 20:00-23:00 UTC (72 x 504, 52 x 502; voice path hit hardest) | Daphne slow/dropping; no `proxy_read_timeout` on `location /` | Report written; see DealerPulse docs | Backend team (17 items) |
| 12 | 2026-10-06 | Graviton test node | Every ECR image amd64-only (`exec format error`) | Rolled back, nodeC terminated | Closed by user decision |
| 13 | 2026-09-07 | certbot.timer renewal had never worked | Config looked right, was not | Fixed | Watch expiry; Kuma 21-day alert |

## Recurring failure shapes (use as hypotheses, then verify)
- **Untracked file lost to `deploy.sh` auto-stash** (`docker-compose.override.yml`, chat_back CORS patch): symptom "Waiting for PostgreSQL..." loop. Check `git stash list` in the repo dir. Hand-edited files in deploy-managed dirs are fragile.
- **Node carries a second SG** -> origin lockdown silently reopened. Check `describe-instances` SecurityGroups first.
- **Missing vhost/cert on one node** -> ~50% of requests fail (ALB sends any hostname to either node).
- **Compose `HOST: db` hardcoded** overrides `.env`. Use the override file.
- **Green dashboard, broken site**: blind spots are SSR 200-with-no-data, chatbot credits, integration memory.
- **A wrong earlier claim is common**: metric not scoped to the LB; "exposed Postgres" was not production; blue/green is automated not manual; `corona.dealerpulse.cloud` NXDOMAIN; a 502 was Twilio not a missing key. Verify, label provenance.
- **Decisions that are closed (do not re-raise)**: Django TIME_ZONE stays Asia/Karachi; Redis per-node; ALB stickiness off; no revert pipeline for Puente Hills; Graviton dropped; Auto Minify impossible.
