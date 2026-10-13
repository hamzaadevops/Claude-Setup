---
name: dealerships-troubleshooting
description: "Symptom-to-cause guide for everything we run, built from real incidents: Dealerships sites down/slow/502/blank content/wrong title, chatbot unavailable, broken or slow images, latency or 5xx alarms, 52x errors, redirect loops, lead or email delivery failures, Postgres too many clients, integration server memory, failed pipelines, Slack alerts missing, Kuma showing everything down, 403 on the Kuma dashboard, VPN not connecting, SSH timeouts, slow RDP box, and DealerPulse calls/SMS/recordings problems. Use whenever anyone reports something broken, slow or strange."
---

# Troubleshooting

**Always investigate read-only first.** Any fix needs the change-control protocol (skill `dealerships-change-control`).
The full catalogues, with root causes, exact fixes and citations:
- `Claude-Setup/knowledge/ISSUES_AWS_A.md` (Aug to mid-Sep: IDs A-, B-, C-, D-, E-, F-, G-, H-, I-, J-, K-, L-; gotchas list; user decisions)
- `Claude-Setup/knowledge/ISSUES_AWS_B.md` (mid-Sep to Oct: D-01..D-33, M-, CF-, V-, T-, R-; health-sweep commands; VPN/Kuma procedures; cost decisions)
- `Claude-Setup/knowledge/DEALERPULSE_OPS.md` (DealerPulse I-1..I-14, health checks)
Search them by symptom text: `grep -n -i "<word>" Claude-Setup/knowledge/*.md`. Then read the cited history lines in `Claude-Setup/records/`.

## Quick table (most likely cause first)
| Symptom | Likely cause (catalogue ID) | First read-only checks |
|---|---|---|
| Site loads but content/inventory is blank; alarms green | Frontend cached a failed crypto bootstrap after a deploy (B D-16) | 428 count per node; frontend vs Django start times. Fix: restart affected frontend containers one node at a time (approval) |
| Burst of 502s for a minute | Deploy window (B D-06), or a manual container restart | Container start times vs 5xx hour |
| ChunkLoadError / JS 404s | Nodes on different builds or a cached 404 (A F-01) | Image digest on both nodes; container start gap; Cloudflare purge |
| Latency alarm `dealerpulse-alb-latency-p99` fires | **The cache stampede was fixed on 2026-09-21 (TTL 72000), so a firing now is a new signal.** Check the HomeNet warm, the image optimizer, deploys (B D-01, A F-11) | Worker logs `ttl=72000 ... failed_dealerships=0`; Redis DBs 2/6/11/12 (not db1); slow paths in nginx `rt=` |
| Inventory pages slow / "No vehicles found" | HomeNet cache degraded or HomeNet SOAP slow (B D-01, D-15, A J-03) | Same as above |
| Vehicle photos slow or broken | Next.js image optimizer (AVIF/1920 widths, fix on branch `perf/next-image-optimizer-2026-09-22`); HomeNet CDN stall (B D-13, D-14) | nginx 5xx and `rt` on `/_next/image` |
| Chatbot "temporarily unavailable" | OpenRouter credits exhausted (B D-17) | chat_back logs for 402; the owner tops up at openrouter.ai |
| Chat widget CORS error | Origin missing from `CORS_ALLOWED_ORIGINS` (A C-04) | chat_back env names; browser console |
| Integration slow / swap high | chat_back on 4 workers (B D-07) | `free -m`, `docker stats`, the command array of chat_back |
| Customer says the site is down for them | Rate limit (`limit_conn`) or the Cloudflare country rule (A G-05) | nginx error log "limiting connections"; Cloudflare Security → Events |
| Testers get 429 | Rate limits 50 r/s burst 150 (A G-04) | nginx error log |
| Form submit 403 on a new domain | CSRF/CORS origins missing (A C-03) | ocean env names |
| Leads not reaching VinSolutions | Business-rule duplicates (fine), invalid email (lead lost), 422 (B D-03) | leads_backend and worker logs |
| Customers don't get confirmation emails | SMTP 535: the credential is rejected (B D-04) | leads_backend logs; credential owner updates it |
| `too many clients` in Postgres logs | JD Power fan-out after the 20:00 UTC warm (B D-02) | connection count; timing |
| Backend stuck applying a migration | Table ownership after a restore (A C-08) | `pg_stat_activity`; container loop |
| Edits in the admin dashboard show only sometimes | Per-node ISR cache (A C-13) | which node served the revalidate |
| Wrong `<title>` (other dealership) | Stale prerender (B D-26) or a build without backend (A F-03) | page source on both nodes |
| A widget/iframe is blank | CSP blocks it (A G-10) | `docker compose logs web | grep csp-violation` |
| 522/524 | Prefix-list drift or extra SG on a node (A H-01) | SGs on the instance; prefix lists vs cloudflare.com/ips |
| 525/526 or redirect loop | Origin cert / SSL mode not "Full" (A G-11, I-02) | `certbot certificates`; Cloudflare SSL mode |
| Old image after replacing it | 30-day extension-based cache (edge skill) | the user purges in Cloudflare |
| nginx panels empty in CloudWatch | Agent config overwritten (A L-02) | list `amazon-cloudwatch-agent.d/` on the node |
| Slack alerts not arriving | Chatbot config / unsupported message type (A A-01, A-02) | SNS delivery metrics; Chatbot logs in **us-east-1** |
| Pipeline red / "dirty files" | Health window or dirty-tree guard (skill `dealerships-deploy`) | the node, not the colour |
| All sites look down from my laptop only | Local DNS resolver (A B-02) | `nslookup <host> 1.1.1.1` |
| Kuma shows everything down, sites fine | Kuma memory pressure (B V-05) | `docker inspect uptime-kuma` restarts; `memory.events` |
| 403 on the Kuma dashboard | IP not allowlisted (B V-07) | connect to the VPN (exit IP allowlisted) or `MyUptimeIP <ip>` |
| Nobody can connect to the VPN | SG lost its UDP 51820 rule (B V-04); stale Endpoint `44.242.4.12` in client configs (B V-03) | SG rules; client config Endpoint must be `44.225.91.181:51820` |
| SSH to the VPN box times out | You're on the VPN (use `vpn-box` 10.8.0.1) or your IP changed (B V-09, V-10) | `curl -s https://checkip.amazonaws.com` |
| Slow on the RDP box | CPU starvation, not network (B R-01) | don't re-diagnose |
| DealerPulse calls silent / staff can't log in | DB waits with no timeouts (DP I-1) | `/health/ready/` vs `/health/live/`; Kuma threads monitor |
| DealerPulse staff SMS missing | `TWILIO_FROM_NUMBER` not on the account (DP I-2) | ask the backend team |
| DealerPulse recording won't play (502) | Twilio recording not ready (DP I-4) | wait a minute and retry |

## Habits that prevent wrong diagnoses
- A green dashboard doesn't mean a working site; check real content.
- Query ALB metrics on the **LoadBalancer** dimension `app/dealerpulse-alb/dc80177beaa3aa2f`, not a target group.
- nginx/CloudWatch are UTC; container text is +0500.
- Heavy log scans on a busy node can themselves cause 504s; run single targeted passes.
- The API returns 428 to plain curl by design.
- Many earlier diagnoses were later corrected; read the "final" root cause in the catalogue, and label provenance.
