# INCIDENTS — what went wrong before, and how it was fixed

This is the index. The full catalogues, each issue with symptom, final root cause, exact fix, verification, status and source lines:
- `knowledge/ISSUES_AWS_A.md`: Dealerships, Aug to mid-Sep 2026 (alerting, bootstrap, ocean config, database, deploy script, frontend,
  nginx/TLS, ALB/SG, Cloudflare, inventory, capacity, observability), plus 67 operational gotchas and 32 user decisions.
- `knowledge/ISSUES_AWS_B.md`: Dealerships, mid-Sep to Oct 2026, plus monitoring, Cloudflare, VPN/Kuma, tooling, the RDP box, the health-sweep
  commands, VPN/Kuma procedures and cost decisions.
- `knowledge/DEALERPULSE_OPS.md`: the DigitalOcean product's incidents (I-1..I-14).
Search by symptom: `grep -n -i "<word>" knowledge/*.md`. The original narrative is in `records/Migration/MIGRATION_HISTORY.md`.

All entries are `[doc]` (latest record 2026-10-06). Verify live before acting.

## The incidents most likely to come up again
| # | Date | Symptom | Final root cause | Fix / status | Catalogue |
|---|---|---|---|---|---|
| 1 | 2026-10-01 | Pages show header/footer but no content; every alarm green | Frontend cached a failed API-crypto bootstrap (started before Django) → 428 on every server render | Restart the affected frontends, one node at a time (approved). Code fix, deploy ordering and a 428 alarm **still open**; can recur after any deploy | B D-16 |
| 2 | 2026-10-02 | Chatbot "temporarily unavailable" for everyone | OpenRouter credits exhausted (fallback model is also OpenRouter) | Top-up; no alarm covers it | B D-17 |
| 3 | 2026-09-11 → 09-21 | Inventory/VIN pages up to 52 s; latency alarm every ~2 h | HomeNet cache TTL 2 h shorter than the gaps between the 3×/day warms; lazy refill without a lock; degraded cache | **Fixed 2026-09-21**: `HOMENET_CACHE_TTL_SECONDS=72000` + forced refresh. Durable code fix with the developer | B D-01, A J-02 |
| 4 | 09-01, 09-11, 09-16 | ChunkLoadError / JS 404 after deploys | Final: deploy-timing skew between nodes + Cloudflare caching the 404 | Atomic two-node deploy, 0 TTL on 4xx/5xx, auto purge | A F-01, B CF-02 |
| 5 | recurring | 502 burst during every frontend deploy | `docker rm -f` + `run` with no draining | Accepted (blue/green not built) | B D-06 |
| 6 | 09-08 → 09-11 | "Site down" for single visitors | Next.js prefetches exceeded `limit_conn 60`, returned 503 | `limit_conn 300`, `_rsc` exemption, 429 status | A G-05 |
| 7 | 09-10 | Slow site + ~5% 500s | Postgres connections exhausted (no `CONN_MAX_AGE`, max 100) | `max_connections` 150; dev set `CONN_MAX_AGE=60` | A C-07 |
| 8 | 09-16, 09-19 | `too many clients` in Postgres | JD Power 15-thread fan-out after the 20:00 UTC warm | Open, non-fatal (code change) | B D-02 |
| 9 | 09-19 → 10-05 | Integration VM swapping (279 MB free) | chat_back running 4 uvicorn workers; a deploy restored the committed value | Fix commit `3ed8deb` on `origin/main-migrated`; deployment unconfirmed | B D-07 |
| 10 | 08-28 → 09-05 | Hand fixes disappearing after deploys | deploy.sh auto-stashed dirty files | deploy.sh now **refuses a dirty tree** (exit 1) | A E-01, B D-10 |
| 11 | 09-04 | New `.env` var "not set" | `docker compose restart` doesn't re-read `.env` | Use `up -d --no-deps` | A C-05 |
| 12 | 09-07 | Certificate renewal had never worked | Country rule blocked ACME + nginx plugin issues | ACME path exempt; DNS-01 via `certbot-dns-cloudflare` | A G-11, B CF-01 |
| 13 | 09-14/16 | nginx log panels empty | CloudWatch agent config overwritten (console wizard / fetch-config) | Separate log config file; `cwagent` in group `adm` | A L-02 |
| 14 | 09-12/15 | nodeA CPU credits at 0 | netdata burning about 30% CPU | netdata removed; ALB weighted 35/65 | A K-01, K-02 |
| 15 | 08-26 | Slack alerts not arriving | Chatbot only renders AWS-service messages; broken config | Config recreated with explicit settings | A A-01, A-02 |
| 16 | 09-18 → 09-22 | Team VPN unreachable for 3-5 days, unnoticed | SG lost its UDP 51820 rule | Rule re-added; nothing monitors the VPN | B V-04 |
| 17 | 09-18 | Kuma: every monitor down, sites fine | Kuma container memory pressure (socket throttling) | Swap + `mem_limit 512m` | B V-05 |
| 18 | 09-24 | nginx reload failed on the VPN box | A `.bak` file inside `sites-enabled/` | Backups in `/etc/nginx/backups/` (MyUptimeIP skill fixed 2026-10-13) | B V-11 |
| 19 | 10-01 → | Customers miss confirmation emails | leads SMTP credential rejected (535) | Open; credential owner must update | B D-04 |
| 20 | 09-19 → | Leads failing to VinSolutions | Mostly business-rule duplicates; invalid emails lose the lead; occasional 422 | Open with developer/Cox | B D-03 |
| 21 | 2026-09-16 | **DealerPulse** site up but not answering for 3 h; calls silent | DB waits with no connect/statement/lock timeouts → threads 12 → 142 (trigger unproven). *Not* the nginx timeout | Ended by a deploy; prevention not shipped | DP I-1 |
| 22 | 09-08 → | **DealerPulse** staff SMS failing | `TWILIO_FROM_NUMBER` not on the Twilio account | Open with backend team | DP I-2 |
| 23 | 10-06 | Graviton test node fails | All ECR images are amd64-only | Rolled back; dropped by user decision | B D-29 |

## Recurring failure shapes (use as hypotheses, then verify)
- **Green dashboard, broken site.** No alarm covers empty SSR content, chatbot credits or integration memory.
- **Config "reverted" after a deploy.** Something wasn't in git: a committed default won, or the dirty-tree guard blocked the deploy.
- **A node behaves differently from the other.** A missing vhost/cert, a second SG attached, a different image digest, or ocean Node B not clicked.
- **A setting "applied" but not effective.** `restart` instead of `up -d`; nginx reload failed (the old config keeps serving); IAM propagation (wait minutes).
- **Earlier diagnoses were often wrong** (wrong metric dimension, wrong scanner IP, "leak" that wasn't). Read the *final* root cause in the catalogue.

## Closed decisions (do not re-raise)
TIME_ZONE `Asia/Karachi`; Redis per node; ALB stickiness off; no Puente Hills revert pipeline; Graviton dropped; no Terraform; country allow-list
US/CA/PK/JP; alarm thresholds as calibrated; resource names kept; keep `dealerpulse-tg-nginx`; HomeNet warms 3×/day; Cloudflare SSL Full with
self-signed origins; frontend blue/green not built; legacy DigitalOcean pipelines left until decommission.
Full list: `knowledge/ISSUES_AWS_A.md` Part 3 and `knowledge/ISSUES_AWS_B.md` section (e).
