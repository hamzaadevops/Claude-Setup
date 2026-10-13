# INTENT_ROUTER — "when someone says X, do Y"

Read this after `CLAUDE.md`. Find the closest row, then follow the linked section. Every row says whether
**approval is needed** before acting. If nothing matches, fall back to: *read-only investigation first, state
what you verified, propose the narrowest action, wait for a yes.*

Provenance tags: `[doc]` from our files (re-verify live), `[verified]` checked at time of writing.
Paths: docs = `Documents\Documentations\`, this pack = `Documents\Claude-Setup\`, repos = `Documents\<repo>\`.

---

## A. Disambiguation (do this first, every time)

| They say | Meaning | Action |
|---|---|---|
| "DealerPulse" + AWS / ALB / nodeA / `dealerpulse-*` / S3 / alarm | The **Dealerships** project's resource prefix | Treat as Dealerships. Never rename. |
| "DealerPulse" + droplet / DigitalOcean / Retell / Twilio / `app.dealerpulse.cloud` / blue-green | The **separate DealerPulse project** | `DEALERPULSE.md`. Ask before logging in. |
| "dealerpulse" + Postgres / pg_dump | chat_back's DB is literally named `dealerpulse` | Not the project. |
| "the nodes", "node A/B", "integration" | nodeA / nodeB / integration EC2 (INVENTORY §1) | Prod: read-only unless approved. |
| "prod", "combined" | **Legacy DigitalOcean** hosts (SSH aliases), being decommissioned | Don't build on them. |
| "the site", "PHN" | Puente Hills Nissan, `www.puentehillsnissan.com` | Third-party CF zone. |
| "phn", "api", "admin", "chat", "leads" | `*.callingyounow.us` hostnames (our zone) | INVENTORY §3. |
| "the VPN" | Team WireGuard box (wg-easy) `44.225.91.181` | §F. |
| "the RDP box" | Rented Windows box `93.127.140.109:10025` | §F. |
| "Surf City" | Tenant Surf City Nissan **and** the droplet's hostname `Surfcity-Live` (DealerPulse) | Check context. |

## B. Something is broken (triage) — all read-only first

| Report | Likely cause `[doc]` | First checks | Fix needs approval? |
|---|---|---|---|
| "Site is down / 5xx / 502" | Brief 502 window during frontend deploy (expected); node unhealthy; integration VM swapping | `describe-alarms`, `describe-target-health` both TGs, ALB 5xx metric, `docker ps` + `free -m` on nodes via SSM | Yes for restarts |
| "Page loads but no content / blank sections" | **428 SSR bootstrap cache** (INCIDENTS #1) | Count ` 428 ` in nginx log last hour; frontend started before Django | Yes: `docker restart website_frontend*` one node at a time |
| "Chatbot says temporarily unavailable" | **OpenRouter credits exhausted** (INCIDENTS #3) | `chat_back` logs for 402; ask user to check OpenRouter balance | Topping up is the user's |
| "Chatbot slow / integration box slow" | `chat_back` back on 4 uvicorn workers -> swap | `free -m`, `docker stats`, compose `--workers` | Yes |
| "ChunkLoadError / JS 404 after deploy" | Two nodes on different builds | Compare `.next/static/chunks` or image digest on nodeA vs nodeB; CF `cf-cache-status` | Yes |
| "Images broken" | Cloudflare hotlink protection; HomeNet image CDN stall + Next optimizer timeouts; stale 30-day static cache | Check hotlink setting; nginx 500/504 on `/_next/image` | Yes |
| "Replaced an image, still old" | CF static rule force-caches by extension for 30 days | Purge in CF (user does it, see §D) | n/a |
| "Latency alarm fired" | **Redis cache stampede every 2 h** (UTC even hours at :00 boundary) + image optimizer; alarm is correct | Check firing time against 00/02/04... UTC boundary | Do not retune alarm |
| "522 / 524 / 525 / 526" | CF cannot reach/validate origin: SG prefix-list drift, expired origin cert (certbot), node SG stale | `certbot certificates`, SG list on instance, prefix lists vs cloudflare.com/ips | Yes |
| "Direct IP does not respond" | By design: origin locked to Cloudflare/ALB | Use SSM, do not edit SGs | n/a |
| "Redirect loop" | Origin SSL mode / HSTS window / `always_use_https` | CF SSL mode must stay "Full" | Yes |
| "Lead not delivered / VinSolutions 422" | `leads.callingyounow.us` rejected payload; CF country rule vs vendor callbacks (Cox/xtime) | `nisanwebsite-worker-1` + leads_backend logs; CF Security Events | Yes |
| "API returns 428 to curl" | Expected: API encryption (`API_CRYPTO_MODE=required`) | Probe via frontend/logs, not curl | n/a |
| "Postgres too many clients" | 15-thread JD Power fan-out after the 20:00 UTC warm; `max_connections` 150 | Logs for `too many clients` | Yes |
| "Slow in the RDP box only" | CPU starvation on box | Don't re-diagnose (§F) | n/a |
| "Slow through VPN" | `t4g.micro` throughput ceiling (~11 Mbps) | Split-tunnel by narrowing `AllowedIPs` | Yes |
| "Cert expiring" | Per-node Let's Encrypt (certbot.timer) + ACM on ALB are separate | `certbot certificates` on nodes; ACM console | Yes |
| "Logs missing in CloudWatch" | Agent log-config overwritten by console wizard | Inspect `amazon-cloudwatch-agent.d/` directly | Yes |

## C. Deploys and changes

| They say | Do | Approval |
|---|---|---|
| "Deploy X" | **Do not run `deploy.sh` by hand.** Normal path = merge to branch -> Bitbucket Pipeline -> ECR -> single SSM call to both nodes -> CF purge. Branches: `main-migrated` (Puente Hills + shared), `main-surfcity`, `main-corona`, `main-sanbernardino`. RUNBOOKS §1 | Always |
| "Rollback" | Surf City: `revert-surfcity` custom pipeline (redeploy by 7-char SHA). Puente Hills: none (cancelled by user); redeploy previous commit via pipeline. ALB: `dealerpulse-tg-nginx` is the detached instant-rollback TG | Always |
| "Add an env var" | `.env` edit then `docker compose up -d --no-deps <svc>` (never `restart`) | Always |
| "Add a new dealership" | RUNBOOKS §2. **Ask which pipeline pattern** (single-branch vs per-branch) | Always |
| "Change Cloudflare" | RUNBOOKS §5. Rulesets are full-replace PUT: resubmit every existing rule | Ask; user supplies token |
| "Purge cache" | Pipeline does it automatically after deploy. Manual purge is blocked by the classifier -> give the user the dashboard path | User does |
| "Create a token / key / secret" | Blocked by the classifier. User creates it in the provider UI and pastes it | User does |
| "Resize / stop / terminate an instance" | Propose exact command, wait for yes, log in COMMAND_LOG | Always |
| "Graviton / ARM" | Tried 2026-10-06, rolled back; every ECR image is amd64-only; user chose not to pursue | Ask first |
| "Terraform / CDK" | Not used by design. Raw CLI + COMMAND_LOG is the record | n/a |
| "Rename the resources" | **No.** | n/a |

## D. Monitoring and information

| They say | Do |
|---|---|
| "Daily check / sweep / health report" | RUNBOOKS §3. Read-only. Write a dated entry in `MIGRATION_HISTORY.md` |
| "Check the alarms" | `aws cloudwatch describe-alarms ...` (HANDOVER §7). 7 alarms expected, all OK as of 10-05 |
| "Uptime / Kuma" | `uptime.callingyounow.us`; setup `Monitoring/UPTIME_MONITORING_SETUP.md`, list `MONITOR_CHECKLIST.md`. Keyword checks use street address, not dealership name |
| "MyUptimeIP <ip>" | Invoke skill `MyUptimeIP` |
| "Logs / what happened at HH:MM" | Container logs are `+0500`, nginx and CloudWatch are **UTC**; user is in Pakistan (PKT = UTC+5) |
| "What's pending / priorities" | `STATUS.md`, then `Documentations/TODO.md` (**do not edit TODO without discussion**) |
| "What did we do about X / why" | `Documentations/Migration/MIGRATION_HISTORY.md` (narrative) then `COMMAND_LOG.md` (exact commands) |
| "Cost / bill" | `Documents/AWS_Cost_Report_Sep-Oct_2026.pdf`; history entry 2026-10-03 "Cost cleanup"; `OCTOBER_CAPACITY_PLAN.md` |
| "Is X still true?" | Run the read-only command, report `[verified]` with output, update `STATUS.md` |

## E. Writing and communication

| They say | Do |
|---|---|
| "Write a handover / report / message for X" | Say who it's written for in one line, match their level. Docs go in `Documentations/`. Published docs: use the Docs/Artifact tools if asked |
| "Update the docs" | Append to MIGRATION_HISTORY (narrative) and COMMAND_LOG (commands, verbatim). Never rewrite the command log |
| "Incident report" | Use `DealerPulse/INCIDENT_REPORT_CTO.md` and `INCIDENT_2026-09-16.md` as templates; all timestamps UTC with PKT equivalent |
| "Message for the dev team" | Drafts exist in MIGRATION_HISTORY 2026-09-17 (`.htm`) and `DealerPulse/BACKEND_FIXES.md` |
| "Remember this" | Save to Claude memory **and** add to this pack, since the pack is the single source of truth |

## F. Side systems

| They say | Do |
|---|---|
| "Open WireGuard UI / add VPN client / peer" | Skill `ConnectWireguardUI`. Always `http://localhost:51821` via SSH tunnel; never the IP |
| "VPN SSH not working" | Admin IP changed -> SG `team-vpn-sg` `sg-020165aeddafe5322` port 22 rule; or you're on the VPN and used the public alias (use `wg-ui-vpn`) |
| "RDP box" | RDP port **10025**, SSH 22. Slow = CPU (27x), not network. Fix is a bigger box (>=4 vCPU, >=8 GB) |
| "DealerPulse droplet" | **Ask before logging in.** `ssh dealerpulse`. `DEALERPULSE.md` |
| "Database exposed / Trusted Sources" | DealerPulse managed Postgres finding, highest severity, needs approval (DEALERPULSE.md §3) |
