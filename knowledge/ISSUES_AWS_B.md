> **Knowledge file (reference).** Extracted 2026-10-13, read-only. Citation keys map to this pack: **MH** = `records/Migration/MIGRATION_HISTORY.md`; **CL** = `records/Migration/COMMAND_LOG.md`; **CF / VPNm / RDP / CRED** = `memory-export/project_dealerships_cloudflare_config.md`, `project_team_vpn.md`, `project_fluten_rdp_box.md`, `feedback_credential_creation_blocked.md`; **VH / VCL** = `records/TeamVPN/HISTORY.md`, `COMMAND_LOG.md`; **UMS / MC / UCY / NGX / NGXP** = `records/Monitoring/{UPTIME_MONITORING_SETUP.md, MONITOR_CHECKLIST.md, uptime-compose.yml, nginx-uptime.callingyounow.us.conf, nginx-kuma-proxy-public.conf}`; **OCP / CB** = `records/Migration/OCTOBER_CAPACITY_PLAN.md`, `CALL_BRIEF_2026-09-18.md`; **HO** = `records/HANDOVER.md`; **SK-UIP / SK-WG** = `skills/MyUptimeIP/SKILL.md`, `skills/ConnectWireguardUI/SKILL.md`. Status lines are as of the last mention in the records (latest 2026-10-06), not live. Section 0 items were applied to the pack on 2026-10-13.

# Dealerships / Cloudflare / VPN+Kuma / monitoring: issue catalogue (read-only extraction)

I modified no files and ran no aws/ssh/curl/git commands. No secret values are included, only names. All facts are `[doc]` (taken from files, not checked live).

**Citation keys** (line numbers are 1-based, from the files as they are today):
- **MH** = `records\Migration\MIGRATION_HISTORY.md` (I read lines 1800-3599; the file ends at 3599)
- **CL** = `records\Migration\COMMAND_LOG.md` (I checked lines 2700-3088 for the sweep commands and the gotchas)
- **CF** = `memory-export\project_dealerships_cloudflare_config.md`
- **VPNm** = `...memory-export\project_team_vpn.md`; **RDP** = `...memory-export\project_fluten_rdp_box.md`; **CRED** = `...memory-export\feedback_credential_creation_blocked.md`
- **VH** = `records\TeamVPN\HISTORY.md`; **VCL** = `records\TeamVPN\COMMAND_LOG.md`
- **UMS** = `records\Monitoring\UPTIME_MONITORING_SETUP.md`; **MC** = `...\Monitoring\MONITOR_CHECKLIST.md`; **UCY** = `...\Monitoring\uptime-compose.yml`; **NGX** = `...\Monitoring\nginx-uptime.callingyounow.us.conf`; **NGXP** = `...\Monitoring\nginx-kuma-proxy-public.conf`
- **OCP** = `...\Migration\OCTOBER_CAPACITY_PLAN.md`; **CB** = `...\Migration\CALL_BRIEF_2026-09-18.md`; **HO** = `records\HANDOVER.md`
- **SK-UIP** = `skills\MyUptimeIP\SKILL.md`; **SK-WG** = `skills\ConnectWireguardUI\SKILL.md`. I read these only to cross-check the procedures in section (c).

---

## 0. Things to fix in the pack first (doc conflicts and logging gaps found during extraction)

1. **The pack's INCIDENTS.md and STATUS.md are stale on the cache stampede.**
   - `Claude-Setup\INCIDENTS.md:10` says it is "Not fixed (ocean not deployed since 09-14)". `Claude-Setup\STATUS.md:19` says the latency alarm "Fires on the HomeNet cache stampede (~2 h) … Expected".
   - The history says otherwise:
     - The stampede was fixed on 2026-09-21 by raising the cache TTL to 72000 (MH:2614-2660).
     - The alarm had not fired for 29 h on 09-22 (MH:2819-2821).
     - It had not changed state since 09-21 at the 09-25 sweep (MH:3139-3140).
     - It flapped only once more, on 09-27 (MH:3302-3303), and had not changed state since then at 10-05 (MH:3552).
   - **So a latency alarm firing today is a new signal, not "expected".**
2. **The nginx copy in `Monitoring\nginx-uptime.callingyounow.us.conf` is stale.** It lacks `allow 44.225.91.181;` (the VPN exit IP), which was added on 09-24 (MH:3060). The copy was taken on 09-22 (MH:2780; NGX:116-121).
3. **The MyUptimeIP skill still has the bug recorded on 09-24.** It writes its backup inside `/etc/nginx/sites-enabled/` (SK-UIP:32, SK-UIP:40). nginx parses every file in that folder (`sites-enabled/*`), so a backup there becomes live config and can fail `nginx -t` (MH:3066-3068). The skill has not been fixed.
4. **MONITOR_CHECKLIST.md is partly stale.**
   - Its Group 1 table still uses dealership-name keywords (MC:18-20). The corrected guidance is street addresses (UMS:54-56; MH:1886).
   - It says the inventory TTL is 2 h, and the beat-heartbeat interval of 9000 s was derived from that (MC:49-51). The TTL is now 72000 s (MH:2616).
5. **Access-model text is stale in several places.**
   - UMS:17, UMS:35-42, MC:3-7 and UCY:21-25 say the security group allows only port 22 from one admin IP and that the UI is tunnel-only.
   - Since 09-18, 80/443 are open and Kuma is public behind an IP allowlist (MH:2743-2754).
   - Shell access also works over the tunnel address 10.8.0.1 while on the VPN (MH:2925).
6. **The VPN command log's resource index still shows the old Elastic IP `44.242.4.12`** (VCL:13; VH:9, VH:17). The current EIP is `44.225.91.181` (VPNm:21; HO:137).
7. **ALB weights conflict.** HO:46 says 50/50. MH:2709 (2026-09-21) says 35/65. STATUS.md already lists this conflict.
8. **Logging gaps (CLAUDE.md §4).**
   - Not in either COMMAND_LOG, only in MH narrative:
     - the 09-22 DLM policy `policy-01e45e775632d7de9` creation and the volume tagging (MH:2803)
     - the 09-18 swap and mem_limit change on the VPN box (MH:1890-1894)
     - the 09-22 and 09-24 nginx edits on the VPN box (MH:2772, MH:3060)
     - the user's 09-22 UDP rule re-add (MH:2784)
   - The 10-05 sweep has no COMMAND_LOG entry, so its exact commands are not recorded.
9. **Time-sensitive [doc].** A registry (RDAP) lookup on 09-25 showed:
   - `surfcitynissan.com` expires **2026-11-12**, about 30 days from today (2026-10-13).
   - `coronanissan.com` expires 2026-11-21.
   - We do not own these registrations and auto-renew status is unknown (MH:3114-3128).

---

## 1. Issue catalogue

Field order for each issue: date | system | symptom (lay terms) | detection | root cause (final; earlier wrong version noted) | fix (with approval status) | verification | status | if it happens again | simple prompt | citations.

### A. Dealerships platform (ocean, frontends, integration VM, ALB)

**D-01 Inventory cache stampede and "ratchet" degradation (TODO item 11)**
- **Dates:** 2026-09-11 to 09-21 (fixed 09-21).
- **System:** ocean (Django, Celery worker/beat, per-node Redis) on nodeA and nodeB; ALB alarm `dealerpulse-alb-latency-p99`.
- **Symptom:** Inventory and vehicle pages got very slow, up to about 52 s. Occasional "502" on vehicle detail pages. The Slack latency alarm fired about every 2 hours, roughly 7 minutes past the hour.
- **Detection:**
  - Alarm firings lined up with the 2 h TTL boundaries (MH:2089-2100).
  - nginx logged 502s at `rt=60.000`, which is exactly gunicorn `--timeout 60`, two hours after the 15:00 warm (MH:1918-1923).
  - Live Redis inspection showed only 1 key per rooftop (MH:2432-2447).
- **Root cause (final):**
  - `HOMENET_CACHE_TTL_SECONDS=7200` (2 h) is shorter than the longest gap between warms. The warms run at 01:00, 15:00 and 20:00 UTC, so the gap reaches 14 h.
  - When the cache expires, user requests refill it lazily with no lock (a stampede).
  - The lazy path writes only the blob. It skips the per-VIN keys, the dropdown stats and `sync_meta`, so the cache degrades.
  - HomeNet SOAP calls plus gunicorn's 60 s timeout kill workers, which produces the 502s (MH:1918-1928, MH:2263-2279, MH:2430-2452).
  - Earlier wrong statement: on 09-17 the 60 s timeout cliff was called "unrealised". This was corrected on 09-19 (MH:1925-1928).
  - An earlier plan to recreate web+worker+beat was superseded (MH:2460-2471).
- **Fix (approved production change, 2026-09-21, nodeA cmds 208a5c2d/46bdd6ea, nodeB 5200e50f):** In `/opt/dealerpulse/backend/ocean`:
  1. Back up `.env` *outside* the repo.
  2. Run `sed` to change `HOMENET_CACHE_TTL_SECONDS` from '7200' to '72000'.
  3. Confirm `diff` shows one line and `git status --porcelain | wc -l` is 0.
  4. Run `docker compose up -d --no-deps --force-recreate worker beat`.
  5. Run `docker compose exec -T worker celery -A coresite call apps.homenet_inventory.tasks.refresh_homenet_inventory_cache`.
  - `web` was not touched (CL:2838-2865; MH:2614-2623).
  - Rollback: restore the backup, recreate worker and beat, re-run the celery call (CL:2864-2865).
- **Verification:**
  - All 8 rooftop caches complete with TTL about 71,8xx s (MH:2625-2638).
  - Homepage 1.66 s to 0.72 s; VIN detail from 52.9 s worst case to 0.94 s (MH:2643-2650).
  - Alarm silent for 29 h and zero 5xx (MH:2819-2821).
  - The fix survived the 09-23 deploy because `deploy.sh` never touches `.env` (MH:2939-2942; MH:2889-2892).
  - Still holding on 09-25 (MH:3149-3153).
- **Status:** Mitigated by configuration. Still with the developer: single-flight plus stale-while-revalidate, a complete-or-nothing fallback write, a longer `sync_meta` TTL and a cache-age alarm (MH:2658-2660).
  - Caveat: the 09-23 deploy moved `web` to 72000 as well. If a warm fails, a degraded entry now persists for 20 h instead of 2 h (MH:3002-3005).
- **If again:**
  - Check the worker logs for `ttl=72000 ... failed_dealerships=0`.
  - Check the `inventory:sync_meta` TTL.
  - Scan Redis DBs 2/6/11/12, **not db1, which is always empty** (CL:2916-2921, CL:2927-2928).
  - Do not retune the alarm (HO:124).
- **Prompt:** "Inventory pages are slow and the latency alarm keeps firing — check the HomeNet inventory cache."

**D-02 Postgres "too many clients" (JD Power fan-out)**
- **Dates:** 2026-09-16 (83 events) and 2026-09-19 21:00 UTC (24 events).
- **System:** ocean, plus `ocean-shared-postgres` on the integration VM.
- **Symptom:** None visible to customers. Logs show `sorry, too many clients already` / `remaining connection slots are reserved`, and JD Power audit-log writes fail.
- **Detection:** Log sweeps on 09-19 and 09-21 (MH:1930-1934, MH:2120-2137).
- **Root cause:**
  - `jdpower_enrichment.py:227` runs `ThreadPoolExecutor` with `JDPOWER_FETCH_WORKERS=15`. Each thread opens its own DB connection, held by `CONN_MAX_AGE=60` with no `close_old_connections()`.
  - The ceiling is 360 connections across both nodes against `max_connections=150`.
  - It is triggered after the 20:00 UTC warm, when new VINs miss the cache.
  - Aggravating settings: `statement_timeout=0`, `idle_in_transaction_session_timeout=0`, and `ATOMIC_REQUESTS=True` wrapping the 30 s SOAP call (MH:1936-1946, MH:2133-2137).
  - Earlier wrong statement: "one burst, nothing since" (MH:1934). Corrected (MH:2122).
- **Fix:** None. It needs a code change.
- **Status:** Open and non-fatal. Not recurred as of 09-24, when connections were 16/150 (MH:2944-2945).
- **If again:** Correlate the events with the 20:00 UTC warm and check the connection count.
- **Prompt:** "Are we running out of Postgres connections again?"

**D-03 Lead booking failures to VinSolutions/Cox**
- **Dates:** 2026-09-19 onward.
- **System:** `leads_backend` on the integration VM; ocean task `book_request_e_price_lead_vinsolutions`.
- **Symptom:** A customer enquiry may not reach the dealership CRM.
- **Root cause and facts:**
  - 15 errors of "Cannot create a lead for a customer that already has an active lead" are a VinSolutions business rule, not a fault (MH:2016-2018). However, on 10-01 the phrase "still booked" matched 0 times, so re-confirm with the developer (MH:3294-3298).
  - 11 note-attach failures with 401 are non-fatal. Hypothesis: a dealer-scoped token is used against another rooftop's contact (MH:2019, MH:2024-2026).
  - An invalid email (Cox does live SMTP verification) **discards the whole lead**. These are the only genuinely lost leads (MH:2020, MH:2028-2030).
  - 422 responses from `https://leads.callingyounow.us/api/vinsolutions/book-lead`: 3 seen (MH:2157-2159); one e-Price lead lost on 09-23 (MH:2963-2967); one more on 10-05 on nodeB (MH:3571-3581).
  - Earlier wrong statement: "15 failed leads = 15 lost customers" (MH:1948-1954). Corrected to about 1 real lost lead in four days (MH:2013-2023).
- **Status:** Open; needs the developer plus Cox.
- **Prompt:** "Did any customer leads fail to reach VinSolutions today?"

**D-04 Customer confirmation emails fail (SMTP 535)**
- **Date:** First recorded 2026-10-01.
- **System:** `leads_backend-web-1` (`app.services.email_service`).
- **Symptom:** Customers never receive their confirmation email.
- **Detection:** 10-01 error sweep; 8 occurrences in 7 days (MH:3256-3265).
- **Root cause:** SMTP rejects the credentials (`535 5.7.8 authentication failed`). It will not self-heal.
- **Fix:** None recorded.
- **Status:** Open as of its last mention, 10-01.
- **If again:** The SMTP credential needs updating by its owner. Agents cannot create credentials (classifier block, T-01).
- **Prompt:** "Customers say they didn't get a confirmation email — check leads_backend email errors."

**D-05 Celery beat runs on both nodes (scheduled tasks run twice)**
- **Date:** Found 2026-09-19.
- **System:** `nisanwebsite-beat-1` on nodeA and nodeB.
- **Symptom:** None visible. Vendor calls are doubled, and duplicate sold-vehicle processing or duplicate emails are possible.
- **Detection:** Both beats log "Sending due task" (MH:1956-1966). Podium sync is also scheduled on both (MH:3568-3569).
- **Fix proposed:** Disable beat on nodeA, but **only together with** a Kuma push-heartbeat monitor (OCP:68-75; MC:47-53; MH:1819).
- **Status:** Open and optional (Claude-Setup\STATUS.md:24).
- **Prompt:** "Are our scheduled jobs running twice?"

**D-06 Every deploy causes a brief burst of 502s**
- **Dates:** Recurring. Measured on 09-23 (21 user-facing 502s), 09-24/25 (24), 09-30 (52 in one hour) and 10-02 (38).
- **System:** Frontend and ocean deploys via Bitbucket, then SSM to both nodes.
- **Symptom:** "502 Bad Gateway" for a few seconds to minutes, or JS chunk errors for visitors holding an old page.
- **Detection:** nginx logs with `rt` 0.000-0.002 (MH:1968-1973), ALB hourly 5xx localisation, and container ages (MH:2957-2961, MH:3156-3160, MH:3304-3309, MH:3553-3554).
- **Root cause:**
  - The pipeline step "Deploy to Node A + Node B (atomic)" sends one SSM command to both nodes.
  - `deploy.sh:141-142` does `docker rm -f` then `docker run`, with no draining and no health-gated cutover.
  - The ALB check does not test port 3000. The drops are connection-level and never reach Django (MH:2032-2049, MH:3307-3308).
  - Correction: the 09-18 502s were a **manual `docker restart`** on both nodes, not a deploy (MH:2290-2311).
- **Fix:** Per-node blue/green is proposed (MH:2046-2049). It is "not built because of cost complexity" (HO:117).
- **Status:** Accepted.
- **If again:** If the 5xx cluster in a deploy hour, it is this. Check `docker inspect` Created/StartedAt.
- **Prompt:** "We got a burst of 502 errors — was it just a deploy?"

**D-07 Integration VM memory pressure, driven by chat_back**
- **Dates:**
  - 09-19: 1,040 MB available, swap 39% (MH:1981-1985, MH:2051-2072).
  - 09-21: recovered after a chat redeploy (MH:2565-2577).
  - 09-25: 478 MB available, swap 487 MB, chat_back 2.01 GiB (MH:3162-3189).
  - 10-01: 961 MB after a restart (MH:3310-3312).
  - 10-05: **279 MB available, swap 51%, chat_back 2.144 GiB** (MH:3520-3530).
- **System:** Integration VM `i-03efb82c808863f84` (t3.medium, 3.8 GB). It also hosts `ocean-shared-postgres`, the database for all rooftops.
- **Symptom:** Chat, admin and leads get slow. The risk is the whole platform going down if the out-of-memory killer hits Postgres (MH:3187-3189).
- **Detection:** Sweeps only. **There is no memory alarm** (MH:3195-3197).
- **Root cause (final):**
  - chat_back runs `uvicorn --workers 4`. Its baseline is about 1.5 GB (model and embedding load) plus about 0.5 GB of growth over 10 days.
  - A `--workers 2` tuning was lost when the 10-02 (Friday) "revert-pull-deploy" restored the committed `--workers 4` (MH:3532-3537).
  - Earlier wrong statement: "leak; a restart reclaims ~1.9 GB". In fact a restart reclaims about 0.5 GB (MH:3483-3489).
- **Fix:** Push commit `3ed8deb` (`--workers ${UVICORN_WORKERS:-2}`) and redeploy chat_back (MH:3538-3541). This is a production change and needs approval.
  - Do not run `swapoff -a && swapon -a` (OCP:121). Do not tune swappiness (OCP:121).
  - Restarting chat drops live websocket chats (MH:2070-2072).
- **Status:** Open at 10-05. STATUS.md:10 says the fix is on `origin/main-migrated` as of 2026-10-13, but deployment is unconfirmed.
- **Prompt:** "Is the integration server running out of memory? Check chat_back workers and swap."

**D-08 Reboot pending on all three VMs (libc6, plus a kernel jump on integration)**
- **Date:** Flag set 2026-09-11.
- **System:** nodeA, nodeB, integration.
- **Symptom:** None visible. Security patches are not active.
- **Root cause:**
  - `unattended-upgrades` installs but never reboots.
  - nodeA and nodeB need a reboot only to activate `libc6`.
  - Integration needs `libc6` plus a kernel move from 6.17 to 7.0 (MH:2178-2200).
- **Preconditions recorded:**
  - The restart-policy trap is fixed (D-09).
  - DLM snapshots exist (MH:2396-2408).
  - The quietest window is about 10:00 UTC (MH:2410-2420).
  - **Rebooting integration is a full-site outage**, because the shared Postgres is on it (MH:2422-2426).
  - For a node reboot, shift the ALB listener weights to 0/100 first (MH:2713-2715).
  - Restart impact per container is listed at MH:2717-2729.
- **Status:** Open; last mentioned 09-21. Needs approval.
- **Prompt:** "Do our servers need a reboot for security updates, and how do we do it safely?"

**D-09 Reboot trap: chat_back containers had restart policy `no`**
- **Date:** 2026-09-21; fixed the same day.
- **Fix:**
  1. The user ran `docker update --restart=unless-stopped chat_back-web-1 chat_back-postgres-1` (MH:2348-2349).
  2. An approved compose edit (CL:2814-2836) broke the deploy (see D-10).
  3. Final fix: the change came through git (PR #47, `a64ba5e`).
- **Verification:** Both containers `unless-stopped`, git diff 0 lines (MH:2595-2610). All compose files declare the policy (MH:2664-2675).
- **Status:** Fixed.
- **If again:** Check both the live policy (`docker inspect`) and the committed compose file. `docker update` alone is temporary (MH:2351-2353).
- **Prompt:** "If the integration server reboots, will everything come back up by itself?"

**D-10 Pipeline fails with "uncommitted or untracked changes" (dirty deploy directory)**
- **Dates:** 2026-09-21. A related loss of the `--workers 2` change on 10-02.
- **System:** Deploy directories on the VMs are git working trees; the `deploy.sh` guard is at `:78` and `:97`.
- **Symptom:** The Bitbucket chat_back deploy failed twice (MH:2475-2491, MH:2584-2589).
- **Root cause:** The agent edited a tracked file and left a `.bak` file inside the working tree.
- **Fix (approved, SSM `0c3042a5`):**
  1. `mv docker-compose.yml.bak.* /opt/dealerpulse/`
  2. `git checkout -- docker-compose.yml`
  - Deploy attempt 3 succeeded (MH:2533-2544, MH:2579-2593).
- **Lessons:**
  - Never edit tracked files in deploy directories.
  - Never write backups inside the tree.
  - `.env` is gitignored and safe to edit. `.env.bak` is **not** gitignored, so keep backups outside the repo (MH:2493-2517; CL:2844).
  - Push first, then deploy (MH:2529-2531).
- **Prompt:** "The deploy pipeline failed saying the directory has uncommitted changes — what do I do?"

**D-11 The ALB health check cannot see a dead frontend**
- **System:** `dealerpulse-tg-nodea` / `-nodeb`: `HTTPS:443 GET /`, matcher `200-499`, 15 s interval.
- **Final finding:** The probe reaches gunicorn and gets a 400 (the gunicorn log shows `ELB-HealthChecker/2.0`). So it verifies nginx and gunicorn, but **not Next.js on port 3000** (MH:3007-3014).
  - Earlier wrong statement: "pure nginx probe, never reaches app" (MH:2680-2705).
  - Consequence: on boot, a node gets traffic before its app containers are ready (MH:2697-2701).
- **Fix proposed:** nginx `location = /healthz { return 200; }` (TODO item 2; MH:3049-3052).
- **Status:** Open.
- **Prompt:** "Would the load balancer notice if a website container died on one server?"

**D-12 `dealerpulse-tg-nginx` looks orphaned but is the rollback path**
- **Date:** 2026-09-24 correction.
- **Earlier wrong recommendation:** Deregister it as waste (MH:2978-2982).
- **Final:** It is the deliberate instant listener rollback target (CL:2262, quoted at MH:3020-3027). Deregistering its targets would break the rollback (MH:3042-3043). It is not health-checking and costs nothing (MH:3141-3145).
- **Status:** Keep (decision).
- **Prompt:** "Can we delete the unused dealerpulse-tg-nginx target group?" (Answer: no.)

**D-13 Slow image tail (TODO item 12) and legacy URL fallthrough (TODO item 3a)**
- **Date:** 2026-09-22.
- **Finding:** 82% of requests slower than 15 s were `/_next/image`, averaging 28 s. The rest were old `.htm` URLs and `/used|/certified|/new/{Make}/...` paths falling through to server-side rendering, taking 16-112 s (MH:2827-2847).
- **Fix:** Committed on branch `perf/next-image-optimizer-2026-09-22`, commit `b9708de` (drops AVIF and the 1920 width). Deploying it causes the D-06 502 window (MH:2894-2919).
- **Status:** On the branch; deployment not recorded.
- **Prompt:** "Why do some vehicle images take 20-30 seconds to load?"

**D-14 Burst of broken vehicle images**
- **Date:** 2026-09-20 07:11:47 UTC.
- **Facts:** 15×504 and 14×500 within one second on nodeB, all from `content.homenetiol.com`. Self-resolved.
- **Cause:** A HomeNet image CDN stall. CPU starvation after the stampede is a hypothesis only (MH:2108-2118).
- **Status:** One-off.
- **Prompt:** "Vehicle photos were broken for a moment — us or HomeNet?"

**D-15 HomeNet SOAP read timeouts**
- **Facts:** 1-3 per day on the warm cron, `read timeout=30.0` (MH:2139-2153).
- **Cause:** Vendor side. The 20 h TTL now absorbs it.
- **Status:** Accepted.

**D-16 INCIDENT: pages render with no content (SSR 428)**
- **Date:** 2026-10-01; resolved the same day.
- **System:** `website_frontend` (`utilis/apiCrypto.ts`) and the ocean encryption middleware.
- **Symptom:** Header and footer show but the body is empty: no FAQs, no inventory. **All alarms stayed green.**
- **Detection:** Reported by the user. A sweep about 30 minutes earlier had said "healthy" (MH:3319-3330).
- **Root cause:**
  - The frontend memoises a *failed* crypto session (`null`) for the life of the process.
  - The deploy started the frontend before Django was serving (12 s gap on nodeB).
  - Every server-side render therefore omits `X-Crypto-Key` and gets `428 crypto_key_required`.
  - `resetSession()` runs only on `crypto_key_invalid`, so the process never recovers (MH:3332-3362).
  - Scale: 2,275 × 428 within one hour, about 190 failed calls per minute (MH:3364-3372).
- **Fix (user approved, production):** `docker restart website_frontend website_frontend_surfcity`, nodeA first, then nodeB (MH:3374-3377; CL:2971-2972).
- **Verification:** 428 rate per minute 66 to 0 and 44 to 1. `/faqs/` renders. Homepage carries inventory data (MH:3379-3385).
- **Follow-ups not done:**
  - Code fix: cache only a successful session; reset on `crypto_key_required` too.
  - Order the deploy so the frontend waits for Django.
  - Add a 428-rate alarm.
  - Purge Cloudflare (MH:3387-3399).
  - On 10-03 there was no recurrence only by luck: the frontend started 8 minutes after Django (MH:3417-3421).
- **Status:** Workaround applied; the root cause can recur after any deploy. No recurrence at 10-05 (MH:3555-3556).
- **If again (diagnosis commands, CL:2963-2969):**
  - Run `docker logs nisanwebsite-web-1 --since 24h | grep ' 428 '` and bucket by hour with `cut -d: -f1-2`.
  - Split server-side traffic (User-Agent "node") from browser traffic ("Mozilla") (CL:2980-2986).
  - Test the bootstrap from inside the frontend: `docker exec website_frontend sh -c 'curl ... https://api.callingyounow.us/api/crypto/public-key/'`.
  - Restart only the affected frontend containers, one node at a time, with approval.
  - Note: `website_frontend_corona` was unaffected that time (MH:3371-3372). There are now four frontends per node (MH:3560-3561).
- **Prompt:** "The website loads but the content and inventory are blank — check the 428 canary."

**D-17 Chatbot says "temporarily unavailable" to everyone**
- **Date:** 2026-10-02, starting 20:13:23 UTC.
- **System:** `chat_back-web-1` and OpenRouter.
- **Symptom:** The widget shows a graceful "temporarily unavailable" message plus the dealer's contact details. The container looks healthy (MH:3451-3474).
- **Root cause:** The OpenRouter account ran out of credits (HTTP 402). The fallback model is also on OpenRouter, so both paths fail together (MH:3465-3470).
- **Fix:** Billing top-up at openrouter.ai/settings/credits. Nothing to deploy (MH:3476-3477).
- **Verification:** At 10-05, 5,370 sessions and 0 OpenRouter errors (MH:3543-3548).
- **Status:** Fixed. **No alarm covers it.** A provider low-credit alert is recommended.
- **Prompt:** "The chatbot keeps saying it's temporarily unavailable."

**D-18 `M2MAttachmentSerializer` AttributeError**
- **Facts:** Breaks the Swagger/schema endpoint, not customer traffic. Source `apps/sitesettings/serializers.py:377`.
- **Status:** Still live on 10-01 (7 per 24 h on nodeA). Open, on the developer list (MH:2993-2997, MH:3267-3276).

**D-19 Lots of unique-violation errors in Postgres logs**
- **Facts:** `uniq_dash_site_visit_bucket`, about 247 per day. Benign: a savepoint handles it, and `current transaction is aborted` appears 0 times.
- **Optional improvement:** `INSERT ... ON CONFLICT` (MH:3280-3287).
- **Other benign log lines:**
  - websocket `ConnectionClosedError` (MH:3288-3290)
  - `syntax error at or near "21"`, from a human ad-hoc query (MH:3291-3293)
  - distiller "Session not found" (MH:3546-3548)
  - `page=error.php` bot traffic (MH:3581-3583)
  - scanner `/error*` probes, doubled by the SSR hairpin (MH:2160-2162)

**D-20 You cannot tell which commit is deployed by looking at the VM**
- **Facts:** Compose pins `:latest` and no git SHA is baked into the image.
- **How to check:** Match `docker inspect -f '{{index .RepoDigests 0}}'` against `aws ecr describe-images`. **Not** `{{.Image}}`, which is the config digest (MH:3425-3431; CL:2993-2998, CL:3003-3006).
- **Prompt:** "Which version of the backend is running in production right now?"

**D-21 "Your models in app(s): 'cms' have changes" on every deploy**
- **Facts:** A no-op pending migration `0050_alter_special_vin` (only `help_text` differs). Committing it clears the warning (MH:3433-3447).
- **Status:** Open; cosmetic.

**D-22 Wasted request patterns**
- `payment-calculator` 301 then 404, about 3,100 per day (MH:2969-2971).
- Trailing-slash 301s, 5,490 per day (MH:2973-2976).
- `pages/null`, about 4% of traffic (OCP:182-184).
- SSR hairpin, about half of ALB RequestCount (OCP:166-172).
- **Status:** Open optimisations.

**D-23 Audit table growth**
- **Facts:** `homenet_inventory_integrationauditlog` was 73% of the database on 09-19 and 78% (112 MB of 143 MB) on 09-24, growing by 2,702 rows per day. There is no retention policy (MH:1975-1979, MH:2984-2986).
- **Status:** Open; not urgent.

**D-24 A configured special silently not shown**
- **Facts:** VIN `1N6ED1EJ3TN664444` has left inventory and there is no snapshot, so the special is skipped (MH:2988-2991).
- **Status:** Open; a dealer content issue.

**D-25 Celery runs as root**
- Low-priority hardening item (MH:2999-3000).

**D-26 Surf City served Puente Hills' `<title>` and `og:title`**
- **Date:** 2026-09-18.
- **Symptom:** The browser tab and search title for surfcity.callingyounow.us said "Puente Hills Nissan". Canonical URL, address and phone were correct (MH:1843-1858). This is a regression from 09-11 (MH:1860).
- **Cause:** Not established. Hypothesis: a stale prerender (`stale-while-revalidate` of about 365 days) combined with per-node ISR caches; `utilis/createPageMetadata.ts` is the suspect file (MH:1864).
- **Fix:** None. Not investigated (MH:1866).
- **Status:** Open at its last mention (MH:1900; UMS:88).
- **Prompt:** "The Surf City site's title says Puente Hills — check the page metadata."

**D-27 Leftovers: do not delete without checking**
- `website-shared-redis` is unused (dbsize 0, zero keyspace hits ever) (MH:2381-2394).
- Orphaned volumes: `nisanwebsite_postgres_data` on nodeA and `chat_backend_postgres_data` on integration (MH:2251-2254).
- Dead compose copy `/opt/dealerships/chat_backend` (MH:2372-2375).
- `integrations_service` compose exists but nothing is deployed from it (MH:2377-2379).

**D-28 Reading the wrong branch for production code**
- `staging` deploys to Docker Hub for other environments. AWS production runs ECR images built from the `main-*` branches (MH:2313-2335; HO:102-107).

**D-29 Graviton (arm64) test**
- **Date:** 2026-10-06.
- **Facts:** Every ECR image is amd64-only and fails with `exec format error`. Test nodeC `i-0b6037690786f7624` was terminated the same day.
- **Status:** Closed by user decision (MH:3585-3599; CL:3052-3088).

**D-30 API returns 428 to plain curl**
- **Facts:** This is by design (encryption layer), not an outage. Infer API health from the frontend or the logs instead (MH:2082-2085; CF:84).

**D-31 Retracted claims, so they are not re-raised**
- "Postgres exposed on 0.0.0.0:5432": the security group restricts it (MH:1997-1999).
- "Port 8129 is an orphan": it is `leads_backend` (MH:2000-2001).
- "JD Power warm is a no-op": it is working (MH:2002-2004).
- "Requests averaging 32 s": a parsing artifact. Log windows that start before 2026-09-16 are skewed, so use windows of 2 days or less (MH:2005-2007).
- "Integration swap is live pressure" on 09-19: it was mostly cold pages at that time (MH:2067-2069). By 10-05 it was real pressure (D-07).

**D-32 Dealership domain registrations expiring**
- **Date:** RDAP lookup on 2026-09-25.
- **Facts:** surfcitynissan.com 2026-11-12, coronanissan.com 2026-11-21, puentehillsnissan.com 2026-12-11, alhambranissan.com 2027-08-01. We don't own them and cannot see auto-renew; it was raised as a question for the CTO (MH:3114-3130).
  - Kuma's default 7/14/21-day thresholds warn too late (MH:3130).
  - `.us` has no RDAP endpoint, so Kuma's built-in check cannot cover `callingyounow.us` (MH:3098-3112).
- **Status:** Open.
- **Prompt:** "When do our dealership domains expire and is anyone renewing them?"

**D-33 Other known gaps (fire exit and access), all open**
- No restore has ever been tested, and there is no RTO/RPO (CB:155-156).
- The old DigitalOcean droplet is not a viable rollback: data diverged at cutover (CB:159).
- Legacy Bitbucket pipelines still deploy to the old DigitalOcean `prod` server on a push to master/main/staging. This was deliberate until decommission (CB:57).
- The IAM groups exist but are empty; no MFA; long-lived keys in use (CB:128-142).
- Redis is unbounded (`maxmemory 0`, `noeviction`). The plan is `volatile-lru` at 512 MB, **never `allkeys-lru`**, because Redis is also the Celery broker. Plan status is DRAFT and application is not recorded (OCP:56-66).
- `effective_cache_size` is 5 GB on a 3.8 GB box (OCP:125).
- t3 CPU-credit cliff on nodeA (OCP:97-103). The nodes were still t3.large at 10-03 (MH:3493-3494; HO:76).

### B. Monitoring and alerting

**M-01 No external (outside-AWS) uptime check**
- **Facts:** Kuma runs in the same account and region, so it cannot report an AWS-level event. The external check was recommended on 09-18 as not optional (MH:1815, MH:1841; MC:69-79; UMS:9-13).
- **Evidence it matters:** The 3-5 day VPN outage went unnoticed (MH:2786).
- **Status:** "Not yet confirmed done" (HO:125).
- **Prompt:** "Do we have any monitoring outside AWS?"

**M-02 No memory, swap or disk alarms (TODO item 1)**
- **Facts:** CWAgent publishes the metrics, but nothing alarms on them. The integration VM's decline was invisible (MH:3195-3197; OCP:85-89; HO:128). Thresholds should come from a measured baseline, not instinct (OCP:89).
- **Status:** Open.

**M-03 Known blind spots (green dashboard, broken site)**
- Server-side render returns 200 with no data (the 428 incident).
- Chatbot out of credits.
- Integration VM memory.
- Sources: HO:126-129; CL:2977-2979; MH:3396-3397, MH:3479-3481.
- **Status:** Covered only by the manual daily sweep.

**M-04 Latency alarm flapped**
- **Date:** 2026-09-27, 03:57-04:08 (+05:00): OK→ALARM→OK→ALARM→OK, self-cleared. No cause is recorded (MH:3302-3303).

**M-05 Kuma keyword-assertion trap**
- **Facts:** The fallback value `DEFAULT_SITE_NAME = "Surf City Nissan"` makes a name keyword useless. Use street addresses instead: `17331 Beach Blvd` (Surf City) and `17320 Gale Ave` (Puente Hills) (MH:1839, MH:1868, MH:1886; UMS:54-58; HO:125).

**M-06 Certificate renewal silently broken**
- **Date:** Found 2026-09-07; fixed.
- **Facts:** `certbot.timer` had never worked. The country rule also blocked ACME HTTP-01, and the nodes moved to DNS-01 (CF:104-110). Kuma's cert-expiry threshold is 21 days (MC:41-45; UMS:60-64).

**M-07 Kuma domain-expiry monitor `callingyounow.com` (id 18) stuck at 0%**
- **Date:** 2026-09-25.
- **Root cause:** The monitor was copied from id 17 and still queried `rdap.nic.us`, which returns 404 for .com. The 404 failed the monitor before the expression ran (MH:3201-3218). Other causes ruled out are at MH:3220-3224.
- **Fix (UI, one field):** Set the URL to `https://rdap.verisign.com/com/v1/domain/callingyounow.com`. Do not edit the database, because Kuma caches monitors in memory (MH:3226-3229).
- **Also:** Turn off `domain_expiry_notification` on ids 17 and 18 (MH:3231-3234).
- **Status:** Fix specified; application not recorded.

**M-08 Wrong p99 from the wrong dimension**
- **Facts:** The 15 Sep p99 was reported from a target group being decommissioned. Always use the LoadBalancer dimension `app/dealerpulse-alb/dc80177beaa3aa2f`, read off the alarm itself (CB:103-107; CL:2735-2737).

**M-09 fd-exhaustion alarm deleted; its metric filter still publishes**
- Sources: OCP:78-83; CB:99. HO:124 says "verify it exists".
- **Status:** Unknown.

**M-10 Other monitoring facts**
- nginx error logs to CloudWatch "broken since a config wipe" (CB:98); status not updated since.
- SNS `dealerpulse-alerts` has one subscriber, the Chatbot (CB:118). Do not casually recreate the Chatbot config (HO:87).
- Alarms were deliberately loosened on 09-14. **Do not retune them to silence noise** (CB:105-107; HO:124; MC:10).
- Timezones: nginx logs are UTC; container logs are +0500 (HO:169).
- Removing the SSR hairpin will halve RequestCount and double computed error rates, so thresholds must be retuned in the same change (OCP:172).

### C. Cloudflare edge (zone callingyounow.us, plus the third-party puentehillsnissan.com zone)

**CF-01 Country rule blocked Let's Encrypt validation (cert renewal failing)**
- **Date:** 2026-09-07.
- **Fix:** Expression changed to `(not (ip.src.country in {"US" "CA" "PK"})) and not starts_with(http.request.uri.path, "/.well-known/acme-challenge/")`. HTTP-01 still failed for an nginx-plugin reason, so the nodes moved to DNS-01 (CF:104-108).
- **DNS token:**
  - The token is in SSM Parameter Store `/dealerpulse/shared/cloudflare-dns-token`.
  - The nodes' `/etc/letsencrypt/cloudflare.ini` is a local copy that must be refreshed on rotation (CF:110).
- **Prompt:** "Certificate renewal is failing on a node."

**CF-02 Cross-node JS chunk 404 cached at the edge**
- **Date:** 2026-09-16.
- **Fix:**
  - `status_code_ttl` set to 0 for 4xx and 5xx on the static rule.
  - Deploy-timing fix: both nodes in one automatic pipeline step (the planned pull/swap split was never built).
  - Automatic `purge_everything` after every deploy (CF:134-154).
- **Status:** Fixed.

**CF-03 Broken pre-existing "BlockingTraffic" rule**
- **Date:** 2026-09-04.
- **Facts:** The disabled rule used `ne ... or ne ...`, which would have blocked almost everyone if enabled. It was replaced with an `in {...}` set (CF:62).

**CF-04 puentehillsnissan.com cutover failures (third-party zone)**
- **Dates:** 2026-09-09/10.
- **Facts:**
  - Grey-cloud (unproxied) DNS gave a total timeout, because the origin lockdown drops direct traffic.
  - "Flexible" SSL mode gave a redirect loop; it needs "Full" (CF:120-126).
  - Zone access was later obtained via a minted token (CF:128-132).

**CF-05 "3 s TTFB" misdiagnosed as backend slowness**
- **Dates:** 2026-09-04/05.
- **Facts:** The real cause was Cloudflare not caching HTML plus round trips to us-west-2; on-box render was 20-30 ms (CF:51, CF:82). Do not reopen query optimisation without re-measuring.

**CF-06 `/_next/image` was not edge-cached**
- **Date:** Fixed 2026-09-05 with a 4th cache rule plus the Set-Cookie strip (CF:86).

**CF-07 Auto Minify silently does nothing**
- **Facts:** The API returns success but the setting stays off. Do not retry (CF:39).

**CF-08 Token permission edits do not persist**
- **Facts:** Create a new token instead of editing. Custom WAF rules need the "Zone WAF Write" permission group (CF:55-57).

**CF-09 Post-purge slowness from Pakistan**
- **Dates:** Measured 2026-09-29/30.
- **Facts:** A cache hit takes 34-44 ms; an origin fetch takes 315 ms from Pakistan (about 9x) versus 68 ms from the US. This is expected after each merge; do not chase it (CF:156-161).

**CF-10 Kuma origin reachable directly, bypassing Cloudflare**
- See V-07.

### D. Team VPN box and Uptime Kuma (`i-0ad5d9743f6c95721`, t4g.micro, EIP 44.225.91.181)

**V-01 wg-easy failed to start at bootstrap**
- **Date:** 2026-09-10.
- **Error:** `sysctl "net.ipv4.conf.all.src_valid_mark" not allowed in host network namespace`.
- **Cause:** A `sysctls:` block combined with `network_mode: host`.
- **Fix:** Set the values in `/etc/sysctl.d/99-wireguard.conf` on the host, remove the block, run compose down/up (VCL:68-87; VH:13).
- **Standing rule:** Never put `sysctls:` in a compose service that uses host networking (VCL:87).

**V-02 SSM role creation blocked, so the box is SSH-only (lockout risk)**
- **Facts:** IAM role creation was classifier-blocked. The user chose SSH (VH:11; VCL:37-41).
- **Risk:** No SSM agent and no instance profile. With a dynamic admin IP, this is a genuine lockout risk (MH:2795).
- **Mitigation:** While on the VPN, use 10.8.0.1 (V-09).

**V-03 Elastic IP changed; wg-easy still hands out the old one**
- **History:**
  - 44.242.4.12 (09-10).
  - 34.210.45.11 (09-11 21:22 UTC, replaced 3 minutes later and left idle; released 10-03).
  - 44.225.91.181 (current) (VCL:48-50; VPNm:21; MH:3497-3500).
- **Problem:** wg-easy's stored host is still 44.242.4.12, so generated client configs carry a dead `Endpoint`. It must be corrected to `44.225.91.181:51820` (SK-WG:52).
- **Status:** Open per the skill.

**V-04 Team VPN down for 3-5 days; nobody noticed**
- **Dates:** About 2026-09-18 to 09-22.
- **System:** `team-vpn-sg` `sg-020165aeddafe5322`.
- **Symptom:** WireGuard clients could not connect.
- **Detection:** Incidental, while reviewing Kuma access (MH:2756-2760).
- **Root cause:** The SG had **zero UDP rules**. The UDP 51820 rule was replaced by a useless TCP 51820 rule when 80/443 were opened on 09-18. The box itself was healthy (MH:2760, MH:2784).
- **Fix:** The user re-added UDP 51820 (MH:2784).
- **Lessons:**
  - Nothing watches the box (MH:2786).
  - `PersistentKeepalive` was off, so handshake age was useless as a health signal. Set it to 25 (MH:2931).
- **Status:** Fixed.
- **Prompt:** "Nobody can connect to the team VPN."

**V-05 Kuma "Down" storm: every monitor failing while the sites were fine**
- **Date:** 2026-09-18.
- **Symptom:** Dozens of `socket hang up`, `ETIMEDOUT` and `timeout of 48000ms` events, clustered across unrelated targets (MH:1872-1874; UMS:93-95).
- **Root cause:**
  - `mem_limit: 256m` was too tight. Kuma sat at 231 MiB, was OOM-killed 12 times, and hit the cgroup max 1,583 times.
  - The real mechanism was **`sock_throttled 996`**: the kernel throttles socket buffers under cgroup memory pressure, which stalls all outbound checks (MH:1876; UMS:97-109).
  - Ruled out with measurements: SNAT/port exhaustion (uptime-kuma#275) and Cloudflare interference (MH:1878; UMS:113-132).
- **Fix (user's explicit go-ahead):**
  1. Swap first: a 2 GiB swapfile, `vm.swappiness=10`, persisted.
  2. Then `mem_limit: 512m` and `dns: [1.1.1.1, 8.8.8.8]`.
  3. Pinned tag verified with `docker manifest inspect` before recreating (MH:1888-1894; UMS:140-154; UCY:42-58).
- **Verification:** cgroup max hits 0, `RestartCount` 0, and `sock_throttled` frozen at 19 across 3 samples. wg-easy was unaffected (MH:1896; UMS:156-169). Still holding on 09-24 (MH:2933).
- **Status:** Fixed. The 48 s to 15 s request-timeout change is recommended but not recorded as done (MH:1900; UMS:86).
- **If again:** `sudo docker inspect uptime-kuma --format "restarts={{.RestartCount}}"` and `sudo docker exec uptime-kuma cat /sys/fs/cgroup/memory.events` (UMS:151-154).
- **Do not:**
  - Raise the limit without swap; the OOM killer could pick wg-easy.
  - Use the user's `louislam/uptime-kuma:1` command. It is a major downgrade against data already migrated to v2 (2.x uses embedded MariaDB), it points at a different volume (empty instance) and has no memory limit (MH:1884, MH:1898).
- **Prompt:** "Uptime Kuma says everything is down but the sites look fine."

**V-06 Kuma DNS override looks like it didn't apply**
- **Facts:** `resolv.conf` always shows `127.0.0.11`. Verify with `docker inspect` (`HostConfig.Dns`) instead (MH:1898; UMS:171).

**V-07 Kuma public exposure, origin bypass, and the "403 everywhere"**
- **Date:** 2026-09-22.
- **Facts:**
  - `uptime.callingyounow.us` was stood up by someone else on 09-18, with a self-signed origin cert that works because SSL mode is Full (MH:2743; NGX:1-3).
  - The origin `44.225.91.181:443` is reachable directly, bypassing Cloudflare. The recommended fix is to narrow 80/443 to Cloudflare ranges; **not recorded as done** (MH:2758).
  - The 403s were a deliberate nginx IP allowlist. The team was locked out by IPv6 and dynamic IPs (MH:2764-2770).
  - Correction: the TLS behaviour was the `return 444` default server, not mTLS (MH:2768).
- **Fix (user's go-ahead):** The `health` status page was carved out as public via `snippets/kuma-proxy-public.conf` plus exact/prefix locations; `serviceWorker.js` was added in a second pass (MH:2772-2776; NGX:61-94).
- **Status:** Status page public; dashboard IP-restricted. Cloudflare Access is suggested to end the IP treadmill (MH:2780).
- **Prompt:** "I get 403 Forbidden on the uptime dashboard."

**V-08 VPN box was never backed up**
- **Date:** Found and fixed 2026-09-22.
- **Root cause:** The DLM policy targets `Project=dealerpulse`, and DLM matches **volume** tags (`ResourceTypes: VOLUME`). The volume was untagged (MH:2790, MH:2797-2801).
- **Fix:** Tagged `vol-0994ceb2ab5c7108a` with `Project=team-vpn` and `Name=team-vpn-box-root`. Created policy `policy-01e45e775632d7de9` (daily 03:30 UTC, retain 7, `dealerpulse-dlm-role`) (MH:2803).
- **Status:** Working (MH:3510-3514). A cost decision on keeping it is pending with the user (see section d). This change is not in the command log (section 0 item 8).

**V-09 SSH to the VPN box fails while connected to the VPN (hairpin)**
- **Date:** 2026-09-24.
- **Symptom:** `Connection timed out`, which looks like a firewall block.
- **Check:** `curl checkip` returns 44.225.91.181 when you are on the VPN.
- **Fix:** Use the tunnel address: `ssh ubuntu@10.8.0.1` (alias `vpn-box`; `kuma-vpn` for the Kuma port-forward). Kuma's 3001 still needs a port-forward because it is bound to 127.0.0.1, deliberately (MH:2921-2929; SK-WG:20-27).
- **Prompt:** "SSH to the VPN box times out."

**V-10 SSH timeout from a new home or office IP**
- **Facts:** The port 22 rule allows only listed IPs. The admin IP has moved 4 times (MH:2762, MH:2770, MH:3060).
- **Fix:** Run the MyUptimeIP skill, or connect to the VPN and use 10.8.0.1.

**V-11 nginx traps on the VPN box**
- **Date:** 2026-09-24.
- **Trap 1:** `sites-enabled/uptime.callingyounow.us` was a regular file, not a symlink, so edits to `sites-available` were inert. Both files were synced (MH:3064).
- **Trap 2:** A `.bak` file inside `sites-enabled/` is parsed as config, producing `[emerg] "real_ip_header" directive is duplicate` and a failed reload. There was no outage, because the running config is kept. Backups were moved to `/etc/nginx/backups/` (MH:3066).
- **Status:** The box is fixed; the **MyUptimeIP skill is not** (MH:3068; SK-UIP:40).

**V-12 Change: VPN exit IP allowlisted for the Kuma dashboard**
- **Date:** 2026-09-24.
- **Facts:** `allow 44.225.91.181;` was added, so anyone on the VPN reaches `/dashboard` (403 to 200). This is the durable replacement for per-person IPs (MH:3058-3062).

**V-13 VPN box disk 41% to 58% (misread)**
- **Facts:** It was a one-time step from the Kuma image (embedded MariaDB), not growth. `docker system df` shows 0 B reclaimable (MH:2791, MH:2805-2807).

**V-14 VPN box reboot-required; 19 packages upgradable**
- **Facts:** `unattended-upgrades` never reboots. No fail2ban (low priority) (MH:2792-2794).
- **Status:** Open as of 09-22.

**V-15 wg-easy admin UI bound to `0.0.0.0:51821`**
- **Facts:** Protected only by the security group. Changing the binding restarts the VPN and needs approval (MH:1837).
- **Status:** Open hardening item.

**V-16 Kuma SSH tunnel drops with `Connection reset by peer`**
- **Facts:** Transient. Reopen with `ServerAliveInterval=20`, `ServerAliveCountMax=6` and `TCPKeepAlive=yes`. Verify the box with `ssh vpn-box 'uptime'` (MH:1870; SK-WG:65).

**V-17 VPN throughput is about 10x slower than without it**
- **Date:** Measured 2026-09-29.
- **Facts:** 11.3 vs 116 Mbps down; about 100 ms extra RTT. The t4g.micro is the likely cause (not confirmed against metrics).
- **Workaround:** Split-tunnel by narrowing `AllowedIPs`. You cannot add routes, because the WFP kill-switch blocks it (VPNm:25).
- **Status:** Accepted ("fine for browsing/API").

**V-18 Exit IP is an AWS datacenter address**
- **Facts:** It passes country checks; it would fail any vendor that blocks hosting-provider networks (VPNm:23).

**V-19 wg-easy first-run wizard needs a browser**
- **Facts:** No API path was found. The user completed it (VH:17; VCL:89-93; VPNm:17). Peers are created in the browser only (V-03; section c).

**V-20 Kuma operational quirks**
- `ubuntu` is not in the docker group, so use `sudo`.
- The compose project name is `ubuntu`, so run compose from `~` or pass `-p`.
- The image is pinned by tag and digest (MH:1833; UCY:7-13, UCY:17).
- Database access: `sudo docker exec uptime-kuma mariadb -u root --socket=/app/data/run/mariadb.sock kuma`. `interval` is a reserved word (MH:3241-3245).
- `/api/push/` is allowed only from the DealerPulse droplet, 146.190.132.236 (NGX:96-110; MH:2778).

### E. Tooling and agent-process gotchas

**T-01 The classifier blocks whole categories**
- Blocked: secret/token creation (IAM role, Cloudflare token), writes to shared resources (even a mocked "purge" string), and remote installs/writes.
- **After the first denial, do not retry or reword.** Restructure to read-only, or hand the exact step to the user (CRED:11-21; CF:146; MH:1823).

**T-02 Windows and AWS CLI quirks**
- `fileb://`/`file://` blob parameters fail under Git Bash; pass the content base64-encoded instead (VCL:66; VH:15).
- Git Bash rewrites absolute paths in SSM JSON; use relative paths or `MSYS_NO_PATHCONV=1` (CL:3007-3009).
- With `MSYS_NO_PATHCONV=1`, `file:///c/...` is unreadable (CL:3073-3075).
- `\|` or `\[` inside SSM JSON is an invalid escape; use `grep -E 'a|b'` / `grep -F` (CL:2949-2951, CL:3010-3011).
- The SSM script runs in **sh, not bash**, so `${k:0:60}` silently fails; use `cut` (CL:2925-2926).
- Foreground `sleep` is blocked; poll with an `until` loop (CL:2952-2954).
- No python or node on the laptop (CL:2955-2956).
- `get-command-invocation` has no timestamp; use `aws ssm list-commands --command-id <id> --query 'Commands[0].RequestedDateTime'` (MH:2591-2593).
- Stopping a Bitbucket run does not cancel an SSM command already sent (HO:116).

**T-03 ocean and Redis specifics**
- Trigger tasks with `celery -A coresite call ...`, not `manage.py shell` (circular import) (CL:2869-2874).
- When polling a warm, `sleep 10`; coronanissan is processed last (CL:2875-2877).
- `inventory:v*` also matches `inventory:vin:*` (CL:2878-2879).
- There is one Redis DB per rooftop (2/6/11/12); db1 is always empty (CL:2916-2921).
- There are two Redis instances; do not conflate them (CL:2922-2923).
- `manage.py` is at `/app/server/manage.py` (CL:2924).

**T-04 AWS CLI session expiry**
- Expiry has repeatedly blocked live verification (CB:191; OCP:48; MH:1837). Report the gap; do not infer around it.

**T-05 No browser automation tool in this environment**
- Sources: VH:17; CF:80.

### F. Fluten RDP box (93.127.140.109, RDP on port 10025)

**R-01 Browsing on the RDP box is very slow**
- **Date:** Measured 2026-09-29.
- **Root cause:** CPU starvation: 1 core, about 27x slower than a laptop, from host contention. The network is excellent (181 Mbps, 3 ms to the site).
  - The tell: `Request sent` takes 35.73 ms vs 0.23 ms on the laptop.
  - The site and origin are healthy (raw fetch 31 ms vs 1,820 ms in Edge) (RDP:10-27; HO:140).
- **Fix:** A bigger box (at least 4 vCPU and 8 GB).
- **Status:** Accepted. **Do not re-diagnose as a network problem.**
- **Techniques:**
  - Relay scripts through the RDP clipboard.
  - `Invoke-WebRequest` is useless for throughput tests.
  - `HttpClient` is not loaded in PowerShell 5.1 (RDP:19).
- **Prompt:** "Websites are slow on the RDP box."

---

## (a) Routine health sweep, as actually performed (all read-only)

**2026-09-25 (CL:2881-2928; results MH:3133-3197).** These are logged verbatim except the brace shorthand: `{A,B}` in the log means one call per metric `[assumed]`.
```
aws sts get-caller-identity
aws cloudwatch describe-alarms --region us-west-2 --query 'sort_by(MetricAlarms,&AlarmName)[].{Name:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp,Actions:length(AlarmActions),On:ActionsEnabled}'
aws elbv2 describe-target-groups --region us-west-2 --query 'TargetGroups[].TargetGroupArn'
aws elbv2 describe-target-health --region us-west-2 --target-group-arn <each>
aws cloudwatch get-metric-statistics --region us-west-2 --namespace AWS/ApplicationELB --metric-name <RequestCount|HTTPCode_ELB_5XX_Count|HTTPCode_Target_5XX_Count|HTTPCode_Target_4XX_Count|TargetConnectionErrorCount> --dimensions Name=LoadBalancer,Value=app/dealerpulse-alb/dc80177beaa3aa2f --period 86400 --statistics Sum
aws cloudwatch get-metric-statistics ... --metric-name TargetResponseTime --extended-statistics p50 p99 p100
aws cloudwatch get-metric-statistics ... --metric-name HTTPCode_Target_5XX_Count --period 3600   # find the hour
aws cloudwatch list-metrics --region us-west-2 --namespace CWAgent --metric-name mem_available_percent
aws cloudwatch get-metric-statistics --region us-west-2 --namespace CWAgent --metric-name mem_available_percent --dimensions Name=InstanceId,Value=i-03efb82c808863f84 --period 86400 --statistics Minimum Average   # 10 days
aws ssm send-command --region us-west-2 --instance-ids i-03efb82c808863f84 --document-name AWS-RunShellScript --parameters file://.../mem.json   # free -m, docker stats, df
aws ssm send-command --region us-west-2 --instance-ids i-061291ea974c4ea1b --document-name AWS-RunShellScript --parameters file://.../{nodea,r2,r5,r6,r7,r8}.json
aws ssm get-command-invocation --region us-west-2 --command-id <id> --instance-id <id>
```
- **What was checked on the box** (exact JSON contents not logged):
  - Redis DBs 2/6/11/12 hold exactly the four key families and one `inventory:v3:<hash>` blob each.
  - The `inventory:sync_meta` TTL is close to 72,000 s.
  - Worker logs show `ttl=72000 ... failed_dealerships=0`.
  - The JD Power warm shows `vins=N enriched=N failed=0`.
  - `docker stats` on integration (MH:3149-3153, MH:3172-3182).
- **Interpretation rule:** 5xx clustered on recent container start times are deploy artefacts (MH:3156-3160).

**2026-10-01 error sweep (CL:2930-2945; results MH:3248-3317):**
```
aws cloudwatch describe-alarms --region us-west-2
aws cloudwatch describe-alarm-history --region us-west-2 --alarm-name dealerpulse-alb-latency-p99 --history-item-type StateUpdate --max-records 4
aws cloudwatch get-metric-statistics --region us-west-2 --namespace AWS/ApplicationELB --metric-name <RequestCount|HTTPCode_ELB_5XX_Count|HTTPCode_Target_5XX_Count|TargetConnectionErrorCount|UnHealthyHostCount> --dimensions Name=LoadBalancer,Value=app/dealerpulse-alb/dc80177beaa3aa2f --period 86400 --statistics Sum
aws cloudwatch get-metric-statistics ... --metric-name HTTPCode_Target_5XX_Count --period 3600
aws ssm send-command --region us-west-2 --instance-ids <nodeA|nodeB|integration> --document-name AWS-RunShellScript --parameters file://.../{err,pg,d3,na}.json
```
- **On-box (as described):**
  - `docker logs` for every container over 24 h, grepped for `ERROR|CRITICAL|Traceback|Exception`.
  - Restart counts, OOM kills (`docker inspect`, `dmesg`), `docker system df`, `free`, `df`.
  - Postgres log check: `current transaction is aborted` count (expect 0) (MH:3250-3252, MH:3284).

**2026-10-05 start-of-week sweep (MH:3516-3583; no COMMAND_LOG entry, so the commands are not verbatim). Items covered:**
1. All 7 alarms, and the last state change.
2. 72 h ALB requests, ELB and target 5xx, localised by hour.
3. **428 canary for the last hour per node.**
4. External render check: Puente Hills `/faqs/` size and question count; same for Surf City.
5. `free -m` and disk on all three VMs.
6. Running ocean digest compared with `origin/main-migrated` HEAD (RepoDigests method, CL:3003-3006).
7. **chat_back:**
   - `docker inspect` command array, to see `--workers`.
   - Repo `git status` clean, and the commit.
   - `docker-compose.yml:5`.
8. chat_back logs for OpenRouter and `chat_service` errors.
9. Beat and worker logs: `sync-podium-reviews`, HomeNet warm `refreshed_dealerships=4`, failed `book_request_e_price_lead_vinsolutions` tasks.

**Standard daily routine (HO:130) and commands (HO:154-171):**
- Read-only, about 15 minutes. Covers:
  - alarm states
  - ALB 5xx and target health
  - `docker ps` restart counts and `free -m` on all three VMs
  - the 428 count on `nisanwebsite-web-1` over the last hour
  - integration swap
  - certificate expiry
  - dashboards over a short window
- Additional items from the pack's RUNBOOKS: chatbot 402 errors and chat_back `--workers`.
- Key commands:
  - `aws cloudwatch describe-alarms --query "MetricAlarms[].[AlarmName,StateValue]" --output table`
  - `aws ssm start-session --target <id>`
  - `docker ps --format '{{.Names}}\t{{.Status}}'; free -m; df -h /; docker stats --no-stream`
  - `sudo grep -c ' 428 ' /var/log/nginx/access.log` (nginx is UTC; container logs are +0500)
  - Lockdown check: `curl -m 5 -sS https://184.32.92.25/ -k` (should time out from outside AWS).
- SSM rule: put commands in a JSON file and use `--parameters file://`; never inline `$(...)` (CLAUDE.md §5).

## (b) Cloudflare operational gotchas (all [doc])

**Debug order for anything odd** (CF:94):
1. Security group or prefix-list drift.
2. The extension-based static cache rule.
3. The HSTS window.
4. Hotlink protection.
5. Only then, application bugs.

**Settings and rules:**
- Admin, chat and leads are proxied, and the integration SG accepts only Cloudflare prefix lists.
  - Direct EIP access times out *by design*.
  - Prefix-list drift would show as sporadic 522/524 errors (CF:15-22).
- HSTS `max_age=300`: for 5 minutes after an HTTPS problem, browsers refuse plain HTTP. This was a deliberate, conservative first step (CF:27-30).
- The static-asset rule matches by **file extension**, so images in the `public/` folder on `phn.` can be stuck for 30 days (CF:32-34).
- "Cache Everything [Template]" **must stay disabled**. If enabled, it could serve one user's or tenant's page to another (CF:35).
- The HTML cache rule excludes the RSC headers (`rsc`, `next-router-state-tree`, `next-router-prefetch`, `next-url`). **Do not remove them.** If a page shows raw JSON, check the exclusions and purge (CF:46-50).
- `strip_set_cookie` lives in the `http_response_cache_settings` phase and may not be visible in the dashboard; verify via the API (CF:48, CF:72).
- Hotlink protection can break social-media link previews and partner image pulls (CF:41-44).
- The WAF Managed Ruleset is in Block mode. Watch Security Events for false positives on admin login and API POSTs (CF:60, CF:69).

**Country rule:**
- The allowlist is US/CA/PK/JP, zone-wide including `api.`, with the ACME path exception.
- The rule is a **full-replace PUT**, so always resubmit the whole list.
- If Cox/xtime callbacks stop, check Security → Events first (CF:61, CF:65, CF:106, CF:112-114).

**Vendor-callback risk:** Minimum TLS is 1.2. A vendor that goes silent may be on TLS 1.0/1.1; the rollback is to PATCH it back to 1.0 (CF:96-102).

**Tokens and permissions:**
- Editing an existing token in the dashboard does not persist; create a new one.
- Custom rules need "Zone WAF Write".
- Never trust the permissions summary screen; test with an API call (CF:55-57).
- Agents cannot mint tokens or call purge; the user does these in the dashboard (CF:146; CRED).
- Ask the user for a token each session; it is never stored (CF:11).
- Deploy-purge tokens: `CF_API_TOKEN_CALLNOW_US` and `CF_API_TOKEN_PUENTEHILLS` (names only) (CF:152).

**Caching behaviour:**
- Cloudflare ignores query strings in the cache key. To force a MISS, use a random *path* such as `/origin-probe-<rnd>` (CF:156; RDP:25).
- `/api/*` can never be edge-cached, because every response is encrypted with a fresh nonce. Whether to exempt `/api/public/` is an open question for the developers (CF:84).
- Stickiness versus HTML caching: keeping `strip_set_cookie` is a user decision. Stickiness is off and must stay off (CF:142-144, CF:154; HO:67).
- Automatic `purge_everything` runs after every deploy (Free plan, so there is no per-host purge). After a merge the site is slower from Pakistan; this is expected (CF:152-161).
- After the 428 incident, Cloudflare may hold pages rendered while broken; purge the zone (MH:3398-3399).
- A single transient 502 right after a rule change is an edge propagation blip; retry (CF:114).

**Other:**
- Auto Minify does not work on this zone. Rocket Loader was deliberately not enabled (risk of breaking page hydration) (CF:39, CF:76).
- The puentehillsnissan.com zone is in another account. It must be orange-cloud (proxied) with SSL mode "Full", never "Flexible" (CF:120-132).
- `uptime.callingyounow.us` uses a self-signed origin cert, so SSL mode must stay **Full** until an Origin Certificate replaces it (NGX:1-3; MH:2743).
- The www.puentehillsnissan.com vhost points at a self-signed *test* cert (`phn-test.crt`); noticed but not investigated (CF:140).

## (c) VPN and Kuma operating procedures

**Add a VPN peer** (MH:2931; SK-WG; RUNBOOKS §6):
1. Check `curl -s https://checkip.amazonaws.com`. If it returns 44.225.91.181 you are on the VPN: use alias `wg-ui-vpn`. Otherwise use `wg-ui`.
2. Make sure local port 51821 is free.
3. Run `ssh -N wg-ui[-vpn]`.
4. Verify `curl -s -o /dev/null -w "%{http_code}" http://localhost:51821/` returns **302**.
5. Open **`http://localhost:51821` only.** Never the IP: key generation uses `crypto.subtle`, which needs localhost or HTTPS. Do not set `INSECURE=true`.
6. The **user** creates the client in the UI; agents never generate the private key.
7. Set `PersistentKeepalive = 25` and name the peer after the person.
8. Fix the `Endpoint` to `44.225.91.181:51820`, because the stored host is the dead 44.242.4.12.
- Do not restart wg-easy while connected; you risk locking yourself out.

**Allowlist a new IP (SSH plus Kuma dashboard)** (SK-UIP; MH:3058-3068):
1. Run `aws ec2 authorize-security-group-ingress --group-id sg-020165aeddafe5322 --protocol tcp --port 22 --cidr <IP>/32`. Check `describe-security-group-rules` for duplicates first.
2. On the box, add `allow <IP>;` to **`/etc/nginx/sites-enabled/uptime.callingyounow.us`** (a regular file; keep `sites-available` in sync).
3. Put the backup in **`/etc/nginx/backups/`, not `sites-enabled/`** (the skill still gets this wrong).
4. Run `nginx -t`, then `systemctl reload nginx`. A failed reload keeps the old config serving.
5. Verify both changes (the SG rule and the nginx line).
- If the remote write is classifier-blocked, hand the script to the user.
- Durable alternative: being on the VPN gives dashboard access, because the exit IP is allowlisted (MH:3060), and SSH works via 10.8.0.1 (MH:2925).
- IPv6 `/64` prefixes change often, which is why literal allowlists fail (MH:2770).

**Reach Kuma:**
- `ssh -i ~/.ssh/team-vpn -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181`, then http://localhost:3001.
- Or alias `kuma-vpn` while on the VPN.
- Or `https://uptime.callingyounow.us` from an allowlisted IP or via the VPN (MC:3-7; MH:2929; HO:94).
- Never publish 3001 on `0.0.0.0` (UMS:42; MH:2927).

**Add a monitor** (MC; UMS):
- Defaults: retries 3, interval 60 s (MC:10).
- HTTP(s) monitors accept `200-299`. Use `200-399` for redirecting hosts (phn, api) (MC:14-20, MC:28-33).
- Keyword: the rooftop's **street address**, not its name (UMS:54-58). Add a row for each new tenant (MC:26).
- Certificate expiry notification: threshold 21 days (MC:41-45).
- Notification: the Slack webhook for `#aws-alerts-dealerpulse`, applied as the default (MC:61-65).
- Push monitor for beat: only when doing the single-beat change. Its interval needs recalculating, since the TTL is now 20 h (MC:47-53).
- Do not add per-node direct checks; that needs a production SG change (MC:55-57; UMS:72-74).
- **Domain expiry** (MH:3236-3239):
  - type `json-query`, interval 36000 s, maxretries 2, accepted 200-299
  - `json_path` = `$floor(($toMillis(events[eventAction='expiration'].eventDate) - $millis()) / 86400000)`, operator `>`, expected `30`
  - Use the correct registry URL per TLD: .us `https://rdap.nic.us/domain/<d>`; .com `https://rdap.verisign.com/com/v1/domain/<d>`
  - Keep `domain_expiry_notification` off.
  - Do not edit the Kuma database directly.
- **New public status page:** add its slug as `=`/`^~` locations. Do **not** widen `location /` (NGX:70). `^~ /api/status-page/health` also exposes any slug beginning "health" (NGX:77).

## (d) Cost-related decisions

**2026-10-03 cost cleanup** (MH:3491-3514; CL:3013-3050). Context: the September bill was $210.04 and October was estimated at about $242, because nodeA and nodeB are t3.large for the whole month (report at `records\Migration\AWS_Cost_Report_Sep-Oct_2026.pdf`). The user asked for three small cleanups:
1. **Released idle EIP 34.210.45.11** (`eipalloc-03513392a6fcc0de0`), about $3.72/month. Not recoverable.
2. **ECR lifecycle policies on all 5 repos** (previously none; 26.7 GB stored, 8.6 GB-month billed).
   - Rules: protect `latest*` and `pre-*`; keep the last 10 per dealership stream; keep the last 10 other builds (30 for website-frontend); expire untagged images after 7 days, **except chat-backend**.
   - Why: gotcha 16 — the keep-N windows count images already claimed by higher-priority rules. Gotcha 17 — chat-backend uses OCI indexes, so its untagged children must not expire.
   - Previewed before applying. JSON is in `Migration\ecr-lifecycle\`.
3. **VPN snapshots NOT changed; the user decides.** They are the only backup of the wg-easy peers. Removing them saves at most $0.75/month, realistically $0.20-0.40. Correction to the cost report: the VPN box has its own policy, not the dealerpulse one.

**October capacity plan** (OCP; status "DRAFT — awaiting approval", OCP:3):
- Phase 0: attach `CloudWatchAgentServerPolicy` and take a baseline.
- Phase 1: bound Redis at 512 MB with `volatile-lru`; single beat with an alarm; recreate the fd alarm; add memory alarms.
- Phase 2: resize nodeA, nodeB and integration to **m7i.large**, nodeB first, then 50/50 weights. Integration last, in a window: it is a full outage.
- Phase 3: tenant-launch inputs.
- Phase 4: SSR hairpin, RDS, shared ISR cache, `pages/null`.
- Estimated cost: about +$70/month compute (+46%), from about $152 to about $222. About $44 of that is the integration VM (OCP:196-205).
- Graviton `m7g.large` is cheaper but needs arm64 builds; "not before 5 October" (OCP:113, OCP:207).
- Outcome:
  - Graviton was tested on 10-06 and **dropped by user decision** (MH:3598).
  - The nodes were still t3.large and integration still t3.medium as of 10-03 (MH:3493-3494; HO:76-78). The m7i resize is not recorded as done.

**Other cost notes:**
- t4g.micro was chosen for the VPN as cheaper than t3.micro (VH:9).
- Kuma was placed on the existing VPN box rather than a new instance; the accepted consequence is that the box carries two jobs (MH:1813-1815).
- `dealerpulse-tg-nginx` health checks cost about nothing (MH:3045-3047, MH:3141-3145).
- Datadog: ask for a budget ceiling; log and custom-metric billing is the risk (CB:81).
- RDP box: a bigger box is the real fix (RDP:17).
- VPN throughput: sizing up is an option (VPNm:25).

## (e) Decisions explicitly made by the user (do not reverse)

1. **Cloudflare country allowlist** applies zone-wide including `api.`, accepting the Cox/xtime callback risk. US/CA/PK, then JP added on 09-09. Keep the ACME exception (CF:61, CF:65, CF:106, CF:114; STATUS.md:29).
2. **WAF Managed Ruleset straight to Block**, no log-only trial (CF:60).
3. **Minimum TLS 1.2**: "go ahead and fix anything that breaks after" (CF:98).
4. **Keep `strip_set_cookie`.** ALB stickiness stays defeated, OFF, and must stay off (CF:142-144, CF:154; HO:67).
5. **Do not retune CloudWatch alarms to silence noise.** The thresholds were deliberately set on 09-14 (HO:124; CB:105-107).
6. **Keep `dealerpulse-tg-nginx`** as the listener rollback path (MH:3016-3056).
7. **Team VPN: SSH access instead of SSM** (user's choice after the IAM block). "Don't touch existing security groups." The VPN lives in the same account but has its own subnet and SG (VH:7, VH:11; VCL:37-41; MH:1821).
8. **Kuma on the VPN box**, accepting that the box carries two jobs. Kuma's memory ceiling is set so that Kuma dies before the VPN (MH:1813-1815, MH:1831). Kuma stays bound to 127.0.0.1 (MH:2927).
9. **The Kuma `health` status page is public**; the dashboard stays IP-restricted (MH:2772).
10. **Graviton/ARM dropped** (2026-10-06) (MH:3598; STATUS.md:28).
11. **Frontend blue/green not built** ("cost complexity"), so the deploy 502 window is accepted (HO:117).
12. **Legacy Bitbucket pipelines to DigitalOcean stay** until the droplet is decommissioned (deliberate) (CB:57).
13. **Domain registrations are not ours**; renewal is a CTO question (MH:3125-3128).
14. **Pending user decision, do not act on it:** removing the VPN-box snapshots (MH:3510-3514).
15. **Pack-level closed decisions** (outside my source set, from CLAUDE.md and STATUS.md):
    - Django `TIME_ZONE` stays Asia/Karachi.
    - Never rename `dealerpulse-*` resources.
    - Redis stays per-node.
    - No Puente Hills revert pipeline.
    - Do not re-diagnose the RDP box as a network problem (RDP:17).

**Process rules learned (agent-side, from incidents):**
- Do not edit files in deploy directories that are git working trees, and do not write backups there (MH:2493-2495).
- An orphaned-looking resource in this estate is intentional until the command log says otherwise (MH:3054-3056).
- Measure from the affected host before believing a matching bug report (MH:1878; UMS:132).
- Agents do not create WireGuard keys or other credentials (MH:2931; CRED).
